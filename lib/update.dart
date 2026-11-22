// ════════════════════════════════════════════════════════════════════
//  نظام التحديث — طبقة رقيقة فوق «دفتر الحسابات»
//
//  كانت هذه النسخة بلا أي آلية تحديث: لا فحص، ولا تنبيه، ولا زر تنزيل.
//  الأثر العملي: أي عطل يبقى في جهاز المستخدم إلى الأبد، لأن التوزيع
//  يتم بملف APK عبر الواتساب لا عبر متجر يحدّث تلقائياً.
//
//  المبدأ هنا: ثلاثة مكوّنات صغيرة — رقم إصدار، فحص بيان، نافذة تنزيل.
//  لا شيء آخر. أي فشل شبكي يجب أن يمرّ صامتاً دون تعطيل التطبيق.
// ════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'core.dart';

// ─────────────────────────── رقم الإصدار ───────────────────────────

/// رقم الإصدار المدمج في البناء. تحدّثه خطوة CI تلقائياً من pubspec.yaml
/// (الخطوة موجودة في .github/workflows/build-flutter-apk.yml).
///
/// صيغة ثابتة يتعرّف عليها sed: `const String kAppVersion = '4.6.0';`
const String kAppVersion = '4.6.0';

/// رقم البناء: `const int kAppBuild = 308;`
const int kAppBuild = 308;

String get appVersionLabel => 'الإصدار $kAppVersion';

/// إصدار قابل للمقارنة (major.minor.patch+build).
class AppSemVer implements Comparable<AppSemVer> {
  final int major, minor, patch, build;
  const AppSemVer(this.major, this.minor, this.patch, [this.build = 0]);

  static const AppSemVer current = AppSemVer(4, 5, 0, kAppBuild);

  /// يقبل `4.5.0` و`4.5.0+307` و`v4.5.0`.
  static AppSemVer? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final m = RegExp(r'(\d+)\.(\d+)(?:\.(\d+))?(?:\+(\d+))?').firstMatch(raw);
    if (m == null) return null;
    return AppSemVer(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.tryParse(m.group(3) ?? '0') ?? 0,
      int.tryParse(m.group(4) ?? '0') ?? 0,
    );
  }

  @override
  int compareTo(AppSemVer o) {
    if (major != o.major) return major.compareTo(o.major);
    if (minor != o.minor) return minor.compareTo(o.minor);
    if (patch != o.patch) return patch.compareTo(o.patch);
    return build.compareTo(o.build);
  }

  bool operator >(AppSemVer o) => compareTo(o) > 0;
  bool operator <(AppSemVer o) => compareTo(o) < 0;

  @override
  String toString() =>
      build > 0 ? '$major.$minor.$patch+$build' : '$major.$minor.$patch';
}

// ─────────────────────────── نتيجة الفحص ───────────────────────────

enum UpdateStatus { upToDate, available, required, unknown }

class UpdateInfo {
  final UpdateStatus status;
  final AppSemVer current;
  final AppSemVer? latest;
  final String? downloadUrl;
  final String? releaseUrl;
  final String notes;
  final String? error;

  const UpdateInfo({
    required this.status,
    required this.current,
    this.latest,
    this.downloadUrl,
    this.releaseUrl,
    this.notes = '',
    this.error,
  });

  bool get hasUpdate =>
      status == UpdateStatus.available || status == UpdateStatus.required;

  bool get isMandatory => status == UpdateStatus.required;

  String get headline => switch (status) {
        UpdateStatus.upToDate => 'التطبيق محدَّث',
        UpdateStatus.available => 'يتوفّر تحديث جديد',
        UpdateStatus.required => 'تحديث إلزامي مطلوب',
        UpdateStatus.unknown => 'تعذّر التحقق من التحديثات',
      };
}

// ─────────────────────────── خدمة الفحص ───────────────────────────

class UpdateService {
  /// البيان على Firebase (المصدر الأساسي: لا يتأثر بخصوصية المستودع).
  static const manifestUrl =
      'https://nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app/workspaces/_registry/system/version_manifest.json';

  /// احتياطي: ملف الإصدار على GitHub Releases.
  static const fallbackUrl =
      'https://github.com/iggdigd218-dev/almohaseb/releases/download/latest/version.json';

  static const releasePage =
      'https://github.com/iggdigd218-dev/almohaseb/releases/latest';

  final http.Client Function() _client;
  final AppSemVer current;
  final Duration timeout;

