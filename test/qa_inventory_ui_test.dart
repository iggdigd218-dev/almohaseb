// QA — (2026-09-22) واجهة المخزون: لوح إدارة الفئات ونمط العرض
//  MGR  : زر «إدارة» يفتح اللوح، وفيه تعديل/حذف/إضافة فئة فرعية.
//  VIEW : مبدّل القائمة/الشبكة يعمل ويُحفظ في التفضيلات المحلية.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/ui/inventory_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  late ProviderContainer container;

  /// كل ما يلمس القرص/قاعدة البيانات يجب أن يجري داخل runAsync: جسم
  /// الاختبار يعمل في منطقة زمن وهمي (fake-async) فتتجمّد عمليات الإدخال
  /// والإخراج الحقيقية خارجها (10 دقائق تعليق بلا سبب ظاهر).
  Future<void> prepare(WidgetTester tester) => tester.runAsync(() async {
        Sfx.setMuted(true);
        tmp = await Directory.systemTemp.createTemp('nexora_inv_ui_');
        db = await databaseFactory.openDatabase('${tmp.path}/ui.db',
            options: OpenDatabaseOptions(
              onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            ));
        await AppDatabase.createSchema(db);
        await AppDatabase.migrateToV23(db);
    await AppDatabase.migrateToV24(db);
        await db.delete('item_categories');
        repo = Repo(databaseProvider: () async => db);
        await repo.initSyncInfra();
        // لا محرك مزامنة هنا: الشاشة لا تقرأ syncEngineProvider.
        container = ProviderContainer(overrides: [
          repoProvider.overrideWithValue(repo),
        ]);
      });

  Future<void> teardown(WidgetTester tester) async {
    // المزوّدات تُنشئ مؤقت timeout (8 ثوانٍ) داخل المنطقة الزمنية الوهمية؛
    // نتجاوزها زمنياً قبل إنهاء الاختبار وإلا فشل بـ «Timer is still pending».
    await tester.pump(const Duration(seconds: 10));
    await tester.runAsync(() async {
        container.dispose();
        await db.close();
        await tmp.delete(recursive: true);
      });
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    // قراءة المزوّدات داخل runAsync قبل البناء: استعلامات القاعدة الحقيقية
    // لا تكتمل في المنطقة الزمنية الوهمية، فتُقرأ البيانات وتُخبَّأ أولاً.
    await tester.runAsync(() async {
      await container.read(itemCategoryTreeProvider.future);
      await container.read(itemsProvider.future);
      await container.read(itemCategoriesProvider.future);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('ar'),
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(body: InventoryScreen()),
          ),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('MGR-01 لوح إدارة الفئات: إضافة فرعية وحذف', (tester) async {
    await prepare(tester);
    await tester.runAsync(() async {
      final rootId = await repo.saveItemCategory(ItemCategory(
        name: 'مواد غذائية',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      await repo.saveItemCategory(ItemCategory(
        name: 'ألبان',
        parentId: rootId,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
    });
    await pumpScreen(tester);

    // (2026-09-24) التنقل الهرمي صار منسدلتين لا شريطاً أفقياً: زر «إدارة»
    // أيقونة في الصفّ على الشاشات العريضة (≥400px)، وخيار داخل الورقة
    // السفلية على الضيقة — سطح الاختبار عريض فيُتوقع الزر مباشرة.
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    await tester.pumpAndSettle();
    final manage = find.byTooltip('إدارة الأقسام والفئات');
    expect(manage, findsOneWidget,
        reason: 'زر إدارة الهرمية ظاهر على الشاشات العريضة');
    await tester.tap(manage);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('الأقسام والفئات'), findsOneWidget,
        reason: 'اللوح يفتح بهيكلية الأقسام والفئات');
    expect(find.text('مواد غذائية'), findsWidgets);
    expect(find.byTooltip('إضافة فئة فرعية'), findsWidgets,
        reason: 'لكل فئة زر إضافة فرعية');
    expect(find.byTooltip('تعديل الاسم'), findsWidgets);
    expect(find.byTooltip('حذف الفئة'), findsWidgets);

    // الحذف نفسه وترقية الأبناء مغطّيان اختبارياً في
    // qa_inventory_tree_test.dart (TREE-05) بقاعدة حقيقية — هنا نتأكد
    // فقط أن اللوح يوفر الأزرار الثلاثة لكل فئة.
    await tester.tapAt(const Offset(5, 5)); // إغلاق اللوح.
    // نترك مهلة كافية لانتهاء حركة الإغلاق وأي مؤقت مرتبط بالصحيفة،
    // وإلا يفشل الاختبار بـ «A Timer is still pending».
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    await tester.binding.setSurfaceSize(null);
    await teardown(tester);
  });

  testWidgets('VIEW-01 مبدّل نمط العرض يُحفظ في التفضيلات', (tester) async {
    await prepare(tester);
    await tester.runAsync(() => repo.saveItemCategory(ItemCategory(
          name: 'فئة للعرض',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        )));
    await pumpScreen(tester);

    expect(find.text('قائمة'), findsOneWidget);
    await tester.tap(find.text('شبكة'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final st = await tester.runAsync(() => repo.settings()) ?? {};
    expect(st[kInventoryViewModeKey], 'grid',
        reason: 'نمط العرض محفوظ في التفضيلات المحلية');
    await teardown(tester);
  });
}
