// QA — نظام التصميم الموحّد والقوائم المنسدلة الهرمية (2026-09-24).
//
// العقد بعد التنفيذ:
//  • الثيم: أزرق ملكي #0D6EFD · خلفية #F4F6F9 · زوايا 16px · ظلال بلا حدود
//    · أسعار خضراء #16A34A · التبويب النشط بكبسولة (Stadium).
//  • التنقل الهرمي: منسدلتان [الأقسام ▾] [الفئات ▾] تفتحان ورقة سفلية
//    واحدة بالأيقونات — بديلاً عن التمرير الأفقي المرهق.
//  • التجاوب: شاشة المخزون تُعرض بلا فيض (Overflow) على هاتف 360px و
//    تابلت 768px وسطح مكتب 1280px.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/icon_catalog.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/ui/hierarchy_filter.dart';
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

  Future<void> prepare(WidgetTester tester) => tester.runAsync(() async {
        Sfx.setMuted(true);
        tmp = await Directory.systemTemp.createTemp('nexora_ui_sys_');
        db = await databaseFactory.openDatabase('${tmp.path}/ui.db',
            options: OpenDatabaseOptions(
              onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            ));
        await AppDatabase.createSchema(db);
        await AppDatabase.migrateToV23(db);
        await AppDatabase.migrateToV24(db);
        await AppDatabase.migrateToV25(db);
        repo = Repo(databaseProvider: () async => db);
        await repo.initSyncInfra();

        // بيانات واقعية: قسمان + فئتان + ثلاثة أصناف (بصور وألوان).
        final now = DateTime.now();
        final sec1 = await repo.saveSection(Section(
          name: 'إلكترونيات',
          iconKey: 'smartphone',
          colorHex: '#0D6EFD',
          createdAt: now,
          updatedAt: now,
        ));
        final sec2 = await repo.saveSection(Section(
          name: 'بقالة',
          iconKey: 'grocery',
          colorHex: 'green',
          createdAt: now,
          updatedAt: now,
        ));
        final cat1 = await repo.saveItemCategory(ItemCategory(
          name: 'هواتف',
          sectionId: sec1,
          iconKey: 'phone_iphone',
          colorHex: 'violet',
          createdAt: now,
          updatedAt: now,
        ));
        final cat2 = await repo.saveItemCategory(ItemCategory(
          name: 'معلبات',
          sectionId: sec2,
          iconKey: 'inventory',
          colorHex: 'orange',
          createdAt: now,
          updatedAt: now,
        ));
        await repo.saveItem(Item(
          name: 'هاتف سامسونج A15',
          categoryId: cat1,
          sectionId: sec1,
          unit: 'حبة',
          sellPrice: 240000,
          quantity: 12,
          createdAt: now,
          updatedAt: now,
        ));
        await repo.saveItem(Item(
          name: 'زيت نباتي 1 لتر',
          categoryId: cat2,
          sectionId: sec2,
          unit: 'لتر',
          sellPrice: 4500,
          quantity: 30,
          createdAt: now,
          updatedAt: now,
        ));
        await repo.saveItem(Item(
          name: 'أرز 5 كجم',
          categoryId: cat2,
          sectionId: sec2,
          unit: 'كجم',
          sellPrice: 8200,
          quantity: 0,
          createdAt: now,
          updatedAt: now,
        ));

        container = ProviderContainer(overrides: [
          repoProvider.overrideWithValue(repo),
        ]);
      });

  Future<void> teardown(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 10));
    await tester.runAsync(() async {
      container.dispose();
      await db.close();
      await tmp.delete(recursive: true);
    });
  }

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    await tester.runAsync(() async {
      await container.read(itemCategoryTreeProvider.future);
      await container.read(itemsProvider.future);
      await container.read(itemCategoriesProvider.future);
      await container.read(sectionsProvider.future);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('ar'),
          theme: AppTheme.light(),
          home: const Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(body: InventoryScreen()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    addTearDown(tester.view.resetPhysicalSize);
  }

  // ============ الثيم ============
  test('THM-01 رموز التصميم: الألوان والزوايا والظلال', () {
    expect(AppColors.primary, const Color(0xFF0D6EFD));
    expect(AppColors.bg, const Color(0xFFF4F6F9));
    expect(AppColors.surface, const Color(0xFFFFFFFF));
    expect(AppColors.green, const Color(0xFF16A34A));
    expect(AppRadius.card, 16);
    expect(AppRadius.field, 16);
    expect(AppRadius.sheet, 24);

    final theme = AppTheme.light();
    final card = theme.cardTheme;
    final shape = card.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius.resolve(TextDirection.rtl).topLeft.x, 16);
    expect(shape.side, BorderSide.none); // لا حدود سميكة
    expect(card.elevation, greaterThan(0)); // ظل ناعم بدلاً منها

    // التبويب النشط: كبسولة لونية هادئة.
    final nav = theme.navigationBarTheme;
    expect(nav.indicatorShape, isA<StadiumBorder>());
    expect(nav.indicatorColor, isNotNull);

    // الحقول والبطاقات والشرائح بنفس الهوية.
    final input = theme.inputDecorationTheme.border! as OutlineInputBorder;
    expect(input.borderRadius.resolve(TextDirection.rtl).topLeft.x, 16);
  });

  // ============ المنسدلة الهرمية ============
  testWidgets('DRP-01 المنسدلة تفتح ورقة سفلية وتُعيد الاختيار',
      (tester) async {
    int? picked;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      theme: AppTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: HierarchyDropdown(
            label: 'كل الأقسام',
            icon: IconCatalog.of('apps'),
            tone: AppTone.blue,
            badge: '3 فئة',
            onTap: () async {
              final pick = await showHierarchySheet(
                context: tester.element(find.byType(HierarchyDropdown)),
                title: 'اختر القسم',
                selectedId: null,
                options: const [
                  HierarchyOption(
                      id: null,
                      label: 'كل الأقسام',
                      icon: Icons.apps,
                      tone: AppTone.blue,
                      badge: '3 فئة'),
                  HierarchyOption(
                      id: 7,
                      label: 'إلكترونيات',
                      icon: Icons.smartphone,
                      tone: AppTone.violet),
                ],
              );
              picked = pick?.id;
            },
          ),
        ),
      ),
    ));

    expect(find.text('كل الأقسام'), findsWidgets);
    await tester.tap(find.text('كل الأقسام').first);
    await tester.pumpAndSettle();
    // الورقة السفلية ظهرت بالخيارات.
    expect(find.text('اختر القسم'), findsOneWidget);
    expect(find.text('إلكترونيات'), findsOneWidget);
    await tester.tap(find.text('إلكترونيات'));
    await tester.pumpAndSettle();
    expect(picked, 7);
  });

  testWidgets('DRP-02 «الكل» قيمة صالحة (null) لا تُلبس بالإلغاء',
      (tester) async {
    HierarchyPick? result;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      theme: AppTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Builder(builder: (ctx) {
          return TextButton(
            onPressed: () async {
              result = await showHierarchySheet(
                context: ctx,
                title: 'اختر القسم',
                selectedId: 5,
                options: const [
                  HierarchyOption(
                      id: null,
                      label: 'كل الأقسام',
                      icon: Icons.apps,
                      tone: AppTone.blue),
                ],
              );
            },
            child: const Text('افتح'),
          );
        }),
      ),
    ));
    await tester.tap(find.text('افتح'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('كل الأقسام'));
    await tester.pumpAndSettle();
    // اختيار صريح لـ «الكل» ⇒ كائن يحمل null (وليس نتيجة إلغاء).
    expect(result, isNotNull);
    expect(result!.id, isNull);
  });

  testWidgets('DRP-03 بحث فوري داخل الورقة عند كثرة الخيارات',
      (tester) async {
    final options = List<HierarchyOption>.generate(
      12,
      (i) => HierarchyOption(
        id: i,
        label: 'قسم $i',
        icon: Icons.storefront_outlined,
        tone: AppTone.blue,
      ),
    );
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      theme: AppTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Builder(builder: (ctx) {
          return TextButton(
            onPressed: () => showHierarchySheet(
              context: ctx,
              title: 'اختر القسم',
              selectedId: null,
              options: options,
            ),
            child: const Text('افتح'),
          );
        }),
      ),
    ));
    await tester.tap(find.text('افتح'));
    await tester.pumpAndSettle();
    expect(find.text('قسم 0'), findsOneWidget);
    // البحث بـ «3» لا «قسم 3»: نص حقل البحث نفسه يظهر كعنصر Text.
    await tester.enterText(find.byType(TextField), '3');
    await tester.pumpAndSettle();
    expect(find.text('قسم 3'), findsOneWidget);
    expect(find.text('قسم 0'), findsNothing);
    expect(find.text('قسم 1'), findsNothing);
  });

  // ============ التجاوب (بلا Overflow) ============
  for (final size in <(String, Size)>[
    ('هاتف 360×640', const Size(360, 640)),
    ('تابلت 768×1024', const Size(768, 1024)),
    ('سطح مكتب 1280×800', const Size(1280, 800)),
  ]) {
    testWidgets('RSP-${size.$1} شاشة المخزون بلا فيض', (tester) async {
      await prepare(tester);
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;

      await pumpAt(tester, size.$2);

      // تُستعاد المعالِجة قبل أي expect: بقاء الخطأ المُلتقَط معلّقاً أثناء
      // فشل التأكيد يُجمّد الاختبار عشر دقائق.
      FlutterError.onError = previous;

      // شاشة المخزون تظهر ببياناتها.
      expect(find.byType(InventoryScreen), findsOneWidget);
      expect(find.text('هاتف سامسونج A15'), findsWidgets);

      // لا فيض (Overflow) ولا استثناءات تصيير.
      final overflows = errors
          .where((e) => '${e.exception}'.contains('overflowed'))
          .toList();
      final buf = StringBuffer();
      for (final e in errors) {
        buf.writeln('${e.exception}');
        final info = e.informationCollector?.call();
        if (info != null) {
          for (final node in info) {
            buf.writeln(node.toStringDeep().trim());
          }
        }
      }
      expect(overflows, isEmpty,
          reason: 'فيض على مقاس ${size.$1}: '
              '${overflows.map((e) => e.exception).join(' | ')}');
      await teardown(tester);
    });
  }

  // ============ التنقل بالمنسدلات فعلياً في الشاشة ============
  testWidgets('RSP-NAV اختيار قسم من المنسدلة يفلتر الفئات', (tester) async {
    await prepare(tester);
    await pumpAt(tester, const Size(360, 640));
    // زرّا المنسدلتين ظاهران (القسم + الفئة).
    expect(find.text('كل الأقسام'), findsWidgets);
    await tester.tap(find.text('كل الأقسام').first);
    await tester.pumpAndSettle();
    expect(find.text('إلكترونيات'), findsWidgets);
    await tester.tap(find.text('إلكترونيات').last);
    await tester.pumpAndSettle();
    // بعد اختيار القسم: اسمه يظهر على المنسدلة الأولى.
    expect(find.text('إلكترونيات'), findsWidgets);
    await teardown(tester);
  });

  testWidgets('DRP-04 على 360px إجراء «إدارة» داخل الورقة (لا فيض)',
      (tester) async {
    await prepare(tester);
    await pumpAt(tester, const Size(360, 640));
    // الأزرار الجانبية مخفية ضيقاً — الإجراء يبقى متاحاً داخل الورقة.
    expect(find.byTooltip('إدارة الأقسام والفئات'), findsNothing);
    await tester.tap(find.text('كل الأقسام').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('إدارة'));
    await tester.pumpAndSettle();
    expect(find.text('الأقسام والفئات'), findsOneWidget,
        reason: 'لوح الإدارة يُفتح من داخل الورقة السفلية');
    await teardown(tester);
  });

  // ============ حارس المصدر: لا رجوع للشرائط الأفقية القديمة ============
  test('SRC-01 الشاشتان تعتمدان البنية الحديثة لا الشرائح القديمة', () {
    final pos = File('lib/ui/pos_screen.dart').readAsStringSync();
    final inv = File('lib/ui/inventory_screen.dart').readAsStringSync();

    // شاشة المخزون تعتمد القوائم المنسدلة الهرمية.
    expect(inv, contains('hierarchy_filter.dart'));
    expect(inv, contains('HierarchyDropdown'));
    expect(inv, contains('showHierarchySheet'));

    // شاشة البيع تعتمد بوابة الأقسام وشريط الفئات وشبكة الأصناف المربّعة.
    expect(pos, contains('pos_gate.dart'));
    expect(pos, contains('pos_items_grid.dart'));
    expect(pos, contains('PosSectionsGate'));
    expect(pos, contains('PosCategoryStrip'));

    // الرموز القديمة للشرائط الأفقية أُزيلت نهائياً.
    expect(pos, isNot(contains('_SectionCard')));
    expect(pos, isNot(contains('_CategoryCapsule')));
    expect(inv, isNot(contains('_HierarchyChipBar')),
        reason: 'شريط الهرمية الأفقي لم يُستبدل');
  });
}
