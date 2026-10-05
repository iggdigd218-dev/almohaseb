// نظام التحديث المركزي.
//
// يقرأ بيان إصدار (version.json) يُنشر تلقائيًا مع كل إصدار على GitHub،
// يقارنه بإصدار التطبيق الحالي، ويقرر: لا تحديث / تحديث اختياري / تحديث إجباري.
// التنزيل والتثبيت يتمّان بفتح رابط الإصدار في المتصفح — لا نُنزّل ونُثبّت
// حزمًا تلقائيًا لأن ذلك يتطلب أذونات خطرة على أندرويد ولا يعمل في المتاجر.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../core/app_version.dart';
import '../core/platform_info.dart';

/// مفتاح معالج أندرويد الحالي، أو `null` إن لم نعرفه (منصّة أخرى).
///
/// يُستعمل لاختيار حزمة APK المطابقة من بيان الإصدار: الحزمة المُقسّمة
/// حسب المعالج (split-per-abi) أصغر بنحو النصف من الشاملة، فإن تعذّرت
/// معرفة المعالج رجعنا إلى الشاملة (`downloads.android`) بلا ضرر.
String? androidAbiKey() {
  if (!PlatformInfo.isAndroid) return null;
  switch (ffi.Abi.current()) {
    case ffi.Abi.androidArm64:
      return 'arm64';
    case ffi.Abi.androidArm:
      return 'armv7';
    case ffi.Abi.androidX64:
      return 'x64';
    default:
      return null;
  }
}

/// يختار رابط APK الأصغر المناسب للجهاز من خريطة `downloads` في version.json.
///
/// الترتيب: حزمة المعالج المطابق (`androidVariants.<abi>`) ← الشاملة
/// (`android`). روابط غير `https://` تُرفض، وأي نقص يرجّع `null` فيبقى
/// سلوك التحديث كما كان (فتح صفحة الإصدار).
String? pickAndroidApkUrl(Object? downloads, String? abiKey) {
  if (downloads is! Map) return null;
  if (abiKey != null) {
    final variants = downloads['androidVariants'];
    if (variants is Map) {
      final v = variants[abiKey];
      if (v is String && v.startsWith('https://')) return v;
    }
  }
  final v = downloads['android'];
  return (v is String && v.startsWith('https://')) ? v : null;
}

/// نتيجة فحص التحديث.
enum UpdateStatus {
  /// التطبيق محدّث.
  upToDate,

  /// يوجد إصدار أحدث (اختياري).
  available,

  /// يوجد إصدار أحدث وإلزامي (الإصدار الحالي أقدم من minSupported).
  required_,

  /// تعذّر الفحص (لا شبكة / خطأ خادم / بيان تالف).
  unknown,
}

/// منصّة التنزيل المطلوبة.
enum UpdatePlatform { android, windows, other }

class UpdateInfo {
  final UpdateStatus status;
  final AppSemVer current;
  final AppSemVer? latest;

  /// أدنى إصدار مدعوم؛ أقل منه = تحديث إجباري.
  final AppSemVer? minSupported;

  /// رابط صفحة الإصدار (يُفتح في المتصفح).
  final String? releaseUrl;

  /// رابط الملف المباشر للمنصّة الحالية إن وُجد.
  final String? downloadUrl;

  /// ملاحظات الإصدار بالعربية.
  final String notes;

  /// تاريخ النشر إن وُجد.
  final DateTime? publishedAt;

  /// سبب الفشل عند status == unknown.
  final String? error;

  const UpdateInfo({
    required this.status,
    required this.current,
    this.latest,
    this.minSupported,
    this.releaseUrl,
    this.downloadUrl,
    this.notes = '',
    this.publishedAt,
    this.error,
  });

  bool get hasUpdate =>
      status == UpdateStatus.available || status == UpdateStatus.required_;

  bool get isMandatory => status == UpdateStatus.required_;

  /// نص مختصر للعرض.
  String get headline => switch (status) {
        UpdateStatus.upToDate => 'التطبيق محدَّث',
        UpdateStatus.available => 'يتوفّر تحديث جديد',
        UpdateStatus.required_ => 'تحديث إلزامي مطلوب',
        UpdateStatus.unknown => 'تعذّر التحقق من التحديثات',
      };
}

/// مزوّد الوقت — لتسهيل الاختبار.
typedef NowFn = DateTime Function();

