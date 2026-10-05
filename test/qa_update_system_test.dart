// اختبارات نظام التحديث المركزي.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/app_version.dart';
import 'package:nexora_app/data/update_service.dart';

UpdateService svcReturning(
  String body, {
  int status = 200,
  AppSemVer? current,
  UpdatePlatform platform = UpdatePlatform.android,
  void Function(Uri)? onRequest,
}) =>
    UpdateService(
      manifestUrl: 'https://example.com/version.json',
      current: current ?? const AppSemVer(3, 12, 3, 20),
      platform: platform,
      clientFactory: () => MockClient((req) async {
        onRequest?.call(req.url);
        return http.Response(body, status,
            headers: {'content-type': 'application/json'});
      }),
    );

String manifest({
  String version = '3.13.0+21',
  String? minSupported,
  String notes = 'تحسينات',
}) =>
    jsonEncode({
      'version': version,
      if (minSupported != null) 'minSupported': minSupported,
      'releaseUrl': 'https://github.com/x/y/releases/tag/latest',
      'downloads': {
        'android': 'https://github.com/x/y/releases/download/latest/app.apk',
        'windows': 'https://github.com/x/y/releases/download/latest/app.zip',
      },
      'publishedAt': '2026-09-06T10:00:00Z',
      'notes': notes,
    });

