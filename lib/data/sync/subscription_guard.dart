// 🔒 محرك الفترة التجريبية الذكية (30-Day Free Trial Engine).
//
// المبادئ الصارمة:
//  1) توقيت الخادم حصراً: التفعيل يُختم بـ {".sv":"timestamp"} على فيربيس،
//     والتحقق يقارن expires_at بوقت الخادم المُستنتج من ختم write-back —
//     لا اعتماد على DateTime.now() للهاتف إطلاقاً في قرار الصلاحية.
//  2) مقاومة التصفير: البصمة العتادية للجهاز تُسجل في فهرس سحابي عالمي
//     (/trials/$fpHash) مستقل عن مساحة العمل — حذف التطبيق أو مسح بياناته
//     أو إنشاء مساحة جديدة يعيد نفس البصمة فيُستأنف العدّاد من سجله الأول.
//  3) بوابة مركزية واحدة (isBlocked) يستشيرها SyncEngine وCloudJoin
//     وCloudSync — انتهاء التجربة يوقف المزامنة والربط والنسخ السحابي،
//     ويبقى العمل المحلي سليماً.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../repository.dart';
import '../../core/license_model.dart';
import 'device_id.dart';

/// مدة التجربة الحالية: شهر كامل (30 يوماً) — تُضبط
/// لاحقاً بتغيير هذا الثابت وحده.
const Duration kTrialDuration = Duration(days: 30);

/// المقاعد الافتراضية لباقة المؤسسات (يرفعها المشغّل من عقدة الاشتراك
/// السحابية `max_devices` بحسب الباقة المباعة).
const int kDefaultEnterpriseSeats = 5;

/// هامش تسامح لانحراف الشبكة عند إسناد وقت الخادم (ثوانٍ قليلة).
const int kServerSkewToleranceMs = 5000;

/// مفاتيح المزايا الثمانية في عقدة features السحابية — القيم الافتراضية
/// حسب الخطة: أثناء التجربة والاشتراك الفعّال كل شيء مفتوح؛ فردي منتهٍ
/// تُقفل مزاياه المدفوعة؛ مؤسسة منتهية تُجمَّد سحابتها.
class PlanFeatures {
  final bool canUseCategories;
  final bool canSendNotifications;
  final bool canCloudBackup;
  final bool canRestoreData;
  final bool canAdvancedSearch;
  final bool multiDeviceSync;
  final bool rolePermissions;
  final bool auditLog;
  final bool cloudSync;
  final bool multiBranch;
  final bool multiUser;
  final bool advancedInvoicing;

  const PlanFeatures({
    required this.canUseCategories,
    required this.canSendNotifications,
    required this.canCloudBackup,
    required this.canRestoreData,
    required this.canAdvancedSearch,
    required this.multiDeviceSync,
    required this.rolePermissions,
    required this.auditLog,
    this.cloudSync = true,
    this.multiBranch = true,
    this.multiUser = true,
    this.advancedInvoicing = true,
  });

  static const allOn = PlanFeatures(
    canUseCategories: true,
    canSendNotifications: true,
    canCloudBackup: true,
    canRestoreData: true,
    canAdvancedSearch: true,
    multiDeviceSync: true,
    rolePermissions: true,
    auditLog: true,
    cloudSync: true,
    multiBranch: true,
    multiUser: true,
    advancedInvoicing: true,
  );

  /// فردي منتهي التجربة: يبقى التسجيل والحركات اليومية محلياً فقط.
  static const individualLocked = PlanFeatures(
    canUseCategories: false,
    canSendNotifications: false,
    canCloudBackup: false,
    canRestoreData: false,
    canAdvancedSearch: false,
    multiDeviceSync: false,
    rolePermissions: false,
    auditLog: false,
    cloudSync: false,
    multiBranch: false,
    multiUser: false,
    advancedInvoicing: false,
  );

  factory PlanFeatures.fromMap(Map<String, dynamic>? m) {
    if (m == null) return allOn;
    bool b(String k, bool dflt) {
      final v = m[k];
      return v is bool ? v : dflt;
    }

    return PlanFeatures(
      canUseCategories: b('can_use_categories', true),
      canSendNotifications: b('can_send_notifications', true),
      canCloudBackup: b('can_cloud_backup', b('cloud_backup', true)),
      canRestoreData: b('can_restore_data', true),
      canAdvancedSearch: b('can_advanced_search', true),
      multiDeviceSync: b('multi_device_sync', b('multi_user', true)),
      rolePermissions: b('role_permissions', true),
      auditLog: b('audit_log', true),
      cloudSync: b('cloud_sync', true),
      multiBranch: b('multi_branch', true),
      multiUser: b('multi_user', true),
      advancedInvoicing: b('advanced_invoicing', true),
    );
  }

  Map<String, Object?> toMap() => {
        'can_use_categories': canUseCategories,
        'can_send_notifications': canSendNotifications,
        'can_cloud_backup': canCloudBackup,
        'can_restore_data': canRestoreData,
        'can_advanced_search': canAdvancedSearch,
        'multi_device_sync': multiDeviceSync,
        'role_permissions': rolePermissions,
        'audit_log': auditLog,
        'cloud_sync': cloudSync,
        'multi_branch': multiBranch,
        'multi_user': multiUser,
        'advanced_invoicing': advancedInvoicing,
      };
}

