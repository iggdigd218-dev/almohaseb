// التحديث بنقرة واحدة (أندرويد):
// ينزّل ملف الـ APK عبر DownloadManager (خدمة نظام) ثم يفتح شاشة تثبيت
// النظام مباشرةً — يبقى القرار النهائي للمستخدم في حوار النظام (لا يسمح
// أندرويد بتثبيت صامت لتطبيقات خارج المتجر، وهذا قيد أمني في النظام نفسه).
//
// لماذا DownloadManager بدل http داخل التطبيق؟
// 1) السرعة: تنزيل داخل عملية التطبيق يخضع لكبح النظام للتطبيقات الخاملة
//    ولقيود Dart isolate، بينما مدير التنزيلات خدمة نظام مخصصة لذلك.
// 2) الاستمرارية: يواصل التنزيل حتى لو أُغلق التطبيق نهائياً.
// 3) الاستئناف: يستأنف تلقائياً بعد انقطاع الشبكة (HTTP Range)، وعند فتح
//    التطبيق مجدداً نلتقط التنزيل الجاري/المكتمل بدل البدء من الصفر.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/sfx.dart';
import '../core/platform_info.dart';

/// مراحل عملية التحديث بنقرة واحدة.
enum InstallPhase {
  idle,
  downloading,
  launchingInstaller,
  awaitingPermission,
  failed,
  done,
}

/// حالة لحظية تُبث أثناء التنزيل/التثبيت لعرض شريط التقدم.
class InstallProgress {
  final InstallPhase phase;

  /// نسبة التنزيل 0..1 (أو null إذا كان الحجم مجهولاً).
  final double? progress;
  final String? error;

  const InstallProgress(this.phase, {this.progress, this.error});
}

class UpdateInstaller {
  static const _channel = MethodChannel('nexora/updates');

  final http.Client Function() _clientFactory;

  UpdateInstaller({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? (() => http.Client());

  /// هل منح المستخدم إذن «تثبيت التطبيقات غير المعروفة» لهذا التطبيق؟
  Future<bool> canInstall() async {
    // ويندوز لا يحتاج إذناً مسبقاً: تشغيل المُثبّت يُظهر حوار UAC للنظام.
    if (PlatformInfo.isWindows) return true;
    if (!PlatformInfo.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// يفتح صفحة إعدادات النظام لمنح إذن التثبيت (مرة واحدة فقط).
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod('openInstallSettings');
    } catch (_) {}
  }

  // ------- تذكّر معرّف التنزيل والرابط بين تشغيلات التطبيق (للاستئناف الدقيق) -------

  Future<File> _idFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/update_download_state.json');
  }

  Future<File> _legacyIdFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/update_download_id.txt');
  }

