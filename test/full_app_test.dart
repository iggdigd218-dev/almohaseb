// اختبار تشغيل كامل: يشغّل التطبيق كأنه على هاتف حقيقي وينتقل بين الشاشات.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nexora_app/core.dart';
import 'package:nexora_app/main.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.dir);
  final String dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

Future<void> _seed() async {
  final existing = await Db.accountByName('منير');
  if (existing != null) return;
  final id = await Db.saveAccount(Account(name: 'منير'));
  await Db.saveTx(Tx(
      accountId: id, kind: 1, amount: 5000, date: '2026-11-21', time: '20:29'));
  await Db.saveTx(Tx(
      accountId: id,
      kind: 2,
      amount: 2000,
      details: 'نقداً',
      date: '2026-11-21',
      time: '20:30'));
}

/// رجوع عبر سهم الشريط العلوي
Future<void> _goBack(WidgetTester tester) async {
  for (final icon in [
    Icons.arrow_back,
    Icons.arrow_back_ios,
    Icons.arrow_back_ios_new
  ]) {
    final f = find.byIcon(icon);
    if (f.evaluate().isNotEmpty) {
      await tester.tap(f.first);
      return;
    }
  }
  final bb = find.byType(BackButton);
  if (bb.evaluate().isNotEmpty) await tester.tap(bb.first);
}

/// مضخّات محدودة آمنة (تمنع التعليق مع الرسوم المتحركة)
Future<void> _settle(WidgetTester tester, {int pumps = 15}) async {
  for (var i = 0; i < pumps; i++) {
    await tester.pump(const Duration(milliseconds: 60));
    // السماح للمستقبلات الحقيقية (IO) بالاكتمال
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
}

void main() {
  late String tmpDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmpDir = (await Directory.systemTemp.createTemp('almohaseb_test')).path;
    PathProviderPlatform.instance = _FakePathProvider(tmpDir);
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
    await Db.open();
    await _seed();
  });

  testWidgets('التطبيق يبدأ ويعرض الرئيسية ببيانات منير', (tester) async {
    await tester.pumpWidget(const LedgerApp());
    await _settle(tester);

    expect(find.text('منير'), findsWidgets);
    expect(find.textContaining('3,000'), findsWidgets);
    expect(find.text('عام'), findsWidgets);
  });

  testWidgets('فتح شاشة الحساب ثم إضافة مبلغ', (tester) async {
    await tester.pumpWidget(const LedgerApp());
    await _settle(tester);

    // فتح شاشة الحساب
    await tester.tap(find.text('منير').first);
    await _settle(tester);
    expect(find.textContaining('إضافة مبلغ'), findsWidgets);

    // فتح شاشة إضافة مبلغ
    await tester.tap(find.textContaining('إضافة مبلغ').first);
    await _settle(tester);
    expect(find.text('المبلغ'), findsWidgets);
    expect(find.text('التفاصيل'), findsWidgets);
    expect(find.text('عليه'), findsWidgets);
    expect(find.text('له'), findsWidgets);
    expect(find.text('محلي'), findsWidgets);
  });

  testWidgets('القائمة الجانبية والإعدادات وشاشاتها الفرعية', (tester) async {
    await tester.pumpWidget(const LedgerApp());
    await _settle(tester);

    // فتح القائمة الجانبية (زر ☰)
    await tester.tap(find.byIcon(Icons.menu).first);
    await _settle(tester);
    expect(find.text('إعدادات'), findsWidgets);

    // فتح الإعدادات
    await tester.tap(find.text('إعدادات').first);
    await _settle(tester);
    expect(find.text('البيانات الشخصية'), findsWidgets);

    // المرور على الشاشات الفرعية
    for (final item in [
      'البيانات الشخصية',
      'خيارات الطابعة',
      'خيارات الأمان',
      'خيارات حفظ البيانات',
      'خيارات أخرى',
    ]) {
      final f = find.text(item);
      if (f.evaluate().isNotEmpty) {
        await tester.tap(f.first);
        await _settle(tester);
        await _goBack(tester);
        await _settle(tester);
      }
    }
  });
}