/// حالة الاشتراك كما تُقرأ من السحابة.
class SubscriptionState {
  /// trial | active | expired | none (لا سحابة مهيأة).
  final String status;

  /// individual | enterprise — يُستنتج تلقائياً (مستقل=فردي، مجموعة=مؤسسة).
  final String planType;

  /// الحد الأقصى للأجهزة (1 للفردي؛ بحسب الباقة للمؤسسة).
  final int maxDevices;

  final int createdAtMs; // ختم خادم فيربيس (ملي ثانية).
  final int expiresAtMs; // ختم خادم.
  final bool isActive;
  final bool isFrozen;
  final String deviceFingerprint;

  /// مفاتيح المزايا من عقدة features السحابية.
  final PlanFeatures features;

  /// وقت الخادم التقريبي لحظة آخر فحص (server_ts المرجعي).
  final int serverNowMs;

  const SubscriptionState({
    required this.status,
    this.planType = 'individual',
    this.maxDevices = 1,
    required this.createdAtMs,
    required this.expiresAtMs,
    required this.isActive,
    this.isFrozen = false,
    required this.deviceFingerprint,
    this.features = PlanFeatures.allOn,
    required this.serverNowMs,
  });

  /// هل انتهت التجربة؟ المقارنة بوقت الخادم حصراً.
  bool get expired =>
      !isFrozen &&
      status != 'active' &&
      expiresAtMs > 0 &&
      serverNowMs >= expiresAtMs;

  /// هل الاشتراك مدفوع وفعّال؟
  bool get isSubscribed => status == 'active' && !isFrozen;

  /// هل الميزة المدفوعة مفتوحة الآن؟ (تجربة سارية أو اشتراك فعّال +
  /// مفتاح الميزة نفسه غير مطفأ من الخادم).
  bool featureUnlocked(bool Function(PlanFeatures) pick) {
    if (status == 'none') return true; // لا سحابة بعد — لا قيود عرضية.
    if (expired && !isSubscribed) return false;
    return pick(features);
  }

  /// المتبقي بالملي ثانية (0 عند الانتهاء). بوقت الخادم.
  int get remainingMs =>
      expired ? 0 : (expiresAtMs - serverNowMs).clamp(0, 1 << 62);

  Duration get remaining => Duration(milliseconds: remainingMs);

  static const none = SubscriptionState(
    status: 'none',
    createdAtMs: 0,
    expiresAtMs: 0,
    isActive: true,
    deviceFingerprint: '',
    serverNowMs: 0,
  );
}

/// المزايا المتقدمة الخاضعة للتقييد في الحساب المقيد (دفعة 65).
enum Feature {
  /// إشعارات ومطالبات الديون عبر واتساب.
  whatsappClaims,

  /// قوالب رسائل مخصصة.
  customTemplates,

  /// تصدير التقارير وكشوف الحساب (PDF / Excel).
  reportsExport,

  /// شعار المتجر على الفواتير والإيصالات الحرارية.
  storeLogo,
}

/// ختم التطبيق الذي يظهر على مخرجات الحساب المقيد (رسائل واتساب، PDF).
///
/// الفلسفة (بقرار صريح): **بدل إغلاق الباب، نترك أثراً لطيفاً**. الحظر
/// الكامل كان يحرم مستخدماً محلياً من مزايا يستعملها يومياً بلا أي نفع
/// مقابل؛ الختم يُبقي الميزة تعمل كاملة ويمنح دافعاً واضحاً للترقية
/// لإزالته — وهو ما يعبّر عنه المستخدم بـ «الشعارات الجمالية».
const String kWatermarkText = 'تمت عبر تطبيق سجل الحسابات';

/// مستوى الوصول إلى ميزة مدفوعة (دفعة 65-ب) — بديل الحظر الثنائي.
enum FeatureAccess {
  /// وصول كامل: بلا ختم وبلا تقليص.
  full,

  /// مسموح **وموسوم**: الميزة تعمل، لكن مخرجاتها تُختم، ويُكتفى في
  /// رسائل الواتساب بإجمالي الحساب دون التفصيل.
  watermarked,
}

/// الحارس المركزي للصلاحيات والمزايا (دفعة 65).
///
/// الحساب **مقيد** في حالتين:
///  ١. مستخدم فردي لم يربط حسابه بالسحابة (`status == 'none'`).
///  ٢. مسجّل بحساب Google لكن فترته التجريبية انتهت دون تجديد
///     (`expired && !isSubscribed`).
///
/// اختلاف معماري مقصود عن [SubscriptionState.featureUnlocked]: ذاك يعتبر
/// `status == 'none'` بلا قيود (لا خطة سحابية أصلاً)، وتبقى البوابات
/// القائمة عليه (`restore`، `cloud_backup`، …) كما هي كي لا يُحرم المستخدم
/// المحلي من بياناته — بينما هذا الحارس يحكم **المزايا المتقدمة** فقط.
class FeatureAccessGuard {
  FeatureAccessGuard._();

  /// هل الحساب مقيد؟
  static bool isRestricted(SubscriptionState sub) =>
      sub.status == 'none' || (sub.expired && !sub.isSubscribed);