  UpdateService({
    http.Client Function()? clientFactory,
    AppSemVer? current,
    this.timeout = const Duration(seconds: 12),
  })  : _client = clientFactory ?? (() => http.Client()),
        current = current ?? AppSemVer.current;

  /// فحص التحديث. لا يرمي استثناءً أبداً — الخطأ يعود حالةً لا انهياراً.
  Future<UpdateInfo> check() async {
    var info = await _fetch(manifestUrl);
    if (info.status == UpdateStatus.unknown) {
      info = await _fetch(fallbackUrl);
    }
    return info;
  }

  /// فحص بمحتوى مُعطى بدل الشبكة — للاختبارات فقط.
  Future<UpdateInfo> checkWithBody(String body) async => _parse(body);

  Future<UpdateInfo> _fetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('https')) {
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'رابط البيان غير صالح',
      );
    }
    // كسر كاش CDN: قد يُخدَّم بيان قديم لدقائق بعد النشر.
    final target = uri.replace(queryParameters: {
      ...uri.queryParameters,
      't': '${DateTime.now().millisecondsSinceEpoch}',
    });
    final client = _client();
    try {
      final res = await client.get(target, headers: {
        'Accept': 'application/json',
        'Cache-Control': 'no-cache',
      }).timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return UpdateInfo(
          status: UpdateStatus.unknown,
          current: current,
          error: 'الخادم أعاد ${res.statusCode}',
        );
      }
      // UTF-8 صريح: البيان بلا charset فتُشوّه العربية لو اعتمدنا res.body.
      return _parse(utf8.decode(res.bodyBytes, allowMalformed: true));
    } on SocketException {
      return UpdateInfo(
          status: UpdateStatus.unknown,
          current: current,
          error: 'تعذّر الاتصال بالإنترنت');
    } on TimeoutException {
      return UpdateInfo(
          status: UpdateStatus.unknown,
          current: current,
          error: 'انتهت مهلة الاتصال');
    } catch (e) {
      return UpdateInfo(
          status: UpdateStatus.unknown, current: current, error: '$e');
    } finally {
      client.close();
    }
  }

  /// تحليل نص بيان — مكشوف للاختبارات (دالة نقية بلا شبكة).
  UpdateInfo parseForTest(String body) => _parse(body);

  UpdateInfo _parse(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      // هذا بالضبط ما حدث سابقاً: بيان غير صالح فلم يظهر أي تحديث أبداً.
      return UpdateInfo(
        status: UpdateStatus.unknown,
        current: current,
        error: 'بيان التحديث بصيغة غير صالحة',
      );
    }
    if (decoded is! Map) {
      return UpdateInfo(
          status: UpdateStatus.unknown,
          current: current,
          error: 'بيان غير متوقع');
    }
    final map = Map<String, Object?>.from(decoded);
    final latest = AppSemVer.tryParse('${map['version'] ?? ''}');
    if (latest == null) {
      return UpdateInfo(
          status: UpdateStatus.unknown,
          current: current,
          error: 'لا رقم إصدار في البيان');
    }
    final minSupported = AppSemVer.tryParse('${map['minSupported'] ?? ''}');

    String? download;
    final downloads = map['downloads'];
    if (downloads is Map) {
      // نفضّل حزمة arm64 (الأغلب في الأجهزة الحديثة) وإلا أي رابط صالح.
      for (final key in const ['android', 'androidArm32', 'androidX64']) {
        final v = downloads[key];
        if (v is String && v.startsWith('https://')) {
          download = v;
          break;
        }
      }
    }

    final rel = map['releaseUrl'];
    final releaseUrl =
        (rel is String && rel.startsWith('https://')) ? rel : releasePage;

    UpdateStatus status;
    if (minSupported != null && current < minSupported) {
      status = UpdateStatus.required;
    } else if (latest > current) {
      status = UpdateStatus.available;
    } else {
      status = UpdateStatus.upToDate;
    }

    return UpdateInfo(
      status: status,
      current: current,
      latest: latest,
      downloadUrl: download,
      releaseUrl: releaseUrl,
      notes: clampNotes('${map['notes'] ?? ''}'),
    );
  }

  /// سجل مختصر: ٣ أسطر كحد أقصى، بلا ترويسات إصدارات قديمة.
  static String clampNotes(String notes, {int maxLines = 3}) {
    final lines = notes
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .where((l) => !RegExp(r'^\d+\.\d+\.\d+(\+\d+)?$').hasMatch(l))
        .take(maxLines)
        .toList();
    return lines.join('\n');
  }
}

// ─────────────────────────── الفحص عند الإقلاع ───────────────────────────

