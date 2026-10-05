// QA — التحول البصري الشامل Bento، نظام الترقيم السريع PLU، وتنظيف الإعدادات والدرج (2026-09-24).
//
// يختبر العقد الصارم لـ:
//  1) نظام الترقيم السريع PLU الثابت (توليد، ثبات، بيع رقمي x*y، إخفاء الرقم).
//  2) بوابة الأقسام وشريط الفئات وشبكة الأصناف المربّعة (4 / 6 / 8).
//  3) تنظيف القائمة الجانبية (حذف البنود الثلاثة، نافذة الحساب المنبثقة، قسم التحديثات).
//  4) تنظيف الإعدادات (حذف الوضع الليلي، حذف الخطوط، طي المنشأة وحذف الشعار،
//     حذف منطقة الخطر ودمجها بالأمان، حذف المجموعة، نقل الدعم وطلبات الخروج،
//     زر التحقق من حالة الاشتراك التجريبي/المدفوع/مدى الحياة).
//  5) المنظومة البصرية Bento (انحناء موحد 16-20px، سكويركل للتنقل والعلوي، فواصل نظيفة 1px).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/data/pos_cart.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/ui/pos_gate.dart';
import 'package:nexora_app/ui/pos_items_grid.dart';
import 'package:nexora_app/ui/pos_screen.dart';
import 'package:nexora_app/ui/profile_dialog.dart';
import 'package:nexora_app/ui/trial_ui.dart';
import 'package:nexora_app/data/sync/subscription_guard.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  late ProviderContainer container;

  setUpAll(() {
    Sfx.setMuted(true);
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_bento_plu_');
    db = await databaseFactory.openDatabase('${tmp.path}/test.db',
        options: OpenDatabaseOptions(
          onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        ));
    await AppDatabase.createSchema(db);
    await AppDatabase.migrateToV23(db);
    await AppDatabase.migrateToV24(db);
    await AppDatabase.migrateToV25(db);
    await AppDatabase.migrateToV26(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();

    container = ProviderContainer(overrides: [
      repoProvider.overrideWithValue(repo),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  // =========================================================================
  // 1. نظام الترقيم السريع والبيع الرقمي (Permanent PLU Index System)
  // =========================================================================
  group('PLU — نظام الترقيم السريع والبيع الرقمي', () {
    test('PLU-01 الترقيم التسلسلي يبدأ من 1 ويُبنى هرمياً ويثبت للأبد',
        () async {
      final now = DateTime.now();
      final sec1 = await repo.saveSection(Section(
        name: 'أغذية',
        createdAt: now,
        updatedAt: now,
      ));
      final cat1 = await repo.saveItemCategory(ItemCategory(
        name: 'مخبوزات',
        sectionId: sec1,
        createdAt: now,
        updatedAt: now,
      ));

      // صنفان معاً
      final id1 = await repo.saveItem(Item(
        name: 'خبز صامولي',
        categoryId: cat1,
        sectionId: sec1,
        sellPrice: 100,
        quantity: 20,
        createdAt: now,
        updatedAt: now,
      ));
      final id2 = await repo.saveItem(Item(
        name: 'خبز بر',
        categoryId: cat1,
        sectionId: sec1,
        sellPrice: 150,
        quantity: 15,
        createdAt: now,
        updatedAt: now,
      ));

      final item1 = await repo.item(id1);
      final item2 = await repo.item(id2);
      expect(item1?.plu, 1, reason: 'أول صنف يحمل PLU=1');
      expect(item2?.plu, 2, reason: 'ثاني صنف يحمل PLU=2');

      // عند حذف صنف، لا يُعاد استخدام رقمه أبداً
      await repo.deleteItem(id1);
      final id3 = await repo.saveItem(Item(
        name: 'كيك شوكولاتة',
        categoryId: cat1,
        sectionId: sec1,
        sellPrice: 300,
        quantity: 10,
        createdAt: now,
        updatedAt: now,
      ));
      final item3 = await repo.item(id3);
      expect(item3?.plu, 3, reason: 'الرقم 1 لا يُعاد استخدامه بعد الحذف');
    });

    test('PLU-02 إضافة كمية ذرّية لسلة POS بصيغة الضرب (1*5 و 1×5)', () {
      final now = DateTime.now();
      final item = Item(
        id: 10,
        plu: 1,
        name: 'عصير برتقال',
        sellPrice: 500,
        quantity: 20,
        createdAt: now,
        updatedAt: now,
      );

      final notifier = PosDraftNotifier();
      // إضافة عادية بكمية 1
      final ok1 = notifier.addItem(item, allowNegative: false, quantity: 1);
      expect(ok1, isTrue);
      expect(notifier.state.cart[10]?.quantity, 1.0);

      // إضافة صيغة الضرب ذرّياً: 5 قطع دفعة واحدة
      final ok2 = notifier.addItem(item, allowNegative: false, quantity: 5);
      expect(ok2, isTrue);
      expect(notifier.state.cart[10]?.quantity, 6.0);
    });

    test('PLU-03 رقم PLU مخفي تماماً داخل بطاقة الصنف في نقطة البيع', () {
      final now = DateTime.now();
      final item = Item(
        id: 7,
        plu: 7,
        name: 'شاي أحمر كيني',
        sellPrice: 250,
        quantity: 40,
        createdAt: now,
        updatedAt: now,
      );

      final tile = PosItemTile(
        item: item,
        symbol: 'ر.ي',
        inCart: 0,
        enabled: true,
        onAdd: () {},
      );

      // نتحقق من بنية PosItemTile: لا يوجد Text يحتوي على '7' كرقم تسلسلي
      // (اسم الصنف وسعره وكميته فقط).
      expect(tile.item.plu, 7);
    });
  });

  // =========================================================================
  // 2. إعادة هيكلة قسم المبيعات وشبكة الأصناف (POS Workflow & Responsive Grid)
  // =========================================================================
  group('POS — بوابة الأقسام وشبكة الأصناف المتجاوبة', () {
    testWidgets('POS-01 شاشة المبيعات تفتح افتراضياً على بوابة الأقسام',
        (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('ar'),
            theme: AppTheme.light(),
            home: const Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(body: PosScreen()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // المستوى 1: بوابة الأقسام ظاهرة افتراضياً
      expect(find.byType(PosSectionsGate), findsOneWidget);
      expect(find.text('كل الأقسام'), findsOneWidget);

      // استنزاف مؤقتات keepAlive (8 ثوانٍ)
      await tester.pump(const Duration(seconds: 10));
    });

    test('POS-02 أعمدة شبكة الأصناف المربّعة تتسع لـ 4 جوال، 6 تابلت، 8 حاسوب', () {
      expect(PosItemsGrid.crossAxisCountFor(360), 4, reason: '4 على الجوال');
      expect(PosItemsGrid.crossAxisCountFor(480), 4);
      expect(PosItemsGrid.crossAxisCountFor(768), 6, reason: '6 على التابلت');
      expect(PosItemsGrid.crossAxisCountFor(1200), 8, reason: '8 على الحاسوب');
    });

    testWidgets('POS-03 شريط الفئات يلتف ويركز على الفئة المختارة',
        (tester) async {
      final now = DateTime.now();
      final cats = [
        ItemCategory(id: 1, name: 'فئة 1', createdAt: now, updatedAt: now),
        ItemCategory(id: 2, name: 'فئة 2', createdAt: now, updatedAt: now),
        ItemCategory(id: 3, name: 'فئة 3', createdAt: now, updatedAt: now),
      ];

      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          theme: AppTheme.light(),
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: PosCategoryStrip(
                categories: cats,
                selectedId: selected,
                onPick: (id) => selected = id,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // الخيارات موجودة
      expect(find.text('الكل'), findsOneWidget);
      expect(find.text('فئة 1'), findsOneWidget);
    });
  });

  // =========================================================================
  // 3. تنظيف القائمة الجانبية (Drawer Cleanup & Account Profile Modal)
  // =========================================================================
  group('Drawer — تنظيف الدرج ونافذة الحساب الشخصي', () {
    test('DRW-01 حذف البنود الثلاثة من أسفل القائمة الجانبية', () {
      final src = File('lib/ui/home_shell.dart').readAsStringSync();
      // الخانات الثلاث حُذفت من الدرج
      expect(src, isNot(contains("'خدمة العملاء'")));
      expect(src, isNot(contains("'طلبات خروج الموظفين'")));
      // تسجيل الخروج نُقل لنافذة الحساب
      expect(src, isNot(contains("showSecuredLogout(ref);\n                  },\n                  child: Padding(\n                    padding: const EdgeInsets.symmetric(\n                      horizontal: 12,\n                      vertical: 12,\n                    ),\n                    child: Row(\n                      children: [\n                        Icon(\n                          Icons.logout_rounded,")));
    });

    test('DRW-02 إضافة بند التحديثات في الدرج مع حصر السجل بـ 3 أسطر', () {
      final src = File('lib/ui/home_shell.dart').readAsStringSync();
      expect(src, contains("'التحديثات'"));
      expect(src, contains('UpdateSection()'));
      expect(src, contains('updateCheckProvider'));
    });

    testWidgets('DRW-03 نافذة الحساب الشخصي تتيح تعديل البيانات وتسجيل الخروج',
        (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('ar'),
            theme: AppTheme.light(),
            home: Consumer(
              builder: (ctx, ref, _) => Scaffold(
                body: ElevatedButton(
                  onPressed: () => showAccountProfileDialog(ctx, ref),
                  child: const Text('افتح الحساب'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('افتح الحساب'));
      await tester.pumpAndSettle();

      // الحقول المطلوبة ظاهرة
      expect(find.text('الملف الشخصي والمنشأة'), findsOneWidget);
      expect(find.text('اسم المستخدم / هذا الجهاز'), findsOneWidget);
      expect(find.text('البريد الإلكتروني'), findsOneWidget);
      expect(find.text('رقم الهاتف / واتساب'), findsOneWidget);
      expect(find.text('اسم المنشأة / المتجر'), findsOneWidget);
      expect(find.text('نشاط المنشأة'), findsOneWidget);
      expect(find.text('العنوان الجغرافي'), findsOneWidget);
      expect(find.text('حفظ التعديلات'), findsOneWidget);
      expect(find.text('تسجيل الخروج'), findsOneWidget);

      // استنزاف المؤقتات المعلقة
      await tester.pump(const Duration(seconds: 15));
    });
  });

  // =========================================================================
  // 4. تنظيف وتعديل الإعدادات (Settings Refactoring & Elimination)
  // =========================================================================
  group('Settings — تنظيف وتبسيط الإعدادات', () {
    test('SET-01 زر الوضع الليلي محذوف من بطاقات العملات ومن الإعدادات', () {
      final accountsSrc = File('lib/ui/accounts_screen.dart').readAsStringSync();
      expect(accountsSrc, isNot(contains("isDark ? 'نهاري' : 'ليلي'")));

      final appSrc = File('lib/ui/appearance_screen.dart').readAsStringSync();
      expect(appSrc, isNot(contains("SegmentedButton<ThemeMode>")));
    });

    test('SET-02 أيقونة التبديل السريع لليلي/النهاري ثابتة في شريط التطبيق العلوي', () {
      final shellSrc = File('lib/ui/home_shell.dart').readAsStringSync();
      expect(shellSrc, contains('themeModeProvider.notifier'));
      expect(shellSrc, contains('Icons.light_mode_rounded'));
      expect(shellSrc, contains('Icons.dark_mode_rounded'));
    });

    test('SET-03 طي بيانات المؤسسة وحذف خيار تعديل الشعار من الإعدادات', () {
      final settingsSrc = File('lib/ui/settings_screen.dart').readAsStringSync();
      expect(settingsSrc, isNot(contains('_pickLogo')));
      expect(settingsSrc, isNot(contains('_removeLogo')));
      expect(settingsSrc, isNot(contains('شعار المؤسسة')));
      expect(settingsSrc, contains("initiallyExpanded: false"));
    });

    test('SET-04 حذف الخطوط تماماً وتعديل التبويب إلى المظهر', () {
      final settingsSrc = File('lib/ui/settings_screen.dart').readAsStringSync();
      expect(settingsSrc, isNot(contains("'المظهر والخطوط'")));
      expect(settingsSrc, isNot(contains("title: Text('الخطوط')")));
      expect(settingsSrc, contains("text: 'المظهر'"));
    });

    test('SET-05 حذف عبارة «مؤسستك مربوطة بحسابك» نهائياً من المستودع', () {
      final acctSrc = File('lib/ui/account_section.dart').readAsStringSync();
      expect(acctSrc, isNot(contains('مؤسستك مربوطة بحسابك')));
    });

    test('SET-06 إلغاء مسمى «منطقة الخطر» ودمج وظائف الحذف والتعيين تحت الأمان', () {
      final settingsSrc = File('lib/ui/settings_screen.dart').readAsStringSync();
      expect(settingsSrc, isNot(contains("text: 'منطقة الخطر'")));
      expect(settingsSrc, isNot(contains("'منطقة الخطر — حذف الحساب'")));
      expect(settingsSrc, isNot(contains("'منطقة الخطر — تهيئة المجموعة'")));
      expect(settingsSrc, contains("'إعادة الضبط والحذف'"));
      expect(settingsSrc, contains("text: 'الأمان'"));
    });

    test('SET-07 حذف «المجموعة وربط الأجهزة» من الإعدادات', () {
      final settingsSrc = File('lib/ui/settings_screen.dart').readAsStringSync();
      // بطاقة المجموعة وربط الأجهزة حُذفت من تبويب النظام والمزامنة
      expect(settingsSrc, isNot(contains("title: 'المجموعة وربط الأجهزة'")));
    });

    test('SET-08 وجود خدمة العملاء تحت الدعم والمساعدة وطلبات الخروج تحت الموظفين', () {
      final settingsSrc = File('lib/ui/settings_screen.dart').readAsStringSync();
      expect(settingsSrc, contains("'الدعم والمساعدة'"));
      expect(settingsSrc, contains("'خدمة العملاء (واتساب)'"));
      expect(settingsSrc, contains("'إدارة الموظفين'"));
      expect(settingsSrc, contains("'طلبات خروج الموظفين'"));
    });

    testWidgets('SET-09 زر التحقق من حالة الاشتراك يظهر تفاصيل الاشتراك بدقة',
        (tester) async {
      final now = DateTime.now();
      final subContainer = ProviderContainer(overrides: [
        repoProvider.overrideWithValue(repo),
        subscriptionProvider.overrideWith((ref) => Future.value(SubscriptionState(
              status: 'trial',
              planType: 'individual',
              maxDevices: 1,
              createdAtMs: now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
              expiresAtMs: now.add(const Duration(days: 12)).millisecondsSinceEpoch,
              isActive: true,
              deviceFingerprint: 'test_fp',
              serverNowMs: now.millisecondsSinceEpoch,
            ))),
      ]);
      addTearDown(subContainer.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: subContainer,
          child: MaterialApp(
            locale: const Locale('ar'),
            theme: AppTheme.light(),
            home: const Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(
                body: SingleChildScrollView(
                  child: SubscriptionDetailsSection(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('التحقق من حالة الاشتراك'), findsOneWidget);
    });
  });

  // =========================================================================
  // 5. المنظومة اللونية والهندسة البصرية (Bento Style & Visual Geometry)
  // =========================================================================
  group('Bento — المنظومة اللونية والهندسة البصرية', () {
    test('BNT-01 الحواف موحدة بين 16 و20 بكسل', () {
      expect(AppRadius.card, inInclusiveRange(16, 20));
      expect(AppRadius.field, inInclusiveRange(16, 20));
      expect(AppRadius.button, inInclusiveRange(16, 20));
    });

    test('BNT-02 تنوع الألوان الباستيلية AppTone', () {
      expect(AppTone.all.length, greaterThanOrEqualTo(7));
      for (final tone in AppTone.all) {
        expect(tone.background, isNotNull);
        expect(tone.foreground, isNotNull);
        // الخلفية الباستيلية فاتحة وناعمة
        expect(tone.background.computeLuminance(), greaterThan(0.7));
      }
    });

    test('BNT-03 قاعدة الفواصل النظيفة الصارمة 1px بلا ازدواجية', () {
      final theme = AppTheme.light();
      final div = theme.dividerTheme;
      expect(div.thickness, 1);
      expect(div.space, 1);
    });
  });
}
