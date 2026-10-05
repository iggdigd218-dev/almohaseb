// الانضمام إلى المجموعة عبر السحابة (بدون شبكة محلية) + سجل الأجهزة السحابي.
//
// الفكرة:
//  - المدير ينشئ «دعوة سحابية»: يرفع لقطة كاملة من بيانات المجموعة إلى
//    {base}/workspaces/{ws}/joinSnapshot ورمز دعوة مؤقت (24 ساعة، يُستخدم مرة
//    واحدة) إلى {base}/workspaces/{ws}/invites/{TOKEN}.
//  - الجهاز الجديد يُدخل الرابط + رمز الدعوة (أو يمسح QR): تُحذف جميع بياناته
//    المحلية بالكامل داخل معاملة واحدة وتُستبدل بنسخة المجموعة، ثم يصبح عضواً
//    ويتزامن تلقائياً عبر نفس رابط السحابة الذي يستخدمه المدير.
//  - سجل الأجهزة السحابي (roster): كل جهاز يرفع سجله (بلا أسرار) إلى
//    {base}/workspaces/{ws}/roster/{deviceId}؛ المدير يرفع سجلات كل الأجهزة
//    (هو المرجع في التعيين/الحظر/الطرد). عند كل سحب سحابي تُدمج السجلات
//    بالأحدث (updated_at) فيرى المدير جهاز العضو البعيد ويعيّن له مستخدماً
//    وصلاحيات، ويصل التعيين/الطرد للعضو خلال دورة سحب واحدة.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../core/factory_reset.dart';
import 'account_workspace.dart';
import '../../core/models.dart';
import '../repository.dart';
import 'operation.dart';
import 'device_id.dart';
import 'google_auth_service.dart';
import 'device_registry.dart';
import 'firebase_auth_service.dart';
import 'snapshot_apply.dart';
import 'subscription_guard.dart';
import '../../core/cloud_config.dart';

const _tokenChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// مهلة بقاء طلب الانضمام بعد أن يُسوّى أمره (قبولاً أو رفضاً).
/// تُحذف العقدة بعد هذه المدة إن لم يحذفها العضو بنفسه بعد إكمال الربط.
/// لا تُستخدم كـ «وقت انتظار» — العضو يرى «تم الارتباط» فور الموافقة.
/// (إصلاح 2026-09-18) كانت دقيقتين فقط — إن وافق المدير والعضو كان
/// offline لحظياً (شبكة ضعيفة) ضاع القرار. الآن 10 دقائق آمنة.
const Duration _approvedRequestTtl = Duration(minutes: 10);

  /// (أ-2) فهرس الدعوات على الجذر: `{base}/invite_index/{pin_XXXXXX|tok_XXXXXXXX}`.
///
/// كان اكتشاف مساحة المدير يتم بمسح `/workspaces?shallow=true` ثم قراءة
/// عقدة `invites` لكل مساحة (سقف 500) — أي استطلاعاً جماعياً لبيانات كل
/// المنشآت واستهلاكاً شبكياً هائلاً من طرف العميل. الفهرس يجعل الاكتشاف
/// **قراءةً واحدة لعقدة واحدة**، ويتيح لقواعد الأمان منع قراءة الجذر.
/// مفتاحان في أب واحد: `pin_` للرمز الرقمي و`tok_` لتوكن الدعوة.
String _inviteIndexPath(String base, String key) =>
    '${base.replaceAll(RegExp(r'/+$'), '')}/invite_index/'
    '${Uri.encodeComponent(key)}.json';

String _invitePinKey(String pin) => 'pin_${pin.trim().toUpperCase()}';

String _inviteTokenKey(String token) => 'tok_${token.trim().toUpperCase()}';

/// (توافق مؤقت) المسح القديم إن تعذّر الفهرس — يلزم فقط لأن مديراً على
/// إصدار ≤ 3.62 ينشئ دعوة بلا فهرس، فيفشل اكتشافها من عضو محدَّث.
/// يُقلب إلى false (ثم يُحذف المسح) بعد انتشار 3.63 بين المديرين.
const bool legacyInviteScanFallback = true;

String _newToken([int len = 8]) {
  final rnd = Random.secure();
  return List.generate(len, (_) => _tokenChars[rnd.nextInt(_tokenChars.length)])
      .join();
}

/// رمز PIN رقمي من 6 خانات — لأجهزة سطح المكتب بلا كاميرا.
String newPairPin() {
  final rnd = Random.secure();
  return List.generate(6, (_) => '${rnd.nextInt(10)}').join();
}

/// بيانات دعوة انضمام سحابية جاهزة للعرض/المشاركة.
class CloudInviteInfo {
  final String backendUrl;
  final String workspaceId;
  final String token;
  final String cloudCode;
  final DateTime expiresAt;

  /// PIN بشري من 6 أرقام يظهر تحت QR — لأجهزة سطح المكتب بلا كاميرا.
  final String pin;
  const CloudInviteInfo({
    required this.backendUrl,
    required this.workspaceId,
    required this.token,
    required this.cloudCode,
    required this.expiresAt,
    this.pin = '',
  });

  /// محتوى QR: nexora://cloudjoin?url=...&ws=...&tok=...&code=...
  String get qrContent => Uri(
        scheme: 'nexora',
        host: 'cloudjoin',
        queryParameters: {
          'url': backendUrl,
          'ws': workspaceId,
          'tok': token,
          if (cloudCode.isNotEmpty) 'code': cloudCode,
        },
      ).toString();

  static Map<String, String>? parseQr(String raw) {
    try {
      final uri = Uri.parse(raw);
      if (uri.scheme != 'nexora' || uri.host != 'cloudjoin') return null;
      return {
        'url': uri.queryParameters['url'] ?? '',
        'ws': uri.queryParameters['ws'] ?? 'default',
        'tok': uri.queryParameters['tok'] ?? '',
        'code': uri.queryParameters['code'] ?? '',
      };
    } catch (_) {
      return null;
    }
  }
}

/// (دفعة 57) مراقب SSE لطلبات الانضمام — يستبدل استطلاع الـ 5 ثوانٍ:
/// قناة بث حيّة على /workspaces/$ws/joinRequests.json تُنبّه المدير
/// لحظياً (صفر كمون) عند وصول طلب اقتران جديد. أول حدث put يحمل
/// اللقطة الحالية فيلتقط الطلبات المعلقة سلفاً أيضاً. إعادة اتصال
/// بتراجع أسّي 4→180 ثانية عند انقطاع الشبكة.
///
/// (تكملة) [nodePath] يعمّم القناة: العضو المنتظر يراقب عقدته
/// 'joinRequests/&lt;deviceId&gt;' فيلتقط قرار المدير (approve/reject)
/// لحظة كتابته بدل انتظار دورة الاستطلاع.
class JoinRequestWatcher {
  final String backendUrl;
  final String workspaceId;
  final String nodePath;
  final void Function() onRequestsChanged;

  JoinRequestWatcher({
    required this.backendUrl,
    this.workspaceId = 'default',
    this.nodePath = 'joinRequests',
    required this.onRequestsChanged,
  });

  bool _running = false;
  HttpClient? _client;
  int _retrySeconds = 4;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  void stop() {
    _running = false;
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }

  Future<void> _loop() async {
    final root =
        '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(workspaceId)}';
    while (_running) {
      try {
        // (إصلاح 2026-09-18) SSE بلا توكن كان يفشل بصمت عند تشديد القواعد
        // أو عند انتهاء جلسة مجهولة — نرفق auth idToken مع كل اتصال، مع
        // تجديد قسري عند auth_revoked/401.
        String? token = FirebaseAuthRest.cachedIdToken;
        if (token == null || token.isEmpty) {
          token = await FirebaseAuthRest.cloudIdToken();
        }
        final sseUrl = token == null || token.isEmpty
            ? '$root/$nodePath.json'
            : '$root/$nodePath.json?auth=${Uri.encodeComponent(token)}';
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        _client = client;
        final req = await client.getUrl(Uri.parse(sseUrl));
        req.headers.set('Accept', 'text/event-stream');
        req.headers.set('Cache-Control', 'no-cache');
        final resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.statusCode == 401 || resp.statusCode == 403) {
          // توكن منتهٍ — جدّد وحاول مرة واحدة فوراً
          final fresh = await FirebaseAuthRest.forceRefreshToken();
          if (fresh != null && fresh != token) {
            try {
              _client?.close(force: true);
            } catch (_) {}
            _client = null;
            continue; // حلقة جديدة بتوكن جديد
          }
          throw StateError('join-sse-http-${resp.statusCode}');
        }
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw StateError('join-sse-http-${resp.statusCode}');
        }
        _retrySeconds = 4;
        String? eventName;
        await for (final line in resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (!_running) break;
          if (line.startsWith('event:')) {
            eventName = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            if (eventName == 'put' || eventName == 'patch') {
              final raw = line.substring(5).trim();
              try {
                final m = jsonDecode(raw);
                if (m is Map && m['data'] != null) {
                  onRequestsChanged();
                }
              } catch (_) {}
            } else if (eventName == 'auth_revoked') {
              // أعد الاتصال بتوكن جديد فوراً
              await FirebaseAuthRest.forceRefreshToken();
              break;
            }
          }
        }
      } catch (_) {
        // شبكة — تراجع ثم إعادة محاولة.
      } finally {
        try {
          _client?.close(force: true);
        } catch (_) {}
        _client = null;
      }
      if (!_running) break;
      await Future<void>.delayed(Duration(seconds: _retrySeconds));
      _retrySeconds = (_retrySeconds * 2).clamp(4, 180);
    }
  }
}

/// (دفعة 65 — كسر حلقة التعليق) المهلة القصوى لأي عملية سحابية مركّبة
/// (رفع لقطة، إنشاء دعوة، موافقة). بلا هذا الثابت كان رفع اللقطة يرث
/// المهلة الافتراضية (60 ثانية) ويتضاعف مع مسار إعادة محاولة 401 إلى
/// ~120 ثانية — داخل حوار غير قابل للإلغاء فيبدو التطبيق معلّقاً تماماً.
const Duration kCloudOpTimeout = Duration(seconds: 15);

/// (دفعة 65 — تصحيح انحدار) مهلة رفع **لقطة المجموعة الكاملة** إلى
/// السحابة. كانت `kCloudOpTimeout * 2` (30 ثانية) وهي تكفي قاعدة فارغة
/// في مختبر سريع، لكنها تسقط أي مؤسسة حقيقية على اتصال هاتفي: رفع
/// لقطة بعشرات الآلاف من الصفوف يتجاوزها، فيفشل `createInvite` قبل
/// كتابة الدعوة، فلا يجد العضو المساحة أبداً ويبدو «الربط معطلاً».
/// اللقطة أثقل عملية في المسار — نمنحها وقتاً واقعياً.
const Duration kCloudSnapshotUploadTimeout = Duration(minutes: 3);

/// (دفعة 65 — تصحيح انحدار) المهلة الكلية لإنشاء دعوة انضمام من
/// الواجهة: تشمل رفع اللقطة (الأثقل) ثم الدعوة ثم الفهرس. يجب أن تبقى
/// **أكبر من** [kCloudSnapshotUploadTimeout] وإلا جهضت الواجهة
/// العملية بعد أن يكون الخادم قد استلم اللقطة وقبل أن يكتب الدعوة،
/// فتظهر للمدير «انتهت المهلة» ولا يجد العضو المساحة أبداً — وهو
/// بالضبط ما جعل «الربط بالمجموعة» يبدو معطلاً بالكامل.
const Duration kCloudInviteTimeout = Duration(minutes: 3, seconds: 30);

class CloudJoinException implements Exception {
  final String message;
  const CloudJoinException(this.message);
  @override
  String toString() => message;
}

class CloudJoin {
  /// (المرحلة 2) تثبيت عضوية **مالك المساحة** في `/members/{uid}`.
  ///
  /// أول عضو في المنشأة ودوره `owner` — هذه العقدة هي ما تقرأه قواعد
  /// الأمان (`auth.uid`) للسماح بالكتابة في مساحة العمل. تُكتب مرة واحدة
  /// ثم لا تُلمس: `existing != null` يوقف إعادة الكتابة.
  static Future<void> ensureOwnerMembership(
    Repo repo, {
    required String backendUrl,
    String? workspaceId,
  }) async {
    // يضمن وجود هوية (مجهولة) قبل قراءة uid — إن كانت التهيئة الصامتة لم
    // تنجح عند الإقلاع لغياب الشبكة، تُحاول هنا عند أول اتصال سحابي.
    await FirebaseAuthRest.cloudIdToken();
    final uid = FirebaseAuthRest.currentUid;
    if (uid.isEmpty || backendUrl.trim().isEmpty) return;
    // (3.71.0 — نظام صارم) المساحة السحابية تُنشأ وتُطالب بالتسجيل بالبريد
    // الإلكتروني (حساب Google) فقط: هوية مجهولة بلا بريد لا تكتب عضوية
    // مالك في السحابة — لا مساحات أشباح بعد اليوم.
    final stGate = await repo.settings();
    if ((stGate[FirebaseAuthRest.emailKey] ?? '').trim().isEmpty) return;
    final ws = workspaceId ?? repo.requireWorkspaceId;
    final path =
        '${_root(backendUrl, ws)}/members/${Uri.encodeComponent(uid)}.json';
    try {
      final existing = await _getJson(path);
      if (existing != null) return; // المالك الأول يثبت للأبد.
      final st = await repo.settings();
      await _putJson(path, {
        'role': 'owner',
        'uid': uid,
        'deviceId': repo.requireDeviceId,
        'email': (st[FirebaseAuthRest.emailKey] ?? '').trim(),
        'joined_at': {'.sv': 'timestamp'},
      }, timeout: const Duration(seconds: 20));
    } catch (_) {}
  }

  /// (401) ترحيل هوية المالك بعد ربط حساب Google: يتغيّر `auth.uid` من الهوية
  /// المجهولة للجهاز إلى الـ UID الحقيقي الناتج عن الاستبدال، فتُكتب عقدة
  /// العضوية الجديدة `workspaces/{ws}/members/{googleUid}` بدور `owner`
  /// وبيانات الجهاز، ويُمحى السجل القديم المفتاح بالهوية المجهولة — وإلا بقي
  /// المالك ممسوك الصلاحية عن مساحته فتُرفض كتاباته (دعوة، invite_index) بـ 401.
  static Future<void> migrateOwnerMembership(
    Repo repo, {
    required String backendUrl,
    required String previousUid,
    String? workspaceId,
  }) async {
    if (backendUrl.trim().isEmpty) return;
    // كتابة الهوية الجديدة أولاً: إن فشلت لا نفقد العضوية القديمة.
    await ensureOwnerMembership(
        repo, backendUrl: backendUrl, workspaceId: workspaceId);
    final uid = FirebaseAuthRest.currentUid;
    if (uid.isEmpty || previousUid.isEmpty || uid == previousUid) return;
    final ws = workspaceId ?? repo.requireWorkspaceId;
    try {
      await _delete('${_root(backendUrl, ws)}/members/'
          '${Uri.encodeComponent(previousUid)}.json');
    } catch (_) {}
  }

  /// (دفعة 53) خطاف الطرد الذاتي: يضبطه SyncEngine عند الإقلاع ليتولى
  /// المعالجة المركزية (إيقاف SSE/الدفع + تنظيف الجلسة + بث للواجهة)
  /// بدل الاكتفاء بإعادة الضبط الصامتة.