void main() {
  group('مطابقة الإصدار', () {
    test('kAppVersion يطابق pubspec.yaml تمامًا', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*([0-9.]+)\+([0-9]+)', multiLine: true)
          .firstMatch(pubspec);
      expect(m, isNotNull, reason: 'pubspec.yaml يجب أن يحتوي version');
      expect(kAppVersion, m!.group(1),
          reason: 'حدّث kAppVersion في lib/core/app_version.dart');
      expect(kAppBuild, int.parse(m.group(2)!),
          reason: 'حدّث kAppBuild في lib/core/app_version.dart');
    });

    test('AppSemVer.current يُشتق من kAppVersion (لا تخلّف يدوي)', () {
      // كانت current مكتوبة يدوياً (3,20,0) وتخلّفت عن kAppVersion فظل
      // زر «تحديث الآن» عالقاً يعرض نفس النسخة المثبتة كتحديث جديد.
      final expected = AppSemVer.tryParse('$kAppVersion+$kAppBuild');
      expect(AppSemVer.current, expected,
          reason: 'current يجب أن يساوي kAppVersion+kAppBuild تلقائياً');
    });

    test('نفس النسخة المثبتة تعرض «لا يوجد تحديث» لا زر تحديث عالق',
        () async {
      // بيان الخادم يعلن نفس نسخة الجهاز تماماً — يجب upToDate لا available.
      final svc = svcReturning(
        manifest(version: '$kAppVersion+$kAppBuild'),
        current: AppSemVer.current,
      );
      final info = await svc.check();
      expect(info.status, UpdateStatus.upToDate);
      expect(info.hasUpdate, isFalse,
          reason: 'لا يظهر زر «تحديث الآن» عندما تكون النسخة مثبتة فعلاً');
    });

    test('لا توجد أرقام إصدار مكتوبة يدويًا في الواجهة', () {
      final bad = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.endsWith('app_version.dart')) continue;
        final src = f.readAsStringSync();
        if (RegExp(r"'الإصدار \d+\.\d+").hasMatch(src)) bad.add(f.path);
      }
      expect(bad, isEmpty,
          reason: 'استخدم appVersionLabel بدل كتابة الإصدار يدويًا');
    });
  });

  group('مقارنة الإصدارات', () {
    test('التحليل يقبل الصيغ المختلفة', () {
      expect(AppSemVer.tryParse('3.12.3')?.toString(), '3.12.3');
      expect(AppSemVer.tryParse('v3.12.3+20')?.toString(), '3.12.3+20');
      expect(AppSemVer.tryParse('flutter-v3.7')?.toString(), '3.7.0');
      expect(AppSemVer.tryParse('نص بلا رقم'), isNull);
      expect(AppSemVer.tryParse(null), isNull);
    });

    test('الترتيب صحيح رقميًا لا نصيًا', () {
      // 3.9.0 < 3.12.0 (نصيًا "3.9" > "3.12" وهو الخطأ الشائع)
      expect(
          AppSemVer.tryParse('3.12.0')! > AppSemVer.tryParse('3.9.0')!, isTrue);
      expect(AppSemVer.tryParse('3.12.3')! > AppSemVer.tryParse('3.12.2')!,
          isTrue);
      expect(
          AppSemVer.tryParse('3.12.3+21')! > AppSemVer.tryParse('3.12.3+20')!,
          isTrue);
      expect(
          AppSemVer.tryParse('3.12.3') == AppSemVer.tryParse('3.12.3'), isTrue);
    });
  });

  group('فحص التحديث', () {
    test('إصدار أحدث ⇒ تحديث متاح', () async {
      final info = await svcReturning(manifest(version: '3.13.0+21')).check();
      expect(info.status, UpdateStatus.available);
      expect(info.hasUpdate, isTrue);
      expect(info.isMandatory, isFalse);
      expect(info.latest.toString(), '3.13.0+21');
    });

    test('نفس الإصدار ⇒ محدَّث', () async {
      final info = await svcReturning(manifest(version: '3.12.3+20')).check();
      expect(info.status, UpdateStatus.upToDate);
      expect(info.hasUpdate, isFalse);
    });

    test('إصدار أقدم على الخادم ⇒ محدَّث (لا تراجع)', () async {
      final info = await svcReturning(manifest(version: '3.10.0+15')).check();
      expect(info.status, UpdateStatus.upToDate);
    });

    test('أقل من الحد الأدنى المدعوم ⇒ تحديث إجباري', () async {
      final info = await svcReturning(
              manifest(version: '4.0.0+30', minSupported: '3.13.0'))
          .check();
      expect(info.status, UpdateStatus.required_);
      expect(info.isMandatory, isTrue);
    });

    test('يختار رابط التنزيل حسب المنصّة', () async {
      final a = await svcReturning(manifest(), platform: UpdatePlatform.android)
          .check();
      expect(a.downloadUrl, endsWith('app.apk'));
      final w = await svcReturning(manifest(), platform: UpdatePlatform.windows)
          .check();
      expect(w.downloadUrl, endsWith('app.zip'));
      final o = await svcReturning(manifest(), platform: UpdatePlatform.other)
          .check();
      expect(o.downloadUrl, isNull);
      expect(o.releaseUrl, isNotNull, reason: 'يبقى رابط الصفحة متاحًا');
    });
  });

  group('الفشل الآمن — لا انهيار أبدًا', () {
    test('خطأ خادم 500', () async {
      final info = await svcReturning('{}', status: 500).check();
      expect(info.status, UpdateStatus.unknown);
      expect(info.hasUpdate, isFalse);
      expect(info.error, contains('500'));
    });

    test('JSON تالف', () async {
      final info = await svcReturning('<<< ليس JSON >>>').check();
      expect(info.status, UpdateStatus.unknown);
      expect(info.error, contains('تالف'));
    });

    test('بيان بلا رقم إصدار', () async {
      final info = await svcReturning(jsonEncode({'notes': 'x'})).check();
      expect(info.status, UpdateStatus.unknown);
    });

    test('انقطاع الشبكة', () async {
      final svc = UpdateService(
        manifestUrl: 'https://example.com/version.json',
        clientFactory: () =>
            MockClient((_) async => throw const SocketException('offline')),
      );
      final info = await svc.check();
      expect(info.status, UpdateStatus.unknown);
      expect(info.hasUpdate, isFalse);
    });

    test('يرفض رابط غير https', () async {
      final svc = UpdateService(manifestUrl: 'http://insecure.example/v.json');
      final info = await svc.check();
      expect(info.status, UpdateStatus.unknown);
      expect(info.error, contains('https'));
    });

    test('يرفض رابط تنزيل غير https داخل البيان', () async {
      final body = jsonEncode({
        'version': '9.9.9',
        'downloads': {'android': 'http://evil.example/x.apk'},
      });
      final info = await svcReturning(body).check();
      expect(info.status, UpdateStatus.available);
      expect(info.downloadUrl, isNull, reason: 'لا نقبل روابط غير آمنة');
    });
  });

  test('يطلب البيان من الرابط الصحيح + معامل كسر الكاش', () async {
    Uri? seen;
    await svcReturning(manifest(), onRequest: (u) => seen = u).check();
    expect(seen!.host, 'example.com');
    expect(seen!.path, '/version.json');
    // (إصلاح CDN) كل طلب يحمل معاملاً زمنياً يمنع كاش السيرفرات الوسيطة.
    final t = int.tryParse(seen!.queryParameters['t'] ?? '');
    expect(t, isNotNull, reason: 'معامل كسر الكاش t مطلوب في كل طلب');
    expect(t! > 0, isTrue);
  });

  test('معامل كسر الكاش يتغير بين الطلبات (لا قيمة ثابتة قابلة للكاش)',
      () async {
    final seen = <String>[];
    final svc = svcReturning(manifest(),
        onRequest: (u) => seen.add(u.queryParameters['t'] ?? ''));
    await svc.check();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await svc.check();
    expect(seen.length, 2);
    expect(seen[0], isNot(seen[1]),
        reason: 'قيمتان مختلفتان = لا يمكن للـ CDN إعادة استجابة مكاشة');
  });

  test('(إصلاح البناء) رفع رقم build وحده = تحديث متاح فوراً', () async {
    // الحالي 3.49.0+85 والبيان 3.49.0+86 — نفس major.minor.patch.
    final info = await svcReturning(
      manifest(version: '3.49.0+86'),
      current: const AppSemVer(3, 49, 0, 85),
    ).check();
    expect(info.status, UpdateStatus.available,
        reason: '+86 أحدث من +85 حتى مع تطابق 3.49.0');
    // والعكس: نفس البناء تماماً = محدَّث.
    final same = await svcReturning(
      manifest(version: '3.49.0+85'),
      current: const AppSemVer(3, 49, 0, 85),
    ).check();
    expect(same.status, UpdateStatus.upToDate);
    // بناء أقدم لا يُعرض كتحديث.
    final older = await svcReturning(
      manifest(version: '3.49.0+84'),
      current: const AppSemVer(3, 49, 0, 85),
    ).check();
    expect(older.status, UpdateStatus.upToDate);
  });
}