/// فحص صامت عند الإقلاع: لا يزعج المستخدم إلا إذا وُجد تحديث فعلاً.
/// يُستدعى بعد إطار كامل حتى لا يُبطئ فتح التطبيق.
Future<void> checkForUpdateOnStart(BuildContext context) async {
  try {
    // مرة واحدة في اليوم كحد أقصى للإزعاج الاختياري، لكن بناءً أحدث
    // يتجاوز الكتم فوراً (المستخدم يستحق تنبيهاً لكل إصدار جديد).
    final info = await UpdateService().check();
    if (!context.mounted || !info.hasUpdate) return;

    final lastBuild = Prefs.s('lastUpdatePromptBuild');
    final lastAt = DateTime.tryParse(Prefs.s('lastUpdatePromptAt'));
    final latestKey = '${info.latest}';

    if (!info.isMandatory && lastBuild == latestKey && lastAt != null) {
      if (DateTime.now().difference(lastAt) < const Duration(hours: 24)) {
        return;
      }
    }
    await Prefs.setS('lastUpdatePromptBuild', latestKey);
    await Prefs.setS('lastUpdatePromptAt', DateTime.now().toIso8601String());

    if (!context.mounted) return;
    await showUpdateDialog(context, info);
  } catch (_) {
    // الفحص الصامت لا يعطّل الإقلاع أبداً.
  }
}

// ─────────────────────────── النافذة ───────────────────────────

Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
  final go = await showDialog<bool>(
    context: context,
    barrierDismissible: !info.isMandatory,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          const Text('⬆️', style: TextStyle(fontSize: 22)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(info.headline,
                style: const TextStyle(
                    fontSize: 16.5, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'الحالي: ${info.current}\nالجديد: ${info.latest}',
            style: const TextStyle(fontSize: 12.5, color: AppColors.sub),
          ),
          if (info.notes.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.driveBlue.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(info.notes,
                  style: TextStyle(fontSize: 12.5, height: 1.6,
                      color: AppColors.text)),
            ),
          ],
          if (info.isMandatory) ...[
            const SizedBox(height: 10),
            const Text(
              'هذا التحديث مطلوب لاستمرار عمل التطبيق بشكل صحيح.',
              style: TextStyle(fontSize: 12, color: AppColors.red),
            ),
          ],
        ],
      ),
      actions: [
        if (!info.isMandatory)
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('لاحقاً', style: TextStyle(color: AppColors.sub)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('تحديث الآن',
              style: TextStyle(
                  color: AppColors.primary, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
  if (go == true && context.mounted) {
    await openDownload(info);
  }
}

/// يفتح رابط التنزيل. المسار المضمون على أندرويد: المتصفح — ينجح دائماً
/// بلا أي تفويض خاص، بخلاف التثبيت الداخلي الذي يمنعه النظام.
Future<void> openDownload(UpdateInfo info) async {
  final target = info.downloadUrl ?? info.releaseUrl;
  if (target == null) return;
  final uri = Uri.tryParse(target);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

// ─────────────────────────── قسم في الإعدادات ───────────────────────────

/// صف «التحديثات» في الإعدادات: يعرض الإصدار الحالي ويفحص عند الطلب.
class UpdateTile extends StatefulWidget {
  const UpdateTile({super.key});

  @override
  State<UpdateTile> createState() => _UpdateTileState();
}

class _UpdateTileState extends State<UpdateTile> {
  bool _busy = false;
  UpdateInfo? _info;

  Future<void> _check() async {
    setState(() => _busy = true);
    final info = await UpdateService().check();
    if (!mounted) return;
    setState(() {
      _info = info;
      _busy = false;
    });
    if (info.hasUpdate) {
      await showUpdateDialog(context, info);
    } else if (info.status == UpdateStatus.upToDate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('التطبيق محدَّث ✅')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر التحقق: ${info.error ?? ''}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sub = _busy
        ? 'جارٍ التحقق...'
        : (_info == null
            ? '$appVersionLabel — اضغط للتحقق'
            : '${_info!.headline} · ${appVersionLabel}');
    return ListTile(
      leading: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Text('🔄', style: TextStyle(fontSize: 20)),
      title: Text('التحديثات',
          style: TextStyle(fontSize: 15, color: AppColors.text)),
      subtitle: Text(sub,
          style: TextStyle(fontSize: 11.5, color: AppColors.textSub)),
      trailing: _busy
          ? null
          : IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: _check,
            ),
      onTap: _busy ? null : _check,
    );
  }
}