  /// 🔒 (التجربة) يرمي CloudJoinException إذا انتهت الفترة التجريبية —
  /// حارس ربط الأجهزة الجديدة (دعوة/موافقة).
  static Future<void> _ensureSubscriptionAllows(Repo repo) async {
    try {
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) return;
      // (إصلاح 2026-09-23) بوابة الترخيص على مساحة العمل المرتبطة فعلاً.
      final ws = await SubscriptionGuard.workspaceIdFor(repo);
      final blocked = await SubscriptionGuard.isBlocked(repo,
          backendUrl: url, workspaceId: ws);
      if (blocked) {
        throw const CloudJoinException(
            '⏳ انتهت الفترة التجريبية — ربط الأجهزة الجديدة متوقف. '
            'فعّل اشتراكك لاستئناف كل المزايا السحابية.');
      }
    } on CloudJoinException {
      rethrow;
    } catch (_) {
      // تعذر الفحص (شبكة) — لا نمنع؛ بوابة المزامنة الدورية تحسم لاحقاً.
    }
  }

  /// (باقة المؤسسات) عدد الأجهزة المتصلة حالياً بالمجموعة: مقترنة وغير
  /// مطرودة/ملغاة — يُعرض في عدّاد المقاعد ويُفحص قبل أي ربط جديد.
  static Future<int> connectedDevicesCount(Repo repo) async {
    final db = await repo.database;
    final rows = await db.rawQuery(
        "SELECT COUNT(*) c FROM devices WHERE is_paired = 1 "
        "AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = ''");
    return (rows.first['c'] as int?) ?? 0;
  }

  /// (باقة المؤسسات) بوابة المقاعد: ربط جهاز جديد يتجاوز max_devices
  /// يُرفض برسالة المدير الواضحة. الجهاز المنضم مجدداً (سجله قائم) لا
  /// يستهلك مقعداً جديداً.
  /// ══ (إصلاح جذري — إغلاق ثغرة fail-open وسباق الموافقات) ══
  /// كان أي فشل شبكة أثناء قراءة subscription/roster يعيد سماحاً فورياً،
  /// فيتجاوز الحد. وأيضاً موافقتان متزامنتان على جهازين مختلفين كانتا
  /// تقرآن نفس العدد وتقبلان معاً متجاوزتين الحد.
  static Future<void> _ensureSeatAvailable(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    required String joiningDeviceId,
  }) async {
    int? maxDevices;
    Map<String, dynamic>? rosterCloud;
    bool subscriptionRead = false;
    try {
      final rec = await _getJson(
          '${_root(backendUrl, workspaceId)}/subscription.json');
      if (rec == null) return; // لا عقدة اشتراك بعد — لا حد مفروضاً.
      subscriptionRead = true;
      final v = rec['max_devices'];
      maxDevices = v is num ? v.toInt() : 0;
      if (maxDevices <= 0) return; // غير محدد = بلا حد.
      // (احتساب ذري) roster السحابي هو المصدر المشترك اللحظي بين كل
      // الأجهزة — الجدول المحلي قد يتخلف عن موافقات جرت على جهاز آخر
      // للتو، فكان يرفض/يقبل خطأً. نقرأه في نفس لحظة القرار.
      try {
        final r =
            await _getJson('${_root(backendUrl, workspaceId)}/roster.json');
        if (r != null) rosterCloud = Map<String, dynamic>.from(r);
      } catch (_) {
        // فشل قراءة roster — لا نلغي الفحص، نكمل بالعدد المحلي فقط.
        rosterCloud = null;
      }
    } catch (_) {
      if (!subscriptionRead) return; // لا نعرف الحد — fail-open مقبول فقط هنا
      // عرفنا أن هناك حداً لكن الشبكة سقطت أثناء قراءة roster — نطبق
      // الحد على العدد المحلي على الأقل بدل السماح المفتوح.
    }
    if (maxDevices == null) return;
    // إعادة انضمام جهاز قائم (له مقعد في roster أو محلياً) لا تستهلك
    // مقعداً جديداً — تجديد لسجله القديم.
    bool activeRow(Map d) =>
        '${d['revoked_at'] ?? ''}'.isEmpty &&
        '${d['expelled_at'] ?? ''}'.isEmpty;
    if (rosterCloud != null) {
      final mine = rosterCloud[joiningDeviceId];
      if (mine is Map && activeRow(mine)) return;
    }
    final db = await repo.database;
    final existing = await db.query('devices',
        where: "id = ? AND is_paired = 1 AND COALESCE(revoked_at,'') = '' "
            "AND COALESCE(expelled_at,'') = ''",
        whereArgs: [joiningDeviceId],
        limit: 1);
    if (existing.isNotEmpty) return;
    // ══ (2026-09-22 — قانون العدّ الصادق) ══
    // السجل السحابي (roster) هو المصدر الوحيد للأجهزة **المرتبطة
    // فعلياً**. الجدول المحلي قد يمتلئ بأشباح: أعضاء غادروا، أو طُردوا
    // من السحابة، أو بقايا ربط قديم على جهاز أُعيد تثبيته — فكان العدد
    // يبلغ الحد (5/5) ويُرفض أي ربط جديد بينما لا يوجد في الحقيقة أي
    // جهاز مرتبط. القاعدة الآن: إن قُرئ roster فالعدد = عدده وحده
    // (لا اتحاداً مع المحلي)، وإن تعذّرت قراءته نعود للعدد المحلي
    // كاحتياط مُرشَّح. كذلك الأعضاء المطرودون/المفصولون لا يُحسبون.
    int current;
    if (rosterCloud != null) {
      current = rosterCloud.values.whereType<Map>().where(activeRow).length;
    } else {
      current = await connectedDevicesCount(repo);
    }
    // (سباق دعوتين) عند إنشاء دعوة جديدة joiningDeviceId='__new__'،
    // نعدّ الدعوات الحية أيضاً كمقاعد محجوزة مؤقتاً — وإلا دعوتان
    // متزامنتان تتجاوزان الحد.
    if (joiningDeviceId == '__new__') {
      try {
        final invites =
            await _getJson('${_root(backendUrl, workspaceId)}/invites.json');
        if (invites != null) {
          var liveInvites = 0;
          final now = DateTime.now();
          for (final v in invites.values) {
            if (v is! Map) continue;
            final exp = DateTime.tryParse('${v['expiresAt'] ?? ''}');
            if (exp != null && now.isBefore(exp)) liveInvites++;
          }
          current += liveInvites;
        }
      } catch (_) {}
    }
    if (current >= maxDevices) {
      throw CloudJoinException(
          '🪑 تم استنفاد عدد الأجهزة المسموح بها لهذه الباقة '
          '($current/$maxDevices). يرجى ترقية الاشتراك لإضافة أجهزة جديدة.');
    }
  }

  /// هل سجل هذا الجهاز في مساحة العمل المعطاة ما زال عضواً **فعّالاً**؟
  ///
  /// `/roster/{deviceId}` هو المصدر المشترك: غياب العقدة أو وجود
  /// `revoked_at`/`expelled_at` يعني انتهاء العضوية (طرد أو حلّ مجموعة)
  /// ولو ظلّ الجهاز محلياً موسوماً `member`.
  /// تعذّر القراءة (شبكة) ⇒ نعدّه غير فعّال: الأوفر ألا نحبس المستخدم
  /// خلف رفض كاذب بدل أن نتركه ينضم.
  static Future<bool> _isActiveCloudMember(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
  }) async {
    final devId = (await repo.settings())['sync.deviceId'] ?? '';
    if (devId.isEmpty) return false;
    try {
      final rec = await _getJson('${_root(backendUrl, workspaceId)}/roster/'
          '${Uri.encodeComponent(devId)}.json');
      if (rec == null || rec.isEmpty) return false;
      return '${rec['revoked_at'] ?? ''}'.trim().isEmpty &&
          '${rec['expelled_at'] ?? ''}'.trim().isEmpty;
    } catch (_) {
      return false;
    }
  }

  static String _root(String base, String ws) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(ws)}';

  // ============ (الاسترداد السيادي) سجل منشئ المساحة الدائم ============

  /// يسجل creator_device_id لمساحة العمل مرة واحدة فقط — إن كانت العقدة
  /// موجودة لا تُلمس أبداً (غير قابلة للتغيير)، مهما تنقّلت الملكية.
  static Future<void> registerCreatorIfAbsent(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    required String deviceId,
  }) async {
    final path = '${_root(backendUrl, workspaceId)}/creator.json';
    final existing = await _getJson(path);
    if (existing != null &&
        '${existing['creator_device_id'] ?? ''}'.isNotEmpty) {
      return; // مسجل مسبقاً — لا يتغير أبداً.
    }
    await _putJson(path, {
      'creator_device_id': deviceId,
      'registered_at': DateTime.now().toIso8601String(),
      'immutable': true,
    }, timeout: const Duration(seconds: 20));
    // نسخة محلية للعرض السريع دون شبكة.
    try {
      await repo.setSetting('creatorDeviceId', deviceId);
    } catch (_) {}
  }

  /// يجلب معرف جهاز منشئ المساحة من السحابة (أو '' إن لم يسجل بعد).
  static Future<String> fetchCreatorDeviceId({
    required String backendUrl,
    required String workspaceId,
  }) async {
    final rec =
        await _getJson('${_root(backendUrl, workspaceId)}/creator.json');
    return '${rec?['creator_device_id'] ?? ''}';
  }

  /// (أ-2) محو فهرسي الدعوة (PIN + توكن) بعد استهلاكها أو انتهائها —
  /// يمنع تراكم مفاتيح ميتة في `/invite_index`.
  static Future<void> _purgeInviteIndex(String base,
      {String pin = '', String token = ''}) async {
    if (pin.trim().isNotEmpty) {
      try {
        await _delete(_inviteIndexPath(base, _invitePinKey(pin)));
      } catch (_) {}
    }
    if (token.trim().isNotEmpty) {
      try {
        await _delete(_inviteIndexPath(base, _inviteTokenKey(token)));
      } catch (_) {}
    }
  }

  /// يضمن وجود توكن صالح قبل أي طلب — يحل مشكلة 401 بعد تشديد Rules.
  /// كان الكود القديم يستخدم cachedIdToken فقط، فإن كان null يرسل بدون
  /// ?auth فيفشل بـ 401 لأن القواعد الآن auth != null.
  static Future<String?> _ensureToken([String? overrideToken]) async {
    if (overrideToken != null && overrideToken.isNotEmpty) return overrideToken;
    var t = FirebaseAuthRest.cachedIdToken;
    if (t != null && t.isNotEmpty) return t;
    // محاولة إنشاء/تجديد هوية مجهولة تلقائياً
    try {
      t = await FirebaseAuthRest.cloudIdToken();
    } catch (_) {}
    return t;
  }

  /// (401) توقيع أي طلب إلى RTDB بـ `?auth=` — القواعد تشترط `auth != null`.
  static Uri _authedUrl(String url, [String? overrideToken]) {
    final token = overrideToken;
    final uri = Uri.parse(url);
    if (token == null || token.isEmpty) return uri;
    final q = Map<String, String>.from(uri.queryParameters)..['auth'] = token;
    return uri.replace(queryParameters: q);
  }

  static Future<Map<String, dynamic>?> getJson(String url) => _getJson(url);

  static Future<Map<String, dynamic>?> _getJson(String url) async {
    var token = await _ensureToken();
    var uri = _authedUrl(url, token);
    var res = await http.get(uri).timeout(const Duration(seconds: 30));
    if (res.statusCode == 401 || res.statusCode == 403) {
      final fresh = await FirebaseAuthRest.forceRefreshToken();
      if (fresh != null && fresh.isNotEmpty) {
        token = fresh;
        res = await http
            .get(_authedUrl(url, fresh))
            .timeout(const Duration(seconds: 30));
      }
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw CloudJoinException(
          'فشل المصادقة مع السحابة (HTTP ${res.statusCode}). '
          'تحقق من اتصال الإنترنت ومفتاح Firebase ApiKey. '
          'إن استمرت المشكلة، أعد تشغيل التطبيق.');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CloudJoinException('تعذّر الاتصال بالسحابة (HTTP ${res.statusCode})');
    }
    final t = res.body.trim();
    if (t.isEmpty || t == 'null') return null;
    final d = jsonDecode(t);
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  static Future<void> _putJson(String url, Object body,
      {Duration timeout = const Duration(seconds: 60)}) async {
    var token = await _ensureToken();
    if (token == null || token.isEmpty) {
      throw const CloudJoinException(
          'تعذّر إنشاء الدعوة: فشل الحصول على هوية سحابية (لا يوجد توكن). '
          'تحقق من اتصال الإنترنت ومن أن مفتاح Firebase (ApiKey) مضبوط في auth_config.dart، '
          'ثم أعد تشغيل التطبيق.');
    }
    var uri = _authedUrl(url, token);
    var res = await http
        .put(uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(timeout);
    if (res.statusCode == 401 || res.statusCode == 403) {
      final fresh = await FirebaseAuthRest.forceRefreshToken();
      if (fresh != null && fresh.isNotEmpty) {
        res = await http
            .put(_authedUrl(url, fresh),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode(body))
            .timeout(timeout);
      }
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw CloudJoinException(
          'فشل الرفع إلى السحابة: المصادقة مرفوضة (HTTP ${res.statusCode}). '
          'السبب المحتمل: توكن Firebase منتهٍ أو ApiKey غير صحيح أو قواعد RTDB تمنع الكتابة. '
          'الحل: تأكد من الإنترنت، وأن قواعد Firebase هي auth != null، وأن ApiKey صحيح، ثم أعد المحاولة.');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw CloudJoinException('فشل الرفع إلى السحابة (HTTP ${res.statusCode})');
    }
  }

  static Future<void> _delete(String url) async {
    try {
      var token = await _ensureToken();
      var uri = _authedUrl(url, token);
      var res = await http.delete(uri).timeout(const Duration(seconds: 20));
      if (res.statusCode == 401 || res.statusCode == 403) {
        final fresh = await FirebaseAuthRest.forceRefreshToken();
        if (fresh != null) {
          await http
              .delete(_authedUrl(url, fresh))
              .timeout(const Duration(seconds: 20));
        }
      }
    } catch (_) {}
  }

  /// حذف حتمي: يفشل بصوت عالٍ إن لم يتأكد الحذف من الخادم
  static Future<void> _deleteStrict(String url) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        var token = await _ensureToken();
        final res = await http
            .delete(_authedUrl(url, token))
            .timeout(const Duration(seconds: 20));
        if (res.statusCode >= 200 && res.statusCode < 300) return;
        if (res.statusCode == 401 || res.statusCode == 403) {
          final fresh = await FirebaseAuthRest.forceRefreshToken();
          if (fresh != null) {
            final r2 = await http
                .delete(_authedUrl(url, fresh))
                .timeout(const Duration(seconds: 20));
            if (r2.statusCode >= 200 && r2.statusCode < 300) return;
          }
        }
      } catch (_) {}
    }
    throw const CloudJoinException(
        'تعذّر إبطال رمز الدعوة على السحابة — أُلغي الانضمام حفاظاً على الأمان. '
        'تحقق من الاتصال وأعد المحاولة بدعوة جديدة.');
  }

  static void _validateHttps(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.hasScheme || !u.isScheme('https')) {
      throw const CloudJoinException(
          'رابط قاعدة البيانات يجب أن يبدأ بـ https://');
    }
  }

  /// سجل جهاز بصيغة آمنة للرفع (بلا أسرار ولا رموز اقتران).
  static Map<String, Object?> _safeDeviceRow(Map<String, Object?> d) {
    final m = Map<String, Object?>.from(d);
    m['auth_secret'] = '';
    m['pair_token'] = '';
    m['pair_token_exp'] = '';
    // (دفعة 58) أعمدة LAN أُسقطت من المخطط — صفوف roster من إصدارات
    // أقدم قد تحملها فتفشل الإدراج/التحديث.
    m.remove('ip_address');
    m.remove('port');
    return m;
  }

  // ==================== إنشاء الدعوة (المدير) ====================

  /// يرفع لقطة كاملة + رمز دعوة صالح 24 ساعة، ويعيد بيانات الدعوة للعرض.
  static Future<CloudInviteInfo> createInvite(Repo repo) async {
    // الملكية الفعلية (is_owner) هي الحكم — لا وضع sync_meta وحده:
    // خلل سابق كان ينسخ workspaceMode من جهاز عضو أثناء المصالحة فيقلب
    // جهاز المدير إلى «member» زوراً. إن كنا المالك فعلاً نصلح الوضع ذاتياً.
    final owner = await repo.isWorkspaceOwner();
    if (!owner) {
      throw const CloudJoinException(
          'إنشاء دعوة سحابية متاح لجهاز المدير (المالك) فقط.');
    }
    // 🔒 (التجربة) انتهاء الفترة يمنع ربط أجهزة جديدة.
    await _ensureSubscriptionAllows(repo);
    // (الخطط المزدوجة) فتح كود ربط لجهاز ثانٍ = تحول تلقائي لمسار
    // المؤسسات بمقاعده — دون المساس بالعداد الزمني للتجربة.
    try {
      final st0 = await repo.settings();
      final url0 = effectiveBackendUrl(st0['cloudBackendUrl']);
      if (url0.isNotEmpty) {
        final ws0 = await repo.activeWorkspaceId();
        await SubscriptionGuard.promoteToEnterprise(repo,
            backendUrl: url0, workspaceId: ws0);
        // 🪑 حد المقاعد: لا معنى لدعوة جديدة والمقاعد مستنفدة — نرفض
        // مبكراً برسالة المدير بدل فشل متأخر عند موافقة العضو.
        await _ensureSeatAvailable(repo,
            backendUrl: url0,
            workspaceId: ws0,
            joiningDeviceId: '__new__');
      }
    } on CloudJoinException {
      rethrow;
    } catch (_) {}
    final mode = await repo.workspaceMode();
    if (mode == 'member') {
      final db0 = await repo.database;
      await db0.insert(
          'sync_meta', {'key': 'workspaceMode', 'value': 'host'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final st = await repo.settings();
    final url = effectiveBackendUrl(st['cloudBackendUrl']);
    if (url.isEmpty) {
      throw const CloudJoinException(
          'اضبط رابط قاعدة البيانات السحابية أولاً من الإعدادات ← المزامنة السحابية.');
    }
    _validateHttps(url);
    // (إصلاح 401) تأكد من وجود هوية سحابية قبل أي رفع — بعد تشديد Rules إلى auth != null
    // أي طلب بلا ?auth يفشل بـ 401. نحاول إنشاء هوية مجهولة تلقائياً هنا.
    final preToken = await _ensureToken();
    if (preToken == null || preToken.isEmpty) {
      throw const CloudJoinException(
          'تعذّر إنشاء الدعوة: فشل الحصول على هوية سحابية (401). '
          'تحقق من: 1) اتصال الإنترنت، 2) مفتاح Firebase ApiKey في lib/core/auth_config.dart، '
          '3) تفعيل Anonymous Auth في Firebase Console، ثم أعد تشغيل التطبيق.');
    }

    final db = await repo.database;
    final ws = await repo.activeWorkspaceId();
    final ourId = await ensureDeviceId(repo);

    // لقطة بنفس بنية لقطة الاقتران المحلي (تُطبَّق بنفس الدالة عند العضو).
    final snapshot = <String, Object?>{};
    const tables = [
      'sections',
      'accounts',
      'transactions',
      'transaction_items',
      'vouchers',
      'currencies',
      'categories',
      'item_categories',
      'items',
      'stock_moves',
      'conversations',
      'messages',
      'users',
      'trash',
      'activity',
      'workspaces',
      'devices',
    ];
    for (final t in tables) {
      final rows = await db.query(t);
      snapshot[t] = rows.map((source) {
        final row = Map<String, Object?>.from(source);
        if (t == 'users') {
          row['pin'] = '';
          row['password'] = '';
        }
        if (t == 'devices') {
          // عبر السحابة لا نوزّع أسرار الأجهزة إطلاقاً — المصادقة السحابية
          // لا تحتاجها، والدعوة نفسها هي إثبات الانضمام.
          row['auth_secret'] = '';
          row['pair_token'] = '';
          row['pair_token_exp'] = '';
        }
        return row;
      }).toList();
    }
    snapshot['workspaceMode'] = 'member';
    snapshot['hostDeviceId'] = ourId;
    // إعدادات المؤسسة (اسم/عنوان/تذييل السند...) تُنقل مع اللقطة لتحل
    // محل إعدادات الجهاز المنضم القديمة — «حذف كامل» يشمل هويته السابقة.
    try {
      final orgRows = await db.query('settings',
          where:
              "key IN ('businessName','businessNameEn','address','phone','whatsapp','email','managerName','voucherFooter','defaultVoucherNotes')");
      snapshot['orgSettings'] = {
        for (final r in orgRows) '${r['key']}': r['value']
      };
    } catch (_) {}

    final now = DateTime.now();
    final root = _root(url, ws);
    // (دفعة 65) مهلة صريحة وسخية: أثقل عملية في المسار (رفع لقطة
    // المجموعة كاملة). 30 ثانية كانت تسقط المؤسسات الحقيقية على اتصال
    // هاتفي فتفشل الدعوة كلها.
    await _putJson(
      '$root/joinSnapshot.json',
      {
        'createdAt': now.toIso8601String(),
        'hostDeviceId': ourId,
        // (دفعة 57) علامة الضغط: كل عمليات السحابة الأقدم من هذه اللحظة
        // أصبحت مادةً مجسّدة داخل هذه اللقطة — روتين الضغط الدوري يحذفها
        // بأمان (المنضمون الجدد يرتوون من اللقطة لا من إعادة تشغيل السجل).
        'compacted_through_ts': now.millisecondsSinceEpoch,
        'data': snapshot,
      },
      timeout: kCloudSnapshotUploadTimeout,
    );
    // نسجّل العلامة محلياً أيضاً ليعتمدها روتين الضغط.
    try {
      final db2 = await repo.database;
      await db2.insert(
          'sync_meta',
          {
            'key': 'snapshotThroughTs:$ws',
            'value': '${now.millisecondsSinceEpoch}',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (_) {}

    // (الاسترداد السيادي) تسجيل منشئ المساحة مرة واحدة وإلى الأبد:
    // creator_device_id يُكتب فقط إن لم يوجد — لا يتغير مع نقل الملكية
    // أبداً، وهو صمام الأمان الأخير لاسترداد المجموعة. المجموعات القائمة
    // قبل هذه الميزة تُسجَّل بأثر رجعي: المالك الحالي وقت أول دعوة جديدة.
    try {
      await registerCreatorIfAbsent(repo,
          backendUrl: url, workspaceId: ws, deviceId: ourId);
    } catch (_) {}
    // (المرحلة 2) عضوية المالك: /members/{uid} بدور owner — أول عضو في
    // المنشأة، وهو مرجع قواعد الأمان (auth.uid) لكتابة هذه المساحة.
    try {
      await ensureOwnerMembership(repo, backendUrl: url, workspaceId: ws);
    } catch (_) {}

    // ══ (إصلاح جذري — منع تصادم PIN 6 أرقام) ══
    // كان توليد PIN يكتب invite_index/pin_XXXXXX مباشرة دون التحقق من
    // وجوده، فدعوتان متزامنتان بنفس الرقم (احتمال 1/1e6 لكنه حتمي على
    // نطاق واسع) تكتب إحداهما فوق الأخرى — العضو يدخل PIN فيجد مساحة
    // خاطئة أو يفشل. الحل: حلقة توليد مع فحص الفهرس حتى نجد مفتاحاً حراً.
    String token = _newToken();
    String pin = newPairPin();
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        final existTok =
            await _getJson(_inviteIndexPath(url, _inviteTokenKey(token)));
        if (existTok != null) {
          token = _newToken();
          continue;
        }
        final existPin =
            await _getJson(_inviteIndexPath(url, _invitePinKey(pin)));
        if (existPin != null) {
          final exp = DateTime.tryParse('${existPin['expiresAt'] ?? ''}');
          if (exp != null && DateTime.now().isBefore(exp)) {
            pin = newPairPin();
            continue;
          }
        }
        break;
      } catch (_) {
        break;
      }
    }
    // TTL دقيق: 15 دقيقة لمسار الموافقة التفاعلي (كانت 24 ساعة — نافذة
    // أوسع من اللازم أمنياً بعد اعتماد موافقة المدير الصريحة).
    final expires = now.add(const Duration(minutes: 15));
    await _putJson('$root/invites/$token.json', {
      'createdAt': now.toIso8601String(),
      'expiresAt': expires.toIso8601String(),
      'ws': ws,
      'pin': pin,
    }, timeout: const Duration(seconds: 20));

    // (أ-2) فهرسان على الجذر (PIN + توكن) — اكتشاف المساحة بقراءة واحدة
    // بدل مسح كل مساحات العمل. نضمن نجاح الفهرسة بمحاولات متكررة.
    for (var i = 0; i < 3; i++) {
      try {
        await _putJson(_inviteIndexPath(url, _invitePinKey(pin)), {
          'ws': ws,
          'token': token,
          'pin': pin,
          'expiresAt': expires.toIso8601String(),
        }, timeout: const Duration(seconds: 20));
        await _putJson(_inviteIndexPath(url, _inviteTokenKey(token)), {
          'ws': ws,
          'token': token,
          'pin': pin,
          'expiresAt': expires.toIso8601String(),
        }, timeout: const Duration(seconds: 20));
        break;
      } catch (_) {
        if (i < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
    }

    // رفع سجل الأجهزة أيضاً حتى تكون الحالة السحابية كاملة قبل انضمام العضو.
    try {
      final devices = await db.query('devices');
      for (final d in devices) {
        await _putJson('$root/roster/${Uri.encodeComponent('${d['id']}')}.json',
            _safeDeviceRow(d),
            timeout: const Duration(seconds: 20));
      }
    } catch (_) {}

    return CloudInviteInfo(
      backendUrl: url,
      workspaceId: ws,
      token: token,
      cloudCode: (st['cloudCode'] ?? '').trim(),
      expiresAt: expires,
      pin: pin,
    );
  }

  // ==================== الانضمام (الجهاز الجديد) ====================

  /// ينضم إلى المجموعة عبر السحابة:
  /// يتحقق من الدعوة ← يجلب اللقطة ← يحذف كل البيانات المحلية ويستبدلها
  /// بنسخة المجموعة (معاملة واحدة) ← يضبط إعدادات السحابة بنفس رابط المدير
  /// ← يسجل جهازه في سجل الأجهزة السحابي.
  static Future<void> join(
    Repo repo, {
    required String backendUrl,
    required String token,
    String workspaceId = 'default',
    String cloudCode = '',
  }) async {
    final url = backendUrl.trim();
    _validateHttps(url);
    final tok = token.trim().toUpperCase();
    if (tok.isEmpty) {
      throw const CloudJoinException('أدخل رمز الدعوة.');
    }
    final mode = await repo.workspaceMode();
    if (mode == 'member') {
      // ══ (دفعة 65) لا تحبس الجهاز في عضوية منتهية ══
      // الرفض الأعمى كان يترك أي جهاز أُزيل سابقاً بلا مخرج: إزالة
      // الجهاز (removePeerFromCloud) تحذف سجله من /roster، فإن كان
      // الجهاز مغلقاً أو بلا شبكة وقتها لم يعالج الإزالة، فيبقى محلياً
      // `member` للأبد. وحين يحاول الانضمام مجدداً يُرفض بهذه الرسالة
      // فلا ينضم ولا يزامن — «الربط لا يعمل» نهائياً.
      // الفحص الصحيح: هل عضويته في **هذه** المساحة ما زالت فعّالة؟
      // فإن كانت منتهية فالانضمام ترميم مشروع للعضوية.
      final stillActive = await _isActiveCloudMember(
        repo,
        backendUrl: url,
        workspaceId: workspaceId,
      );
      if (stillActive) {
        throw const CloudJoinException(
            'هذا الجهاز عضو فعّال في مجموعة قائمة بالفعل — لا يمكن '
            'الانضمام لمجموعة أخرى.');
      }
      // عضو صوري (مطرود/سجله محذوف) — نكمل الانضمام.
    }

    final root = _root(url, workspaceId);
    final invite = await _getJson('$root/invites/$tok.json');
    if (invite == null) {
      throw const CloudJoinException(
          'رمز الدعوة غير صحيح أو انتهت صلاحيته أو استُخدم من قبل.');
    }
    final exp = DateTime.tryParse('${invite['expiresAt'] ?? ''}');
    if (exp == null || DateTime.now().isAfter(exp)) {
      await _delete('$root/invites/$tok.json');
      throw const CloudJoinException(
          'انتهت صلاحية رمز الدعوة — اطلب من المدير إنشاء دعوة جديدة.');
    }

    // ══ (إصلاح جذري — منع فقدان البيانات) ══
    // كان الترتيب القديم: حذف الدعوة → مسح الجداول → جلب اللقطة.
    // إن فشل جلب اللقطة بعد الحذف والمسح، الجهاز يفقد بياناته المحاسبية
    // ولا يستطيع إعادة المحاولة بنفس الدعوة (لأنها حُذفت) — يعلق بلا بيانات.
    // الترتيب الصحيح: جلب اللقطة أولاً (قراءة فقط)، ثم حذف الدعوة، ثم المسح
    // والتطبيق. هكذا فشل الشبكة أثناء الجلب يترك الجهاز سليماً والدعوة صالحة
    // لإعادة المحاولة.
    final snapRec = await _getJson('$root/joinSnapshot.json');
    final snapData = snapRec?['data'];
    if (snapData is! Map) {
      throw const CloudJoinException(
          'لا توجد نسخة بيانات للمجموعة في السحابة — اطلب من المدير إنشاء دعوة جديدة.');
    }
    final snap = Map<String, Object?>.from(snapData);

    // إبطال الدعوة بعد التأكد من وجود اللقطة — استخدام لمرة واحدة.
    await _deleteStrict('$root/invites/$tok.json');
    await _purgeInviteIndex(url, pin: '${invite['pin'] ?? ''}', token: tok);

    // ══════════ (دفعة 65) الانضمام الآمن — أربع خطوات قبل أي دمج ══════════
    // 1) نسخة احتياطية صامتة — أفضل جهد (فشلها لا يُلغي الانضمام).
    try {
      final data = await repo.exportAll(withImages: false);
      await FactoryReset.silentBackup(data,
          fileName: FactoryReset.kBackupBeforeJoining);
    } catch (e) {
      debugPrint('CloudJoin: silent backup: $e');
    }

    // 2) تفريغ الجداول المحاسبية — تمنع تداخل حركات الموظف السابقة مع
    //    حسابات المتجر. هوية الجهاز وإعداداته لا تُمسّ.
    await FactoryReset.wipeAccountingTables(await repo.database);

    // 3) هوية مجهولة مقترنة بمساحة المالك: تسجيل خروج أي حساب Google
    //    شخصي أولاً، ثم جلسة مجهولة مستقلة لا ترث بصمة الموظف.
    try {
      await GoogleAuthService(await repo.database).signOut();
    } catch (e) {
      debugPrint('CloudJoin: google signOut: $e');
    }
    await FirebaseAuthRest.clearSession(repo);
    await FirebaseAuthRest.resetAnonymousSession(repo);
    await FirebaseAuthRest.ensureScopedAnonymous(repo, workspaceId);
    await FirebaseAuthRest.initSilentAuth(repo);

    // 4) نوع الحساب يصير «مؤسسة» فوراً بعد انضمام ناجح.
    await repo.setSetting('account.type', 'enterprise');

    final db = await repo.database;
    final ourId = await ensureDeviceId(repo);
    // نلتقط سجل جهازنا قبل الاستبدال: إعادة إدراج workspaces بنمط REPLACE
    // قد تحذف سجلنا عبر قيد ON DELETE CASCADE، فنعيد إنشاءه بعد اللقطة.
    final ourRowBefore = await db.query('devices',
        where: 'id = ?', whereArgs: [ourId], limit: 1);
    // حذف كامل البيانات المحلية واستبدالها بنسخة المجموعة (معاملة واحدة):
    // نفس منطق الانضمام المحلي بالضبط — الجهاز يبدأ نظيفاً ببيانات المجموعة.
    await SnapshotApply.applySnapshot(() async => db, ourId, snap);

    // ضمان وجود سجل جهازنا كعضو بعد الاستبدال (يظهر لدى المدير عبر roster).
    final ourRowAfter = await db.query('devices',
        where: 'id = ?', whereArgs: [ourId], limit: 1);
    final ws2 = workspaceId.isNotEmpty && workspaceId != 'default'
        ? workspaceId
        : await repo.activeWorkspaceId();
    final nowIso = DateTime.now().toIso8601String();
    final before = ourRowBefore.isNotEmpty
        ? Map<String, Object?>.from(ourRowBefore.first)
        : <String, Object?>{};
    final myDevName = (before['name'] as String?)?.trim();
    final effectiveMemberName =
        (myDevName != null && myDevName.isNotEmpty) ? myDevName : 'كاشير';

    // فحص إن كان المدير عيّن مستخدماً ودوراً مسبقاً في السجل السحابي
    int? assignedUid;
    UserRole assignedRole = UserRole.cashier;
    try {
      final oldRec = await _getJson(
          '$root/roster/${Uri.encodeComponent(ourId)}.json');
      if (oldRec != null && oldRec.isNotEmpty) {
        if (oldRec['user_id'] is int) assignedUid = oldRec['user_id'] as int;
        final roleCode = '${oldRec['user_role'] ?? ''}';
        if (roleCode.isNotEmpty) {
          assignedRole = UserRole.values.firstWhere(
              (r) => r.code == roleCode,
              orElse: () => UserRole.cashier);
        }
      }
    } catch (_) {}

    final memberPerms = defaultPerms(assignedRole);
    final memberPermStr = memberPerms.entries
        .where((e) => e.value)
        .map((e) => e.key)
        .join(',');

    int? validUid;
    if (assignedUid != null) {
      final userHit = await db.query('users',
          where: 'id = ?', whereArgs: [assignedUid], limit: 1);
      if (userHit.isNotEmpty) {
        validUid = assignedUid;
      }
    }

    final memberUid = validUid ?? await db.insert('users', {
      if (assignedUid != null) 'id': assignedUid,
      'name': effectiveMemberName,
      'role': assignedRole.code,
      'pin': '',
      'password': '',
      'permissions': memberPermStr,
      'is_me': 1,
      'active': 1,
      'workspace_id': ws2,
      'deleted_at': '',
      'created_at': nowIso,
      'updated_at': nowIso,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await db.update('users', {
      'is_me': 1,
      'role': assignedRole.code,
      'permissions': memberPermStr,
    }, where: 'id = ?', whereArgs: [memberUid]);

    if (ourRowAfter.isEmpty) {
      await db.insert(
          'devices',
          {
            'id': ourId,
            'workspace_id': ws2,
            'user_id': memberUid,
            'name': effectiveMemberName,
            'platform': before['platform'] ?? '',
            'auth_secret': before['auth_secret'] ?? '',
            'is_paired': 1,
            'is_owner': 0,
            'revoked_at': '',
            'expelled_at': '',
            'last_seen_at': nowIso,
            'created_at': '${before['created_at'] ?? nowIso}',
            'updated_at': nowIso,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await db.update(
        'devices',
        {
          'workspace_id': ws2,
          'is_owner': 0,
          'user_id': memberUid,
          'updated_at': nowIso,
        },
        where: 'id = ?',
        whereArgs: [ourId],
      );
    }

    // إعدادات السحابة بنفس رابط المدير حتى تعمل المزامنة الفورية مباشرة.
    await repo.setSetting('cloudBackendUrl', url);
    await repo.setSetting('cloudAutoSync', '1');
    // ══ تثبيت ربط العضو بمساحة المنشأة الواحدة حصراً ومحو أي مساحات أخرى ══
    await repo.bindWorkspaceId(workspaceId);
    await repo.setSetting('sync.workspaceId', workspaceId);
    await db.delete('workspaces', where: 'id != ?', whereArgs: [workspaceId]);
    await repo.setSetting('account.type', 'enterprise');
    await db.delete('settings', where: "key IN ('account.email', 'email')");
    await db.insert(
        'sync_meta',
        {
          'key': 'workspaceMode',
          'value': 'member',
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    // (الاسترداد السيادي) كاش سجل المنشئ الدائم محلياً: تتحقق منه
    // apply_remote عند وصول عملية creator_recovery.
    try {
      final creator = await fetchCreatorDeviceId(
          backendUrl: url, workspaceId: workspaceId);
      if (creator.isNotEmpty) {
        await repo.setSetting('creatorDeviceId', creator);
      }
    } catch (_) {}
    if (cloudCode.trim().isNotEmpty) {
      await repo.setSetting('cloudCode', cloudCode.trim().toUpperCase());
    }
    // صفّر كل مؤشرات المزامنة (سحابة/roster/LAN) حتى يُعاد تشغيل كامل
    // تاريخ العمليات فوق اللقطة (idempotent) — الترطيب النظيف يبدأ من
    // إصدار اللقطة بالضبط قبل الاستماع للعمليات الجديدة.
    await db.delete('sync_meta',
        where: "key LIKE 'lastCloudTs:%' OR key LIKE 'lastRosterPush:%' "
            "OR key LIKE 'lastLanTs:%'");

    // مضاد الأشباح: deviceId حتمي من بصمة العتاد — إعادة التثبيت تعيد
    // إنتاج نفس المعرف. إن وُجد سجلنا القديم في roster السحابي (بدوره
    // وصلاحياته) نحييه: نستعيد user_id والاسم ونمسح أي طرد قديم بدل
    // إنشاء جهاز مكرر جديد.
    try {
      final oldRec = await _getJson(
          '$root/roster/${Uri.encodeComponent(ourId)}.json');
      if (oldRec != null && oldRec.isNotEmpty) {
        final nowIso = DateTime.now().toIso8601String();
        await db.update(
          'devices',
          {
            'user_id': oldRec['user_id'],
            'name': (oldRec['name'] as String?)?.trim().isNotEmpty == true
                ? oldRec['name']
                : null,
            'revoked_at': '',
            'expelled_at': '',
            'is_paired': 1,
            'last_seen_at': nowIso,
            'updated_at': nowIso,
          }..removeWhere((k, v) => v == null),
          where: 'id = ?',
          whereArgs: [ourId],
        );
      }
    } catch (_) {}

    // سجّل جهازنا في السجل السحابي حتى يراه المدير ويعيّن له الصلاحيات.
    final own = await db.query('devices',
        where: 'id = ?', whereArgs: [ourId], limit: 1);
    if (own.isNotEmpty) {
      try {
        await _putJson(
            '$root/roster/${Uri.encodeComponent(ourId)}.json',
            {..._safeDeviceRow(own.first), 'user_role': assignedRole.code},
            timeout: const Duration(seconds: 20));
      } catch (_) {}
    }

    // 🔒 تحديث فهرس الأجهزة السحابي فوراً: تسجيل هذا الجهاز كعضو في المساحة الجديدة
    // حتى لا يعيده استرداد العتاد الصامت (WorkspaceRecovery) لمساحته الفردية القديمة.
    try {
      await DeviceRegistry.upsertBinding(repo,
          backendUrl: url, force: true);
    } catch (_) {}

    // الدعوة تُستخدم مرة واحدة (حُذفت مبكراً؛ هذا حذف احتياطي idempotent).
    try {
      await _delete('$root/invites/$tok.json');
    } catch (_) {}
  }

  // ==================== سجل الأجهزة السحابي (roster) ====================

  /// دمج + رفع سجل الأجهزة. تُستدعى مع كل سحب سحابي:
  ///  - الدمج: أي سجل سحابي أحدث من المحلي (updated_at) يُطبَّق محلياً
  ///    (بلا مساس بأسرار المصادقة المحلية ولا بملكية جهازنا).
  ///  - الرفع: المدير يرفع سجلات كل الأجهزة التي تغيّرت، والعضو يرفع سجله فقط.
  static Future<bool> syncRoster(
    Repo repo,
    Database db, {
    required String backendUrl,
    required String workspaceId,
  }) async {
    final root = _root(backendUrl, workspaceId);
    final ourId = (await repo.settings())['sync.deviceId'] ?? '';
    if (ourId.isEmpty) return false;
    final isOwner = await repo.isWorkspaceOwner();
    var changed = false;

    // 1) الدمج من السحابة.
    Map<String, dynamic>? remote;
    try {
      remote = await _getJson('$root/roster.json');
    } catch (_) {
      remote = null;
    }
    if (remote != null && remote.isNotEmpty) {
      final localRows = await db.query('devices');
      final localById = {
        for (final r in localRows) '${r['id']}': Map<String, Object?>.from(r)
      };
      final localWs = workspaceId.isNotEmpty && workspaceId != 'default'
          ? workspaceId
          : await repo.activeWorkspaceId();
      var sawNewPeer = false;
      for (final entry in remote.entries) {
        final v = entry.value;
        if (v is! Map) continue;
        final r = Map<String, Object?>.from(v);
        final id = '${r['id'] ?? entry.key}';
        if (id.isEmpty) continue;
        final remoteUpd = '${r['updated_at'] ?? ''}';
        final local = localById[id];
        if (id == ourId) {
          // سجلنا: المدير هو المرجع في التعيين/التسمية/الحظر/الطرد فقط.
          // المالك لا يُغيَّر اسمه أو دوره محلياً بروستير قادم من السحابة.
          if (local == null) continue;
          final localUpd = '${local['updated_at'] ?? ''}';
          if (remoteUpd.compareTo(localUpd) <= 0) continue;
          final patch = <String, Object?>{
            'revoked_at': r['revoked_at'] ?? '',
            'expelled_at': r['expelled_at'] ?? '',
            'is_paired': r['is_paired'] ?? local['is_paired'],
            'updated_at': remoteUpd,
          };
          if (!isOwner) {
            patch['name'] = r['name'] ?? local['name'];
            patch['user_id'] = r['user_id'];
          }
          await db.update(
            'devices',
            patch,
            where: 'id = ?',
            whereArgs: [id],
          );
          changed = true;
          continue;
        }
        if (local == null) {
          final row = _safeDeviceRow(r);
          // (دفعة 56) user_role حقل عرضي للشارات فقط — ليس عموداً في
          // جدول devices، وإبقاؤه يفشل الإدراج بصمت ويعطل مزامنة السجل.
          row.remove('user_role');
          row['id'] = id;
          row['workspace_id'] = localWs;
          row['created_at'] =
              '${r['created_at'] ?? DateTime.now().toIso8601String()}';
          row['updated_at'] = remoteUpd.isEmpty
              ? DateTime.now().toIso8601String()
              : remoteUpd;
          try {
            await db.insert('devices', row,
                conflictAlgorithm: ConflictAlgorithm.ignore);
            changed = true;
            sawNewPeer = true;
          } catch (_) {}
        } else {
          final localUpd = '${local['updated_at'] ?? ''}';
          if (remoteUpd.compareTo(localUpd) <= 0) continue;
          final row = _safeDeviceRow(r);
          row.remove('id');
          row.remove('created_at');
          // (دفعة 56) حقل عرضي — ليس عموداً في devices (انظر أعلاه).
          row.remove('user_role');
          // لا نلمس سرّ المصادقة المحلي (قد يكون تعلّمه عبر اقتران LAN).
          row.remove('auth_secret');
          row['workspace_id'] = localWs;
          try {
            await db.update('devices', row, where: 'id = ?', whereArgs: [id]);
            changed = true;
            // طرد كامل: انتقال القرين إلى مطرود يطهّر محادثته الفردية
            // من قوائم الدردشة لدى كل الأجهزة التي تصلها المصالحة.
            final wasExpelled =
                '${local['expelled_at'] ?? ''}'.isNotEmpty ||
                    '${local['revoked_at'] ?? ''}'.isNotEmpty;
            final nowExpelled = '${row['expelled_at'] ?? ''}'.isNotEmpty ||
                '${row['revoked_at'] ?? ''}'.isNotEmpty;
            if (nowExpelled && !wasExpelled) {
              try {
                await repo.purgePeerChat(id);
              } catch (_) {}
            }
          } catch (_) {}
        }
      }
      // مدير مستقل انضم إليه أول عضو عن بُعد → المساحة أصبحت مُدارة.
      if (isOwner && sawNewPeer) {
        final mode = await repo.workspaceMode();
        if (mode == 'standalone') {
          await db.insert(
              'sync_meta', {'key': 'workspaceMode', 'value': 'host'},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    }

    // 2) الرفع إلى السحابة (التغييرات فقط منذ آخر رفع).
    try {
      final metaKey = 'lastRosterPush:$workspaceId';
      final metaRows = await db.query('sync_meta',
          where: 'key = ?', whereArgs: [metaKey], limit: 1);
      final lastPush =
          metaRows.isEmpty ? '' : '${metaRows.first['value'] ?? ''}';
      // (دفعة 56) ضمّ دور المستخدم المرتبط لكل جهاز — حتى تعرض بقية
      // الأجهزة شارة الدور الصحيحة فور تغييرها من المدير.
      final rows = isOwner
          ? await db.rawQuery('SELECT d.*, u.role AS user_role '
              'FROM devices d LEFT JOIN users u ON u.id = d.user_id')
          : await db.rawQuery(
              'SELECT d.*, u.role AS user_role FROM devices d '
              'LEFT JOIN users u ON u.id = d.user_id WHERE d.id = ?',
              [ourId]);
      var maxUpd = lastPush;
      for (final d in rows) {
        final upd = '${d['updated_at'] ?? ''}';
        if (upd.compareTo(lastPush) <= 0) continue;
        final map = _safeDeviceRow(Map<String, Object?>.from(d));
        if (!isOwner) {
          map['is_owner'] = 0;
        }
        map['workspace_id'] = workspaceId;
        await _putJson(
            '$root/roster/${Uri.encodeComponent('${d['id']}')}.json',
            map,
            timeout: const Duration(seconds: 20));
        if (upd.compareTo(maxUpd) > 0) maxUpd = upd;
      }
      if (maxUpd.compareTo(lastPush) > 0) {
        await db.insert('sync_meta', {'key': metaKey, 'value': maxUpd},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (_) {}

    return changed;
  }

  // ══════════ خط أنابيب الانضمام بموافقة المدير (دفعة 51) ══════════
  //
  // التدفق: الجهاز الجديد يتحقق من الدعوة (QR أو PIN من 6 أرقام) ثم يدفع
  // طلباً إلى /workspaces/$ws/joinRequests/$deviceId ويدخل حالة
  // «بانتظار موافقة المدير» — حارس صارم: لا سحب لللقطة ولا أي بيانات
  // قبل الموافقة. المدير يرى الطلب، يعيّن دوراً، ويوافق/يرفض. عند
  // الموافقة فقط يُنفَّذ الترطيب النظيف (join الكامل).

  static String requestPath(String base, String ws, String deviceId) =>
      '${_root(base, ws)}/joinRequests/${Uri.encodeComponent(deviceId)}.json';

  /// (الجهاز الجديد — خطوة 3) التحقق من الدعوة/PIN ودفع طلب الانضمام.
  /// لا يمس أي بيانات محلية ولا يسحب اللقطة — يسجّل الطلب فقط.
  /// يتحقق من التوكن الكامل أو رمز PIN المرافق للدعوة (invite.pin).
  /// (المعمارية الصامتة) اكتشاف مساحة العمل من رمز الدعوة وحده:
  /// المستخدم يُدخل PIN من 6 أرقام (أو توكن الدعوة) فقط — لا يعرف معرف
  /// WS-XXXXXXXX الخاص بمدير المجموعة. نمسح مفاتيح /workspaces (shallow)
  /// ونبحث عن دعوة حية مطابقة؛ نعيد معرف المساحة أو null.
  static Future<String?> findWorkspaceByInvite({
    required String backendUrl,
    required String tokenOrPin,
  }) async {
    final url = backendUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final input = tokenOrPin.trim().toUpperCase();
    if (input.isEmpty) return null;
    final isPin = RegExp(r'^\d{6}$').hasMatch(input);
    // (أ-2) الفهرس أولاً: **قراءة واحدة** لعقدة واحدة بدل مسح كل المساحات
    // وقراءة invites كل واحدة (حتى 500 قراءة). هذا هو المسار الطبيعي الآن.
    try {
      final Map<String, dynamic>? rec = await _getJson(_inviteIndexPath(
          url, isPin ? _invitePinKey(input) : _inviteTokenKey(input)));
      if (rec != null) {
        final exp = DateTime.tryParse('${rec['expiresAt'] ?? ''}');
        final ws = '${rec['ws'] ?? ''}'.trim();
        if (ws.isNotEmpty && exp != null && DateTime.now().isBefore(exp)) {
          return ws;
        }
      }
    } catch (_) {}
    // لم توجد في الفهرس (مدير على إصدار ≤ 3.62 أنشأ دعوة بلا فهرس) —
    // المسح القديم يبقى شبكة أمان مؤقتة إلى حين انتشار 3.63.
    if (!legacyInviteScanFallback) return null;
    final keys = await _getJson('$url/workspaces.json?shallow=true');
    if (keys == null) return null;
    // الأحدث إنشاءً لا يمكن تمييزه من shallow — نمسح بالترتيب مع سقف
    // حماية (500 مساحة) يبقي الفحص سريعاً على القاعدة المشتركة.
    var scanned = 0;
    for (final ws in keys.keys) {
      if (++scanned > 500) break;
      try {
        if (isPin) {
          final all = await _getJson(
              '${_root(url, ws)}/invites.json');
          if (all == null) continue;
          for (final e in all.entries) {
            final v = e.value;
            if (v is Map && '${v['pin'] ?? ''}' == input) {
              final exp = DateTime.tryParse('${v['expiresAt'] ?? ''}');
              if (exp != null && DateTime.now().isBefore(exp)) return ws;
            }
          }
        } else {
          final inv = await _getJson(
              '${_root(url, ws)}/invites/${Uri.encodeComponent(input)}.json');
          if (inv != null) {
            final exp = DateTime.tryParse('${inv['expiresAt'] ?? ''}');
            if (exp != null && DateTime.now().isBefore(exp)) return ws;
          }
        }
      } catch (_) {
        // مساحة معطوبة/محظورة قراءةً — تُتجاوز.
      }
    }
    return null;
  }

  static Future<void> requestJoin(
    Repo repo, {
    required String backendUrl,
    required String tokenOrPin,
    required String deviceName,
    String workspaceId = 'default',
  }) async {
    final url = backendUrl.trim();
    _validateHttps(url);
    final input = tokenOrPin.trim().toUpperCase();
    if (input.isEmpty) throw const CloudJoinException('أدخل رمز الاقتران.');
    if (deviceName.trim().isEmpty) {
      throw const CloudJoinException('أدخل اسم الجهاز أولاً.');
    }

    // ══ (توجيه حتمي لمساحة عمل المدير) ══
    // إذا كانت المساحة غير محددة أو افتراضية، نكتشف مساحة المدير الفعلية من الفهرس السحابي أولاً
    var targetWs = workspaceId.trim();
    if (targetWs.isEmpty || targetWs == 'default') {
      final discoveredWs = await findWorkspaceByInvite(
        backendUrl: url,
        tokenOrPin: input,
      );
      if (discoveredWs != null && discoveredWs.isNotEmpty) {
        targetWs = discoveredWs;
      }
    }

    final mode = await repo.workspaceMode();
    if (mode == 'member') {
      // ══ (2026-09-22) لا تحبس العضو المطرود خلف وضع محلي منتهٍ ══
      // طرد المدير (removePeerFromCloud) يحذف سجل الجهاز من /roster، فإن
      // كان جهاز العضو مغلقاً/بلا شبكة وقت الطرد فلم يعالجه، يبقى محلياً
      // `member` للأبد — والرفض الأعمى هنا كان يمنع إعادة دعوته نهائياً
      // («عضو في مجموعة قائمة بالفعل»). الفحص الصحيح: هل عضويته ما زالت
      // فعّالة في السحابة فعلاً؟
      final curWs = repo.requireWorkspaceId;
      final stillActive = await _isActiveCloudMember(
        repo,
        backendUrl: url,
        workspaceId: curWs,
      );
      final sameWs = targetWs.isNotEmpty && targetWs == curWs;
      if (stillActive && !sameWs) {
        throw const CloudJoinException(
            'هذا الجهاز عضو فعّال في مجموعة قائمة بالفعل — لا يمكن '
            'الانضمام لمجموعة أخرى.');
      }
      if (!stillActive) {
        // عضو صوري (مطرود/سجله محذوف): صفّي الوضع المحلي المنتهي ثم
        // اكمل الانضمام — الموافقة والترطيب سيعيدان الربط الصحيح.
        try {
          final db = await repo.database;
          await db.insert(
            'sync_meta',
            {'key': 'workspaceMode', 'value': 'standalone'},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } catch (_) {}
      }
      // sameWs && stillActive: ترميم مشروع لعضوية المجموعة نفسها — نكمل.
    }
    final root = _root(url, targetWs);
    // مطابقة الدعوة: توكن كامل، أو PIN من 6 أرقام (نمسح كل الدعوات الحية).
    String? matchedToken;
    Map<String, dynamic>? invite;
    if (RegExp(r'^\d{6}$').hasMatch(input)) {
      // 1) فحص الفهرس O(1) السريع للحصول على التوكن مباشرة
      try {
        final rec = await _getJson(_inviteIndexPath(url, _invitePinKey(input)));
        if (rec != null) {
          final tok = '${rec['token'] ?? ''}'.trim();
          if (tok.isNotEmpty) {
            final inv = await _getJson('$root/invites/$tok.json');
            if (inv != null) {
              matchedToken = tok;
              invite = inv;
            }
          }
        }
      } catch (_) {}

      // 2) احتياط: إذا لم يُعثر عليه في الفهرس، نفحص قائمة الدعوات تحت مساحة العمل
      if (invite == null) {
        final all = await _getJson('$root/invites.json');
        if (all != null) {
          for (final e in all.entries) {
            final v = e.value;
            if (v is Map && '${v['pin'] ?? ''}' == input) {
              matchedToken = e.key;
              invite = Map<String, dynamic>.from(v);
              break;
            }
          }
        }
      }
    } else {
      invite = await _getJson('$root/invites/$input.json');
      if (invite != null) matchedToken = input;
    }
    if (invite == null || matchedToken == null) {
      throw const CloudJoinException(
          'رمز الاقتران غير صحيح أو انتهت صلاحيته.');
    }
    final exp = DateTime.tryParse('${invite['expiresAt'] ?? ''}');
    if (exp == null || DateTime.now().isAfter(exp)) {
      await _delete('$root/invites/$matchedToken.json');
      await _purgeInviteIndex(url,
          pin: '${invite['pin'] ?? ''}', token: matchedToken);
      throw const CloudJoinException(
          'انتهت صلاحية رمز الاقتران — اطلب من المدير رمزاً جديداً.');
    }
    // (إصلاح 2026-09-18) لا نمحي فهرس الدعوة عند الطلب — فقط عند
    // الانضمام الناجح (join). محو الفهرس عند الطلب كان يمنع إعادة
    // المحاولة بنفس الرمز إذا فشل دفع الطلب شبكياً، ويجبر المسار البطيء
    // (مسح كل المساحات). الآن الفهرس يبقى حتى completeApprovedJoin
    // يحذفه مع الدعوة، فيستطيع العضو إعادة المحاولة بنفس PIN بسهولة.
    // حفظ اسم الجهاز محلياً + دفع الطلب.
    await setDeviceName(repo, deviceName.trim());
    final ourId = await ensureDeviceId(repo);
    final fp = await hardwareFingerprintRaw();

    // ══ (عزل الجهاز تلقائياً من المؤسسة السابقة عند إعادة التثبيت والانضمام لمؤسسة أخرى) ══
    try {
      final fpKey = await DeviceRegistry.fingerprintKey(repo);
      final prevReg = await DeviceRegistry.lookup(
        backendUrl: url,
        fingerprint: fpKey,
      );
      if (prevReg != null &&
          prevReg.role == 'member' &&
          prevReg.workspaceId.isNotEmpty &&
          prevReg.workspaceId != targetWs) {
        final oldWs = prevReg.workspaceId;
        final oldDevId =
            prevReg.deviceId.isNotEmpty ? prevReg.deviceId : ourId;
        final oldRoot = _root(url, oldWs);
        final encOld = Uri.encodeComponent(oldDevId);
        final nowIso = DateTime.now().toIso8601String();
        await _putJson('$oldRoot/evictions/$encOld.json', {
          'deviceId': oldDevId,
          'reason': 'isolated_joined_another_workspace',
          'evictedAt': nowIso,
        });
        final oldRoster = await _getJson('$oldRoot/roster/$encOld.json');
        if (oldRoster != null) {
          await _putJson('$oldRoot/roster/$encOld.json', {
            ...oldRoster,
            'is_paired': 0,
            'revoked_at': nowIso,
            'expelled_at': nowIso,
            'isolation_reason': 'joined_another_workspace',
          });
        }
        await _delete(requestPath(url, oldWs, oldDevId));
      }
    } catch (_) {}
    // (المرحلة 2) هوية الجهاز المنضم (auth.uid) تُسجَّل داخل الطلب ليضيفها
    // المدير إلى /members بالدور الذي يختاره لحظة الموافقة.
    await FirebaseAuthRest.cloudIdToken();
    final joinerUid = FirebaseAuthRest.currentUid;
    await _putJson(requestPath(url, targetWs, ourId), {
      'deviceId': ourId,
      'deviceName': deviceName.trim(),
      'fingerprint': fp == null ? '' : fp.hashCode.toRadixString(16),
      'platform': Platform.operatingSystem,
      'token': matchedToken,
      'uid': joinerUid,
      'status': 'pending',
      'requestedAt': DateTime.now().toIso8601String(),
    }, timeout: const Duration(seconds: 20));
    // حفظ سياق الانتظار محلياً لاستئناف الاستطلاع بعد إعادة التشغيل.
    await repo.setSetting('pendingJoin.url', url);
    await repo.setSetting('pendingJoin.ws', targetWs);
    await repo.setSetting('pendingJoin.token', matchedToken);
  }

  /// فحص هل تم اعتماد الجهاز وتثبيته في سجل الأجهزة السحابي (roster)
  /// يُستخدم كحراسة سيادية تمنع فشل العضو إذا اختفت عقدة /joinRequests
  /// بعد موافقة المدير عليها.
  static Future<bool> isDeviceApprovedInRoster({
    required String backendUrl,
    required String workspaceId,
    required String deviceId,
  }) async {
    try {
      final rec = await _getJson('${_root(backendUrl, workspaceId)}/roster/'
          '${Uri.encodeComponent(deviceId)}.json');
      if (rec == null) return false;
      final isPaired = rec['is_paired'] == 1 ||
          rec['is_paired'] == true ||
          '${rec['is_paired']}' == '1';
      final revoked = '${rec['revoked_at'] ?? ''}'.isNotEmpty;
      final expelled = '${rec['expelled_at'] ?? ''}'.isNotEmpty;
      return isPaired && !revoked && !expelled;
    } catch (_) {
      return false;
    }
  }

  /// (الجهاز الجديد — استطلاع الحالة) يعيد: pending | approved | rejected |
  /// missing. عند approved تُعاد أيضاً بيانات الدور المعيّن.
  static Future<Map<String, String>> pollJoinStatus(
    Repo repo, {
    required String backendUrl,
    required String deviceId,
    String workspaceId = 'default',
  }) async {
    final rec =
        await _getJson(requestPath(backendUrl, workspaceId, deviceId));
    if (rec == null) {
      // ══ (حراسة صلبة 2026-09-29) ══
      // إذا اختفت عقدة الطلب من /joinRequests (بسبب تقليم أو فجوة سباق)،
      // نتحقق مباشرة من سجل الأجهزة السحابي (roster).
      // إذا وجدنا أن المدير قد أضاف الجهاز بالفعل واعتمد اقترانه، نعتبر
      // الطلب معتمداً فوراً ونسترجع التوكن المحفوظ لتبدأ المزامنة بسلاسة.
      try {
        final recRoster = await _getJson(
            '${_root(backendUrl, workspaceId)}/roster/${Uri.encodeComponent(deviceId)}.json');
        if (recRoster != null) {
          final isPaired = recRoster['is_paired'] == 1 ||
              recRoster['is_paired'] == true ||
              '${recRoster['is_paired']}' == '1';
          final revoked = '${recRoster['revoked_at'] ?? ''}'.isNotEmpty;
          final expelled = '${recRoster['expelled_at'] ?? ''}'.isNotEmpty;
          if (isPaired && !revoked && !expelled) {
            final savedToken =
                (await repo.settings())['pendingJoin.token'] ?? '';
            return {
              'status': 'approved',
              'role': '${recRoster['user_role'] ?? 'cashier'}',
              'token': savedToken,
            };
          }
        }
      } catch (_) {}
      return {'status': 'missing'};
    }
    return {
      'status': '${rec['status'] ?? 'pending'}',
      'role': '${rec['role'] ?? ''}',
      'token': '${rec['token'] ?? ''}',
    };
  }

  /// (الجهاز الجديد — خطوة 4ب) بعد الموافقة: الترطيب النظيف الكامل —
  /// مسح ذري + لقطة + مؤشرات. ثم حذف الطلب من السحابة (نظافة).
  static Future<void> completeApprovedJoin(
    Repo repo, {
    required String backendUrl,
    required String token,
    String workspaceId = 'default',
    String cloudCode = '',
  }) async {
    await join(repo,
        backendUrl: backendUrl,
        token: token,
        workspaceId: workspaceId,
        cloudCode: cloudCode);
    final ourId = await ensureDeviceId(repo);
    try {
      await _delete(requestPath(backendUrl, workspaceId, ourId));
    } catch (_) {}
    // (استرداد بصمة العتاد) تسجيل بصمة العضو مربوطة بمساحة المجموعة —
    // حذف التطبيق ثم إعادة تثبيته تعيده عضواً لنفس المجموعة تلقائياً.
    try {
      await DeviceRegistry.bindAsMember(repo,
          backendUrl: backendUrl, workspaceId: workspaceId);
    } catch (_) {}
    // تنظيف سياق الانتظار.
    final db = await repo.database;
    await db.delete('settings',
        where: "key LIKE 'pendingJoin.%'");
  }

  /// تطهير شامل للبيانات المحلية والسحابية السابقة للعضو وعزله عن أي مؤسسة سابقة
  /// لحظة موافقته على تحذير تقديم طلب الانضمام إلى منشأة قائمة.
  static Future<void> purgeAndIsolateJoiningMember(
    Repo repo, {
    required String backendUrl,
    required String targetWorkspaceId,
  }) async {
    final url = backendUrl.trim();
    final db = await repo.database;
    try {
      // 1) تسجيل خروج ومسح أي حساب Google شخصي مرتبط بالجهاز
      try {
        await GoogleAuthService(db).signOut();
      } catch (_) {}
      final oldUid = await FirebaseAuthRest.savedUid(repo);
      var root = url;
      while (root.endsWith('/')) {
        root = root.substring(0, root.length - 1);
      }
      if (root.isNotEmpty && oldUid.isNotEmpty) {
        try {
          await _delete(
              '$root/workspaces/_registry/accounts_index/${Uri.encodeComponent(oldUid)}.json');
        } catch (_) {}
      }
      final st = await repo.settings();
      final oldEmail = (st['account.email'] ?? st['email'] ?? '').trim();
      if (root.isNotEmpty && oldEmail.isNotEmpty) {
        try {
          final emailKey = AccountWorkspace.emailToKey(oldEmail);
          await _delete('$root/workspaces/_registry/emails_index/$emailKey.json');
        } catch (_) {}
      }
      await FirebaseAuthRest.clearSession(repo);
      await db.delete('settings',
          where: "key IN ('account.email','email','user.email')");

      // 2) إذا كان لهذا الجهاز مساحة سابقة خاصة به (كمدير فردي قبل الانضمام)، نحذفها من السحابة
      final oldLocalWs = repo.requireWorkspaceId;
      final ourId = await ensureDeviceId(repo);
      if (root.isNotEmpty &&
          oldLocalWs.isNotEmpty &&
          oldLocalWs != 'default' &&
          oldLocalWs != targetWorkspaceId) {
        final onlyOurs =
            await _workspaceHasOnlyOurDevice(url, oldLocalWs, ourId);
        if (onlyOurs) {
          try {
            await _delete(
                '$root/workspaces/${Uri.encodeComponent(oldLocalWs)}.json');
          } catch (_) {}
        } else {
          // إذا كان عضواً في مؤسسة سابقة، نعزله منها رسمياً
          try {
            final oldRoot = _root(url, oldLocalWs);
            final encOld = Uri.encodeComponent(ourId);
            final nowIso = DateTime.now().toIso8601String();
            await _putJson('$oldRoot/evictions/$encOld.json', {
              'deviceId': ourId,
              'reason': 'isolated_joined_another_workspace',
              'evictedAt': nowIso,
            });
            final oldRoster = await _getJson('$oldRoot/roster/$encOld.json');
            if (oldRoster != null) {
              await _putJson('$oldRoot/roster/$encOld.json', {
                ...oldRoster,
                'is_paired': 0,
                'revoked_at': nowIso,
                'expelled_at': nowIso,
                'isolation_reason': 'joined_another_workspace',
              });
            }
          } catch (_) {}
        }
      }

      // 3) تفريغ جميع الجداول المحاسبية المحلية فوراً قبل إرسال الطلب
      await FactoryReset.wipeAccountingTables(db);
    } catch (_) {}
  }

  /// (دفعة 58 — متطلب 11) «طلب مغادرة»: العضو يكتب طلباً في نفس عقدة
  /// /joinRequests بوسم kind=leave — يصل للمدير لحظياً عبر نفس قناة SSE
  /// ليقرّه (طرد نظيف + بث شاهدة) أو يرفضه.
  /// (إصلاح تسليم الإدارة) رفع فوري لعلم الملكية الجديد إلى roster:
  /// عقدة المالك الجديد تُرفع بـ is_owner=1 ودور admin، وعقدة المدير
  /// السابق بـ is_owner=0 — حتى تلتقط المصالحة الدورية على كل الأجهزة
  /// الملكية الجديدة حتى لو سبقت وصولَ العمليات.
  static Future<void> pushOwnershipToRoster(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    required String newOwnerDeviceId,
    required String previousOwnerDeviceId,
  }) async {
    final url = backendUrl.trim();
    _validateHttps(url);
    final root = _root(url, workspaceId);
    final db = await repo.database;
    for (final id in [newOwnerDeviceId, previousOwnerDeviceId]) {
      final rows = await db.rawQuery(
          'SELECT d.*, u.role AS user_role FROM devices d '
          'LEFT JOIN users u ON u.id = d.user_id WHERE d.id = ?',
          [id]);
      if (rows.isEmpty) continue;
      await _putJson(
          '$root/roster/${Uri.encodeComponent(id)}.json',
          _safeDeviceRow(Map<String, Object?>.from(rows.first)),
          timeout: const Duration(seconds: 20));
    }
  }

  static Future<void> requestLeave(
    Repo repo, {
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final url = backendUrl.trim();
    _validateHttps(url);
    final ourId = await ensureDeviceId(repo);
    final db = await repo.database;
    final own = await db.query('devices',
        where: 'id = ?', whereArgs: [ourId], limit: 1);
    final name = own.isNotEmpty ? '${own.first['name'] ?? ''}'.trim() : '';
    await _putJson(requestPath(url, workspaceId, ourId), {
      'deviceId': ourId,
      'deviceName': name.isEmpty ? 'جهاز عضو' : name,
      'kind': 'leave',
      'platform': Platform.operatingSystem,
      'status': 'pending',
      'requestedAt': DateTime.now().toIso8601String(),
    }, timeout: const Duration(seconds: 20));
  }

  /// (المدير) حذف طلب انضمام/مغادرة من السحابة (رفض أو تنظيف).
  static Future<void> deleteJoinRequest({
    required String backendUrl,
    String workspaceId = 'default',
    required String deviceId,
  }) =>
      _delete(requestPath(backendUrl, workspaceId, deviceId));

  /// (المدير) اعتماد طلب مغادرة عضو: يوسم الطلب بـ approved ليلتقطه العضو فوراً
  static Future<void> approveLeaveRequest({
    required String backendUrl,
    required String workspaceId,
    required String deviceId,
  }) async {
    final path = requestPath(backendUrl, workspaceId, deviceId);
    final req = await _getJson(path);
    await _putJson(path, {
      ...?req,
      'status': 'approved',
      'approvedAt': DateTime.now().toIso8601String(),
    }, timeout: const Duration(seconds: 15));
  }

  /// (العضو) فحص هل تمت الموافقة على المغادرة أو طرد الجهاز من السجل السحابي
  static Future<bool> checkLeaveOrEvicted({
    required String backendUrl,
    required String workspaceId,
    required String deviceId,
  }) async {
    try {
      final root = _root(backendUrl, workspaceId);
      final enc = Uri.encodeComponent(deviceId);
      // 1) فحص حالة طلب المغادرة في السحابة — حصراً لطلبات المغادرة kind == 'leave'
      // منع الخلط القاتل: طلب الانضمام المعتمد (kind == 'join') هو موافقة دخول وليس طرداً!
      final req = await _getJson(requestPath(backendUrl, workspaceId, deviceId));
      if (req != null &&
          '${req['status'] ?? ''}' == 'approved' &&
          '${req['kind'] ?? ''}' == 'leave') {
        return true;
      }
      // 2) فحص عقدة الطرد الصريحة (evictions)
      final eviction = await _getJson('$root/evictions/$enc.json');
      if (eviction != null) {
        return true;
      }
      // 3) فحص عقدة السجل (roster): إذا تم وسمه صراحة كمطرود
      final roster = await _getJson('$root/roster/$enc.json');
      if (roster != null) {
        final expelled = '${roster['expelled_at'] ?? ''}'.trim().isNotEmpty;
        final revoked = '${roster['revoked_at'] ?? ''}'.trim().isNotEmpty;
        if (expelled || revoked) {
          return true;
        }
      }
      // غياب السجل أو تأخره لا يعني أبداً الطرد — لا طرد بالظن أو بالغياب المؤقت
      return false;
    } catch (_) {
      return false;
    }
  }

  /// (العضو) تأكيد وجود الجهاز في سجل الأجهزة السحابي (roster)
  /// إذا كان السجل خالياً من العقدة لأي سبب، يُعاد رفعها لضمان ظهوره لدى المدير في إدارة المجموعة
  static Future<void> ensureMemberRosterPresence({
    required String backendUrl,
    required String workspaceId,
    required String deviceId,
    required Map<String, Object?> deviceRow,
  }) async {
    try {
      // صمام أمان حاسم: لا يُعاد رفع العضو إلى السجل إذا كان موسوماً بالطرد أو الإلغاء
      if ('${deviceRow['expelled_at'] ?? ''}'.isNotEmpty ||
          '${deviceRow['revoked_at'] ?? ''}'.isNotEmpty) {
        return;
      }
      final root = _root(backendUrl, workspaceId);
      final enc = Uri.encodeComponent(deviceId);
      // إذا كانت هناك شاهدة طرد صريحة في /evictions، لا يُعاد رفعه نهائياً
      final eviction = await _getJson('$root/evictions/$enc.json');
      if (eviction != null) {
        return;
      }
      final existing = await _getJson('$root/roster/$enc.json');
      if (existing == null) {
        await _putJson(
          '$root/roster/$enc.json',
          _safeDeviceRow(deviceRow),
          timeout: const Duration(seconds: 15),
        );
      }
    } catch (_) {}
  }

  /// (المدير) جلب طلبات الانضمام والمغادرة المعلّقة.
  static Future<List<Map<String, Object?>>> fetchJoinRequests(
    Repo repo, {
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final all =
        await _getJson('${_root(backendUrl, workspaceId)}/joinRequests.json');
    if (all == null) return const [];

    final out = <Map<String, Object?>>[];
    for (final e in all.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final m = Map<String, Object?>.from(v);
      final status = '${m['status'] ?? 'pending'}';
      if (status != 'pending') continue;
      final devId = '${m['deviceId'] ?? e.key}';
      if (devId.isEmpty) continue;
      m['deviceId'] = devId;
      out.add(m);
    }
    out.sort((a, b) =>
        '${a['requestedAt']}'.compareTo('${b['requestedAt']}'));
    return out;
  }

  /// (المدير — خطوة 4أ) الموافقة: تعيين الدور + تسجيل الجهاز في roster
  /// + تحديث الطلب إلى approved ليستلمه الجهاز المنتظر فوراً.
  /// (إصلاح 2026-09-18 — طلبات الانضمام لا تزال تظهر بعد الموافقة)
  /// كان الترتيب: إنشاء مستخدم + جهاز محلي → رفع roster → كتابة approved.
  /// إن فشلت كتابة approved (شبكة) يبقى الطلب pending في السحابة، فيظهر
  /// مرة أخرى عند المدير رغم أن الجهاز انضاف محلياً — «طلبات لا تزال تظهر».
  /// الإصلاح الجذري: كتابة approved **أولاً** فوراً (يُخفي الطلب من قائمة
  /// pending ويُنبه العضو لحظياً)، ثم إكمال بقية العمل في الخلفية. حتى لو
  /// فشل roster لاحقاً، الطلب يبقى approved ولن يظهر مرة أخرى كـ pending.
  static Future<void> approveJoinRequest(
    Repo repo, {
    required String backendUrl,
    required String deviceId,
    required String deviceName,
    required String roleCode,
    String workspaceId = 'default',
  }) async {
    final owner = await repo.isWorkspaceOwner();
    if (!owner) {
      throw const CloudJoinException('الموافقة لجهاز المدير فقط.');
    }
    final ourOwnDeviceId = await ensureDeviceId(repo);
    if (deviceId == ourOwnDeviceId) {
      throw const CloudJoinException('لا يمكن لجهاز المدير قبول نفسه كعضو في مجموعته.');
    }
    await _ensureSubscriptionAllows(repo);
    await _ensureSeatAvailable(repo,
        backendUrl: backendUrl,
        workspaceId: workspaceId,
        joiningDeviceId: deviceId);

    // 1) اقرأ الطلب الأصلي أولاً (للحصول على uid و token)
    final existingReq =
        await _getJson(requestPath(backendUrl, workspaceId, deviceId));

    // 2) (الإصلاح الجوهري) اكتب approved فوراً — قبل أي عمل محلي ثقيل.
    // هذا يُخفي الطلب من قائمة pending عند كل المديرين، ويُنبه العضو
    // عبر SSE لحظياً ليبدأ الترطيب. حتى لو فشل ما بعده، الطلب لن يظهر
    // كـ pending مرة أخرى.
    try {
      await _putJson(requestPath(backendUrl, workspaceId, deviceId), {
        ...?existingReq,
        'status': 'approved',
        'role': roleCode,
        'approvedAt': {'.sv': 'timestamp'},
        'deleteAfterMs': DateTime.now().millisecondsSinceEpoch +
            _approvedRequestTtl.inMilliseconds,
        'expiresAt':
            DateTime.now().add(_approvedRequestTtl).toIso8601String(),
      }, timeout: const Duration(seconds: 20));
    } catch (e) {
      // فشل كتابة approved = فشل الموافقة كلها — لا نكمل
      throw CloudJoinException(
          '❌ فشل الموافقة: تعذر تحديث حالة الطلب في السحابة.\n'
          'السبب: $e\n'
          'الحل: تحقق من الإنترنت وأعد المحاولة.');
    }

    // 3) الآن أكمل العمل المحلي والرفع السحابي — حتى لو فشل، الطلب
    // يبقى approved ولن يظهر مرة أخرى في قائمة الانتظار.
    final db = await repo.database;
    final now = DateTime.now().toIso8601String();
    final initialRole = UserRole.values.firstWhere((r) => r.code == roleCode,
        orElse: () => UserRole.cashier);
    // منع تعيين رتبة مدير لجهاز منضم عبر الموافقة — الرتبة الافتراضية كاشير
    final role =
        initialRole == UserRole.admin ? UserRole.cashier : initialRole;
    final perms = defaultPerms(role);
    final permStr =
        perms.entries.where((e) => e.value).map((e) => e.key).join(',');

    int uid;
    String effectiveName = deviceName.trim();
    bool reuse = false;
    final existing = await db.query('users',
        columns: ['id'],
        where: "name = ? AND is_me = 0 AND COALESCE(deleted_at,'') = ''",
        whereArgs: [effectiveName],
        limit: 1);
    if (existing.isNotEmpty) {
      final candId = existing.first['id'] as int;
      final linked = await db.query('devices',
          columns: ['id'],
          where:
              "user_id = ? AND id <> ? AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = '' AND is_paired = 1",
          whereArgs: [candId, deviceId],
          limit: 1);
      if (linked.isEmpty) {
        reuse = true;
        uid = candId;
        await db.update(
            'users',
            {
              'role': role.code,
              'permissions': permStr,
              'active': 1,
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: [uid]);
      } else {
        var suffix = 2;
        var baseName = effectiveName;
        while (true) {
          final tryName = '$baseName $suffix';
          final dup = await db.query('users',
              columns: ['id'],
              where: "name = ? AND COALESCE(deleted_at,'') = ''",
              whereArgs: [tryName],
              limit: 1);
          if (dup.isEmpty) {
            effectiveName = tryName;
            break;
          }
          suffix++;
          if (suffix > 99) break;
        }
      }
    }
    if (!reuse) {
      uid = await db.insert('users', {
        'name': effectiveName,
        'role': role.code,
        'pin': '',
        'password': '',
        'permissions': permStr,
        'is_me': 0,
        'active': 1,
        'workspace_id': repo.requireWorkspaceId,
        'deleted_at': '',
        'created_at': now,
        'updated_at': now,
      });
    } else {
      uid = existing.first['id'] as int;
    }

    try {
      final userRow = await db.query('users',
          where: 'id = ?', whereArgs: [uid], limit: 1);
      if (userRow.isNotEmpty) {
        await repo.queueOperation(
          entityType: EntityKind.user,
          entityId: '$uid',
          opType: reuse ? OpKind.update : OpKind.create,
          payload: Map<String, Object?>.from(userRow.first),
        );
      }
    } catch (_) {}

    await db.insert(
        'devices',
        {
          'id': deviceId,
          'workspace_id': repo.requireWorkspaceId,
          'name': deviceName,
          'is_paired': 1,
          'is_owner': 0,
          'user_id': uid,
          'revoked_at': '',
          'expelled_at': '',
          'last_seen_at': now,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);

    // فحص سباق المقاعد بعد الإدراج
    try {
      final rec2 = await _getJson(
          '${_root(backendUrl, workspaceId)}/subscription.json');
      if (rec2 != null) {
        final v2 = rec2['max_devices'];
        final max2 = v2 is num ? v2.toInt() : 0;
        if (max2 > 0) {
          bool activeRow2(Map d) =>
              '${d['revoked_at'] ?? ''}'.isEmpty &&
              '${d['expelled_at'] ?? ''}'.isEmpty;
          int cur2 = await connectedDevicesCount(repo);
          try {
            final r2 = await _getJson(
                '${_root(backendUrl, workspaceId)}/roster.json');
            if (r2 != null) {
              final cloudCount = (r2 as Map).values
                  .whereType<Map>()
                  .where(activeRow2)
                  .length;
              if (cloudCount > cur2) cur2 = cloudCount;
              if (!r2.containsKey(deviceId)) cur2++;
            }
          } catch (_) {}
          if (cur2 > max2) {
            await db.delete('devices', where: 'id = ?', whereArgs: [deviceId]);
            try {
              await db.delete('users', where: 'id = ?', whereArgs: [uid]);
            } catch (_) {}
            // أعد الطلب إلى pending حتى يرى المدير السبب
            try {
              await _putJson(requestPath(backendUrl, workspaceId, deviceId), {
                ...?existingReq,
                'status': 'pending',
                'requestedAt': DateTime.now().toIso8601String(),
                'error': 'seat_limit_$cur2/$max2',
              }, timeout: const Duration(seconds: 20));
            } catch (_) {}
            throw CloudJoinException(
                '🪑 تم استنفاد عدد الأجهزة أثناء الموافقة '
                '($cur2/$max2) — سباق موافقات متزامنة. يرجى المحاولة بعد ترقية الباقة.');
          }
        }
      }
    } catch (e) {
      if (e is CloudJoinException) rethrow;
    }

    // رفع roster و members — أفضل جهد، لا يفشل الموافقة لو تعثر
    final root = _root(backendUrl, workspaceId);
    try {
      final own = await db.query('devices',
          where: 'id = ?', whereArgs: [deviceId], limit: 1);
      if (own.isNotEmpty) {
        await _putJson('$root/roster/${Uri.encodeComponent(deviceId)}.json',
            {..._safeDeviceRow(own.first), 'user_role': role.code},
            timeout: const Duration(seconds: 20));
      }
      final memberUid = '${existingReq?['uid'] ?? ''}'.trim();
      if (memberUid.isNotEmpty) {
        await _putJson(
          '$root/members/${Uri.encodeComponent(memberUid)}.json',
          {
            'role': role.code,
            'uid': memberUid,
            'deviceId': deviceId,
            'joined_at': {'.sv': 'timestamp'},
          },
          timeout: const Duration(seconds: 20),
        );
      }
    } catch (_) {
      // roster فشل — سيُعاد رفعه في دورة المزامنة التالية
    }
  }

  /// ══ (2026-09-22 — توجيه العمليات بين الأجهزة) ══
  /// أين يسكن هذا الجهاز في السحابة؟ يمسح سجلات (roster) كل المساحات
  /// ويعيد المساحة التي تضم معرّف جهازنا، مرجَّحة بالأحدث نشاطاً
  /// (last_sync_at ثم last_seen_at/updated_at).
  ///
  /// هذه هي الحقيقة المشتركة بين الأجهزة: إن اختلف عنها الربط المحلي
  /// كتب الجهاز عملياته في مسار لا يقرأه أحد — «الأسهم خضراء ولا شيء
  /// ينتقل» — وهو بالضبط العطل المُبلَّغ عنه. تُستدعى قبل بناء النقل
  /// السحابي في كل دورة، وعند ربط الحساب.
  /// نتيجة المسح: [workspaceId] المساحة التي يحمل سجلها هذا الجهاز
  /// (أو فارغاً)، و[scanned] هل نجح المسح أصلاً — فتعذّر الوصول
  /// للسحابة **ليس** معناه «لا عضوية»، والخلط بينهما يجعلنا نسترجع
  /// مساحة من الفهرس ثم نُهيّئها فنمحو بيانات مجموعة غيرنا.
  static Future<({String workspaceId, bool scanned})> scanWorkspaceOfDevice(
    String backendUrl,
    String deviceId, {
    int maxScan = 40,
  }) async {
    if (deviceId.isEmpty) return (workspaceId: '', scanned: false);
    final base = backendUrl.replaceAll(RegExp(r'/+$'), '');
    // مفاتيح المساحات فقط (shallow) — قراءة الشجرة كاملة تحمل كل
    // العمليات فتثقل الشبكة بلا داع.
    Map<String, dynamic>? wsMap;
    var scanned = false;
    try {
      final res = await http
          .get(Uri.parse('$base/workspaces.json?shallow=true'))
          .timeout(const Duration(seconds: 20));
      // وصلنا السحابة فعلاً (حتى لو أجابت بلا مساحات) ⇒ المسح ناجح.
      if (res.statusCode >= 200 && res.statusCode < 300) {
        scanned = true;
        final body = utf8.decode(res.bodyBytes).trim();
        if (body.isNotEmpty && body != 'null') {
          final d = jsonDecode(body);
          if (d is Map) {
            wsMap = d.map((k, v) => MapEntry('$k', v));
          }
        }
      }
    } catch (_) {}
    final ids = <String>[];
    wsMap?.forEach((k, _) {
      if (k.isEmpty || k == '_registry') return;
      if (ids.length < maxScan) ids.add(k);
    });
    if (ids.isEmpty) return (workspaceId: '', scanned: scanned);
    String best = '';
    int bestTs = -1;
    for (final ws in ids) {
      Map? row;
      try {
        final r = await _getJson(
            '${_root(backendUrl, ws)}/roster/'
            '${Uri.encodeComponent(deviceId)}.json');
        if (r is Map) row = r;
      } catch (_) {}
      if (row == null) continue;
      int ms(Object? v) =>
          DateTime.tryParse('${v ?? ''}')?.millisecondsSinceEpoch ?? 0;
      final ts = [
        ms(row['last_sync_at']),
        ms(row['last_seen_at']),
        ms(row['updated_at']),
      ].reduce((a, b) => a > b ? a : b);
      if (ts > bestTs) {
        bestTs = ts;
        best = ws;
      }
    }
    return (workspaceId: best, scanned: true);
  }

  /// (2026-09-22) مسح سجلات المساحات للبحث عن سجل هذا الجهاز —
  /// تُعيد فارغاً إن لم يوجد له سجل في أي مساحة.
  static Future<String> findWorkspaceOfDevice(
    String backendUrl,
    String deviceId, {
    int maxScan = 40,
  }) async =>
      (await scanWorkspaceOfDevice(backendUrl, deviceId, maxScan: maxScan))
          .workspaceId;

  /// هل هذه المساحة لجهازنا وحده؟ (لا سجل لعضو آخر فيها) — حارس يمنع
  /// تهيئة مساحة ما زال فيها أعضاء: لا تُمحى بيانات غيرنا ولو بدا
  /// الجهاز «جديداً» (تثبيت جديد أو بعد مسح بياناته).
  static Future<bool> _workspaceHasOnlyOurDevice(
    String backendUrl,
    String workspaceId,
    String deviceId,
  ) async {
    try {
      final raw = await _getJson(
          '${_root(backendUrl, workspaceId)}/roster.json?shallow=true');
      if (raw == null) return false; // غير متأكدين: لا نمحو
      final roster = Map<dynamic, dynamic>.from(raw);
      if (roster.isEmpty) return true;
      for (final k in roster.keys) {
        if ('$k' != deviceId) return false;
      }
      return true;
    } catch (_) {
      return false; // إن تعذّر التحقق لا نُقدم على محو شيء
    }
  }

  /// ══ (2026-09-22 — مساحة واحدة لكل جهاز) ══
  /// البصمة (فهرس device_index) تعرّف الجهاز ولو اختلف بريد جوجل:
  /// نعيد استخدام مساحته السابقة نفسها بدل إنشاء مساحة جديدة لكل
  /// تسجيل — فلا يتفرّق أعضاء المجموعة في مساحات متوازية.
  static Future<String> workspaceOfDeviceIndex(
    Repo repo,
    String backendUrl,
  ) async {
    try {
      final fp = await DeviceRegistry.fingerprintKey(repo);
      if (fp.isEmpty) return '';
      final base = backendUrl.replaceAll(RegExp(r'/+$'), '');
      final rawRec = await _getJson(
          '$base/workspaces/_registry/device_index/'
          '${Uri.encodeComponent(fp)}.json');
      final rec = rawRec == null
          ? const <String, Object?>{}
          : Map<String, Object?>.from(rawRec);
      if (rec.isEmpty) return '';
      final ws = (rec['workspaceId'] ?? '').toString().trim();
      if (ws.isEmpty || ws == 'default') return '';
      // المساحة ما زالت قائمة؟
      final alive = await _getJson('${_root(backendUrl, ws)}/subscription') ??
          await _getJson('${_root(backendUrl, ws)}.json?shallow=true');
      if (alive == null) return '';
      return ws;
    } catch (_) {
      return '';
    }
  }

  /// تهيئة مساحة الجهاز للعمل «كأنها أول مرة»: تُفرغ العمليات
  /// والدعوات والطلبات والدردشة واللقطات والنسخ، وتُبقي رخصة
  /// الاشتراك وسجل جهازنا فقط — فلا يبدأ الجهاز على بيانات قديمة.
  /// يُستدعى فقط عند بداية جديدة (لا بيانات أعمال محلية).
  static Future<void> resetWorkspaceContents(
    String backendUrl,
    String workspaceId, {
    String keepDeviceId = '',
  }) async {
    final root = _root(backendUrl, workspaceId);
    for (final node in const [
      'operations',
      'invites',
      'joinRequests',
      'joinSnapshot',
      'chat',
      'backup',
      'notifications',
      'evictions',
    ]) {
      try {
        await _delete('$root/$node.json');
      } catch (_) {}
    }
    // السجل: نبقي صف جهازنا ونحذف بقية الأجهزة (أعضاء قدامى).
    try {
      final rawRoster = await _getJson('$root/roster.json?shallow=true');
      final roster = rawRoster == null
          ? const <String, Object?>{}
          : Map<String, Object?>.from(rawRoster);
      if (roster.isNotEmpty) {
        for (final k in roster.keys) {
          final id = k;
          if (id.isEmpty || id == keepDeviceId) continue;
          try {
            await _delete(
                '$root/roster/${Uri.encodeComponent(id)}.json');
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// هل هذا الجهاز بلا بيانات أعمال؟ (تثبيت جديد أو بعد تهيئة) — تُتخذ
  /// على ضوئه قرار تنظيف مساحته السحابية عند استرجاعها.
  static Future<bool> _hasNoBusinessData(Repo repo) async {
    try {
      final db = await repo.database;
      for (final t in const ['transactions', 'accounts']) {
        final c = await db.rawQuery('SELECT COUNT(*) c FROM $t');
        final n = (c.first['c'] as int?) ?? 0;
        if (n > 0) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// (2026-09-22) مواءمة ربط المساحة مع السحابة: إن كان سجلنا في مساحة
  /// أخرى غير المحلية نثبّت المحلي عليها — فتعود العمليات تُكتب وتُقرأ
  /// من المسار الذي تقرأه بقية الأجهزة. تعيد المعرف المُثبَّت (أو فارغاً).
  static Future<String> reconcileWorkspaceBinding(
    Repo repo, {
    required String backendUrl,
  }) async {
    try {
      final devId = await ensureDeviceId(repo);
      final current = (await repo.settings())['sync.workspaceId'] ?? '';
      final mode = await repo.workspaceMode();

      // ══ العضو المنضم مقيد حصرياً بمساحة المنشأة المعتمدة ولا يتنقل إطلاقاً ══
      if (mode == 'member' && current.trim().isNotEmpty && current.trim() != 'default') {
        return current.trim();
      }

      // ══ (تحسين الأداء الحاسم 2026-09-29) ══
      // إذا كان الجهاز مقترناً بمساحة محددة بالفعل (خصوصاً المدير المالك أو العضو المسجل):
      // نتحقق مباشرة من سجل تلك المساحة بطلب واحد سريع بدلاً من مسح عشرات المساحات
      if (current.trim().isNotEmpty) {
        final curWs = current.trim();
        try {
          final curRoster = await _getJson(
              '${_root(backendUrl, curWs)}/roster/${Uri.encodeComponent(devId)}.json');
          if (curRoster != null &&
              ('${curRoster['id'] ?? ''}' == devId || curRoster.isNotEmpty)) {
            return curWs;
          }
          if (await repo.isWorkspaceOwner()) {
            final creator = await _getJson(
                '${_root(backendUrl, curWs)}/creator.json');
            if (creator != null &&
                '${creator['creator_device_id'] ?? ''}' == devId) {
              return curWs;
            }
          }
        } catch (_) {}
      }

      // إذا لم يكن في مساحته الحالية، ابحث في فهرس الأجهزة device_index أولاً O(1)
      final fromIndex = await workspaceOfDeviceIndex(repo, backendUrl);
      if (fromIndex.isNotEmpty) {
        if (current.trim() != fromIndex) {
          await repo.bindWorkspaceId(fromIndex);
        }
        return fromIndex;
      }

      final scan = await scanWorkspaceOfDevice(backendUrl, devId, maxScan: 10)
          .timeout(const Duration(seconds: 4),
              onTimeout: () => (workspaceId: '', scanned: false));
      // تعذّر الوصول للسحابة: لا نُغيّر الربط ولا ننظّف شيئاً —
      // المسح الفاشل ليس «بلا عضوية».
      if (!scan.scanned) return '';
      var cloud = scan.workspaceId;
      var freshStart = false;
      if (cloud.isEmpty) {
        cloud = await workspaceOfDeviceIndex(repo, backendUrl);
        if (cloud.isEmpty) return '';
        freshStart = await _hasNoBusinessData(repo) &&
            await _workspaceHasOnlyOurDevice(backendUrl, cloud, devId);
      }
      if (freshStart) {
        await resetWorkspaceContents(backendUrl, cloud, keepDeviceId: devId);
      }
      if (current.trim() == cloud) return cloud;
      await repo.bindWorkspaceId(cloud);
      return cloud;
    } catch (_) {
      return '';
    }
  }

  /// ══ (2026-09-22 — قانون الطرد الكامل) ══
  /// طرد العضو = محوه من المجموعة **ومن السحابة** بلا أي أثر:
  ///   1) عضويته في السجل (/roster/{deviceId}).
  ///   2) أي طلب انضمام معلّق له (بمفتاحه أو بمطابقة deviceId).
  ///   3) عضوية المستخدم (/members/{uid}) المرتبطة بجهازه.
  ///   4) سجله في فهرس الأجهزة (device_index) حتى لا يُستعاد ببصمته.
  ///   5) عقدة محادثته الخاصة إن وُجدت.
  /// إعادة ربطه لاحقاً تُنشئ له نفس المعرّف (جهاز واحد لا جهازان) —
  /// لا ازدواج في السجل ولا في المقاعد.
  static Future<void> expelMemberCompletely(
    Repo repo, {
    required String backendUrl,
    required String deviceId,
    String workspaceId = 'default',
  }) async {
    final base = backendUrl.replaceAll(RegExp(r'/+$'), '');
    final root = _root(backendUrl, workspaceId);
    final enc = Uri.encodeComponent(deviceId);
    // 0) بث شاهدة الطرد الصريحة في /evictions ليراها العضو فوراً في دورة فحصه
    try {
      await _putJson('$root/evictions/$enc.json', {
        'deviceId': deviceId,
        'expelled_at': {'.sv': 'timestamp'},
        'reason': 'expelled_by_manager',
      }, timeout: const Duration(seconds: 15));
    } catch (_) {}
    // 1) عضوية السجل.
    try {
      await _delete('$root/roster/$enc.json');
    } catch (_) {}
    // 2) طلبات الانضمام: بمفتاح الجهاز + مطابقة الحقل (دفاع مزدوج).
    try {
      await _delete(requestPath(backendUrl, workspaceId, deviceId));
    } catch (_) {}
    await _deleteMatching(root, 'joinRequests', deviceId);
    // 3) عضوية المستخدم المرتبطة بهذا الجهاز.
    await _deleteMatching(root, 'members', deviceId);
    // 4) فهرس الأجهزة (بصمة العتاد) — أي سجل يشير لهذا الجهاز بالذات.
    try {
      final idx = await _getJson(
          '$base/workspaces/_registry/device_index.json');
      if (idx != null) {
        for (final e in idx.entries) {
          final v = e.value;
          if (v is! Map) continue;
          if ('${v['device_id'] ?? ''}' == deviceId) {
            try {
              await _delete('$base/workspaces/_registry/device_index/'
                  '${Uri.encodeComponent(e.key)}.json');
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    // 5) محادثته الخاصة.
    try {
      await _delete('$root/chat/$enc.json');
    } catch (_) {}
    // 6) نبض وسجل الجهاز تحت devices.
    try {
      await _delete('$root/devices/$enc.json');
    } catch (_) {}
  }

  /// يحذف كل العقد المطابقة تحت `node` التي يشير حقل `deviceId` فيها
  /// (أو المعرّف نفسه) إلى `deviceId`.
  static Future<void> _deleteMatching(
    String root,
    String node,
    String deviceId,
  ) async {
    try {
      final map = await _getJson('$root/$node.json');
      if (map == null) return;
      for (final e in map.entries) {
        final v = e.value;
        String ref = '';
        if (v is Map) ref = '${v['deviceId'] ?? ''}';
        if (ref.isEmpty && Uri.decodeComponent(e.key) == deviceId) {
          ref = deviceId;
        }
        if (ref == deviceId && deviceId.isNotEmpty) {
          try {
            await _delete(
                '$root/$node/${Uri.encodeComponent(e.key)}.json');
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// ══ (2026-09-22 — مواءمة السجل مع الجدول المحلي) ══
  /// السجل السحابي هو الحقيقة؛ الجدول المحلي قد يحتوي أشباحاً (صفوف
  /// مقترنة بلا عضوية سحابية) فتظهر في قائمة الأجهزة وتُربك عدّ المقاعد.
  /// القاعدة: من له عضوية فعّالة في roster ⇒ مقترن نظيف؛ من لا عضوية له
  /// (وهو ليس المالك ولا جهازنا) ⇒ يُوسم مفصولاً ليظهر في «الأجهزة
  /// المطرودة» بدل أن يُحسب جهازاً مرتبطاً. لا تُلمس صفوف المالك أبداً،
  /// ولا يُنفَّذ شيء إن تعذّرت قراءة roster.
  static Future<int> reconcileRosterWithLocal(
    Repo repo, {
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final root = _root(backendUrl, workspaceId);
    Map<String, dynamic>? roster;
    try {
      roster = await _getJson('$root/roster.json');
    } catch (_) {
      return 0;
    }
    if (roster == null || roster.isEmpty) return 0;
    bool active(Map d) =>
        '${d['revoked_at'] ?? ''}'.isEmpty &&
        '${d['expelled_at'] ?? ''}'.isEmpty;
    final db = await repo.database;
    final ourId = (await repo.settings())['sync.deviceId'] ?? '';
    final rows = await db.query('devices');
    final now = DateTime.now().toIso8601String();
    var fixed = 0;

    // ══ (2026-09-29 — قانون شاشة إدارة المجموعة: لا أشباح في السحابة) ══
    // إذا كان هذا جهاز المدير: أي عضو معتمد بالسحابة يظهر فوراً في إدارة المجموعة
    // وإذا لم يكن موجوداً محلياً يُدرج في جدول devices فوراً لمنع حذفه بالخطأ.
    final localIds = rows.map((r) => '${r['id']}').toSet();
    for (final e in roster.entries) {
      final rId = Uri.decodeComponent(e.key);
      if (rId == ourId || rId.isEmpty) continue;
      final cloudDev = e.value;
      if (cloudDev is! Map || !active(cloudDev)) continue;
      if (!localIds.contains(rId)) {
        try {
          final row = _safeDeviceRow(Map<String, Object?>.from(cloudDev));
          row.remove('user_role');
          row['id'] = rId;
          row['workspace_id'] = workspaceId;
          row['created_at'] = '${cloudDev['created_at'] ?? now}';
          row['updated_at'] = '${cloudDev['updated_at'] ?? now}';
          row['is_paired'] = 1;
          row['is_owner'] = 0;
          row['revoked_at'] = '';
          row['expelled_at'] = '';
          await db.insert('devices', row,
              conflictAlgorithm: ConflictAlgorithm.replace);
          localIds.add(rId);
          fixed++;
        } catch (_) {}
      }
    }

    for (final r in rows) {
      final id = '${r['id']}';
      if (id.isEmpty) continue;
      final isOwner = (r['is_owner'] as int? ?? 0) == 1;
      if (isOwner || id == ourId) continue; // لا نفصل المدير ولا أنفسنا
      final entry = roster[id];
      if (entry is Map && active(entry)) {
        if ((r['is_paired'] as int? ?? 0) != 1 ||
            '${r['revoked_at'] ?? ''}'.isNotEmpty ||
            '${r['expelled_at'] ?? ''}'.isNotEmpty) {
          await db.update(
            'devices',
            {
              'is_paired': 1,
              'revoked_at': '',
              'expelled_at': '',
              'updated_at': now,
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          fixed++;
        }
        continue;
      }
      // بلا عضوية سحابية = شبح (أو مفصول من جهاز آخر) ⇒ وسمه مفصولاً.
      if ('${r['expelled_at'] ?? ''}'.isEmpty ||
          (r['is_paired'] as int? ?? 0) == 1) {
        await db.update(
          'devices',
          {
            'is_paired': 0,
            'revoked_at': now,
            'expelled_at': now,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        fixed++;
      }
    }
    return fixed;
  }

  /// ══ (2026-09-22 — قانون فك الارتباط الشامل) ══
  /// حذف كل الأعضاء رسمياً من المجموعة ومن السحابة (منطقة الخطر):
  /// كل عضو يُمحى من roster وmembers وdevice_index، وتُحذف الدعوات
  /// وطلبات الانضمام. جهاز المدير (صاحب الاستدعاء) لا يُمسّ.
  /// يعيد عدد الأعضاء الذين مُحوا.
  static Future<int> purgeAllMembers(
    Repo repo, {
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final base = backendUrl.replaceAll(RegExp(r'/+$'), '');
    final root = _root(backendUrl, workspaceId);
    var ourId = '';
    try {
      ourId = (await repo.settings())['sync.deviceId'] ?? '';
    } catch (_) {}
    final victims = <String>{};
    try {
      final roster = await _getJson('$root/roster.json');
      if (roster != null) {
        for (final e in roster.entries) {
          final id = Uri.decodeComponent(e.key);
          if (id.isNotEmpty && id != ourId) victims.add(id);
        }
      }
    } catch (_) {}
    for (final id in victims) {
      await expelMemberCompletely(repo,
          backendUrl: backendUrl, deviceId: id, workspaceId: workspaceId);
    }
    // نظافة العقد المشتركة: الدعوات وطلبات الانضمام كلها.
    for (final node in const ['invites', 'joinRequests', 'evictions']) {
      try {
        await _delete('$root/$node.json');
      } catch (_) {}
    }
    // أي فهرس جهاز ما زال يشير لهذه المساحة (عدا بصمة المدير نفسه).
    try {
      final idx = await _getJson(
          '$base/workspaces/_registry/device_index.json');
      if (idx != null) {
        for (final e in idx.entries) {
          final v = e.value;
          if (v is! Map) continue;
          if ('${v['workspaceId'] ?? ''}' == workspaceId &&
              '${v['device_id'] ?? ''}' != ourId) {
            try {
              await _delete('$base/workspaces/_registry/device_index/'
                  '${Uri.encodeComponent(e.key)}.json');
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return victims.length;
  }

  /// (المدير — دفعة 66) إزالة جهاز من المجموعة: حذف عضويته من السجل
  /// السحابي وأي طلب انضمام معلّق له — **بلا أي أثر على جهازه**.
  ///
  /// حلّت محلّ `purgePeerFromCloud` (دفعة 54) التي كانت تكتب «شاهدة
  /// طرد» في /evictions تجبر الجهاز المستهدف على مسح بياناته وإعادة
  /// ضبط نفسه تلقائياً. القرار: لا طرد قسري — إزالة الجهاز تعني توقف
  /// مزامنته مع المجموعة فحسب، وبياناته تبقى بين يديه (ما قبل 3.55).
  static Future<void> removePeerFromCloud(
    Repo repo, {
    required String backendUrl,
    required String deviceId,
    String workspaceId = 'default',
  }) async {
    final root = _root(backendUrl, workspaceId);
    // 1) إزالة عقدة الجهاز من السجل.
    try {
      await _delete('$root/roster/${Uri.encodeComponent(deviceId)}.json');
    } catch (_) {}
    // 2) حذف أي طلب انضمام قديم له (نظافة).
    try {
      await _delete(requestPath(backendUrl, workspaceId, deviceId));
    } catch (_) {}
  }

  /// (المدير — دفعة 55) حل المجموعة نهائياً وإلغاء كل الارتباطات:
  ///  1) كتابة شاهدة طرد لكل جهاز عضو (غير المالك) في /evictions —
  ///     تصلهم لحظياً عبر قنواتهم المخصصة فيبطلون جلساتهم ويعودون مستقلين.
  ///  2) مهلة سماح قصيرة ليلتقط الأعضاء المتصلون الشواهد عبر SSE.
  ///  3) حذف عقدة المجموعة بأكملها من السحابة.
  /// يعيد عدد الأجهزة التي بُثّت لها شواهد.
  static Future<int> dissolveGroup(
    Repo repo, {
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    if (!await repo.isWorkspaceOwner()) {
      throw const CloudJoinException('حل المجموعة متاح لجهاز المدير فقط.');
    }
    final root = _root(backendUrl, workspaceId);
    final db = await repo.database;
    final ourId = (await repo.settings())['sync.deviceId'] ?? '';

    // 1) اجمع كل معرفات الأجهزة: المحلية + السحابية (roster) — اتحاداً،
    //    حتى لا يفلت جهاز موجود سحابياً فقط.
    final ids = <String>{};
    // لا تُكتب شواهد لأجهزة المالك إطلاقاً (جهاز المدير نفسه).
    for (final r in await db.query('devices',
        columns: ['id'], where: 'COALESCE(is_owner, 0) <> 1')) {
      ids.add('${r['id']}');
    }
    try {
      final remote = await _getJson('$root/roster.json');
      if (remote != null) ids.addAll(remote.keys);
    } catch (_) {}
    ids.remove(ourId);
    ids.removeWhere((e) => e.isEmpty);

    // 2) (دفعة 66) لا شواهد طرد عند الحلّ: تُحذف عضوية كل جهاز، وبيانات
    //    كل جهاز تبقى له — الحلّ يُفرغ المجموعة السحابية لا أجهزة
    //    أعضائها (سلوك ما قبل 3.55).
    var removed = 0;
    for (final id in ids) {
      try {
        await _delete('$root/roster/${Uri.encodeComponent(id)}.json');
        removed++;
      } catch (_) {}
    }

    // 3) تفكيك عقدة المجموعة السحابية بالكامل — كل الأقسام عدا
    //    الاشتراك المدفوع (كل قسم على حدة — أفضل جهد).
    for (final node in const [
      'roster',
      'operations',
      'invites',
      'joinRequests',
      'joinSnapshot',
      'members',
      'chat',
      'notifications',
    ]) {
      try {
        await _delete('$root/$node.json');
      } catch (_) {}
    }
    return removed;
  }

  /// تدمير مساحة سحابية مع الاحتفاظ بالاشتراك إن وُجد.
  static Future<void> destroyWorkspaceKeepSubscription(
      String base, String ws) async {
    if (ws.isEmpty || ws == '_registry') return;
    final root = _root(base, ws);
    for (final node in const [
      'roster',
      'operations',
      'invites',
      'joinRequests',
      'joinSnapshot',
      'members',
      'evictions',
      'chat',
      'notifications',
      'devices',
      'backup',
      'creator',
    ]) {
      try {
        await _delete('$root/$node.json');
      } catch (_) {}
    }
  }

  /// حذف المساحة الشخصية للعضو عند الانضمام أو التهيئة.
  static Future<void> deleteIndividualWorkspace(
    Repo repo, {
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final root = _root(backendUrl, workspaceId);
    for (final node in const [
      'roster',
      'operations',
      'invites',
      'joinRequests',
      'joinSnapshot',
      'members',
      'evictions',
      'chat',
      'notifications',
      'devices',
      'backup',
      'creator',
    ]) {
      try {
        await _delete('$root/$node.json');
      } catch (_) {}
    }
  }

  /// حذف قيد الفهرس السحابي accounts_index للحساب الحالي.
  static Future<void> forgetIndex(
      Repo repo, {required String backendUrl}) async {
    try {
      final uid = FirebaseAuthRest.currentUid;
      if (uid.isEmpty) return;
      final base = backendUrl.replaceAll(RegExp(r'/+$'), '');
      for (final p in [
        '$base/workspaces/_registry/accounts_index/'
            '${Uri.encodeComponent(uid)}.json',
        '$base/accounts_index/${Uri.encodeComponent(uid)}.json',
      ]) {
        try {
          await _delete(p);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// مسح الجهاز من السحابة تماماً (للتنظيف وإعادة الضبط).
  static Future<void> purgeDeviceEverywhere(
      Repo repo, {required String backendUrl}) async {
    final base = backendUrl.replaceAll(RegExp(r'/+$'), '');
    final ws = repo.requireWorkspaceId;
    final root = _root(backendUrl, ws);
    String mode = 'standalone';
    try {
      mode = await repo.workspaceMode();
    } catch (_) {}
    if (mode == 'member') {
      final st = await repo.settings();
      final ourId = (st['sync.deviceId'] ?? '').toString();
      if (ourId.isNotEmpty) {
        for (final p in [
          '$root/roster/${Uri.encodeComponent(ourId)}.json',
          '$root/joinRequests/${Uri.encodeComponent(ourId)}.json',
        ]) {
          try {
            await _delete(p);
          } catch (_) {}
        }
      }
      try {
        final uid = FirebaseAuthRest.currentUid;
        if (uid.isNotEmpty) {
          await _delete('$root/members/${Uri.encodeComponent(uid)}.json');
        }
      } catch (_) {}
      if (ourId.isNotEmpty) {
        try {
          final ops = await _getJson('$root/operations.json');
          if (ops != null) {
            for (final e in ops.entries) {
              final v = e.value;
              final dev = v is Map ? '${v['device_id'] ?? ''}' : '';
              if (dev == ourId) {
                try {
                  await _delete(
                      '$root/operations/${Uri.encodeComponent(e.key)}.json');
                } catch (_) {}
              }
            }
          }
        } catch (_) {}
      }
    } else {
      for (final node in const [
        'roster',
        'operations',
        'invites',
        'joinRequests',
        'joinSnapshot',
        'members',
        'evictions',
        'chat',
        'notifications',
        'devices',
        'backup',
        'creator',
      ]) {
        try {
          await _delete('$root/$node.json');
        } catch (_) {}
      }
    }
    try {
      final uid = FirebaseAuthRest.currentUid;
      if (uid.isNotEmpty) {
        final rws =
            await AccountWorkspace.lookup(backendUrl: backendUrl, uid: uid);
        if (rws.isNotEmpty && rws != ws) {
          await destroyWorkspaceKeepSubscription(base, rws);
        }
      }
    } catch (_) {}
    try {
      final fp = await DeviceRegistry.fingerprintKey(repo);
      if (fp.isNotEmpty) {
        final di =
            await _getJson('$base/device_index/${Uri.encodeComponent(fp)}.json');
        final iws = di == null ? '' : '${di['workspaceId'] ?? ''}';
        if (iws.isNotEmpty && iws != ws) {
          await destroyWorkspaceKeepSubscription(base, iws);
        }
        await _delete('$base/device_index/${Uri.encodeComponent(fp)}.json');
      }
    } catch (_) {}
    await forgetIndex(repo, backendUrl: backendUrl);
  }

  /// (المدير — دفعة 57) زوال اللقطة: يحذف الدعوات المنتهية من /invites،
  /// وإن لم تبق أي دعوة حيّة يحذف joinSnapshot.json نهائياً — لقطة
  /// الأعمال الكاملة لا تبقى معلقة بمسار قابل للتخمين بعد انتهاء
  /// نافذة الانضمام (15 دقيقة). يعيد true إن حُذفت اللقطة.
  /// (إصلاح 2026-09-18) كان يحذف اللقطة بمجرد انتهاء الدعوات حتى لو
  /// كان هناك طلبات انضمام معلقة (pending) أو موافق عليها للتو (approved
  /// خلال 10 دقائق) — فيفشل الترطيب عند العضو بـ «لا توجد نسخة بيانات».
  /// الآن يتحقق أيضاً من وجود طلبات معلقة/موافق عليها قبل الحذف.
  static Future<bool> purgeStaleInviteArtifacts({
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final root = _root(backendUrl, workspaceId);
    Map<String, dynamic>? invites;
    try {
      invites = await _getJson('$root/invites.json');
    } catch (_) {
      return false; // شبكة — لا نحذف اللقطة على عمى.
    }
    final now = DateTime.now();
    var liveInvite = false;
    if (invites != null) {
      for (final e in invites.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final exp = DateTime.tryParse('${v['expiresAt'] ?? ''}');
        if (exp != null && now.isBefore(exp)) {
          liveInvite = true; // دعوة سارية — اللقطة ما تزال مطلوبة.
          continue;
        }
        // دعوة منتهية → تُحذف (وفهرساها).
        try {
          await _delete('$root/invites/${Uri.encodeComponent(e.key)}.json');
          await _purgeInviteIndex(backendUrl,
              pin: '${v['pin'] ?? ''}', token: e.key);
        } catch (_) {}
      }
    }
    if (liveInvite) return false;
    // (إصلاح) لا تحذف اللقطة إن كانت هناك طلبات انضمام معلقة أو موافق
    // عليها حديثاً — العضو قد يكون في مرحلة الترطيب الآن.
    try {
      final reqs = await _getJson('$root/joinRequests.json');
      if (reqs != null && reqs.isNotEmpty) {
        for (final v in reqs.values) {
          if (v is! Map) continue;
          final status = '${v['status'] ?? 'pending'}';
          if (status == 'pending') return false; // طلب معلق — اللقطة مطلوبة
          if (status == 'approved') {
            // موافق عليه خلال آخر 10 دقائق — قد يكون العضو ينزل اللقطة الآن
            final exp = DateTime.tryParse('${v['expiresAt'] ?? ''}');
            if (exp != null && now.isBefore(exp)) return false;
            final approvedAt = v['approvedAt'];
            if (approvedAt is Map && approvedAt['.sv'] == 'timestamp') {
              return false; // ختم خادم حديث — لا نحذف
            }
          }
        }
      }
    } catch (_) {
      // تعذر قراءة الطلبات — لا نحذف احتياطاً
      return false;
    }
    // لا دعوات حية ولا طلبات معلقة: هل توجد لقطة أصلاً؟ احذفها.
    try {
      final snap = await _getJson('$root/joinSnapshot.json');
      if (snap == null) return false;
      await _delete('$root/joinSnapshot.json');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// (المدير — دفعة 57) ضغط سجل العمليات السحابي: يحذف كل عملية
  /// server_ts ≤ [throughTsMs] — تُستدعى فقط من SyncEngine بعد التحقق
  /// من أن الحد مغطى بلقطة موثّقة. تحذف على دفعات (استعلام مرشّح
  /// بالفهرس، وتراجع «جلب كامل» عند غياب .indexOn). تعيد عدد المحذوف.
  /// (دفعة 58 — متطلب 4) تطهير سحابي لرسائل الدردشة الأقدم من 24 ساعة:
  /// يحذف من /operations كل عملية entity=message تجاوز server_ts عمرها
  /// المقرر — حمولات المرفقات (base64) تختفي من السحابة نهائياً.
  /// يستدعيها المدير في دورة الصيانة. يعيد عدد العقد المحذوفة.
  static Future<int> purgeOldChatOperations({
    required String backendUrl,
    String workspaceId = 'default',
    Duration ttl = const Duration(hours: 24),
  }) async {
    final root = _root(backendUrl, workspaceId);
    final cutoffMs = DateTime.now().subtract(ttl).millisecondsSinceEpoch;
    Map<String, dynamic>? all;
    try {
      final token = await _ensureToken();
      final uri = Uri.parse('$root/operations.json').replace(
        queryParameters: {
          'orderBy': jsonEncode('server_ts'),
          'endAt': '$cutoffMs',
          if (token != null && token.isNotEmpty) 'auth': token,
        },
      );
      var res = await http.get(uri).timeout(const Duration(seconds: 30));
      if ((res.statusCode == 401 || res.statusCode == 403) && token != null) {
        final fresh = await FirebaseAuthRest.forceRefreshToken();
        if (fresh != null) {
          final rUri = Uri.parse('$root/operations.json').replace(
            queryParameters: {
              'orderBy': jsonEncode('server_ts'),
              'endAt': '$cutoffMs',
              'auth': fresh,
            },
          );
          res = await http.get(rUri).timeout(const Duration(seconds: 30));
        }
      }
      if (res.statusCode == 400 && res.body.contains('Index not defined')) {
        all = await _getJson('$root/operations.json');
      } else if (res.statusCode >= 200 && res.statusCode < 300) {
        final d = jsonDecode(res.body);
        all = d is Map ? Map<String, dynamic>.from(d) : null;
      }
    } catch (_) {
      return 0;
    }
    if (all == null || all.isEmpty) return 0;
    var removed = 0;
    for (final e in all.entries) {
      final v = e.value;
      if (v is! Map) continue;
      if ('${v['entity_type'] ?? ''}' != 'message') continue;
      final ts = (v['server_ts'] as num?)?.toInt() ?? 0;
      if (ts == 0 || ts > cutoffMs) continue;
      try {
        await _delete('$root/operations/${Uri.encodeComponent(e.key)}.json');
        removed++;
      } catch (_) {}
    }
    return removed;
  }

  static Future<int> compactOperations({
    required String backendUrl,
    String workspaceId = 'default',
    required int throughTsMs,
  }) async {
    final root = _root(backendUrl, workspaceId);
    Map<String, dynamic>? all;
    try {
      // ترشيح خادمي إن توفر الفهرس.
      final token = await _ensureToken();
      var uri = Uri.parse('$root/operations.json').replace(
        queryParameters: {
          'orderBy': jsonEncode('server_ts'),
          'endAt': '$throughTsMs',
          if (token != null && token.isNotEmpty) 'auth': token,
        },
      );
      var res = await http.get(uri).timeout(const Duration(seconds: 30));
      if ((res.statusCode == 401 || res.statusCode == 403) && token != null) {
        final fresh = await FirebaseAuthRest.forceRefreshToken();
        if (fresh != null) {
          uri = Uri.parse('$root/operations.json').replace(
            queryParameters: {
              'orderBy': jsonEncode('server_ts'),
              'endAt': '$throughTsMs',
              'auth': fresh,
            },
          );
          res = await http.get(uri).timeout(const Duration(seconds: 30));
        }
      }
      if (res.statusCode == 400 && res.body.contains('Index not defined')) {
        all = await _getJson('$root/operations.json');
      } else if (res.statusCode >= 200 && res.statusCode < 300) {
        final d = jsonDecode(res.body);
        all = d is Map ? Map<String, dynamic>.from(d) : null;
      }
    } catch (_) {
      return 0;
    }
    if (all == null || all.isEmpty) return 0;
    var removed = 0;
    for (final e in all.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final ts = (v['server_ts'] as num?)?.toInt() ?? 0;
      if (ts == 0 || ts > throughTsMs) continue;
      try {
        await _delete(
            '$root/operations/${Uri.encodeComponent(e.key)}.json');
        removed++;
      } catch (_) {}
    }
    return removed;
  }

  /// (أ-2) تقليم فهرس الدعوات المنتهية على الجذر — يمنع تراكم مفاتيح
  /// ميتة في `/invite_index` بعد انتهاء مهلتها (15 دقيقة).
  /// يعيد عدد المفاتيح المُقلَّمة.
  static Future<int> pruneExpiredInviteIndex({
    required String backendUrl,
  }) async {
    Map<String, dynamic>? all;
    final base = backendUrl.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      all = await _getJson('$base/invite_index.json');
    } catch (_) {
      return 0;
    }
    if (all == null || all.isEmpty) return 0;
    final now = DateTime.now();
    var pruned = 0;
    for (final e in all.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final exp = DateTime.tryParse('${v['expiresAt'] ?? ''}');
      if (exp != null && now.isBefore(exp)) continue;
      try {
        await _delete(_inviteIndexPath(backendUrl, e.key));
        pruned++;
      } catch (_) {}
    }
    return pruned;
  }

  /// تقليم طلبات الانضمام التي سُوّي أمرها وانقضت مهلتها (قبولاً أو رفضاً).
  ///
  /// يُستدعى من دورة صيانة المدير بجانب `pruneExpiredEvictions` فيمنع
  /// تراكم `/joinRequests` بلا حذف فوري يُعلّق العضو المنتظر.
  /// يعيد عدد الطلبات المُقلَّمة.
  static Future<int> pruneStaleJoinRequests({
    required String backendUrl,
    String workspaceId = 'default',
  }) async {
    final root = _root(backendUrl, workspaceId);
    Map<String, dynamic>? all;
    try {
      all = await _getJson('$root/joinRequests.json');
    } catch (_) {
      return 0;
    }
    if (all == null || all.isEmpty) return 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var pruned = 0;
    for (final e in all.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final status = '${v['status'] ?? 'pending'}';
      // طلب لا يزال قيد الانتظار؟ لا يُلمس — قرار المدير بانتظاره.
      if (status == 'pending') continue;
      var dueMs = (v['deleteAfterMs'] as num?)?.toInt() ?? 0;
      if (dueMs == 0) {
        final exp = DateTime.tryParse('${v['expiresAt'] ?? ''}');
        if (exp == null) continue; // لا مهلة معروفة — لا نخاطر بالحذف.
        dueMs = exp.millisecondsSinceEpoch;
      }
      if (nowMs < dueMs) continue;
      try {
        await _delete(
            '$root/joinRequests/${Uri.encodeComponent(e.key)}.json');
        pruned++;
      } catch (_) {}
    }
    return pruned;
  }

  /// (المدير — دفعة 56) «حذف نهائي من السجل»: محو كل أثر سحابي لجهاز
  /// مطرود — roster + شاهدة الطرد + طلب الانضمام. يُستدعى بعد أن يكون
  /// الجهاز قد استهلك شاهدته (أو لم يعد يهمنا وصولها): البطاقة تختفي
  /// من كل الأجهزة ولا يبقى ركام في /evictions.
  static Future<void> purgeDeviceRecordFromCloud({
    required String backendUrl,
    required String deviceId,
    String workspaceId = 'default',
  }) async {
    final root = _root(backendUrl, workspaceId);
    final enc = Uri.encodeComponent(deviceId);
    for (final url in [
      '$root/roster/$enc.json',
      '$root/devices/$enc.json',
      '$root/evictions/$enc.json',
      '$root/joinRequests/$enc.json',
    ]) {
      try {
        await _delete(url);
      } catch (_) {}
    }
  }

  /// (المدير) الرفض: تحديث الحالة rejected — الجهاز المنتظر يتلقاها
  /// ويعرضها للمستخدم دون أي مساس ببياناته.
  static Future<void> rejectJoinRequest(
    Repo repo, {
    required String backendUrl,
    required String deviceId,
    String workspaceId = 'default',
  }) async {
    final req =
        await _getJson(requestPath(backendUrl, workspaceId, deviceId));
    await _putJson(requestPath(backendUrl, workspaceId, deviceId), {
      ...?req,
      'status': 'rejected',
      'rejectedAt': DateTime.now().toIso8601String(),
    }, timeout: const Duration(seconds: 20));
  }
}
