// تدفق الانضمام بموافقة المدير (دفعة 51) — جهة الجهاز الجديد:
//   ١) تسمية الجهاز (إلزامي قبل فتح الكاميرا أو إدخال الرمز).
//   ٢) مسح QR أو إدخال PIN من 6 أرقام.
//   ٣) دفع طلب الانضمام + حالة «بانتظار موافقة المدير…» — حارس صارم:
//      لا سحب لللقطة ولا مساس بالبيانات المحلية قبل الموافقة.
//   ٤) عند الموافقة: ترطيب نظيف كامل ثم الانتقال للشاشة الرئيسية فوراً.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cloud_config.dart';
import '../core/platform_info.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/sync/cloud_join.dart'
    show CloudJoin, CloudJoinException, JoinRequestWatcher, kCloudOpTimeout;
import '../data/sync/device_id.dart';
import 'home_shell.dart';
import 'lock_gate.dart';
import 'qr_pair_scanner.dart' show scanQrPair;

/// نقطة الدخول: تفتح معالج الانضمام التفاعلي كاملاً.
Future<void> startJoinApprovalFlow(BuildContext context, WidgetRef ref) async {
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const JoinApprovalScreen()),
  );
}

class JoinApprovalScreen extends ConsumerStatefulWidget {
  const JoinApprovalScreen({
    super.key,
    this.prefillUrl = '',
    this.prefillWs = '',
    this.prefillToken = '',
    this.startWaiting = false,
  });

  /// عند القدوم من مسح QR جاهز: بعد التسمية يُرسل الطلب مباشرة.
  final String prefillUrl;
  final String prefillWs;
  final String prefillToken;

  /// عند إرسال الطلب مسبقاً من نافذة الحساب الموحدة: يبدأ شاشة الانتظار مباشرة.
  final bool startWaiting;

  @override
  ConsumerState<JoinApprovalScreen> createState() =>
      _JoinApprovalScreenState();
}

enum _JoinStep { naming, method, waiting, done, rejected }

/// (دفعة 65) فاصل الاستطلاع **الثابت** لحالة الموافقة. كان التباعد
/// التصاعدي (15→30→60) يترك المدير ينتظر قراره دقيقة كاملة في أسوأ حال،
/// والاستجابة هنا أهم من توفير الشبكة.
const Duration _pollInterval = Duration(seconds: 4);

/// (إصلاح 2026-09-18 — ممنوع مؤقت انتظار)
/// لا يوجد سقف انتظار لقرار المدير — الاستطلاع مستمر إلى الأبد مع SSE حيّة
/// حتى يوافق المدير أو يرفض أو يلغي العضو يدوياً. هذا يمنع حالة «انتهت
/// مدة انتظار موافقة المدير 2 دقائق بلا رد بينما الطلب ما زال عند المدير».
/// السبب الحقيقي للطلبات المتكررة كان: انتهاء المؤقت يوقف polling عند العضو،
/// فيبقى الطلب pending في Firebase، فيظهر مرة أخرى عند المدير كطلب جديد.

class _JoinApprovalScreenState extends ConsumerState<JoinApprovalScreen> {
  _JoinStep _step = _JoinStep.naming;
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  String _error = '';
  bool _busy = false;
  Timer? _pollTimer;
  // (دفعة 57 — تكملة) قناة SSE على عقدة طلبنا: قرار المدير يصل لحظياً.
  JoinRequestWatcher? _decisionWatcher;
  /// (منع الاستنزاف) قفل يمنع فتح قناة SSE ثانية أثناء إنشاء الأولى.
  bool _sseStarting = false;
  /// (دفعة 65) لحظة بدء الاستطلاع — يُحسب منها سقف الدقيقتين.
  DateTime? _pollStartedAt;
  /// (دفعة 65) قفل إرسال الطلب: يُضبط بعد أول إرسال ناجح ويُحفظ محلياً،
  /// فلا يتكدّس أكثر من طلب حتى لو ضُغط الزر مراراً أو أُعيد فتح الشاشة.
  bool _sentOnce = false;
  /// استُنفدت المحاولات التلقائية — بانتظار تدخّل المستخدم.
  bool _gaveUp = false;
  int _missingCount = 0;
  String _joinUrl = '';
  String _joinWs = 'default';
  String _joinToken = '';