  /// مستوى الوصول إلى [feature]: كامل أو موسوم.
  ///
  /// التحوّل الجوهري: الحساب المقيد **لا يُحجب** عن المزايا — الإشعارات
  /// تُرسل، والشعار مسموح، والتصدير متاح — بل تُوسم مخرجاته فقط. الحظر
  /// الكامل كان يعطّل مستخدماً محلياً عن مزايا يومية بلا مقابل، أما الختم
  /// فيحفظ إنتاجيته ويترك له سبباً مفهوماً للترقية.
  static FeatureAccess accessLevel(SubscriptionState sub, Feature feature) {
    if (isRestricted(sub)) return FeatureAccess.watermarked;
    final unlocked = sub.featureUnlocked((p) => switch (feature) {
          Feature.whatsappClaims => p.canSendNotifications,
          Feature.customTemplates => p.canSendNotifications,
          _ => true,
        });
    return unlocked ? FeatureAccess.full : FeatureAccess.watermarked;
  }

  /// هل تُوسم مخرجات [feature] بختم التطبيق؟
  static bool shouldWatermark(SubscriptionState sub, Feature feature) =>
      accessLevel(sub, feature) == FeatureAccess.watermarked;
}

/// حارس الاشتراك: التفعيل، الفحص الدوري بوقت الخادم، والبوابة المركزية.
class SubscriptionGuard {
  SubscriptionGuard._();

  /// آخر حالة مفحوصة (كاش خفيف) + لحظة فحصها بساعة أحادية محلية —
  /// نستخدم Stopwatch (monotonic) لا DateTime.now() حتى لا يكسر تقديم
  /// ساعة الهاتف حساب «العمر منذ آخر فحص».
  static SubscriptionState _last = SubscriptionState.none;
  static final Stopwatch _sinceCheck = Stopwatch();
  static bool _everChecked = false;

  /// نافذة صلاحية الكاش قبل إعادة الفحص السحابي.
  static Duration cacheTtl = const Duration(minutes: 5);

  /// (للاختبارات) تجاوز جالب وقت الخادم — يعيد ملي ثانية خادم فيربيس.
  static Future<int> Function(String backendUrl)? debugServerNowOverride;

  static SubscriptionState get lastState => _last;

  /// تجزئة البصمة العتادية إلى مفتاح سحابي ثابت وآمن (لا نص خام يصعد).
  static String fingerprintHash(String raw) =>
      sha256.convert(utf8.encode(raw.trim())).toString().substring(0, 32);