/// (2026-09-24) يقصّر سجل ملاحظات التحديث إلى أحدث إصدار فقط وبحد أقصى
/// [maxLines] أسطر — ويُسقط ترويسات الإصدارات القديبة (مثل `3.75.0+151`)
/// والأسطر الفارغة، فلا يُدمج أي سجل تاريخي مع سجل الإصدار الأخير.
///
/// دالة نقية (pure) يسهل اختبارها، وتُطبَّق على كل ما يصل من
/// `version.json` فلا يعتمد العرض على محتوى الخادم.
String clampReleaseNotes(String notes, {int maxLines = 3}) {
  final lines = notes
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      // ترويسة إصدار قديم (3.75.0+151) ليست ميزة — تُسقط.
      .where((l) => !RegExp(r'^\d+\.\d+\.\d+\+\d+$').hasMatch(l))
      .take(maxLines)
      .toList();
  return lines.join('\n');
}

/// أسطر سجل التحديث جاهزة للعرض (بلا رمز النقطة في أولها).
List<String> releaseNoteLines(String notes, {int maxLines = 3}) =>
    clampReleaseNotes(notes, maxLines: maxLines)
        .split('\n')
        .map((l) => l.trim().replaceFirst(RegExp(r'^[•\-*]\s*'), ''))
        .where((l) => l.isNotEmpty)
        .toList();

class UpdateService {
  /// الرابط الافتراضي لبيان الإصدار (يُقرأ من قاعدة Firebase RTDB العامة الموثوقة
  /// ولا يتأثر بخصوصية مستودع الأكواد).
  static const String kDefaultManifestUrl =
      'https://nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app/workspaces/_registry/system/version_manifest.json';

  /// رابط احتياطي على GitHub Releases للمستودع العام.
  static const String kFallbackManifestUrl =
      'https://github.com/iggdigd218-dev/almohaseb/releases/download/latest/version.json';

  /// صفحة الإصدار الرسمية (احتياطي إذا لم يذكر البيان رابطًا).
  static const String kFallbackReleaseUrl =
      'https://github.com/iggdigd218-dev/almohaseb/releases/latest';

  final String manifestUrl;
  final http.Client Function() _clientFactory;
  final AppSemVer current;
  final UpdatePlatform platform;
  final Duration timeout;

  UpdateService({
    String? manifestUrl,
    http.Client Function()? clientFactory,
    AppSemVer? current,
    UpdatePlatform? platform,
    this.timeout = const Duration(seconds: 10),
  })  : manifestUrl = manifestUrl ?? kDefaultManifestUrl,
        _clientFactory = clientFactory ?? (() => http.Client()),
        current = current ?? AppSemVer.current,
        platform = platform ?? detectPlatform();

  static UpdatePlatform detectPlatform() {
    if (PlatformInfo.isAndroid) return UpdatePlatform.android;
    if (PlatformInfo.isWindows) return UpdatePlatform.windows;
    return UpdatePlatform.other;
  }

  /// يفحص وجود تحديث. لا يرمي استثناءً أبدًا — يُعيد status=unknown عند الفشل.
  Future<UpdateInfo> check() async {
    var info = await _fetchFromUrl(manifestUrl);
    // إذا فشل الرابط الافتراضي (انقطاع أو خطأ خادم)، نحاول الرابط الاحتياطي العام
    if (info.status == UpdateStatus.unknown &&
        manifestUrl == kDefaultManifestUrl &&
        kFallbackManifestUrl != kDefaultManifestUrl) {
      final fallbackInfo = await _fetchFromUrl(kFallbackManifestUrl);
      if (fallbackInfo.status != UpdateStatus.unknown) {
        return fallbackInfo;
      }
    }
    return info;
  }