  Future<({int id, String url})?> _savedDownload() async {
    try {
      // إتلاف الملف القديم لتفادي تثبيت أي حزم سابقة قديمة
      final leg = await _legacyIdFile();
      if (leg.existsSync()) await leg.delete();

      final f = await _idFile();
      if (!f.existsSync()) return null;
      final raw = await f.readAsString();
      final map = jsonDecode(raw);
      if (map is Map) {
        final id = (map['id'] is int) ? map['id'] as int : int.tryParse('${map['id']}');
        final u = map['url']?.toString();
        if (id != null && u != null && u.isNotEmpty) {
          return (id: id, url: u);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDownload(int? id, String? url) async {
    try {
      final f = await _idFile();
      if (id == null || url == null) {
        if (f.existsSync()) await f.delete();
      } else {
        await f.writeAsString(jsonEncode({'id': id, 'url': url}));
      }
    } catch (_) {}
  }

  Future<Map<String, Object?>> _query(int id) async {
    try {
      final r = await _channel
          .invokeMapMethod<String, Object?>('queryDownload', {'id': id});
      return r ?? const {'status': 'unknown'};
    } catch (_) {
      return const {'status': 'unknown'};
    }
  }

  /// ينزّل APK من [url] ويبث التقدم، ثم يفتح شاشة تثبيت النظام.
  /// لا يرمي استثناءً — يبث InstallPhase.failed مع سبب عربي مفهوم.
  Stream<InstallProgress> downloadAndInstall(String url) async* {
    if (PlatformInfo.isWindows) {
      yield* _windowsDownloadAndInstall(url);
      return;
    }
    if (!PlatformInfo.isAndroid) {
      yield const InstallProgress(InstallPhase.failed,
          error: 'التحديث المباشر متاح على أندرويد وويندوز فقط.');
      return;
    }

    // 0) إذن «المصادر غير المعروفة»: إن لم يُمنح نفتح إعداداته وننتظر المستخدم.
    if (!await canInstall()) {
      yield const InstallProgress(InstallPhase.awaitingPermission);
      await openInstallSettings();
      // ننتظر عودة المستخدم من الإعدادات (فحص دوري بمهلة قصوى دقيقة واحدة).
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (await canInstall()) break;
      }
      if (!await canInstall()) {
        yield const InstallProgress(InstallPhase.failed,
            error: 'لم يُمنح إذن تثبيت التحديثات. فعّله من إعدادات النظام '
                'ثم أعد المحاولة.');
        return;
      }
    }

    yield const InstallProgress(InstallPhase.downloading, progress: 0);

    // 1) استئناف تنزيل سابق إن وُجد وكان لنفس الرابط المطلوب حصراً
    var saved = await _savedDownload();
    int? id;
    if (saved != null && saved.url == url) {
      final st = await _query(saved.id);
      final status = '${st['status']}';
      if (status == 'done' && '${st['path']}'.isNotEmpty) {
        final apk = File('${st['path']}');
        if (apk.existsSync() && apk.lengthSync() > 1024 * 1024) {
          // اكتمل في الخلفية لنفس هذا الرابط — أشعر ثم ثبّت مباشرة
          _notifyDownloadComplete('${st['path']}');
          yield* _install('${st['path']}');
          return;
        }
      }
      if (status == 'running' || status == 'pending' || status == 'paused') {
        id = saved.id;
      }
    }

    // تنظيف أي حالة تنزيل قديمة مخالفة للرابط الحالي
    if (id == null) {
      await _saveDownload(null, null);
    }

    // 2) بدء تنزيل جديد عبر مدير تنزيلات النظام.
    if (id == null) {
      try {
        final r = await _channel.invokeMethod<Object?>(
            'startDownload', {'url': url});
        final started = (r is int) ? r : int.tryParse('$r') ?? -1;
        if (started >= 0) {
          id = started;
          await _saveDownload(id, url);
        }
      } catch (_) {}
    }

    if (id == null) {
      // مسار احتياطي (أجهزة عطّل فيها مدير التنزيلات): تنزيل مباشر.
      yield* _fallbackHttpDownload(url);
      return;
    }

    // 3) متابعة التقدم — التنزيل نفسه بيد النظام ويستمر لو خرج المستخدم.
    var stuckCount = 0;
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final st = await _query(id);
      final status = '${st['status']}';
      final bytes = (st['bytes'] as num?)?.toInt() ?? 0;
      final total = (st['total'] as num?)?.toInt() ?? -1;
      switch (status) {
        case 'done':
          final path = '${st['path']}';
          if (path.isEmpty) {
            await _saveDownload(null, null);
            yield const InstallProgress(InstallPhase.failed,
                error: 'اكتمل التنزيل لكن الملف غير موجود. أعد المحاولة.');
            return;
          }
          // (2026-09-22) إشعار نظام: اكتمل التنزيل — نقرة تفتح المجلد.
          await _saveDownload(null, null);
          _notifyDownloadComplete(path);
          yield* _install(path);
          return;
        case 'failed':
          await _saveDownload(null, null);
          yield InstallProgress(InstallPhase.failed,
              error: 'فشل التنزيل (رمز ${st['reason'] ?? '?'}). '
                  'تحقق من الاتصال ثم أعد المحاولة.');
          return;
        case 'paused':
          // انقطاع مؤقت — النظام سيستأنف وحده؛ نُبقي الشريط ظاهراً.
          yield InstallProgress(InstallPhase.downloading,
              progress: (total > 0) ? bytes / total : null);
          break;
        case 'unknown':
          // اختفى من قائمة التنزيلات (أُلغي من الإشعار مثلاً).
          if (++stuckCount >= 6) {
            await _saveDownload(null, null);
            yield const InstallProgress(InstallPhase.failed,
                error: 'أُلغي التنزيل. أعد المحاولة.');
            return;
          }
          break;
        default: // running / pending
          stuckCount = 0;
          yield InstallProgress(InstallPhase.downloading,
              progress: (total > 0) ? bytes / total : null);
      }
    }
  }

  /// (2026-09-22) إشعار نظام بعد اكتمال تنزيل التحديث — نقرته تفتح
  /// مجلد التنزيلات العام (Download/Nexora) عبر openNotificationEntity.
  void _notifyDownloadComplete(String path) {
    Sfx.systemNotify(
      title: 'اكتمل تنزيل التحديث',
      body: 'الملف محفوظ في Download/Nexora — اضغط لفتح مجلد التنزيلات.',
      entityType: 'update_download',
      entityId: path,
    );
  }

  /// يفتح مجلد التنزيلات العام الذي يحفظ فيه التطبيق ملفات التحديث —
  /// أندرويد: نافذة مستندات النظام؛ ويندوز: المستكشف على الملف نفسه.
  static Future<bool> openDownloadsFolder(String path) async {
    try {
      if (PlatformInfo.isAndroid) {
        final r = await _channel.invokeMethod<bool>('openDownloadsFolder');
        return r ?? false;
      }
      if (PlatformInfo.isWindows && path.isNotEmpty) {
        await Process.start('explorer.exe', ['/select,', path],
            mode: ProcessStartMode.detached);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// يتحقق من الملف ثم يطلق شاشة تثبيت النظام.
  Stream<InstallProgress> _install(String path) async* {
    final apk = File(path);
    if (!apk.existsSync() || apk.lengthSync() < 1024 * 1024) {
      await _saveDownload(null, null);
      yield const InstallProgress(InstallPhase.failed,
          error: 'الملف المنزَّل غير مكتمل. أعد المحاولة.');
      return;
    }
    yield const InstallProgress(InstallPhase.launchingInstaller, progress: 1);
    try {
      final r =
          await _channel.invokeMethod<String>('installApk', {'path': path});
      await _saveDownload(null, null);
      if (r == 'ok') {
        yield const InstallProgress(InstallPhase.done, progress: 1);
      } else {
        yield InstallProgress(InstallPhase.failed,
            error: switch (r) {
              'file_missing' => 'ملف التحديث اختفى بعد التنزيل.',
              'uri_failed' => 'تعذّر تجهيز ملف التثبيت.',
              _ => 'تعذّر فتح شاشة التثبيت.',
            });
      }
    } catch (e) {
      await _saveDownload(null, null);
      yield InstallProgress(InstallPhase.failed,
          error: 'تعذّر فتح شاشة التثبيت: $e');
    }
  }

  // ------------------------- مسار ويندوز -------------------------

  /// ويندوز: ينزّل مُثبّت NexoraSetup.exe (أو الملف المتاح) داخل التطبيق
  /// ثم يشغّله — معالج التثبيت يحدّث النسخة فوق الحالية مع بقاء البيانات.
  Stream<InstallProgress> _windowsDownloadAndInstall(String url) async* {
    yield const InstallProgress(InstallPhase.downloading, progress: 0);
    final segs = Uri.tryParse(url)?.pathSegments ?? const <String>[];
    final name = segs.isEmpty ? '' : segs.last;
    final isExe = name.toLowerCase().endsWith('.exe');
    final fileName = isExe ? 'NexoraSetup.exe' : 'nexora-update.zip';
    yield* _httpDownload(url, fileName, (file) async* {
      if (file.lengthSync() < 512 * 1024) {
        yield const InstallProgress(InstallPhase.failed,
            error: 'الملف المنزَّل غير مكتمل. أعد المحاولة.');
        return;
      }
      yield const InstallProgress(InstallPhase.launchingInstaller,
          progress: 1);
      try {
        if (isExe) {
          // (دفعة 58) تشغيل المُثبّت عبر ShellExecute (Start-Process
          // -Verb RunAs): الإطلاق المباشر بـ Process.start يفشل صامتاً
          // عندما يتطلب المُثبّت صلاحية مسؤول (ERROR_ELEVATION_REQUIRED)
          // — كان هذا سبب تعطل التحديث التلقائي على ويندوز.
          try {
            await Process.start(
              'powershell.exe',
              [
                '-NoProfile',
                '-NonInteractive',
                '-Command',
                'Start-Process -FilePath \'${file.path}\' -Verb RunAs',
              ],
              mode: ProcessStartMode.detached,
              runInShell: false,
            );
          } catch (_) {
            // احتياط: cmd start يمرّ عبر ShellExecute أيضاً فيُظهر UAC.
            await Process.start(
              'cmd.exe',
              ['/c', 'start', '', file.path],
              mode: ProcessStartMode.detached,
              runInShell: false,
            );
          }
        } else {
          // نسخة zip محمولة: نفتح مجلدها ليستخرجها المستخدم.
          await Process.start('explorer.exe', ['/select,', file.path],
              mode: ProcessStartMode.detached);
        }
        yield const InstallProgress(InstallPhase.done, progress: 1);
        // (إصلاح UAC) لا exit(0) هنا: قتل العملية بعد 3 ثوانٍ كان يقتل
        // سلسلة الإطلاق قبل موافقة المستخدم على حوار صلاحيات المسؤول،
        // فيموت المثبّت صامتاً. NexoraSetup.exe (Inno Setup) يغلق التطبيق
        // بنفسه عبر CloseApplications عند بدء التثبيت الفعلي — نبقى أحياء
        // حتى يتولى هو الإغلاق.
      } catch (e) {
        yield InstallProgress(InstallPhase.failed,
            error: 'تعذّر تشغيل المُثبّت: $e');
      }
    });
  }

  /// مسار احتياطي: تنزيل http داخل التطبيق (كما في السابق) إذا تعذّر
  /// استخدام مدير تنزيلات النظام.
  Stream<InstallProgress> _fallbackHttpDownload(String url) async* {
    yield* _httpDownload(url, 'nexora-update.apk', (f) => _install(f.path));
  }

  /// (2026-09-22) مجلد التنزيل: على أندرويد مجلد عام مخصص في الهاتف
  /// Download/Nexora — مرئي في مدير الملفات ولا يضخّم تخزين التطبيق
  /// الخاص؛ وعند تعذّر الكتابة فيه (قيود بعض المصانع) نعود لمجلد
  /// التطبيق الخارجي. بقية الأنظمة: مجلد مؤقت يُنظف قبل كل تنزيل.
  Future<Directory> _downloadDir(String fileName) async {
    Directory? dir;
    if (PlatformInfo.isAndroid) {
      try {
        final d = Directory('/storage/emulated/0/Download/Nexora');
        await d.create(recursive: true);
        final probe = File('${d.path}/.probe');
        await probe.writeAsString('x');
        await probe.delete();
        dir = d;
      } catch (_) {
        try {
          final ext = await getExternalStorageDirectory();
          if (ext != null) {
            final d = Directory('${ext.path}/updates');
            await d.create(recursive: true);
            dir = d;
          }
        } catch (_) {}
      }
    }
    if (dir == null) {
      final cache = await getTemporaryDirectory();
      final d = Directory('${cache.path}/updates');
      if (d.existsSync()) d.deleteSync(recursive: true);
      d.createSync(recursive: true);
      dir = d;
    }
    // نظّف ملفات التحديث القديمة حتى لا تتراكم وتهدر مساحة الهاتف.
    final keep = '${dir.path}/$fileName';
    try {
      await for (final e in dir.list()) {
        if (e is File && e.path != keep) {
          await e.delete();
        }
      }
    } catch (_) {}
    return dir;
  }

  /// تنزيل http عام إلى ملف مؤقت ثم تمرير الملف لخطوة ما بعد التنزيل.
  Stream<InstallProgress> _httpDownload(
    String url,
    String fileName,
    Stream<InstallProgress> Function(File file) onDone,
  ) async* {
    final File apk;
    try {
      final dir = await _downloadDir(fileName);
      apk = File('${dir.path}/$fileName');
    } catch (e) {
      yield InstallProgress(InstallPhase.failed,
          error: 'تعذّر تجهيز مجلد التنزيل: $e');
      return;
    }

    final client = _clientFactory();
    IOSink? sink;
    try {
      final req = http.Request('GET', Uri.parse(url));
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        yield InstallProgress(InstallPhase.failed,
            error: 'الخادم أعاد الرمز ${res.statusCode}.');
        return;
      }
      final total = res.contentLength;
      var received = 0;
      sink = apk.openWrite();
      var lastYield = DateTime.now();
      await for (final chunk
          in res.stream.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastYield).inMilliseconds > 150) {
          lastYield = now;
          yield InstallProgress(
            InstallPhase.downloading,
            progress: (total != null && total > 0) ? received / total : null,
          );
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } on TimeoutException {
      yield const InstallProgress(InstallPhase.failed,
          error: 'انقطع الاتصال أثناء التنزيل. أعد المحاولة.');
      return;
    } catch (e) {
      yield InstallProgress(InstallPhase.failed, error: 'فشل التنزيل: $e');
      return;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
    }
    yield* onDone(apk);
  }
}
