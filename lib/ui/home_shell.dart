import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/shell_nav.dart';
import '../core/app_version.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/update_installer.dart';
import '../data/update_service.dart';
import 'update_section.dart';
import 'account_form.dart';
import 'accounts_screen.dart';
import 'backup_screen.dart';
import 'currencies_screen.dart';

import 'dart:async';

import 'reports_screen.dart';
import 'settings_screen.dart';
import 'trash_screen.dart';
import 'transactions_screen.dart';
import 'tx_form.dart';
import 'vouchers_screen.dart';
import 'widgets/golden_bell_icon.dart';
import 'sync_ops_screen.dart';
import '../data/sync/sync_service.dart';

import 'notifications_sheet.dart';
import 'app_notice.dart';
import '../core/sfx.dart';
import '../core/keep_alive_service.dart';
import '../data/sync/device_id.dart';
import '../data/sync/sync_engine.dart';
import '../data/sync/sync_activity.dart';
import '../data/repository.dart';
import '../data/sync/cloud_control_service.dart';
import 'trial_ui.dart';
import 'dialogs/sync_resolution_dialog.dart';

/// كل شاشات التطبيق الاثنتي عشرة.
enum AppScreen {
  accounts('الحسابات', Icons.people_alt_outlined, Icons.people_alt),
  transactions('العمليات', Icons.receipt_long_outlined, Icons.receipt_long),
  vouchers('السندات', Icons.receipt_outlined, Icons.receipt),
  reports('التقارير', Icons.bar_chart_outlined, Icons.bar_chart),
  currencies(
    'العملات',
    Icons.currency_exchange_outlined,
    Icons.currency_exchange,
  ),
  trash('سلة المهملات', Icons.delete_outline, Icons.delete),
  activity('سجل النشاط', Icons.history, Icons.history),
  backup('النسخ الاحتياطي', Icons.backup_outlined, Icons.backup),
  syncOps('العمليات المتزامنة', Icons.cloud_sync_outlined, Icons.cloud_sync),
  settings('الإعدادات', Icons.settings_outlined, Icons.settings);

  const AppScreen(this.title, this.icon, this.activeIcon);
  final String title;
  final IconData icon;
  final IconData activeIcon;
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  AppScreen _screen = AppScreen.accounts;

  // (3.70.0) لوحة التحكم مثبّتة كأول شاشة دائمة على كل المنصات —
  // عند الإقلاع وبعد تجاوز شاشة القفل.

  /// الشريط الجانبي المكتبي: مطوي (أيقونات) أو موسّع (أيقونات + عناوين).

  Timer? _syncTimer;
  bool _updatePrompted = false;

  Timer? _greetingTimer;
  DateTime _lastDeliveredNotice = DateTime.fromMillisecondsSinceEpoch(0);

  /// (إصلاح تسليم الإدارة) نبضات نشاط المزامنة → تحديث حي لمزودي
  /// الملكية/الدور/الوضع، فتظهر «إدارة المجموعة» وشاشات الأجهزة فوراً
  /// عند استلام الملكية دون إعادة تشغيل أو تسجيل خروج.
  StreamSubscription<int>? _activityBus;

  /// تجميع النبضات المتتالية بمهلة قصيرة: bump فوري مع كل نبضة كان يطلق
  /// استعلامات المزودين أثناء معاملة كتابة مفتوحة فيقفل قاعدة البيانات
  /// (database locked) — التأجيل يترك المعاملة تكتمل أولاً.
  Timer? _activityDebounce;