  static String _wsRoot(String base, String ws) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(ws)}';

  static String _trialsRoot(String base) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/trials';

  /// **المرجع الوحيد** لمعرف مساحة العمل الذي تُقرأ به عقدة الترخيص.
  ///
  /// (إصلاح 2026-09-23) مسارات الترخيص كانت تقرأ `workspaces` بـ limit 1
  /// بلا ترتيب ⇒ أول صف مُدرج (مساحة الجهاز الشخصية القديمة) حتى بعد ربطه
  /// بمجموعة — فيُحسم الترخيص على عقدة اشتراك **غير** العقدة التي يدفع
  /// إليها الجهاز ويفعّلها الأدمن («الترخيص لا يعمل»). الربط الصريح في
  /// الإعدادات هو الحكم (نفس قانون ensureWorkspace)، ثم المعرّف المحمّل.
  static Future<String> workspaceIdFor(Repo repo) async {
    try {
      final st = await repo.settings();
      final bound = (st['sync.workspaceId'] ?? '').toString().trim();
      if (bound.isNotEmpty) return bound;
    } catch (_) {}
    return repo.requireWorkspaceId;
  }

  /// وقت خادم فيربيس الحقيقي — بطبقتين مؤمّنتين:
  ///  1) الأساس: كتابة {".sv":"timestamp"} وقراءة الناتج (الختم يحسبه
  ///     خادم فيربيس نفسه — الكتابة المشوّهة من عميل متلاعب لا تغيّره،
  ///     وقواعد الأمان يمكنها حصر هذا المسار دون كسر الآلية).
  ///  2) تحقق تقاطعي + احتياط: ترويسة HTTP `Date` من استجابة الخادم —
  ///     إن انحرف الختم عنها انحرافاً فاحشاً (>10 دقائق) نرفض القيمة
  ///     (حماية من backend مزيف يعيد أختاماً معدلة)، وإن فشلت الكتابة
  ///     (قواعد أمان تمنعها) نعتمد الترويسة نفسها كمصدر وقت موثوق —
  ///     فهي من خادم Google ولا سبيل للعميل للتلاعب بها.
  static Future<int> serverNowMs(String backendUrl) async {
    final o = debugServerNowOverride;
    if (o != null) return o(backendUrl);
    final base = backendUrl.replaceAll(RegExp(r'/+$'), '');
    final url = '$base/server_clock.json';
    http.Response res;
    try {
      res = await http
          .put(Uri.parse(url),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'ts': {'.sv': 'timestamp'}}))
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      return _serverNowFromDateHeader(base);
    }
    // ترويسة Date من نفس الاستجابة — للتقاطع أو الاحتياط.
    final headerMs = _parseHttpDate(res.headers['date']);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // قواعد الأمان تمنع الكتابة؟ الترويسة تكفي كمصدر خادمي موثوق.
      if (headerMs > 0) return headerMs;
      return _serverNowFromDateHeader(base);
    }
    final m = jsonDecode(res.body);
    final ts = m is Map ? m['ts'] : null;
    final tsMs = ts is int ? ts : (ts is num ? ts.toInt() : 0);
    if (tsMs > 0) {
      // تقاطع: ختم منحرف >10 دقائق عن ترويسة الخادم = مصدر مشبوه.
      const crossTolMs = 10 * 60 * 1000;
      if (headerMs > 0 && (tsMs - headerMs).abs() > crossTolMs) {
        throw StateError('server-clock-cross-check-failed');
      }
      return tsMs;
    }
    if (headerMs > 0) return headerMs;
    throw StateError('server-clock-bad-payload');
  }

  /// احتياط: وقت الخادم من ترويسة HTTP Date لطلب قراءة خفيف (لا كتابة).
  static Future<int> _serverNowFromDateHeader(String base) async {
    final res = await http
        .get(Uri.parse('$base/server_clock.json'))
        .timeout(const Duration(seconds: 15));
    final ms = _parseHttpDate(res.headers['date']);
    if (ms > 0) return ms;
    throw StateError('server-clock-no-date-header');
  }

  /// تفكيك ترويسة HTTP Date (RFC 1123 بتوقيت GMT) إلى مللي ثانية UTC.
  static int _parseHttpDate(String? v) {
    if (v == null || v.isEmpty) return 0;
    try {
      return HttpDate.parse(v).millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }

  /// تفعيل التجربة عند أول إعداد سحابي لمساحة العمل:
  ///  1) فحص فهرس /trials/$fp — بصمة سبق أن استهلكت تجربة تستأنف سجلها
  ///     الأصلي (منع التصفير بإعادة التثبيت/مساحة جديدة).
  ///  2) وإلا: كتابة سجل جديد بختم خادم، ثم write-back لحساب expires_at
  ///     خادمياً (created_at + kTrialDuration) وتثبيته رقماً.
  static Future<SubscriptionState> ensureTrialStarted(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
  }) async {
    final devId = await ensureDeviceId(repo);
    final raw = await hardwareFingerprintRaw() ?? 'fallback:$devId';
    final hwFp = fingerprintHash(raw);
    // (معمارية حساب Google) الترخيص والفترة التجريبية يتبعان الحساب إن
    // سجّل المستخدم دخوله — فيبقيان معه عند تغيير الهاتف. بلا حساب:
    // بصمة العتاد كما كان (لا كسر للمستخدمين القائمين).
    final acctUid =
        ((await repo.settings())['account.uid'] ?? '').trim();
    final fp = acctUid.isEmpty ? hwFp : fingerprintHash('uid:$acctUid');
    final wsSub = '${_wsRoot(backendUrl, workspaceId)}/subscription.json';
    final trialIdx = '${_trialsRoot(backendUrl)}/$fp.json';
    final hwTrialIdx = '${_trialsRoot(backendUrl)}/$hwFp.json';
    // (الخطط المزدوجة) plan_type يُستنتج تلقائياً: العمل المنفرد = فردي؛
    // مجموعة قائمة (host/member) = مؤسسة بمقاعدها الافتراضية.
    final planType = await _detectPlanType(repo);
    final maxDevices =
        planType == 'enterprise' ? kDefaultEnterpriseSeats : 1;

    final st = await repo.settings();
    final clientName =
        (st['sync.deviceName'] ?? st['account.name'] ?? '').trim();
    final storeName = (st['businessName'] ?? '').trim();
    final phone = (st['phone'] ?? st['whatsapp'] ?? '').trim();
    final licenseKey = generateLicenseKey(devId);

    // (1) عقدة المساحة موجودة مسبقاً؟ لا إعادة تفعيل أبداً — نعيد قراءتها.
    //     (يشمل المستخدمين القدامى الذين هُيّئت عقدتهم في إقلاع سابق.)
    final existing = await _readJson(wsSub);
    if (existing != null && (existing['expires_at'] is num) &&
        (existing['expires_at'] as num) > 0) {
      return _stateFrom(existing, await serverNowMs(backendUrl));
    }
    // (1-ب) إصلاح عقدة نصف مكتوبة (انقطاع بين خطوتي الكتابة): created_at
    //     الخادمي موجود لكن expires_at لم يُثبَّت — نكمل الحساب من الختم
    //     الأصلي نفسه دون أي تصفير للعداد.
    if (existing != null) {
      final priorCreated = _asInt(existing['created_at']);
      if (priorCreated > 0) {
        final repaired = {
          'clientName': clientName,
          'storeName': storeName,
          'phone': phone,
          'deviceId': devId,
          'licenseKey': licenseKey,
          'expiryDate': priorCreated + kTrialDuration.inMilliseconds,
          'status': '${existing['status'] ?? 'trial'}',
          'client_name': clientName,
          'store_name': storeName,
          'device_id': devId,
          'license_key': licenseKey,
          'created_at': priorCreated,
          'expires_at': priorCreated + kTrialDuration.inMilliseconds,
          'is_active': existing['is_active'] != false,
          'device_fingerprint':
              '${existing['device_fingerprint'] ?? ''}'.isNotEmpty
                  ? existing['device_fingerprint']
                  : fp,
        };
        await _putJson(wsSub, repaired);
        await _putJson(trialIdx, {
          ...repaired,
          'workspace_id': workspaceId,
          'first_seen': priorCreated,
          // معرف الجهاز صراحة: تطبيق الأدمن يطابق DEVICE-… مباشرة.
          'device_id': devId,
        });
        return _stateFrom(
            Map<String, dynamic>.from(repaired), await serverNowMs(backendUrl));
      }
    }

    // (2) فهرس البصمة العالمي: تجربة سابقة لنفس الهوية = استئناف لا تصفير.
    //     مع حساب Google: نفحص فهرس الحساب أولاً، ثم فهرس العتاد —
    //     تسجيل الدخول لا يصفّر تجربة بدأت قبل الربط على نفس الجهاز.
    var prior = await _readJson(trialIdx);
    if (prior == null && fp != hwFp) {
      prior = await _readJson(hwTrialIdx);
    }
    if (prior != null && (prior['expires_at'] is num) &&
        (prior['expires_at'] as num) > 0) {
      final resumed = {
        'clientName': clientName.isNotEmpty
            ? clientName
            : '${prior['clientName'] ?? prior['client_name'] ?? ''}',
        'storeName': storeName.isNotEmpty
            ? storeName
            : '${prior['storeName'] ?? prior['store_name'] ?? ''}',
        'phone': phone.isNotEmpty
            ? phone
            : '${prior['phone'] ?? prior['whatsapp'] ?? ''}',
        'deviceId': devId,
        'licenseKey': licenseKey,
        'expiryDate': prior['expires_at'],
        'status': '${prior['status'] ?? 'trial'}',
        'created_at': prior['created_at'],
        'expires_at': prior['expires_at'],
        'is_active': true,
        'device_fingerprint': fp,
        'resumed': true,
      };
      await _putJson(wsSub, resumed);
      // ترقيع الفهرس القديم: سجلات ما قبل هذا الإصدار بلا device_id —
      // نضيفه ليتمكن تطبيق الأدمن من المطابقة المباشرة.
      if ('${prior['device_id'] ?? ''}'.isEmpty) {
        await _putJson(trialIdx, {
          ...prior,
          'workspace_id': '${prior['workspace_id'] ?? ''}'.isEmpty
              ? workspaceId
              : prior['workspace_id'],
          'device_id': devId,
        });
      }
      return _stateFrom(resumed, await serverNowMs(backendUrl));
    }

    // (3) تفعيل جديد: ختم خادم ثم تثبيت expires_at رقمياً من قيمة الخادم
    //     المكتوبة فعلاً (write-back) — الحساب خادمي بالكامل.
    await _putJson(wsSub, {
      'clientName': clientName,
      'storeName': storeName,
      'phone': phone,
      'deviceId': devId,
      'licenseKey': licenseKey,
      'expiryDate': 0,
      'status': 'trial',
      'client_name': clientName,
      'store_name': storeName,
      'device_id': devId,
      'license_key': licenseKey,
      'plan_type': planType,
      'max_devices': maxDevices,
      'created_at': {'.sv': 'timestamp'},
      'expires_at': 0,
      'is_active': true,
      'device_fingerprint': fp,
      'features': PlanFeatures.allOn.toMap(),
    });
    final written = await _readJson(wsSub) ?? {};
    final createdMs = _asInt(written['created_at']);
    final expiresMs = createdMs + kTrialDuration.inMilliseconds;
    final finalRec = {
      'clientName': clientName,
      'storeName': storeName,
      'phone': phone,
      'deviceId': devId,
      'licenseKey': licenseKey,
      'expiryDate': expiresMs,
      'status': 'trial',
      'client_name': clientName,
      'store_name': storeName,
      'device_id': devId,
      'license_key': licenseKey,
      'plan_type': planType,
      'max_devices': maxDevices,
      'created_at': createdMs,
      'expires_at': expiresMs,
      'is_active': true,
      'device_fingerprint': fp,
      'features': PlanFeatures.allOn.toMap(),
    };
    await _putJson(wsSub, finalRec);
    // فهرس البصمة العالمي — صمّام منع إعادة الاستغلال.
    await _putJson(trialIdx, {
      ...finalRec,
      'workspace_id': workspaceId,
      'first_seen': createdMs,
      // معرف الجهاز صراحة: تطبيق الأدمن يطابق DEVICE-… مباشرة.
      'device_id': devId,
    });
    return _stateFrom(finalRec, createdMs);
  }

  /// تسجيل طلب تفعيل / ترخيص جديد مع إرفاق كافة بيانات المنشأة والمسؤول.
  static Future<void> registerLicenseRequest(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    required String clientName,
    required String storeName,
    required String phone,
    required String deviceId,
    required String licenseKey,
  }) async {
    final devId = deviceId.isNotEmpty ? deviceId : await ensureDeviceId(repo);
    final key = licenseKey.isNotEmpty ? licenseKey : generateLicenseKey(devId);
    final raw = await hardwareFingerprintRaw() ?? 'fallback:$devId';
    final hwFp = fingerprintHash(raw);
    final trialIdx = '${_trialsRoot(backendUrl)}/$hwFp.json';
    final reqPath = '${_wsRoot(backendUrl, workspaceId)}/license_request.json';

    final data = {
      'clientName': clientName,
      'storeName': storeName,
      'phone': phone,
      'deviceId': devId,
      'licenseKey': key,
      'requested_at': {'.sv': 'timestamp'},
      'workspace_id': workspaceId,
      'client_name': clientName,
      'store_name': storeName,
      'device_id': devId,
      'license_key': key,
    };
    try {
      await _putJson(reqPath, data);
    } catch (_) {}
    try {
      await _putJson(trialIdx, {
        'clientName': clientName,
        'storeName': storeName,
        'phone': phone,
        'deviceId': devId,
        'licenseKey': key,
        'client_name': clientName,
        'store_name': storeName,
        'device_id': devId,
        'license_key': key,
        'workspace_id': workspaceId,
      });
    } catch (_) {}
  }

  /// الفحص المرجعي: يقرأ العقدة ويقارن بوقت الخادم. يحدّث الكاش
  /// ويثبّت آخر حالة ناجحة محلياً (settings) حتى يبقى العدّاد ظاهراً
  /// بعد إغلاق التطبيق وفتحه ولو تعذرت الشبكة لحظة الإقلاع.
  static Future<SubscriptionState> check(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    bool force = false,
  }) async {
    if (!force &&
        _everChecked &&
        _sinceCheck.elapsed < cacheTtl) {
      // إسناد لحظي: نقدّم وقت الخادم المرجعي بعمر الكاش (ساعة أحادية
      // لا تتأثر بتلاعب ساعة الهاتف) — العدّاد يتجدد بين الفحوصات
      // بدل التجمد على قيمة آخر فحص.
      return _advanced();
    }
    try {
      final wsSub = '${_wsRoot(backendUrl, workspaceId)}/subscription.json';
      var rec = await _readJson(wsSub);
      final now = await serverNowMs(backendUrl);
      if (rec == null) {
        // لا عقدة اشتراك بعد — فعّل التجربة الآن (أول استخدام سحابي).
        final st = await ensureTrialStarted(repo,
            backendUrl: backendUrl, workspaceId: workspaceId);
        _cache(st);
        await _persist(repo, st);
        return st;
      }
      final st = _stateFrom(rec, now);
      _cache(st);
      await _persist(repo, st);
      // (ترقيع صامت) سجلات /trials القديمة بلا device_id: نضيفه مرة
      // واحدة عند أول فحص ناجح — الأجهزة القائمة تصبح قابلة للمطابقة
      // في تطبيق الأدمن دون انتظار إعادة تفعيل.
      unawaited(_backfillTrialDeviceId(repo, backendUrl));
      return st;
    } catch (_) {
      // شبكة غائبة: آخر حالة معروفة في الذاكرة، وإلا (إقلاع جديد بلا
      // شبكة) الحالة المثبّتة محلياً من آخر فحص ناجح — الشريط لا يختفي.
      if (_everChecked) return _advanced();
      final persisted = await _loadPersisted(repo);
      if (persisted != null) {
        _cache(persisted);
        return persisted;
      }
      return _last;
    }
  }

  /// ترقيع لمرة واحدة: إضافة device_id لسجل /trials القديم إن غاب.
  static bool _backfilledOnce = false;
  static Future<void> _backfillTrialDeviceId(
      Repo repo, String backendUrl) async {
    if (_backfilledOnce) return;
    _backfilledOnce = true;
    try {
      final devId = await ensureDeviceId(repo);
      final acctUid = ((await repo.settings())['account.uid'] ?? '').trim();
      final raw = await hardwareFingerprintRaw() ?? 'fallback:$devId';
      final hwFp = fingerprintHash(raw);
      // (إصلاح 2026-09-23) الترخيص يتبع حساب Google متى سجّل المستخدم
      // دخوله، ومفتاح فهرس /trials حينئذٍ sha256('uid:…') لا بصمة العتاد.
      // الترقيع القديم كان يقرأ عقدة العتاد وحدها ⇒ سجلات العملاء
      // المرتبطين بحساب تبقى بلا device_id، فيعجز الأدمن عن مطابقة
      // DEVICE-… بها ويبدو التفعيل كأنه لم يُسجَّل. نفحص المفتاحين.
      final root = _trialsRoot(backendUrl);
      final keys = <String>{
        if (acctUid.isNotEmpty) fingerprintHash('uid:$acctUid'),
        hwFp,
      };
      for (final fp in keys) {
        final idx = '$root/$fp.json';
        final rec = await _readJson(idx);
        if (rec == null) continue; // لا سجل — جرّب المفتاح الآخر.
        if ('${rec['device_id'] ?? ''}'.isNotEmpty) continue; // مرقّع أصلاً.
        await _putJson(idx, {...rec, 'device_id': devId});
        return;
      }
    } catch (_) {} // تحسيني بحت — لا يعطل الفحص.
  }

  /// (للاختبارات) تنفيذ الترقيع صراحة داخل runWithClient.
  static Future<void> debugBackfillTrialDeviceId(
          Repo repo, String backendUrl) =>
      _backfillTrialDeviceId(repo, backendUrl);

  /// آخر حالة مع تقديم وقت الخادم المرجعي بعمر الكاش (monotonic).
  static SubscriptionState _advanced() {
    if (!_everChecked || _last.serverNowMs <= 0) return _last;
    return SubscriptionState(
      status: _last.status,
      createdAtMs: _last.createdAtMs,
      expiresAtMs: _last.expiresAtMs,
      isActive: _last.isActive,
      deviceFingerprint: _last.deviceFingerprint,
      serverNowMs: _last.serverNowMs + _sinceCheck.elapsedMilliseconds,
    );
  }

  /// تثبيت آخر حالة ناجحة محلياً — تُقرأ عند الإقلاع بلا شبكة.
  static Future<void> _persist(Repo repo, SubscriptionState st) async {
    try {
      if (st.status == 'none') return;
      await repo.setSetting(
          'subCachedState',
          jsonEncode({
            'status': st.status,
            'plan_type': st.planType,
            'max_devices': st.maxDevices,
            'created_at': st.createdAtMs,
            'expires_at': st.expiresAtMs,
            'is_active': st.isActive,
            'fp': st.deviceFingerprint,
            'features': st.features.toMap(),
            'server_now': st.serverNowMs,
            'device_ms': DateTime.now().millisecondsSinceEpoch,
          }));
    } catch (_) {}
  }

  /// استرجاع الحالة المثبّتة محلياً مع إسناد تقديري لوقت الخادم
  /// (لأغراض العرض فقط — البوابات تُحسم بفحص سحابي حقيقي عند توفر
  /// الشبكة، ولا يُسمح للإسناد بإرجاع الساعة للخلف).
  /// (للاختبار فقط) كشف مسار الاسترجاع المحلي — يمر عبر نفس منطق
  /// كشف التراجع الزمني الحقيقي.
  static Future<SubscriptionState?> debugLoadPersisted(Repo repo) =>
      _loadPersisted(repo);

  static Future<SubscriptionState?> _loadPersisted(Repo repo) async {
    try {
      final raw = (await repo.settings())['subCachedState'] ?? '';
      if (raw.isEmpty) return null;
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final serverNow = _asInt(m['server_now']);
      final deviceMs = _asInt(m['device_ms']);
      final nowDevice = DateTime.now().millisecondsSinceEpoch;
      // 🛡️ (كشف التلاعب) ساعة الهاتف الآن أقدم من لحظة آخر تثبيت =
      // المستخدم أرجع الساعة للخلف وهو بلا شبكة. لا نكافئه: نعتبر
      // الجلسة المحلية منتهية الصلاحية فوراً (المزايا المدفوعة تُقفل)
      // حتى يتصل بالإنترنت ويحسم فحص سحابي حقيقي بساعة الخادم.
      // هامش دقيقتين يمتص فروق NTP/التوقيت الصيفي المشروعة.
      const rollbackGraceMs = 2 * 60 * 1000;
      if (deviceMs > 0 && nowDevice < deviceMs - rollbackGraceMs) {
        final rawFeat0 = m['features'];
        return SubscriptionState(
          status: '${m['status'] ?? 'trial'}' == 'active'
              ? 'active' // المشترك المدفوع لا يعاقَب — الخادم يحسم لاحقاً.
              : 'trial',
          planType: '${m['plan_type'] ?? 'individual'}' == 'enterprise'
              ? 'enterprise'
              : 'individual',
          maxDevices:
              _asInt(m['max_devices']) > 0 ? _asInt(m['max_devices']) : 1,
          createdAtMs: _asInt(m['created_at']),
          expiresAtMs: _asInt(m['expires_at']),
          isActive: m['is_active'] != false,
          deviceFingerprint: '${m['fp'] ?? ''}',
          features: PlanFeatures.fromMap(rawFeat0 is Map
              ? Map<String, dynamic>.from(rawFeat0)
              : null),
          // إسناد وقت الخادم إلى expires_at مباشرة ⇒ expired=true
          // للتجربة، فتُقفل كل المزايا المدفوعة حتى الفحص السحابي.
          serverNowMs: _asInt(m['expires_at']) > 0
              ? _asInt(m['expires_at'])
              : serverNow,
        );
      }
      // الإسناد للأمام فقط: إرجاع ساعة الهاتف لا يُرجع وقت الخادم.
      final drift = (nowDevice - deviceMs).clamp(0, 1 << 62);
      final rawFeat = m['features'];
      return SubscriptionState(
        status: '${m['status'] ?? 'trial'}',
        planType:
            '${m['plan_type'] ?? 'individual'}' == 'enterprise'
                ? 'enterprise'
                : 'individual',
        maxDevices: _asInt(m['max_devices']) > 0 ? _asInt(m['max_devices']) : 1,
        createdAtMs: _asInt(m['created_at']),
        expiresAtMs: _asInt(m['expires_at']),
        isActive: m['is_active'] != false,
        deviceFingerprint: '${m['fp'] ?? ''}',
        features: PlanFeatures.fromMap(
            rawFeat is Map ? Map<String, dynamic>.from(rawFeat) : null),
        serverNowMs: serverNow + drift,
      );
    } catch (_) {
      return null;
    }
  }

  /// البوابة المركزية: true = السحابة محظورة (التجربة انتهت وغير مدفوع، أو الحساب مجمّد).
  /// تُستدعى قبل أي دفع/سحب/ربط/نسخ سحابي.
  static Future<bool> isBlocked(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
  }) async {
    final st = await check(repo,
        backendUrl: backendUrl, workspaceId: workspaceId);
    if (st.isFrozen) return true; // مجمّد عن بعد عبر مفتاح القفل الفوري
    if (st.status == 'active') return false; // اشتراك مدفوع فعّال.
    if (st.status == 'none') return false; // لا سحابة — لا حظر.
    return st.expired;
  }

  static void _cache(SubscriptionState st) {
    _last = st;
    _everChecked = true;
    _sinceCheck
      ..reset()
      ..start();
  }

  /// (للاختبارات) تصفير الكاش.
  static void debugReset() {
    _last = SubscriptionState.none;
    _everChecked = false;
    _backfilledOnce = false;
    _sinceCheck
      ..stop()
      ..reset();
  }

  static SubscriptionState _stateFrom(Map<String, dynamic> m, int nowMs) {
    final rawFeat = m['feature_flags'] ?? m['features'];
    final frozen = m['is_frozen'] == true ||
        '${m['status']}'.trim().toLowerCase() == 'suspended';
    return SubscriptionState(
      status: frozen ? 'suspended' : '${m['status'] ?? 'trial'}',
      isFrozen: frozen,
      planType: '${m['plan_type'] ?? 'individual'}' == 'enterprise'
          ? 'enterprise'
          : 'individual',
      maxDevices: (() {
        final v = m['max_devices'];
        if (v is int && v > 0) return v;
        if (v is num && v > 0) return v.toInt();
        return '${m['plan_type'] ?? ''}' == 'enterprise'
            ? kDefaultEnterpriseSeats
            : 1;
      })(),
      createdAtMs: _asInt(m['created_at']),
      expiresAtMs: _asInt(m['expires_at']),
      isActive: m['is_active'] != false,
      deviceFingerprint: '${m['device_fingerprint'] ?? ''}',
      features: PlanFeatures.fromMap(
          rawFeat is Map ? Map<String, dynamic>.from(rawFeat) : null),
      serverNowMs: nowMs,
    );
  }

  /// استنتاج المسار تلقائياً: مجموعة قائمة (مضيف أو عضو) = مؤسسة؛
  /// العمل المنفرد = فردي.
  static Future<String> _detectPlanType(Repo repo) async {
    try {
      final mode = await repo.workspaceMode();
      if (mode == 'host' || mode == 'member') return 'enterprise';
      // مضيف فعلي بأجهزة مقترنة أخرى (حتى لو تلكأ الوضع) = مؤسسة.
      final db = await repo.database;
      final peers = await db.rawQuery(
          "SELECT COUNT(*) c FROM devices WHERE is_paired = 1 "
          "AND COALESCE(revoked_at,'') = '' AND COALESCE(expelled_at,'') = ''");
      final c = (peers.first['c'] as int?) ?? 0;
      if (c > 1) return 'enterprise';
    } catch (_) {}
    return 'individual';
  }

  /// الترقية التلقائية للمسار: بمجرد إنشاء مجموعة/فتح كود ربط لجهاز ثانٍ
  /// يتحول الاشتراك إلى enterprise بمقاعده — دون المساس بالعداد الزمني
  /// (created_at/expires_at يبقيان كما هما بختم الخادم الأصلي).
  static Future<void> promoteToEnterprise(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    int? maxDevices,
  }) async {
    final wsSub = '${_wsRoot(backendUrl, workspaceId)}/subscription.json';
    final rec = await _readJson(wsSub);
    if (rec == null) return; // لا عقدة بعد — ensureTrialStarted سينشئها.
    if ('${rec['plan_type'] ?? ''}' == 'enterprise') return; // مرقّاة أصلاً.
    final seats = maxDevices ?? kDefaultEnterpriseSeats;
    await _putJson(wsSub, {
      ...rec,
      'plan_type': 'enterprise',
      'max_devices':
          (rec['max_devices'] is num && (rec['max_devices'] as num) > seats)
              ? rec['max_devices']
              : seats,
      'features': (rec['features'] is Map)
          ? rec['features']
          : PlanFeatures.allOn.toMap(),
    });
    debugReset(); // الفحص التالي يقرأ الخطة الجديدة فوراً.
  }

  /// تحويل آمن لأي قيمة سحابية إلى عدد صحيح (timestamps و max_devices).
  /// (كان اسمه _asMs فيُقرأ خطأً مخصّصاً بالأختام فقط.)
  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  static Future<Map<String, dynamic>?> _readJson(String url) async {
    final res =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('subscription-http-${res.statusCode}');
    }
    final t = res.body.trim();
    if (t.isEmpty || t == 'null') return null;
    final d = jsonDecode(t);
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  static Future<void> _putJson(String url, Object body) async {
    final res = await http
        .put(Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('subscription-put-http-${res.statusCode}');
    }
  }
}