  @override
  void initState() {
    super.initState();
    if (widget.startWaiting && widget.prefillUrl.isNotEmpty) {
      _joinUrl = widget.prefillUrl;
      _joinWs = widget.prefillWs.isEmpty ? 'default' : widget.prefillWs;
      _joinToken = widget.prefillToken;
      _sentOnce = true;
      _step = _JoinStep.waiting;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startPolling();
      });
    }
  }

  @override
  void dispose() {
    _stopDrain();
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  /// (منع الاستنزاف) يوقف كل مصادر الاستهلاك دفعة واحدة: مؤقت الاستطلاع
  /// وقناة SSE — يُستدعى عند التوقف والرفض والفشل النهائي والتدمير.
  void _stopDrain() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _decisionWatcher?.stop();
    _decisionWatcher = null;
  }

  // ---------- خطوة 2أ: مسح QR ----------
  Future<void> _scanQr() async {
    if (_busy) return;
    final data = await scanQrPair(context);
    if (data == null || !mounted) return;
    if (!data.isCloud || data.cloudUrl.isEmpty || data.tok.isEmpty) {
      setState(() => _error = 'رمز QR غير صالح — تأكد أنه رمز دعوة سحابية.');
      return;
    }
    await _sendRequest(
      url: data.cloudUrl,
      ws: data.ws.isEmpty ? 'default' : data.ws,
      tokenOrPin: data.tok,
    );
  }

  // ---------- خطوة 2ب: PIN يدوي ----------
  // (المعمارية الصامتة) لا حقل رابط بعد اليوم: الرابط الرسمي مضمّن،
  // ومساحة عمل المدير تُكتشف تلقائياً من رمز الدعوة نفسه.
  Future<void> _submitPin() async {
    final pin = _pinCtrl.text.trim();
    if (pin.isEmpty) {
      setState(() => _error = 'أدخل رمز الاقتران.');
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      final ws = await CloudJoin.findWorkspaceByInvite(
          backendUrl: url, tokenOrPin: pin);
      if (ws == null) {
        setState(() {
          _busy = false;
          _error = 'رمز الاقتران غير صحيح أو انتهت صلاحيته.';
        });
        return;
      }
      _busy = false;
      await _sendRequest(url: url, ws: ws, tokenOrPin: pin);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e is CloudJoinException ? e.message : '$e';
      });
    }
  }

  /// (3.71.0) حوار التحذير الصريح قبل الانضمام — موافقة أو إلغاء.
  Future<bool> _confirmDestructiveJoin() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded,
            color: Colors.orange, size: 40),
        title: const Text('تحذير: الانضمام للمجموعة'),
        content: const Text(
          'سيتم حذف جميع بياناتك الحالية نهائياً — الحسابات والسندات '
          'والأصناف والمحادثات — ولا يمكن التراجع.\n\n'
          'ستدخل المجموعة نظيفاً تماماً ببيانات المجموعة فقط، وصلاحياتك '
          'يحددها مدير المجموعة.\n\nهل توافق على المتابعة؟',
          style: TextStyle(height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('أوافق — انضم'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // ---------- خطوة 3: دفع الطلب والانتظار ----------
  Future<void> _sendRequest({
    required String url,
    required String ws,
    required String tokenOrPin,
  }) async {
    // (دفعة 65) أرسل **مرة واحدة فقط**. القفل محلي ويُحفظ في الإعدادات،
    // فلا يتكدّس طلب ثانٍ بتكرار الضغط أو بإعادة فتح الشاشة. العقدة
    // السحابية مفتاحها معرّف الجهاز أصلاً (joinRequests/{ws}/{deviceId})
    // فإعادة الإرسال كانت تستبدل الطلب نفسه لا تُنشئ آخر — لكن منع
    // التكرار من الأساس أوفر للشبكة وأوضح للمدير في قائمة الانتظار.
    if (_busy || _sentOnce) return;
    // (3.71.0 — انضمام صارم) تحذير صريح وموافقة صريحة قبل الإرسال:
    // الانضمام يحذف كل بيانات الجهاز الحالية نهائياً ويدخل ببيانات
    // المجموعة فقط — لا انضمام صامت بعد اليوم.
    if (!await _confirmDestructiveJoin()) return;
    _sentOnce = true;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final repo = ref.read(repoProvider);
      await CloudJoin.requestJoin(
        repo,
        backendUrl: url,
        tokenOrPin: tokenOrPin,
        deviceName: _nameCtrl.text,
        workspaceId: ws,
      ).timeout(kCloudOpTimeout);
      // حالة الطلب تُحفظ محلياً ليعرف الجهاز أنه أرسل بالفعل.
      await repo.setSetting(
          'pendingJoin.sentAt', DateTime.now().toIso8601String());
      _joinUrl = url;
      _joinWs = ws;
      Sfx.click();
      setState(() {
        _step = _JoinStep.waiting;
        _busy = false;
        // (منع الاستنزاف) عدّاد نظيف مع كل طلب انضمام جديد.
        _gaveUp = false;
        _missingCount = 0;
      });
      _startPolling();
    } on TimeoutException catch (_) {
      // فشل الإرسال نفسه — نسمح بمحاولة جديدة (لم يصل الطلب أصلاً).
      _sentOnce = false;
      setState(() {
        _busy = false;
        _error = 'انتهت مهلة إرسال الطلب '
            '(${kCloudOpTimeout.inSeconds} ثانية) — تحقّق من الشبكة.';
      });
    } catch (e) {
      _sentOnce = false;
      setState(() {
        _busy = false;
        _error = e is CloudJoinException ? e.message : '$e';
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    // (دفعة 57 — تكملة) SSE أولاً: أي كتابة على عقدة طلبنا (موافقة/رفض
    // المدير) تُفحص فوراً بصفر كمون؛ الاستطلاع يبقى شبكة أمان أبطأ
    // لحالات انقطاع القناة فقط.
    _pollStartedAt = DateTime.now();
    _startDecisionSse();
    _schedulePoll(_pollInterval);
    _pollOnce();
  }

  /// (إصلاح 2026-09-18 — ممنوع مؤقت انتظار)
  /// يجدول الاستطلاع القادم بلا سقف — يبقى ينتظر موافقة المدير إلى الأبد
  /// حتى يوافق أو يرفض أو يلغي المستخدم يدوياً. هذا يحل سببين:
  /// 1) العضو لا يستلم الموافقة: كان المؤقت 2 دقائق يوقف polling بينما
  ///    الطلب ما زال pending عند المدير، فيفشل الربط.
  /// 2) الطلبات المتكررة عند المدير: العضو بعد انتهاء المؤقت كان يعيد
  ///    إرسال نفس الطلب بنفس deviceId فيكتب pending فوق approved، فيظهر
  ///    مرة أخرى كطلب جديد.
  /// الآن لا يوجد إيقاف تلقائي — فقط إلغاء يدوي من المستخدم.
  void _scheduleNextPoll() {
    if (!mounted || _pollStartedAt == null) return;
    // لا يوجد timeout — استمرار إلى الأبد
    _schedulePoll(_pollInterval);
  }

  /// (منع الاستنزاف) يجدول الاستطلاع القادم بتباعد تصاعدي بعد إلغاء أي
  /// مؤقت سابق — فلا تتكدس المؤقتات فوق بعضها بعد كل فشل.
  void _schedulePoll([Duration? delay]) {
    _pollTimer?.cancel();
    _pollTimer = Timer(delay ?? _pollInterval, _pollOnce);
  }


  Future<void> _startDecisionSse() async {
    // (منع الاستنزاف) لا قناة SSE ثانية أبداً: القفل `_sseStarting` يحمي
    // فجوة الـ await بين الفحص والإسناد، فلا تتكرر القناة ولا تُستنزف
    // الشبكة عند كل دورة فشل.
    if (_decisionWatcher != null || _sseStarting) return;
    _sseStarting = true;
    try {
      final repo = ref.read(repoProvider);
      final ourId = await ensureDeviceId(repo);
      if (!mounted || ourId.isEmpty) return;
      final watcher = JoinRequestWatcher(
        backendUrl: _joinUrl,
        workspaceId: _joinWs,
        nodePath: 'joinRequests/${Uri.encodeComponent(ourId)}',
        onRequestsChanged: () {
          if (mounted) _pollOnce();
        },
      )..start();
      _decisionWatcher = watcher;
    } catch (_) {
      // انقطاع القناة ليس قاتلاً — الاستطلاع يبقى شبكة الأمان.
    } finally {
      _sseStarting = false;
    }
  }

  Future<void> _pollOnce() async {
    if (!mounted || _step != _JoinStep.waiting || _busy) return;
    try {
      final repo = ref.read(repoProvider);
      final ourId = await ensureDeviceId(repo);
      final st = await CloudJoin.pollJoinStatus(
        repo,
        backendUrl: _joinUrl,
        deviceId: ourId,
        workspaceId: _joinWs,
      );
      final status = st['status'];
      if (status == 'approved') {
        _missingCount = 0;
        // (منع الاستنزاف) القرار وصل: نوقف المؤقت والقناة قبل الترطيب.
        _stopDrain();
        _joinToken = st['token'] ?? '';
        // (إصلاح حرج 2026-09-18) تثبيت مشاهدة الموافقة قبل الترطيب:
        // صمام أمان إن اختفت عقدة الطلب أثناء التنزيل (نسخ مدير قديمة
        // تحذفها فور إغلاق النافذة، أو تقليم TTL) — يكمل الاستطلاع
        // الانضمام بدل الحكم الخاطئ «حُذف من المدير».
        try {
          await repo.setSetting(
              'pendingJoin.approved', DateTime.now().toIso8601String());
        } catch (_) {}
        await _hydrate();
      } else if (status == 'rejected') {
        _missingCount = 0;
        _stopDrain();
        // (تنظيف) القرار استُهلك: تُحذف عقدة طلبنا من السحابة بعد رؤية
        // الرفض فلا تبقى مخلفات في /joinRequests.
        unawaited(_deleteOwnRequest());
        Sfx.error();
        if (mounted) setState(() => _step = _JoinStep.rejected);
      } else if (status == 'pending' || status == '') {
        _missingCount = 0;
        // (دفعة 65) الطلب ما زال قيد الانتظار — أعد الجدولة بعد 4 ثوانٍ.
        // هذا الفرع هو صمام الحلقة المفقود: بلا إعادة الجدولة كان
        // الاستطلاع ينفّذ محاولتين ثم يتوقف، فيبقى العضو معلّقاً على
        // «بانتظار موافقة المدير…» إلى الأبد إن انقطعت قناة SSE.
        _scheduleNextPoll();
      } else if (status == 'missing' || status == 'expired') {
        // (إصلاح حرج 2026-09-18 — سباق الموافقة/الاختفاء) إن شوهدت
        // الموافقة سابقاً (علم مثبت) فاختفاء العقدة سباق حميد لا فشل:
        // نُكمل الترطيب بالتوكن المحفوظ — اللقطة والدعوة عقدتان مستقلتان
        // لا يمسهما حذف الطلب.
        final saved = await repo.settings();
        final canRecover =
            (saved['pendingJoin.approved'] ?? '').toString().isNotEmpty;
        if (canRecover) {
          final savedToken = (saved['pendingJoin.token'] ?? '').toString();
          if (savedToken.isNotEmpty) _joinToken = savedToken;
          _stopDrain();
          await _hydrate();
          return;
        }

        // ══ (حراسة إضافية 2026-09-29) ══
        // فحص سجل roster السحابي مباشرة: قد يكون المدير وافق وأضاف الجهاز
        // إلى roster قبل أن يرى الاستطلاع حالة approved
        try {
          final approvedInRoster = await CloudJoin.isDeviceApprovedInRoster(
            backendUrl: _joinUrl,
            workspaceId: _joinWs,
            deviceId: ourId,
          );
          if (approvedInRoster) {
            final savedToken = (saved['pendingJoin.token'] ?? '').toString();
            if (savedToken.isNotEmpty) _joinToken = savedToken;
            _stopDrain();
            await _hydrate();
            return;
          }
        } catch (_) {}

        // لا نستسلم من أول استطلاع مفقود: نسمح بما يصل لـ 4 محاولات (16 ثانية)
        // تجنباً لأي تأرجح مؤقت في شبكة الجوال أو سباق خادم
        _missingCount++;
        if (_missingCount < 4) {
          _scheduleNextPoll();
          return;
        }

        // (العضو لا يعلّق أبداً) عقدة الطلب لم تعد موجودة — حُذفت من
        // المدير أو انتهت مهلتها. بلا هذه المعالجة كان الاستطلاع يستمر
        // إلى ما لا نهاية على طلب لا وجود له.
        _stopDrain();
        Sfx.error();
        if (!mounted) return;
        setState(() {
          _busy = false;
          _gaveUp = true;
          _step = _JoinStep.waiting;
          _error = '❌ انتهى طلب الانضمام أو حُذف من المدير — '
              'اطلب رمزاً جديداً من مدير المجموعة.\n'
              'السبب: الطلب غير موجود في /joinRequests (حُذف أو انتهت صلاحيته بعد 10 دقائق من الموافقة/الرفض).\n'
              'الحل: اطلب من المدير إنشاء دعوة جديدة (PIN جديد) وأعد المحاولة.';
        });
      }
    } catch (_) {
      // (دفعة 65) خطأ شبكي عابر: أعد الجدولة بعد 4 ثوانٍ بدل التوقف
      // الصامت — أي انقطاع مؤقت كان يُعلّق العضو نهائياً.
      _scheduleNextPoll();
    }
  }

  // ---------- خطوة 4: الترطيب النظيف — إشعار فوري بلا انتظار ----------
  Future<void> _hydrate() async {
    if (_busy || !mounted) return;
    // ممنوع وقت انتظار عند الموافقة: نظهر «تم الارتباط» فوراً
    if (mounted) {
      setState(() {
        _step = _JoinStep.done;
        _busy = true;
        _error = '';
      });
      Sfx.pair();
      // إشعار فوري صريح
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ تم الارتباط والمزامنة فيما بعد',
              style: TextStyle(fontWeight: FontWeight.w800)),
          backgroundColor: Color(0xFF16A34A),
          duration: Duration(seconds: 3),
        ),
      );
    }
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final repo = container.read(repoProvider);
      await CloudJoin.completeApprovedJoin(
        repo,
        backendUrl: _joinUrl,
        token: _joinToken,
        workspaceId: _joinWs,
      );
      final engine = container.read(syncEngineProvider);
      engine.stop();
      await engine.start();
      container.read(refreshProvider.notifier).state++;
      if (!mounted) return;
      // انتقال فوري للرئيسية بعد الربط — المزامنة تتم في الخلفية
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LockGate(child: HomeShell())),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;
      _stopDrain();
      Sfx.error();
      // رسالة خطأ صريحة وقاطعة توضح السبب والحل — بلا انتظار
      String explicitError;
      final msg = e.toString();
      if (msg.contains('لا توجد نسخة بيانات')) {
        explicitError = '❌ فشل الربط: لا توجد نسخة بيانات للمجموعة في السحابة.\n'
            'السبب: المدير لم يرفع اللقطة أو انتهت صلاحية الدعوة.\n'
            'الحل: اطلب من المدير إنشاء دعوة جديدة.';
      } else if (msg.contains('رمز الدعوة') || msg.contains('غير صحيح')) {
        explicitError = '❌ فشل الربط: رمز الدعوة غير صالح أو منتهي.\n'
            'السبب: $msg\n'
            'الحل: اطلب دعوة جديدة من المدير.';
      } else if (msg.contains('المقاعد') || msg.contains('مقعد') || msg.contains('seat')) {
        explicitError = '❌ فشل الربط: تم استنفاد مقاعد الباقة.\n'
            'السبب: $msg\n'
            'الحل: ترقية الاشتراك أو إزالة جهاز قديم.';
      } else if (msg.contains('شبكة') || msg.contains('الاتصال') || msg.contains('HTTP')) {
        explicitError = '❌ فشل الربط: تعذر الاتصال بالسحابة.\n'
            'السبب: $msg\n'
            'الحل: تحقق من الإنترنت وأعد المحاولة.';
      } else {
        explicitError = '❌ فشل الربط: $msg\n'
            'السبب: خطأ غير متوقع أثناء المزامنة.\n'
            'الحل: أعد المحاولة أو راجع مدير المجموعة.';
      }
      setState(() {
        _busy = false;
        _gaveUp = true;
        _step = _JoinStep.waiting;
        _error = explicitError;
      });
    }
  }

  /// (تنظيف) حذف عقدة طلب الانضمام الخاصة بنا بعد استهلاك القرار (رفض).
  Future<void> _deleteOwnRequest() async {
    try {
      final repo = ref.read(repoProvider);
      final ourId = await ensureDeviceId(repo);
      if (ourId.isEmpty) return;
      await CloudJoin.deleteJoinRequest(
        backendUrl: _joinUrl,
        workspaceId: _joinWs,
        deviceId: ourId,
      );
    } catch (_) {
      // غير حرج: العقدة مُرشَّحة من قائمة الانتظار بحالتها أصلاً.
    }
  }

  /// (منع الاستنزاف) إعادة المحاولة يدوياً بعد استنفاد المحاولات
  /// التلقائية — تُصفّر العدّاد وتستأنف الاستطلاع من جديد.
  void _retryNow() {
    if (_busy) return;
    Sfx.click();
    _missingCount = 0;
    setState(() {
      _gaveUp = false;
      _error = '';
      _step = _JoinStep.waiting;
    });
    _startPolling();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الانضمام إلى مجموعة')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(22),
              shrinkWrap: true,
              children: [
                switch (_step) {
                  _JoinStep.naming => _namingStep(),
                  _JoinStep.method => _methodStep(),
                  _JoinStep.waiting => _waitingStep(),
                  _JoinStep.done => _doneStep(),
                  _JoinStep.rejected => _rejectedStep(),
                },
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: Colors.red.withValues(alpha: .3)),
                    ),
                    child: Text(_error,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 12.5, height: 1.5)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════ خطوة 1: تسمية الجهاز ═══════════
  Widget _namingStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.badge_outlined,
              size: 52, color: AppColors.primaryOf(context)),
          const SizedBox(height: 14),
          const Text(
            'ما اسم هذا الجهاز؟',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            'سيظهر هذا الاسم للمدير عند طلب الانضمام وفي قوائم الأجهزة '
            '(مثال: «كاشير الصالة»، «جوال المبيعات»).',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5, height: 1.6, color: AppColors.text2Of(context)),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _nameCtrl,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'اسم الجهاز',
              prefixIcon: Icon(Icons.devices),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _toMethod(),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _toMethod,
            icon: const Icon(Icons.arrow_back_ios_new, size: 15),
            label: const Text('متابعة'),
          ),
        ],
      );

  void _toMethod() {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'اسم الجهاز مطلوب قبل المتابعة.');
      return;
    }
    Sfx.click();
    setState(() => _error = '');
    // بيانات دعوة جاهزة (قادمة من QR ممسوح مسبقاً)؟ أرسل الطلب فوراً.
    if (widget.prefillUrl.isNotEmpty && widget.prefillToken.isNotEmpty) {
      _sendRequest(
        url: widget.prefillUrl,
        ws: widget.prefillWs.isEmpty ? 'default' : widget.prefillWs,
        tokenOrPin: widget.prefillToken,
      );
      return;
    }
    setState(() => _step = _JoinStep.method);
  }

  // ═══════════ خطوة 2: طريقة الاقتران ═══════════
  Widget _methodStep() {
    final mobile = PlatformInfo.isMobile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.qr_code_scanner,
            size: 52, color: AppColors.primaryOf(context)),
        const SizedBox(height: 14),
        Text(
          'كيف تريد الاقتران يا «${_nameCtrl.text.trim()}»؟',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 18),
        if (mobile) ...[
          FilledButton.icon(
            onPressed: _busy ? null : _scanQr,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('مسح رمز QR'),
          ),
          const SizedBox(height: 12),
          const Row(children: [
            Expanded(child: Divider()),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('أو', style: TextStyle(fontSize: 12)),
            ),
            Expanded(child: Divider()),
          ]),
          const SizedBox(height: 12),
        ],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('إدخال رمز من 6 أرقام',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                // (المعمارية الصامتة) حقل الرابط أُزيل — يكفي رمز الاقتران.
                TextField(
                  controller: _pinCtrl,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  decoration: const InputDecoration(
                    labelText: 'رمز الاقتران (6 أرقام أو رمز الدعوة)',
                    counterText: '',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : _submitPin,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('إرسال طلب الانضمام'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ═══════════ خطوة 3: الانتظار — بلا مؤقت انتظار (إصلاح 2026-09-18)
  // السبب الحقيقي لفشل استلام الموافقة: كان هناك مؤقت 2 دقائق يوقف
  // polling عند العضو بينما الطلب ما زال pending عند المدير.
  // الآن انتظار مفتوح مع SSE لحظي + polling كل 4 ثوانٍ كاحتياط.
  Widget _waitingStep() {
    if (_gaveUp) return _giveUpStep();
    final elapsed = _pollStartedAt == null
        ? 0
        : DateTime.now().difference(_pollStartedAt!).inSeconds;
    final minutes = elapsed ~/ 60;
    final seconds = elapsed % 60;
    return Column(
      children: [
        const SizedBox(height: 20),
        SizedBox(
          width: 64,
          height: 64,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: AppColors.primaryOf(context),
          ),
        ),
        const SizedBox(height: 22),
        const Text(
          'بانتظار موافقة المدير…',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          minutes > 0
              ? 'مضى $minutes دقيقة و $seconds ثانية'
              : 'مضى $seconds ثانية',
          style: TextStyle(
              fontSize: 11, color: AppColors.text3Of(context)),
        ),
        const SizedBox(height: 10),
        Text(
          'وصل طلبك «${_nameCtrl.text.trim()}» إلى جهاز المدير.\n'
          'فور ضغط المدير «قبول وتفعيل» سيظهر «تم الارتباط والمزامنة فيما بعد» '
          'وتنتقل للرئيسية فوراً — المزامنة تتم في الخلفية.\n'
          'لا تغلق التطبيق، وابقَ على هذه الشاشة.',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12.5, height: 1.7, color: AppColors.text2Of(context)),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () {
                _stopDrain();
                setState(() {
                  _step = _JoinStep.method;
                  _sentOnce = false;
                  _error = '';
                });
              },
              icon: const Icon(Icons.close, size: 18),
              label: const Text('إلغاء الطلب'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _pollOnce,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('تحديث الآن'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'تلميح: تأكد أن المدير فاتح «الأجهزة والمستخدمين» ويرى طلبك',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 11, height: 1.5, color: AppColors.text3Of(context)),
        ),
      ],
    );
  }

  /// (إصلاح 2026-09-18 — بلا مؤقت انتظار)
  /// شاشة فشل الترطيب فقط (بعد الموافقة) — تظهر رسالة صريحة قاطعة
  /// توضح السبب والحل. لا تظهر أبداً لانتهاء مهلة موافقة المدير لأن
  /// الانتظار الآن مفتوح بلا سقف.
  Widget _giveUpStep() {
    return Column(
      children: [
        const SizedBox(height: 20),
        const Icon(Icons.cloud_off_outlined, size: 64, color: Colors.redAccent),
        const SizedBox(height: 18),
        const Text(
          'تعذّر تنزيل نسخة المجموعة',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        Text(
          'فشل الربط بعد موافقة المدير. لم يُمسس أي شيء في هذا الجهاز.\n'
          'السبب والحل موضحان في الرسالة الحمراء أدناه.',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12.5, height: 1.7, color: AppColors.text2Of(context)),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _busy ? null : _retryNow,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('إعادة المحاولة'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => setState(() {
            _error = '';
            _gaveUp = false;
            _step = _JoinStep.method;
            _sentOnce = false;
          }),
          icon: const Icon(Icons.qr_code, size: 18),
          label: const Text('إدخال رمز جديد'),
        ),
      ],
    );
  }

  Widget _doneStep() => const Column(
        children: [
          SizedBox(height: 20),
          Icon(Icons.check_circle, size: 64, color: Color(0xFF16A34A)),
          SizedBox(height: 18),
          Text('✅ تم الارتباط والمزامنة فيما بعد',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          SizedBox(height: 8),
          Text('تم ربط جهازك بالمجموعة بنجاح. سيتم مزامنة البيانات في الخلفية.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.6, color: Colors.black54)),
        ],
      );

  Widget _rejectedStep() => Column(
        children: [
          const SizedBox(height: 20),
          const Icon(Icons.cancel_outlined, size: 64, color: Colors.red),
          const SizedBox(height: 18),
          const Text('رفض المدير طلب الانضمام',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            'لم يُمس أي شيء في هذا الجهاز — بياناتك المحلية كما هي. '
            'يمكنك المحاولة مجدداً برمز جديد من المدير.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5, height: 1.6, color: AppColors.text2Of(context)),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => setState(() {
              _error = '';
              _step = _JoinStep.method;
            }),
            child: const Text('إعادة المحاولة'),
          ),
        ],
      );
}
