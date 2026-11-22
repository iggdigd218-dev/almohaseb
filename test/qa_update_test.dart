// (2026-11-22) نظام التحديث — حارس ضد الأخطاء التي حدثت فعلياً:
//   ١) بيان JSON غير صالح ⇒ لا تحديث أبداً (حدث بسبب heredoc مكسور).
//   ٢) رقم مضبوط على قيمة ثابتة ⇒ دائماً «محدَّث» (يجب أن يتبع pubspec).
//   ٣) رابط تنزيل لخطأ يتجاوز 20MB.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/update.dart';

void main() {
  test('UPD-01 مقارنة الإصدارات صحيحة', () {
    expect(AppSemVer.tryParse('4.5.0+307')! > AppSemVer(4, 5, 0, 306), isTrue);
    expect(AppSemVer.tryParse('4.6.0+1')! > AppSemVer(4, 5, 9, 999), isTrue);
    expect(AppSemVer.tryParse('4.5.0+307')! > AppSemVer(4, 5, 0, 307), isFalse);
    expect(AppSemVer.tryParse('غير صالح'), isNull);
  });

  test('UPD-02 بيان غير صالح لا يرمي استثناءً', () async {
    // المحاكاة: خادم يعيد نصاً ليس JSON.
    final svc = _FakeService('{not json at all}');
    final info = await svc.check();
    expect(info.status, UpdateStatus.unknown);
    expect(info.hasUpdate, isFalse, reason: 'لا انهيار ولا تحديث وهمي');
  });

  test('UPD-03 بيان صالح أحدث ⇒ تحديث متاح برابط صالح', () async {
    final body = jsonEncode({
      'version': '4.9.0+400',
      'minSupported': '3.13.0',
      'downloads': {'android': 'https://example.com/app.apk'},
      'notes': '• إصلاح\n• تحسين',
    });
    final info = await _FakeService(body).check();
    expect(info.status, UpdateStatus.available);
    expect(info.downloadUrl, startsWith('https://'));
    expect(info.notes, contains('إصلاح'));
  });

  test('UPD-04 نفس الإصدار ⇒ محدَّث', () async {
    final body = jsonEncode({
      'version': '$kAppVersion+$kAppBuild',
      'downloads': {'android': 'https://example.com/app.apk'},
    });
    expect((await _FakeService(body).check()).status, UpdateStatus.upToDate);
  });

  test('UPD-05 رقم الإصدار المدمج يطابق pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version: ([\d.]+)\+(\d+)', multiLine: true)
        .firstMatch(pubspec)!;
    expect(kAppVersion, m.group(1),
        reason: 'انفصاله عن pubspec يجعل التطبيق يرى نفسه محدَّثاً دائماً');
    expect(kAppBuild, int.parse(m.group(2)!));
    // والكود يطابق القيمة المدمجة في AppSemVer.
    expect(AppSemVer.current.toString(), '$kAppVersion+$kAppBuild');
  });

  test('UPD-06 مسار الاسترجاع لا يعطّل الإقلاع', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('checkForUpdateOnStart'));
    expect(main, contains('addPostFrameCallback'),
        reason: 'الفحص يجب أن يبدأ بعد بناء الواجهة لا قبله');
  });

  test('UPD-07 بوابة الحجم 20MB موجودة في الـ workflow', () {
    final wf = File('.github/workflows/build-flutter-apk.yml').readAsStringSync();
    expect(wf, contains('20000000'), reason: 'بوابة الحجم شرط صارم');
    expect(wf, contains('--split-per-abi'), reason: 'البناء المقسم يحقق الحجم');
    expect(wf, contains('gen_version_manifest.py'),
        reason: 'البيان يُبنى بسكربت متحقّق لا بـ heredoc');
  });
}

/// خدمة اختبار: تعيد جسم استجابة ثابتاً بدل الشبكة.
class _FakeService extends UpdateService {
  final String body;
  _FakeService(this.body);

  @override
  Future<UpdateInfo> check() async {
    // نصل إلى المنطق الداخلي عبر الواجهة العامة باستخدام عميل وهمي.
    return super.checkWithBody(body);
  }
}