  Future<UpdateInfo> _fetchFromUrl(String targetUrl) async {
    final uri = Uri.tryParse(targetUrl);
    if (uri == null || !uri.isScheme('https')) {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'رابط بيان التحديث غير صالح (يجب أن يكون https).',
      );
    }
    // كسر كاش CDN الوسيط: GitHub/Fastly قد يخدمان version.json قديماً
    // لدقائق بعد النشر — معامل عشوائي لكل طلب يضمن قراءة أحدث بيان.
    final uriWithBuster = uri.replace(queryParameters: {
      ...uri.queryParameters,
      't': '${DateTime.now().millisecondsSinceEpoch}',
    });
    final client = _clientFactory();
    try {
      final res = await client.get(uriWithBuster, headers: {
        'Accept': 'application/json',
        'Cache-Control': 'no-cache',
      }).timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return UpdateInfo(
          status: UpdateStatus.unknown,
          current: current,
          error: 'الخادم أعاد الرمز ${res.statusCode}.',
        );
      }
      // نفكّ البايتات بـ UTF-8 صراحةً: GitHub يقدّم version.json بنوع
      // application/octet-stream بلا charset، فتتراجع res.body إلى Latin-1
      // ويتشوّه النص العربي في الملاحظات (Ø§Ù…). allowMalformed حمايةً من بايتات شاذة.
      return _parse(utf8.decode(res.bodyBytes, allowMalformed: true));
    } on SocketException {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'تعذّر الاتصال بالإنترنت.',
      );
    } on TimeoutException {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'انتهت مهلة الاتصال.',
      );
    } on http.ClientException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('socketexception') ||
          msg.contains('failed host lookup') ||
          msg.contains('connection refused') ||
          msg.contains('network') ||
          msg.contains('connection closed') ||
          msg.contains('connection reset')) {
        return UpdateInfo(
          status: UpdateStatus.unknown,
          current: current,
          error: 'تعذّر الاتصال بالإنترنت.',
        );
      }
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'خطأ في خادم التحديثات (${e.message}).',
      );
    } catch (e) {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'تعذّر فحص التحديثات: $e',
      );
    } finally {
      client.close();
    }
  }

  UpdateInfo _parse(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'بيان التحديث تالف.',
      );
    }
    if (decoded is! Map) {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'بيان التحديث بصيغة غير متوقعة.',
      );
    }
    final map = Map<String, Object?>.from(decoded);
    final latest = AppSemVer.tryParse('${map['version'] ?? ''}');
    if (latest == null) {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'بيان التحديث لا يحتوي رقم إصدار صالح.',
      );
    }
    final minSupported = AppSemVer.tryParse('${map['minSupported'] ?? ''}');
    final downloads = map['downloads'];
    String? downloadUrl;
    if (downloads is Map) {
      if (platform == UpdatePlatform.android) {
        // حزمة المعالج المطابق (أصغر بنحو النصف) والشاملة بديلاً آمناً.
        downloadUrl = pickAndroidApkUrl(downloads, androidAbiKey());
      } else if (platform == UpdatePlatform.windows) {
        final v = downloads['windows'];
        if (v is String && v.startsWith('https://')) {
          downloadUrl = v;
        } else if (downloads['windows'] != null) {
          downloadUrl = downloads['windows'].toString();
        }
      }
    }
    // احتياطي لويندوز: إذا كان البيان بلا رابط مباشر لويندوز
    if (downloadUrl == null && platform == UpdatePlatform.windows) {
      downloadUrl = 'https://github.com/iggdigd218-dev/almohaseb/releases/download/latest/NexoraSetup.exe';
    }
    final release = map['releaseUrl'];
    final releaseUrl = (release is String && release.startsWith('https://'))
        ? release
        : kFallbackReleaseUrl;

    final status = () {
      if (minSupported != null && current < minSupported) {
        return UpdateStatus.required_;
      }
      // مقارنة صريحة لرقم البناء: تطابق major.minor.patch مع بناء أحدث
      // (مثل 3.50.0+86 → 3.50.0+87) = تحديث متاح فوراً. (compareTo يشمل
      // build أصلاً — هذا التصريح توثيق وضمانة ضد أي تعديل مستقبلي.)
      if (latest.major == current.major &&
          latest.minor == current.minor &&
          latest.patch == current.patch &&
          latest.build > current.build) {
        return UpdateStatus.available;
      }
      if (latest > current) return UpdateStatus.available;
      return UpdateStatus.upToDate;
    }();

    return UpdateInfo(
      status: status,
      current: current,
      latest: latest,
      minSupported: minSupported,
      releaseUrl: releaseUrl,
      downloadUrl: downloadUrl,
      // (2026-09-24) سجل التحديث مقتضب: أحدث إصدار فقط، ٣ أسطر كحد أقصى.
      notes: clampReleaseNotes('${map['notes'] ?? ''}'),
      publishedAt: DateTime.tryParse('${map['publishedAt'] ?? ''}'),
    );
  }
}