  /// هل بانر «نافذة الخطر» ظاهر حالياً؟ (لمنع تكرار الصوت مع كل فحص).
  bool _dangerShown = false;
  bool _dangerSyncing = false; // سبينر «إعادة المحاولة» داخل بانر الخطر.
  DateTime? _dangerSnoozedUntil; // «إخفاء» = غفوة 30 دقيقة لا كتم دائم.

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // (2026-09-24) قناة تنقّل من الشاشات الداخلية (زر الرئيسية).
    ShellNav.request.addListener(_onShellNavRequest);
    _refreshSync();
    _syncTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _refreshSync(),
    );
    _checkForUpdateOnStart();
    _wireSyncNotices();
    _scheduleGreeting();
    _greetingTimer = Timer.periodic(
      const Duration(minutes: 20),
      (_) => _scheduleGreeting(),
    );
    // فُتح التطبيق بالضغط على إشعار خارجي أو بدء مسار الإقلاع التلقائي
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyStartupRouting();
      _consumeNotifyTap();
    });
    // 🔒 إشعارات الفترة التجريبية محذوفة بناءً على طلب المستخدم.
    // (إصلاح تسليم الإدارة) أي دفعة عمليات مطبقة (ومنها نقل الملكية أو
    // تغيير دور) تعيد بناء كل المزودات المشتقة من refreshProvider —
    // الشريط الجانبي والإعدادات يعكسان الصلاحيات الجديدة لحظياً.
    _activityBus = SyncActivityBus.instance.stream.listen((_) {
      _activityDebounce?.cancel();
      _activityDebounce = Timer(const Duration(milliseconds: 400), () {
        if (!mounted) return;
        // إبطال موجّه لمزودي الهوية/الصلاحيات فقط — لا bump شاملاً حتى
        // لا تُفرَّغ قوائم البيانات (العمليات/الحسابات) أثناء إعادة البناء.
        ref.invalidate(isOwnerProvider);
        ref.invalidate(workspaceModeProvider);
      });
    });
    // يقظة المجموعة + أذونات النظام الحقيقية (إشعارات/بطارية).
    _ensureGroupKeepAlive();
    // 🌐 مركز التحكم السحابي والتنبيهات المباشرة والإدارة عن بعد
    CloudControlService.instance
        .startPeriodicHeartbeat(ref.read(repoProvider));
  }

  /// سلوك الإقلاع: دخول مباشر إلى شاشة العملاء — لا واجهة رئيسية.
  Future<void> _applyStartupRouting() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (mounted) setState(() => _screen = AppScreen.accounts);
  }

  /// داخل مجموعة: يشغّل خدمة اليقظة (foreground service) ليستقبل الجهاز
  /// العمليات والإشعارات فوراً حتى والشاشة مطفأة، ويطلب — بنوافذ النظام
  /// الرسمية — إذن الإشعارات (أندرويد 13+) والإعفاء من تحسينات البطارية.
  Future<void> _ensureGroupKeepAlive() async {
    try {
      final repo0 = ref.read(repoProvider);
      final mode = await repo0.workspaceMode();
      final st0 = await repo0.settings();
      // إعداد المستخدم «المزامنة في الخلفية وأثناء السكون» (افتراضي: مفعّل).
      final wantBg = (st0['bgKeepAlive'] ?? '1') != '0';
      final inGroup = mode != 'standalone';
      await NexKeepAlive.setEnabled(inGroup && wantBg);
      if (!inGroup || !wantBg) return;
      // إذن الإشعارات: نافذة النظام مباشرة (لا نافذة مصطنعة).
      if (!await NexKeepAlive.hasPermission(NexKeepAlive.permNotifications)) {
        await NexKeepAlive.requestPermission(NexKeepAlive.permNotifications);
      }
      // الإعفاء من تحسينات البطارية: نافذة النظام الرسمية، مرة واحدة فقط
      // (إن رفض لا نلاحقه في كل إقلاع).
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      if (!await NexKeepAlive.isBatteryExempt() &&
          st['batteryExemptAsked'] != '1') {
        await repo.setSetting('batteryExemptAsked', '1');
        await NexKeepAlive.requestBatteryExempt();
      }
    } catch (_) {
      // اليقظة كمالية — لا تعطل الإقلاع.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // عاد التطبيق للمقدمة بنقرة إشعار خارجي: افتح السجل المقصود فوراً.
    if (state == AppLifecycleState.resumed) {
      _consumeNotifyTap();
      // إعادة تقييم اليقظة (ربما اقترن/غادر مجموعة أثناء عمل التطبيق).
      _ensureGroupKeepAlive();
    }
  }

  /// يستهلك نقرة إشعار النظام (إن وُجدت) ويفتح السجل المرتبط بها.
  Future<void> _consumeNotifyTap() async {
    final tap = await Sfx.takeNotifyTap();
    if (tap == null || !mounted) return;
    await openNotificationEntity(tap['entityType']!, tap['entityId'] ?? '');
  }

  /// نافذة منبثقة داخلية لكل إشعار — تستجيب للضغط: تفتح السجل المرتبط
  /// أو نافذة توضيحية إن لم يكن للإشعار سجل محدد.
  void _showTappableNotice(
    String title,
    String body, {
    String entityType = '',
    String entityId = '',
  }) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        content: InkWell(
          onTap: () {
            messenger.hideCurrentSnackBar();
            if (entityType.isNotEmpty) {
              openNotificationEntity(entityType, entityId);
            } else {
              showAppNotice(
                context,
                title: title,
                message: body,
                kind: AppNoticeKind.info,
                playSound: false,
              );
            }
          },
          child: Row(
            children: [
              const Icon(
                Icons.notifications_active,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    if (body.isNotEmpty)
                      Text(
                        body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left, color: Colors.white70, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  /// يفتح الشاشة/السجل المرتبط بإشعار: عملية مالية → قسم العمليات مع نافذة
  /// تفاصيلها فوراً؛ أنواع أخرى → قسمها المناسب. يعيد false إن لم يكن للنوع
  /// وجهة معروفة (إشعار عام بلا سجل محدد).
  Future<bool> openNotificationEntity(String type, String id) async {
    switch (type) {
      case 'tx':
        _go(AppScreen.transactions);
        final txId = int.tryParse(id);
        if (txId == null) return true;
        final repo = ref.read(repoProvider);
        final tx = await repo.transactionById(txId);
        if (!mounted) return true;
        if (tx == null) {
          await showAppNotice(
            context,
            title: 'العملية غير موجودة',
            message: 'العملية المشار إليها في الإشعار حُذفت أو لم تعد متاحة.',
            kind: AppNoticeKind.warning,
            playSound: false,
          );
          return true;
        }
        final acc = tx.type == OpType.transfer
            ? (tx.fromId == null ? null : await repo.account(tx.fromId!))
            : (tx.accountId == null ? null : await repo.account(tx.accountId!));
        final toAcc = tx.toId == null ? null : await repo.account(tx.toId!);
        if (!mounted) return true;
        await showTxDetails(
          context,
          ref,
          tx: tx,
          account: acc,
          toAccount: toAcc,
        );
        return true;
      case 'account':
        _go(AppScreen.accounts);
        return true;
      case 'voucher':
        _go(AppScreen.vouchers);
        return true;
      case 'message' || 'conversation':
        _go(AppScreen.transactions);
        return true;
      case 'sync':
        _go(AppScreen.syncOps);
        return true;
      case 'user':
        _go(AppScreen.accounts);
        return true;
      case 'cloud_alert':
        await showCloudAlertsSheet(context, ref);
        return true;
      case 'update_download':
        // (2026-09-22) إشعار اكتمال تنزيل التحديث: نقرة تفتح مجلد
        // التنزيلات العام (Download/Nexora) ليصل المستخدم للملف مباشرة.
        await UpdateInstaller.openDownloadsFolder(id);
        return true;
    }
    // نوع بلا وجهة معروفة: نافذة توضيحية بدل تجاهل النقرة.
    if (mounted) {
      await showAppNotice(
        context,
        title: 'إشعار عام',
        message: 'هذا الإشعار لا يقود إلى سجل محدد يمكن فتحه.',
        kind: AppNoticeKind.info,
        playSound: false,
      );
    }
    return true;
  }

  /// ربط أحداث المزامنة بالإشعارات: «تمت مزامنة العملية» عند التسليم،
  /// و«الجهاز متصل» عند عودة قرين — إشعار خارجي بصوت مميز + صوت داخلي.
  void _wireSyncNotices() {
    SyncEngine.onOpDelivered = (opDesc, deviceName0, entityType, entityId) {
      // الاسم الموحد: جهاز بلا اسم يظهر «مستخدم جديد» في كل الإشعارات.
      final deviceName =
          deviceName0.trim().isEmpty ? kDefaultMemberName : deviceName0;
      Sfx.synced();
      // لا نغرق المستخدم: إشعار خارجي واحد كحد أقصى كل 20 ثانية.
      final now = DateTime.now();
      if (now.difference(_lastDeliveredNotice) > const Duration(seconds: 20)) {
        _lastDeliveredNotice = now;
        Sfx.systemNotify(
          title: 'تمت مزامنة العملية',
          body: '$opDesc — وصلت إلى $deviceName بنجاح',
          entityType: entityType,
          entityId: entityId,
        );
      }
      // حدث مالي مهم → يُسجَّل في جدول الإشعارات الداخلية (الجرس) أيضاً.
      try {
        ref.read(repoProvider).notify(
              title: 'تمت مزامنة العملية',
              body: '$opDesc — وصلت إلى $deviceName',
              kind: 'success',
              entityType: entityType,
              entityId: entityId,
            );
      } catch (_) {}
      _showTappableNotice(
        'تمت مزامنة العملية',
        '$opDesc — وصلت إلى $deviceName',
        entityType: entityType,
        entityId: entityId,
      );
    };
    // جهاز عاد للاتصال: حدث تشغيلي عابر — صوت + بانر داخلي فقط،
    // لا يلوث جدول الإشعارات الداخلية (المخصص للمالي والإداري المهم).
    SyncEngine.onPeerJoined = (deviceName0) {
      final deviceName =
          deviceName0.trim().isEmpty ? kDefaultMemberName : deviceName0;
      Sfx.pair();
      _showTappableNotice(
        'جهاز متصل',
        '$deviceName عاد للاتصال — تجري المزامنة الفورية الآن',
        entityType: 'sync',
      );
    };
    // اكتمال المزامنة مع جهاز: حدث تشغيلي عابر — توست سفلي خفيف يختفي
    // وحده، لا يُخزَّن أبداً في جدول notifications الداخلي (قاعدة صارمة).
    SyncEngine.onDeviceSyncComplete = (deviceName0) {
      final deviceName =
          deviceName0.trim().isEmpty ? kDefaultMemberName : deviceName0;
      Sfx.synced();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
            content: Text('تم اكتمال المزامنة مع $deviceName ✅'),
          ),
        );
    };
    // «نافذة الخطر»: تباين خطير محتمل في السجلات — بانر مثبّت أعلى
    // الشاشة يتكرر مع كل فحص حتى تُستعاد سلامة المزامنة، ثم يُزال.
    // البانر قابل للحل مباشرة: زر «إعادة المحاولة والمزامنة فوراً» ينفّذ
    // triggerImmediateSync() مع سبينر داخل البانر، والنجاح يخفيه لحظياً
    // (المحرك يبثّ null فور تفريغ الطابور). «إخفاء» = غفوة 30 دقيقة.
    SyncEngine.onSyncDanger = (message) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (message == null) {
        // زوال الخطر يلغي أي غفوة سارية — الحالة القادمة تبدأ من جديد.
        _dangerSnoozedUntil = null;
        if (_dangerShown) {
          _dangerShown = false;
          _dangerSyncing = false;
          messenger.hideCurrentMaterialBanner();
        }
        return;
      }
      // غفوة سارية (ضغط المستخدم «إخفاء»)؟ نصمت حتى تنقضي الـ 30 دقيقة.
      final snooze = _dangerSnoozedUntil;
      if (snooze != null && DateTime.now().isBefore(snooze)) return;
      _dangerSnoozedUntil = null;
      if (!_dangerShown) Sfx.error();
      _dangerShown = true;
      _showDangerBanner(messenger, message);
    };
    // وصول تنبيه سحابي أو إداري جديد (Broadcast / In-App Alert)
    CloudControlService.instance.onNewAlertReceived = (alert) {
      if (!mounted) return;
      Sfx.systemNotify(
        title: alert.title,
        body: alert.body,
        entityType: 'cloud_alert',
        entityId: alert.id,
      );
      if (alert.isModal) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.campaign_rounded, color: Color(0xFF7C3AED)),
                const SizedBox(width: 8),
                Expanded(child: Text(alert.title)),
              ],
            ),
            content: Text(alert.body),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('حسناً، فهمت'),
              ),
            ],
          ),
        );
      } else {
        _showTappableNotice(
          alert.title,
          alert.body,
          entityType: 'cloud_alert',
          entityId: alert.id,
        );
      }
    };
  }

  /// تحية داخلية موقوتة: «صباح الخير» (5-11:59) و«مساء الخير» (16-21:59)
  /// مرة واحدة لكل فترة يومياً، بصوت هادئ ونافذة منبثقة أنيقة.
  Future<void> _scheduleGreeting() async {
    try {
      // وضع الاختبار الصامت: لا نوافذ تحية تحجب الشاشة وتكسر اختبارات E2E
      // (كانت نافذة «مساء الخير» تفتح فوق الشاشة فتحجب كل النقرات).
      if (Sfx.muted) return;
      final now = DateTime.now();
      final isMorning = now.hour >= 5 && now.hour < 12;
      final isEvening = now.hour >= 16 && now.hour < 22;
      if (!isMorning && !isEvening) return;
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final key = isMorning ? 'lastMorningGreeting' : 'lastEveningGreeting';
      final today = '${now.year}-${now.month}-${now.day}';
      if (st[key] == today) return;
      await repo.setSetting(key, today);
      final title = isMorning ? 'صباح الخير' : 'مساء الخير';
      final msg = isMorning
          ? 'صباح الخير! نتمنى لك يوماً موفقاً ودفاتر موزونة.'
          : 'مساء الخير! نتمنى لك أمسية هادئة وحسابات رابحة.';
      // صوت هادئ عبر إشعار النظام + نافذة داخلية أنيقة.
      Sfx.systemNotify(title: title, body: msg, peaceful: true);
      if (!mounted) return;
      await showAppNotice(
        context,
        title: title,
        message: msg,
        kind: AppNoticeKind.info,
        playSound: false,
      );
    } catch (_) {
      // التحية كمالية — لا تعطل شيئاً.
    }
  }

  /// 🔒 دورة حياة الفترة التجريبية على الشاشة الرئيسية:
  /// (دفعة 58 — متطلب 12) «الجديد في هذا التحديث» الديناميكي:
  /// يُعرض مرة واحدة فقط بعد كل ترقية فعلية (تغيّر kAppVersion عن آخر
  /// إصدار شوهد)، وبملاحظات هذا الإصدار حصراً — تُقرأ من بيان التحديث
  /// عندما يطابق رقمه إصدارنا المثبَّت، فلا يظهر أي نص قديم أبداً.
  Future<void> _maybeShowWhatsNew(UpdateInfo info) async {
    final repo = ref.read(repoProvider);
    final st = await repo.settings();
    // (3.70.0+133) المفتاح مربوط برقم البناء: إعادة نشر نفس الإصدار
    // ببناء أحدث (+132 ← +133) تستحق تنبيه «ما الجديد» أيضاً — لا فقط
    // عند تغيير الإصدار التسويقي (كانت الأجهزة المثبَّت لها نفس الرقم
    // لا ترى أي إشعار رغم تغيّر محتوى الحزمة).
    const buildKey = '$kAppVersion+$kAppBuild';
    final seen = (st['whatsNewSeenVersion'] ?? '').trim();
    if (seen == buildKey) return; // عُرض لهذا البناء من قبل.
    // أول تثبيت (لا قيمة سابقة): سجّل بصمت بلا حوار.
    if (seen.isEmpty) {
      await repo.setSetting('whatsNewSeenVersion', buildKey);
      return;
    }
    // ملاحظات البيان تخص أحدث إصدار منشور — نعرضها فقط إن كانت نسختنا
    // (إصداراً وبناءً) هي ذاتها الأحدث (ترقية اكتملت للتو).
    final latest = info.latest;
    final isCurrentRelease = latest != null &&
        '${latest.major}.${latest.minor}.${latest.patch}' == kAppVersion &&
        latest.build == kAppBuild;
    await repo.setSetting('whatsNewSeenVersion', buildKey);
    if (!isCurrentRelease || info.notes.trim().isEmpty) return;
    if (!mounted) return;
    await showWhatsNewDialog(context, kAppVersion, info.notes);
  }

  /// فحص تحديث صامت عند الإقلاع: لا يزعج المستخدم إلا إذا وُجد تحديث فعلًا،
  /// ولا يظهر الحوار الاختياري أكثر من مرة واحدة في اليوم.
  Future<void> _checkForUpdateOnStart() async {
    if (_updatePrompted) return;
    _updatePrompted = true;
    try {
      final repo = ref.read(repoProvider);
      final info = await ref.read(updateServiceProvider).check();
      if (!mounted) return;
      // «الجديد في هذا التحديث» بعد اكتمال ترقية — قبل أي حوار تحديث آخر.
      try {
        await _maybeShowWhatsNew(info);
      } catch (_) {}
      if (!mounted || !info.hasUpdate) return;
      if (!info.isMandatory) {
        // كتم الحوار الاختياري 24 ساعة بعد آخر عرض/تأجيل — **إلا** إذا
        // نُشر بناء أحدث منذ الكتم: كل بناء جديد يستحق تنبيهاً فورياً
        // مرة واحدة (كان الجهاز الذي حدّث اليوم لا يرى بناء الغد إلا
        // بعد 24 ساعة).
        final st = await repo.settings();
        final last = DateTime.tryParse(st['lastUpdatePrompt'] ?? '');
        final lastBuild = (st['lastUpdatePromptBuild'] ?? '').trim();
        final latestKey = info.latest?.toString() ?? '';
        if (last != null &&
            lastBuild == latestKey &&
            DateTime.now().difference(last) < const Duration(hours: 24)) {
          return;
        }
        await repo.setSetting(
          'lastUpdatePrompt',
          DateTime.now().toIso8601String(),
        );
        await repo.setSetting('lastUpdatePromptBuild', latestKey);
      }
      if (!mounted) return;
      await showUpdateDialog(context, ref, info);
    } catch (_) {
      // الفحص الصامت لا يجب أن يعطّل الإقلاع أبدًا.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _greetingTimer?.cancel();
    _activityBus?.cancel();
    _activityDebounce?.cancel();
    if (SyncEngine.onOpDelivered != null) SyncEngine.onOpDelivered = null;
    if (SyncEngine.onPeerJoined != null) SyncEngine.onPeerJoined = null;
    if (SyncEngine.onPermissionsChanged != null) {
      SyncEngine.onPermissionsChanged = null;
    }
    SyncEngine.onDeviceSyncComplete = null;
    SyncEngine.onSyncDanger = null;
    ShellNav.request.removeListener(_onShellNavRequest);
    CloudControlService.instance.stop();
    super.dispose();
  }

  void _refreshSync() {
    final repo = ref.read(repoProvider);
    final engine = ref.read(syncEngineProvider);
    if (!engine.hasStarted) engine.start();
    // (2026-09-24) أُزيلت شارة المزامنة المكرّرة من الشريط؛ نُبقي الاستعلام
    // الدوري (يهيّئ حالة المزامنة) بلا تخزين نتيجته — لا مستهلك لها بعد الآن.
    unawaited(_safeSyncStatus(repo, engine));
  }

  /// (3.71.0+136) درع سباق الإغلاق: تحديث دوري قيد الطيران قد يكتمل بعد
  /// التفكيك وإغلاق القاعدة — database_closed يُبتلع ويعاد وضع خامد صامت
  /// بدل خطأ غير معالج خارج النطاق غير المتزامن (أسقط شارد CI رغم خضرة محلية).
  Future<SyncStatusInfo> _safeSyncStatus(Repo repo, SyncEngine engine) async {
    try {
      return await SyncService(repo: repo, engine: engine).status();
    } catch (_) {
      return const SyncStatusInfo(
        state: SyncState.offline,
        pending: 0,
        failed: 0,
        cloudConfigured: false,
      );
    }
  }

  /// فحص تحديث التطبيق يدوياً (زر التحديث بسطح المكتب): يجري بالخلفية
  /// وعند توفر إصدار أحدث يظهر إشعار فوري بزر يقود لشاشة الإعدادات
  /// (قسم التحديث). الفشل صامت — الفحص الدوري يغطي لاحقاً.
  bool _updateCheckBusy = false;
  Future<void> _checkForAppUpdate() async {
    if (_updateCheckBusy) return;
    _updateCheckBusy = true;
    try {
      final info = await UpdateService().check();
      if (!mounted) return;
      if (info.hasUpdate) {
        Sfx.notify();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 8),
            content: Text(
              '🚀 يتوفر إصدار أحدث: ${info.latest} — التحديث من الإعدادات',
            ),
            action: SnackBarAction(
              label: 'فتح',
              onPressed: () => _go(AppScreen.settings),
            ),
          ),
        );
      }
    } catch (_) {
      // صامت — لا نزعج المستخدم بفشل فحص خلفي.
    } finally {
      _updateCheckBusy = false;
    }
  }

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// يعرض بانر التحذير المصغّر الأنيق وغير المزعج.
  void _showDangerBanner(ScaffoldMessengerState messenger, String message) {
    final syncing = _dangerSyncing;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    messenger
      ..hideCurrentMaterialBanner()
      ..showMaterialBanner(
        MaterialBanner(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          backgroundColor: isDark
              ? const Color(0xFF2D1E0F)
              : const Color(0xFFFFFBEB),
          leading: syncing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFD97706),
                  ),
                )
              : const Icon(
                  Icons.warning_amber_rounded,
                  color: Color(0xFFD97706),
                  size: 20,
                ),
          content: InkWell(
            onTap: () {
              messenger.hideCurrentMaterialBanner();
              _dangerShown = false;
              SyncResolutionDialog.show(context);
            },
            child: Text(
              syncing
                  ? 'جارٍ إعادة المحاولة ودفع العمليات المعلّقة…'
                  : (message.isNotEmpty
                      ? message
                      : 'تنبيه مزامنة: توجد عمليات معلقة لم تكتمل بعد'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isDark
                    ? const Color(0xFFFDE68A)
                    : const Color(0xFF92400E),
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'مزامنة الآن',
              icon: const Icon(Icons.sync_rounded, size: 18),
              onPressed: syncing ? null : () => _dangerRetryNow(messenger),
            ),
            TextButton(
              onPressed: () {
                messenger.hideCurrentMaterialBanner();
                _dangerShown = false;
                SyncResolutionDialog.show(context);
              },
              child: const Text(
                'عرض التفاصيل والحلول',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 11.5,
                ),
              ),
            ),
            IconButton(
              tooltip: 'إخفاء',
              icon: const Icon(Icons.close, size: 16),
              onPressed: () {
                _dangerSnoozedUntil = DateTime.now().add(
                  const Duration(minutes: 30),
                );
                messenger.hideCurrentMaterialBanner();
                _dangerShown = false;
              },
            ),
          ],
        ),
      );
  }

  /// زر «إعادة المحاولة والمزامنة فوراً»: يصفّر backoff ويدفع كل المعلّق
  /// حالاً. النجاح يبثّ null عبر onSyncDanger فيختفي البانر تلقائياً؛
  /// وإن بقيت عمليات عالقة يعود البانر برسالته دون السبينر.
  Future<void> _dangerRetryNow(ScaffoldMessengerState messenger) async {
    if (_dangerSyncing) return;
    Sfx.click();
    final engine = ref.read(syncEngineProvider);
    _dangerSyncing = true;
    // أعد عرض البانر بحالة «جارٍ المزامنة» (سبينر + تعطيل الأزرار).
    if (_dangerShown && mounted) {
      _showDangerBanner(messenger, '');
    }
    try {
      await engine.triggerImmediateSync().timeout(const Duration(seconds: 45));
    } catch (_) {
      // فشل/مهلة: يبقى الخطر قائماً وسيُعاد بثه بالدورة التالية.
    } finally {
      _dangerSyncing = false;
      // إن كان البانر ما زال معروضاً (لم يصل null) نعيد الرسالة الحية
      // من المحرك بالفحص الفوري — وإلا فقد أُخفي تلقائياً بالنجاح.
      if (mounted && _dangerShown) {
        try {
          await engine.recheckDangerNow();
        } catch (_) {}
      }
    }
  }

  /// (2026-09-24) يستجيب لطلبات التنقّل القادمة من الشاشات الداخلية.
  void _onShellNavRequest() {
    final target = ShellNav.request.value;
    if (target.isEmpty) return;
    switch (target) {
      case ShellNav.home:
        _go(AppScreen.accounts);
    }
  }

  void _go(AppScreen s) {
    // دفتر فردي لصاحبه — لا بوابات صلاحيات.
    _screenHistory
      ..clear()
      ..add(AppScreen.accounts);
    if (s != AppScreen.accounts) {
      _screenHistory.add(s);
    }
    setState(() => _screen = s);
  }

  Widget _body() => switch (_screen) {
        AppScreen.accounts => const AccountsScreen(),
        AppScreen.transactions => const TransactionsScreen(),
        AppScreen.vouchers => const VouchersScreen(),
        AppScreen.reports => const ReportsScreen(),
        AppScreen.currencies => const CurrenciesScreen(),
        AppScreen.trash => const TrashScreen(),
        AppScreen.activity => const ActivityScreen(),
        AppScreen.backup => const BackupScreen(),
        AppScreen.syncOps => const SyncOpsScreen(),
        AppScreen.settings => const SettingsScreen(),
      };

  /// زر العملية العائم المميّز بالتدرج الدائري كما في هوية التطبيق
  /// هل المستخدم مشترك مدفوع فعّال؟ — بوابات الميزات المدفوعة.
  bool get _subscribed =>
      ref.watch(subscriptionProvider).valueOrNull?.isSubscribed ?? false;

  Widget? _fab() {
    // (تصحيح 2026-11-03) زر + سياقي صغير (48px) يطفو أسفل يمين الشاشة
    // فوق بطاقة الملخص ولا يمس أي حافة: الحسابات → حساب جديد، العمليات
    // → عملية، السندات → سند. داخل تفاصيل الحساب يظهر زر عملية خاص
    // به هناك. أما بقية الشاشات فلا زر (لا معنى له هناك).
    final VoidCallback onTap;
    final IconData icon;
    final String tooltip;
    switch (_screen) {
      case AppScreen.accounts:
        tooltip = 'حساب جديد';
        icon = Icons.person_add_alt_outlined;
        onTap = () {
          Sfx.click();
          openAccountForm(context, ref);
        };
      case AppScreen.transactions:
        tooltip = 'تسجيل عملية';
        icon = Icons.receipt_long_outlined;
        onTap = () {
          Sfx.click();
          openTxForm(context, ref);
        };
      case AppScreen.vouchers:
        tooltip = 'سند جديد';
        icon = Icons.post_add_outlined;
        onTap = () {
          Sfx.click();
          openVoucherForm(context, ref);
        };
      default:
        return null;
    }
    return FloatingActionButton.small(
      tooltip: tooltip,
      backgroundColor: const Color(0xFF0284C7),
      foregroundColor: Colors.white,
      onPressed: onTap,
      child: Icon(icon, size: 22),
    );
  }

  // (تصحيح 2026-11-03) حُذفت ورقة الإجراءات السريعة — زر + صار
  // سياقيًا مباشرًا: حساب جديد على شاشة الحسابات، وعملية داخل الحساب.

  final List<AppScreen> _screenHistory = [AppScreen.accounts];
  bool _isExitDialogOpen = false;

  /// زر رجوع النظام:
  /// 1. إغلاق القائمة الجانبية (Drawer) أولاً إن كانت مفتوحة.
  /// 2. إغلاق أي حوار أو مسار منبثق إن وُجد.
  /// 3. الرجوع للشاشة السابقة إن كان المستخدم في شاشة فرعية (العودة إلى العملاء).
  /// 4. على شاشة العملاء: إظهار مربع حوار تأكيد الخروج (نعم / لا) مباشرة وسلساً.
  void _handleRootPop(bool didPop) {
    if (didPop) return;

    // 1) إغلاق القائمة الجانبية إن كانت مفتوحة
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null && scaffold.isDrawerOpen) {
      scaffold.closeDrawer();
      return;
    }
    if (scaffold != null && scaffold.isEndDrawerOpen) {
      scaffold.closeEndDrawer();
      return;
    }

    // 2) إغلاق أي حوار أو مسار فرعي مفتوح
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
      return;
    }

    // 3) أي شاشة فرعية داخل القشرة تعود مباشرة إلى العملاء بضغطة واحدة فقط
    if (_screen != AppScreen.accounts) {
      _screenHistory
        ..clear()
        ..add(AppScreen.accounts);
      setState(() => _screen = AppScreen.accounts);
      return;
    }

    // 4) شاشة العملاء: عرض حوار تأكيد الخروج مباشرة
    _showExitConfirmationDialog();
  }

  /// مربع حوار تأكيد الخروج من التطبيق عند ضغط زر رجوع النظام في الرئيسية
  Future<void> _showExitConfirmationDialog() async {
    if (_isExitDialogOpen || !mounted) return;
    _isExitDialogOpen = true;
    try {
      final shouldExit = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0x1FFF0000),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.exit_to_app, color: Colors.red, size: 24),
              ),
              const SizedBox(width: 12),
              const Text(
                'الخروج من التطبيق',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: const Text(
            'هل تريد الخروج من التطبيق؟',
            style: TextStyle(fontSize: 15),
          ),
          actionsPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(
                'لا',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                elevation: 0,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text(
                'نعم',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );

      if (shouldExit == true && mounted) {
        await SystemNavigator.pop();
        if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
          exit(0);
        }
      }
    } finally {
      _isExitDialogOpen = false;
    }
  }
  Widget _appBarSquircleAction({
    required Widget icon,
    required String tooltip,
    required VoidCallback onTap,
    required Color bg,
    required Color fg,
    Border? border,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
        child: Tooltip(
          message: tooltip,
          child: Container(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: border,
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: Center(child: icon),
                ),
              ),
            ),
          ),
        ),
      );


  @override
  Widget build(BuildContext context) {
    ref.watch(hideBalancesProvider);

    return ValueListenableBuilder<bool>(
      valueListenable: CloudControlService.instance.isFrozenNotifier,
      builder: (ctx, frozen, _) {
        if (frozen) {
          return const FrozenAccountBarrier();
        }
        return ValueListenableBuilder<bool>(
          valueListenable: CloudControlService.instance.forceUpdateNotifier,
          builder: (ctx, forceUpdate, _) {
            if (forceUpdate) {
              return const ForceUpdateBarrier();
            }
            return ValueListenableBuilder<bool>(
              valueListenable:
                  CloudControlService.instance.maintenanceActiveNotifier,
              builder: (ctx, inMaintenance, _) {
                if (inMaintenance) {
                  return const MaintenanceModeBarrier();
                }
                return PopScope(
                  canPop: false,
                  onPopInvokedWithResult: (didPop, _) => _handleRootPop(didPop),
                  child: Scaffold(
                    key: _scaffoldKey,
        appBar: AppBar(
          leading: Builder(
            builder: (ctx) {
              final isDark = Theme.of(ctx).brightness == Brightness.dark;
              return Padding(
                padding: const EdgeInsets.all(8),
                child: Material(
                  color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Scaffold.of(ctx).openDrawer(),
                    child: Icon(
                      Icons.menu,
                      size: 20,
                      color: AppColors.textOf(ctx),
                    ),
                  ),
                ),
              );
            },
          ),
          title: Text(_screen.title),
          actions: [
            // (تصحيح 2026-11-03) البحث أيقونة بجوار الجرس أعلى يسار
            // الشاشة — تظهر في شاشة الحسابات، وتفتح شريط البحث الذي
            // حُذف من أعلى القائمة ليوفر مساحة الصفحة.
            if (_screen == AppScreen.accounts)
              Builder(
                builder: (ctx) {
                  final isDark = Theme.of(ctx).brightness == Brightness.dark;
                  final open = ref.watch(accountsSearchOpenProvider);
                  return _appBarSquircleAction(
                    tooltip: 'بحث في الحسابات',
                    bg: open
                        ? const Color(0xFF0284C7)
                        : (isDark
                            ? const Color(0xFF0C2A3F)
                            : const Color(0xFFE0F2FE)),
                    fg: open
                        ? Colors.white
                        : (isDark
                            ? const Color(0xFF7DD3FC)
                            : const Color(0xFF0284C7)),
                    border: Border.all(
                      color: open
                          ? const Color(0xFF0369A1)
                          : (isDark
                              ? const Color(0xFF075985)
                              : const Color(0xFFBAE6FD)),
                      width: 1.1,
                    ),
                    icon: Icon(
                      open ? Icons.search_off_rounded : Icons.search_rounded,
                      size: 21,
                    ),
                    onTap: () {
                      Sfx.tap();
                      ref.read(accountsSearchOpenProvider.notifier).state =
                          !open;
                    },
                  );
                },
              ),
            Consumer(
              builder: (ctx, rref, _) {
                final unreadLocal =
                    rref.watch(unreadCountProvider).valueOrNull ?? 0;
                final isDark = Theme.of(ctx).brightness == Brightness.dark;
                return ValueListenableBuilder<int>(
                  valueListenable:
                      CloudControlService.instance.unreadAlertCountNotifier,
                  builder: (ctx, unreadCloud, _) {
                    final unread = unreadLocal + unreadCloud;
                    return _appBarSquircleAction(
                      tooltip: 'الإشعارات',
                      bg: isDark
                          ? const Color(0xFF291E04)
                          : const Color(0xFFFEF9C3),
                      fg: const Color(0xFFB45309),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF854D0E)
                            : const Color(0xFFFDE047),
                        width: 1.1,
                      ),
                      icon: Badge(
                        isLabelVisible: unread > 0,
                        label: Text(
                          '$unread',
                          style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              color: Colors.white),
                        ),
                        backgroundColor: const Color(0xFFDC2626),
                        child: const GoldenBellIcon(size: 22),
                      ),
                      onTap: () => openNotifications(
                        context,
                        ref,
                        onOpenEntity: openNotificationEntity,
                      ),
                    );
                  },
                );
              },
            ),
            // قائمة الخيارات الإضافية (⋮) — نقل الوضع الليلي، إخفاء الأرصدة، وتبديل الوردية
            Consumer(
              builder: (ctx, rref, _) {
                final isDark = Theme.of(ctx).brightness == Brightness.dark;
                final currentTheme = rref.watch(themeModeProvider);
                final darkActive = currentTheme == ThemeMode.dark ||
                    (currentTheme == ThemeMode.system && isDark);
                final hidden = rref.watch(hideBalancesProvider);

                return Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: PopupMenuButton<String>(
                    tooltip: 'خيارات إضافية',
                    icon: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.more_vert_rounded,
                        size: 20,
                        color: AppColors.textOf(ctx),
                      ),
                    ),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    onSelected: (val) {
                      if (val == 'theme') {
                        Sfx.tap();
                        rref.read(themeModeProvider.notifier).state =
                            darkActive ? ThemeMode.light : ThemeMode.dark;
                      } else if (val == 'balances') {
                        Sfx.tap();
                        rref.read(hideBalancesProvider.notifier).state = !hidden;
                      } else if (val == 'refresh') {
                        bump(ref);
                        _refreshSync();
                        try {
                          ref.read(syncEngineProvider).forceSyncNow();
                        } catch (_) {}
                        _checkForAppUpdate();
                      } else if (val == 'syncOps') {
                        Sfx.tap();
                        _go(AppScreen.syncOps);
                      }
                    },
                    itemBuilder: (c) => [
                      PopupMenuItem(
                        value: 'theme',
                        child: Row(
                          children: [
                            Icon(
                              darkActive ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                              size: 19,
                              color: darkActive ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
                            ),
                            const SizedBox(width: 10),
                            Text(darkActive ? 'التبديل إلى الوضع النهاري' : 'التبديل إلى الوضع الليلي'),
                          ],
                        ),
                      ),
                      // (تصحيح 2026-11-03) «العمليات المتزامنة» ميزة
                      // مدفوعة — تظهر للمشترك الفعّال فقط.
                      if (_subscribed)
                        const PopupMenuItem(
                          value: 'syncOps',
                          child: Row(
                            children: [
                              Icon(
                                Icons.cloud_sync_outlined,
                                size: 19,
                                color: Color(0xFF0284C7),
                              ),
                              SizedBox(width: 10),
                              Text('العمليات المتزامنة'),
                            ],
                          ),
                        ),
                      PopupMenuItem(
                        value: 'balances',
                        child: Row(
                          children: [
                            Icon(
                              hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                              size: 19,
                              color: const Color(0xFF7C3AED),
                            ),
                            const SizedBox(width: 10),
                            Text(hidden ? 'إظهار الأرصدة' : 'إخفاء الأرصدة'),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        drawer: _Drawer(current: _screen, onSelect: _go),
        // سطح المكتب (>900dp): شريط جانبي قابل للطي على يمين الشاشة (RTL)
        // بدل الشريط السفلي؛ الهاتف يبقى على الشريط السفلي كما هو.
        body: _body(),
        floatingActionButton: _fab(),
        // (تصحيح 2026-11-03) حُذف شريط التبويبات السفلي — التنقل كله من
        // القائمة الجانبية. مكانه بطاقة ملخص: لك / عليك / الإجمالي
        // مع اختصار «+ حساب جديد».
        floatingActionButtonLocation:
            FloatingActionButtonLocation.startFloat,
        bottomNavigationBar: const _SummaryBar(),
      ),
    );
              },
            );
          },
        );
      },
    );
  }
}

/// بطاقة الملخص السفلية — تحل محل شريط التبويبات المحذوف (2026-11-03):
/// «لك» مستحق لنا (أخضر) و«عليك» مستحق علينا (أحمر) والإجمالي، لكل
/// عملة ذات أرصدة، مع اختصار «+» لإضافة حساب جديد بسرعة.
class _SummaryBar extends ConsumerWidget {
  const _SummaryBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hidden = ref.watch(hideBalancesProvider);
    final summary = ref.watch(summaryProvider).valueOrNull;
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;

    final rows = curs.where((c) {
      final toUs = summary?.owedToUs[c.code] ?? 0;
      final byUs = summary?.owedByUs[c.code] ?? 0;
      return toUs.abs() > Fmt.moneyEpsilon ||
          byUs.abs() > Fmt.moneyEpsilon;
    }).toList();
    if (rows.isEmpty && curs.isNotEmpty) rows.add(curs.first);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : Colors.white,
        border: Border(
          top: BorderSide(
            color:
                isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.05),
            blurRadius: 8,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              Expanded(
                child: rows.isEmpty
                    ? const SizedBox.shrink()
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const VerticalDivider(
                          width: 20,
                          indent: 14,
                          endIndent: 14,
                        ),
                        itemBuilder: (_, i) {
                          final c = rows[i];
                          final toUs =
                              summary?.owedToUs[c.code] ?? 0; // لك
                          final byUs =
                              summary?.owedByUs[c.code] ?? 0; // عليك
                          final net = summary?.net[c.code] ?? 0;
                          return Row(
                            children: [
                              _SummaryCell(
                                label: 'لك',
                                value: hidden
                                    ? '•••'
                                    : Fmt.moneyFor(toUs, c),
                                color: const Color(0xFF059669),
                                symbol: c.symbol,
                              ),
                              const SizedBox(width: 14),
                              _SummaryCell(
                                label: 'عليك',
                                value: hidden
                                    ? '•••'
                                    : Fmt.moneyFor(byUs, c),
                                color: const Color(0xFFDC2626),
                                symbol: c.symbol,
                              ),
                              const SizedBox(width: 14),
                              _SummaryCell(
                                label: 'الإجمالي',
                                value: hidden
                                    ? '•••'
                                    : Fmt.moneyFor(net, c),
                                color: net.abs() <= Fmt.moneyEpsilon
                                    ? (isDark
                                        ? const Color(0xFF94A3B8)
                                        : const Color(0xFF64748B))
                                    : (net > 0
                                        ? const Color(0xFF059669)
                                        : const Color(0xFFDC2626)),
                                symbol: c.symbol,
                              ),
                            ],
                          );
                        },
                      ),
              ),
              // اختصار + لإضافة حساب جديد
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 4, end: 10),
                child: Tooltip(
                  message: 'حساب جديد',
                  child: Material(
                    color: const Color(0xFF0284C7),
                    borderRadius: BorderRadius.circular(13),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () {
                        Sfx.click();
                        openAccountForm(context, ref);
                      },
                      child: const SizedBox(
                        width: 38,
                        height: 38,
                        child: Icon(
                          Icons.person_add_alt_outlined,
                          size: 21,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// خلية واحدة في بطاقة الملخص: تسمية صغيرة وقيمة ملونة.
class _SummaryCell extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final String symbol;

  const _SummaryCell({
    required this.label,
    required this.value,
    required this.color,
    required this.symbol,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).hintColor,
            fontFamily: 'AppNaskh',
          ),
        ),
        const SizedBox(height: 1),
        Text(
          value,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w800,
            color: color,
            fontFamily: 'AppNaskh',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}


class _Drawer extends ConsumerWidget {
  final AppScreen current;
  final void Function(AppScreen) onSelect;
  const _Drawer({required this.current, required this.onSelect});

  /// (3.70.0) قسم في الدرج: عنوان صغير بارز + بلاطات الشاشات المسموحة
  /// (تصفية الصلاحيات/الوضع من _DrawerItems + بوابة Google للمجموعة).
  List<Widget> _drawerSection(
    BuildContext context,
    String title,
    List<AppScreen> order,
    AppScreen current,
    bool dark,
    void Function(AppScreen) onSelect,
  ) {
    if (order.isEmpty) return const [];
    return [
      Builder(
        builder: (ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(
            title,
            style: TextStyle(
              color: AppColors.text3Of(ctx),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: .2,
            ),
          ),
        ),
      ),
      for (final s in order)
        _DrawerTile(
          screen: s,
          active: current == s,
          color: _colorOf(s),
          dark: dark,
          onTap: () {
            Navigator.pop(context);
            scheduleMicrotask(() => onSelect(s));
          },
        ),
    ];
  }

  /// لون مميز لكل قسم (كما في التصميم المرجعي).
  Color _colorOf(AppScreen s) => switch (s) {
        AppScreen.transactions => const Color(0xFF0EA5E9),
        AppScreen.accounts => const Color(0xFF2563EB),
        AppScreen.reports => const Color(0xFF6366F1),
        AppScreen.settings => const Color(0xFF64748B),
        AppScreen.currencies => AppColors.primary2,
        AppScreen.vouchers => const Color(0xFFF59E0B),
        AppScreen.trash => const Color(0xFFE11D48),
        AppScreen.activity => const Color(0xFF64748B),
        AppScreen.backup => AppColors.primary2,
        AppScreen.syncOps => const Color(0xFF0284C7),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Drawer(
      backgroundColor: AppColors.surfaceOf(context),
      child: SafeArea(
        child: Column(
          children: [
            // ---------- ترويسة التطبيق الأنيقة والنظيفة ----------
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 18),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1E3A5F), AppColors.primary],
                ),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(22),
                  bottomRight: Radius.circular(22),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.account_balance_wallet_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'مدير الحسابات',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 16.5,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'دفتر الحسابات والديون',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ---------- عناصر القائمة حسب الوضع النشط ----------
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                children: [
                  // (تصحيح 2026-11-03) القسم الرئيسي أولاً — دفتر متكامل:
                  // كل الوجهات في الدرج لا التبويبات السفلية وحدها.
                  ..._drawerSection(
                    context,
                    'الرئيسية',
                    const [
                      AppScreen.accounts,
                      AppScreen.transactions,
                      AppScreen.reports,
                      AppScreen.settings,
                    ],
                    current,
                    dark,
                    onSelect,
                  ),
                  ..._drawerSection(
                    context,
                    'الدفاتر والمحاسبة',
                    const [
                      AppScreen.vouchers,
                      AppScreen.currencies,
                    ],
                    current,
                    dark,
                    onSelect,
                  ),
                  // عناصر النظام
                  ..._drawerSection(
                    context,
                    'النظام',
                    const [
                      AppScreen.backup,
                      AppScreen.trash,
                      AppScreen.activity,
                    ],
                    current,
                    dark,
                    onSelect,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // ---------- التحديثات (الإصدار وسجل التغييرات 3 أسطر) ----------
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Consumer(
                builder: (ctx, rref, _) {
                  final updateAsync = rref.watch(updateCheckProvider);
                  final info = updateAsync.valueOrNull;
                  final hasUpdate = info?.hasUpdate ?? false;
                  return Material(
                    color: hasUpdate
                        ? const Color(0xFFFEF3C7)
                        : AppColors.surface2Of(context),
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        Navigator.pop(context);
                        showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (_) => DraggableScrollableSheet(
                            initialChildSize: .7,
                            minChildSize: .4,
                            maxChildSize: .9,
                            builder: (c, s) => SingleChildScrollView(
                              controller: s,
                              child: const Padding(
                                padding: EdgeInsets.all(16),
                                child: UpdateSection(),
                              ),
                            ),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: hasUpdate
                                    ? const Color(0xFFF59E0B)
                                    : AppColors.primary.withValues(alpha: .14),
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: Icon(
                                hasUpdate
                                    ? Icons.system_update_rounded
                                    : Icons.system_update_alt_rounded,
                                color: hasUpdate ? Colors.white : AppColors.primary,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'التحديثات',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13.5,
                                    ),
                                  ),
                                  Text(
                                    hasUpdate
                                        ? 'يتوفر تحديث جديد: ${info?.latest}'
                                        : 'الإصدار $appVersionLabel (محدث)',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: hasUpdate
                                          ? const Color(0xFFB45309)
                                          : AppColors.text3Of(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (hasUpdate)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF59E0B),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Text(
                                  'تحديث',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                appVersionLabel,
                style: TextStyle(
                  fontSize: 10.5,
                  color: AppColors.text3Of(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// صف عنصر في القائمة الجانبية بتصميم البطاقة النشطة.
class _DrawerTile extends StatelessWidget {
  final AppScreen screen;
  final bool active;
  final Color color;
  final bool dark;
  final VoidCallback onTap;
  const _DrawerTile({
    required this.screen,
    required this.active,
    required this.color,
    required this.dark,
    required this.onTap,
  });


  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: active ? AppColors.infoSoftOf(context) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: active
                  ? Border.all(color: AppColors.infoOf(context), width: 1.4)
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  active ? screen.activeIcon : screen.icon,
                  color: active ? AppColors.infoOf(context) : color,
                  size: 22,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    screen.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w700,
                      color: active
                          ? AppColors.infoOf(context)
                          : AppColors.textOf(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// عناصر الدرج: كل الشاشات ما عدا الموجودة في الشريط السفلي، حتى لا تتكرر
/// الأيقونة نفسها في مكانين. إدارة المجموعة للمدير فقط.
class DrawerItems {
  /// عناصر الدرج الثانوية — دفتر فردي لصاحبه بلا صلاحيات:
  /// السندات والعملات (الدفاتر) + النسخ والمهملات وسجل النشاط (النظام).
  /// «العمليات المتزامنة» تُفتح من قائمة الخيارات (⋮) لا من الدرج.
  static const List<AppScreen> drawerScreens = [
    AppScreen.vouchers,
    AppScreen.currencies,
    AppScreen.backup,
    AppScreen.trash,
    AppScreen.activity,
  ];
}
