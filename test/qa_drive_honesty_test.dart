// (2026-11-22) حارس الصدق: النسخ السحابي كان **وهماً بالكامل**.
//   حقل «حساب الدرايف» يُحفظ في التفضيلات بلا أي تسجيل دخول، وزر
//   «فتح جوجل درايف» يفتح المتصفح فقط. أوهم المستخدم بأن بياناته
//   محفوظة سحابياً. هذه الاختبارات تمنع رجوع الوهم.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final reports = File('lib/ui/reports_screens.dart').readAsStringSync();
  final settings = File('lib/ui/settings_screen.dart').readAsStringSync();
  final pubspec = File('pubspec.yaml').readAsStringSync();

  test('DRIVE-01 لا خانة بريد درايف وهمية', () {
    // كان المستخدم يكتب بريده ويظن أن النسخ يُرفع — ولا شيء يُرفع.
    expect(settings.contains("title: 'تغيير الحساب'"), isFalse,
        reason: 'الخانة توهم بتسجيل دخول غير موجود');
    expect(settings.contains('حساب الدرايف'), isFalse);
  });

  test('DRIVE-02 الشاشة تعلن بصراحة أن الرفع التلقائي غير مُفعّل', () {
    expect(reports.contains('الرفع التلقائي إلى درايف غير مُفعّل'), isTrue,
        reason: 'إخفاء القيد يضلّل المستخدم أكثر من غياب الميزة');
  });

  test('DRIVE-03 لا ادعاء تسجيل دخول جوجل بلا حزمة مصادقة', () {
    final claimsSignIn = reports.contains('تسجيل الدخول بـ Google') ||
        reports.contains('GoogleSignIn') ||
        reports.contains('google_sign_in');
    if (claimsSignIn) {
      expect(pubspec.contains('google_sign_in'), isTrue,
          reason: 'ادعاء تسجيل دخول بلا حزمة مصادقة = وهم');
    }
  });

  test('DRIVE-04 المسار المعروض يعمل فعلاً (مشاركة + نسخ محلي)', () {
    // البديل الصادق: مشاركة الملف عبر نظام أندرويد + قائمة النسخ المحلي.
    expect(reports.contains('Share.shareXFiles'), isTrue);
    expect(reports.contains('RestoreScreen'), isTrue);
  });

  test('DRIVE-05 زر «فتح drive.google.com» الميت أُزيل', () {
    expect(reports.contains("'https://drive.google.com'"), isFalse,
        reason: 'فتح الموقع لا يسجّل دخولاً ولا يرفع نسخة');
  });
}
