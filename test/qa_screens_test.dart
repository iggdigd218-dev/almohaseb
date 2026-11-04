import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:nexora_app/ui/accounts_screen.dart';
import 'package:nexora_app/ui/backup_screen.dart';
import 'package:nexora_app/ui/currencies_screen.dart';
import 'package:nexora_app/ui/home_shell.dart';
import 'package:nexora_app/ui/reports_screen.dart';
import 'package:nexora_app/ui/settings_screen.dart';
import 'package:nexora_app/ui/splash.dart';
import 'package:nexora_app/ui/transactions_screen.dart';
import 'package:nexora_app/ui/trash_screen.dart';
import 'package:nexora_app/ui/vouchers_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/cloud_config.dart';

void main() {
  // هذه الحزمة تحاكي سيناريوهات «لا سحابة» — نلغي الرابط الافتراضي
  // المضمن (Zero-Config) حتى تبقى فرضياتها صالدة.
  debugDefaultBackendUrlOverride = '';
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  setUpAll(() async {
    await initializeDateFormatting('ar');
    await initializeDateFormatting('en');
    Sfx.setMuted(true);
    await (FontLoader('AppNaskh')
          ..addFont(rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/NotoNaskhArabic-Bold.ttf')))
        .load();
  });

  // ═══ (دفتر الحسابات الخالص) عقد الواجهة الجديد ═══
  // الشاشات الحية بعد اجتثاث المجموعات/الأدوار/الدردشة والواجهة الرئيسية.
  final screens = <String, Widget>{
    'accounts': const AccountsScreen(),
    'transactions': const TransactionsScreen(),
    'vouchers': const VouchersScreen(),
    'reports': const ReportsScreen(),
    'currencies': const CurrenciesScreen(),
    'backup': const BackupScreen(),
    'trash': const TrashScreen(),
    'activity': const ActivityScreen(),
    'settings': const SettingsScreen(),
  };

  Future<(Directory, Database, Repo, SyncEngine, ProviderContainer)>
      bootstrap(WidgetTester tester) async {
    late Directory tmp;
    late Database db;
    late Repo repo;
    late SyncEngine engine;
    late ProviderContainer container;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('nexora_screen_');
      db = await databaseFactory.openDatabase('${tmp.path}/ui.db',
          options: OpenDatabaseOptions(
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          ));
      await AppDatabase.createSchema(db);
      repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra();
      // (تصحيح 2026-11-03) بيانات الشاشة: عميل ومورد — التصنيف صار
      // نوع الحساب لا رصيده ولا عملته. تُنشأ قبل قراءة المزودات
      // حتى تلتقطها القوائم في أول تحميل.
      final now = DateTime(2026, 9, 6);
      await repo.saveAccount(Account(
        name: 'عميل الاختبار',
        kind: AccountKind.customer,
        openingBalance: -150,
        notifyChannel: 'none',
        createdAt: now,
        updatedAt: now,
      ));
      await repo.saveAccount(Account(
        name: 'مورد الاختبار',
        kind: AccountKind.supplier,
        openingBalance: 400,
        notifyChannel: 'none',
        createdAt: now,
        updatedAt: now,
      ));
      engine = SyncEngine(repo: repo, dbProvider: () async => db);
      container = ProviderContainer(overrides: [
        repoProvider.overrideWithValue(repo),
        syncEngineProvider.overrideWithValue(engine),
      ]);
      await Future.wait([
        container.read(settingsProvider.future),
        container.read(summaryProvider.future),
        container.read(accountsProvider.future),
        container.read(allAccountsProvider.future),
        container.read(currenciesProvider.future),
        container.read(currentUserProvider.future),
        container.read(txPageProvider.future),
        container.read(vouchersProvider.future),
        container.read(recentTxProvider.future),
        container.read(alertsProvider.future),
        container.read(isOwnerProvider.future),
        container.read(countsProvider.future),
        container.read(reportDataProvider.future),
        container.read(trashProvider.future),
        container.read(activityProvider.future),
      ]);
    });
    return (tmp, db, repo, engine, container);
  }

  Future<void> teardown(WidgetTester tester, Directory tmp, Database db,
      SyncEngine engine, ProviderContainer container) async {
    // (استقرار CI) أوقف المحرك أولاً حتى لا تُشعل المضخات اللاحقة
    // سحبًا سحابيًا جديدًا، ثم هدم الشجرة، ثم صفّر العمليات الجارية فعليًا
    // (استعلامات sqflite عالقة تُبقي مؤقتاتها الحارسة 10 ثوانٍ معلّقة).
    engine.stop();
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    container.dispose();
    await tester.runAsync(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  for (final width in [360.0, 1000.0]) {
    for (final entry in screens.entries) {
      testWidgets(
          'QA-SCREEN ${entry.key} RTL width=$width with real SQLite and Arabic font',
          (tester) async {
    final (tmp, db, repo, engine, container) = await bootstrap(tester);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 850);
        try {
          await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              locale: const Locale('ar'),
              supportedLocales: const [Locale('ar')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: Scaffold(body: entry.value),
            ),
          ));
          for (var i = 0; i < 3; i++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 60)));
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(Directionality.of(tester.element(find.byWidget(entry.value))),
              TextDirection.rtl);
          final error = tester.takeException();
          if (error != null) {
            debugPrint('SCREEN_LAYOUT ${entry.key} $width: $error');
          }
          expect(error, isNull);
          expect(find.byType(ErrorWidget), findsNothing);
        } finally {
          await teardown(tester, tmp, db, engine, container);
        }
      });
    }
  }

  testWidgets('QA-NAV-01 التطبيق يفتح مباشرة على شاشة العملاء بلا واجهة رئيسية',
      (tester) async {
    final (tmp, db, repo, engine, container) = await bootstrap(tester);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const HomeShell(),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      // (تصحيح 2026-11-03) البحث أيقونة بجوار الجرس أعلى يسار الشاشة —
      // لا خانة بحث دائمة تعلو القائمة.
      expect(find.text('بحث بالاسم أو الهاتف أو الملاحظات…'), findsNothing);
      expect(find.byIcon(Icons.search_rounded), findsOneWidget);
      // (تصحيح 2026-11-03) التصنيف صار **نوع الحساب**: عملاء/موردين/عام.
      expect(find.text('عملاء'), findsWidgets);
      expect(find.text('موردين'), findsOneWidget);
      expect(find.text('حساب عام'), findsOneWidget);
      // ولا وجود لأي تصنيف عملة أو فرز أرصدة (لكم/عليكم) في الشاشة.
      expect(find.text('كل العملات'), findsNothing);
      expect(find.text('عليكم'), findsNothing);
      expect(find.text('لكم'), findsNothing);
      expect(find.text('اسحب البطاقات للتبديل بين العملات'), findsNothing);
      // (تصحيح 2026-11-03) لا شريط تبويبات سفلي — التنقل كله من الدرج.
      // مكانه بطاقة الملخص: لك / عليك / الإجمالي.
      expect(find.text('الحركات'), findsNothing);
      expect(find.text('التقارير'), findsNothing);
      expect(find.text('الإعدادات'), findsNothing);
      expect(find.text('لك'), findsWidgets);
      expect(find.text('عليك'), findsWidgets);
      expect(find.text('الإجمالي'), findsWidgets);
      // (بوابة الاشتراك) «العمليات المتزامنة» في قائمة ⋮ لا تظهر إلا
      // للمشترك المدفوع — بيئة الاختبار بلا سحابة فلا اشتراك.
      await tester.tap(find.byIcon(Icons.more_vert_rounded).first,
          warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('العمليات المتزامنة'), findsNothing);
      await tester.tapAt(const Offset(20, 20)); // إغلاق القائمة
      await tester.pump(const Duration(milliseconds: 200));
      final error = tester.takeException();
      expect(error, isNull);
    } finally {
      await teardown(tester, tmp, db, engine, container);
    }
  });

  testWidgets(
      'QA-NAV-02 الدرج الثانوي: سندات/عملات/نسخ/مهملات/نشاط — بلا مجموعات ولا عمليات متزامنة',
      (tester) async {
    final (tmp, db, repo, engine, container) = await bootstrap(tester);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const HomeShell(),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      // فتح الدرج (مع إعادة المحاولة لطبقة عابرة محتملة).
      for (var i = 0;
          i < 40 && find.byType(Drawer).evaluate().isEmpty;
          i++) {
        await tester.tap(find.byIcon(Icons.menu).first, warnIfMissed: false);
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(find.byType(Drawer).evaluate(), isNotEmpty,
          reason: 'الدرج يجب أن يفتح');
      Finder inDrawer(String text) => find.descendant(
            of: find.byType(Drawer),
            matching: find.text(text),
          );
      // (تصحيح 2026-11-03) القسم الرئيسي أولاً — الدرج متكامل.
      expect(inDrawer('الحسابات'), findsOneWidget);
      expect(inDrawer('العمليات'), findsOneWidget);
      expect(inDrawer('التقارير'), findsOneWidget);
      expect(inDrawer('الإعدادات'), findsOneWidget);
      // العناصر الثانوية كلها ظاهرة (لا بوابات صلاحيات).
      expect(inDrawer('السندات'), findsOneWidget);
      expect(inDrawer('العملات'), findsOneWidget);
      expect(inDrawer('النسخ الاحتياطي'), findsOneWidget);
      expect(inDrawer('سلة المهملات'), findsOneWidget);
      expect(inDrawer('سجل النشاط'), findsOneWidget);
      // المجتثاث: لا مجموعات ولا دردشة ولا عمليات متزامنة ولا مستخدمين.
      expect(inDrawer('إدارة المجموعة'), findsNothing);
      expect(inDrawer('الدردشة'), findsNothing);
      expect(inDrawer('العمليات المتزامنة'), findsNothing);
      expect(inDrawer('لوحة التحكم'), findsNothing);
      final error = tester.takeException();
      expect(error, isNull);
    } finally {
      await teardown(tester, tmp, db, engine, container);
    }
  });

  testWidgets('QA-ACCOUNTS-01 تصنيف نوع الحساب (عملاء/موردين) بلا فلاتر عملة',
      (tester) async {
    final (tmp, db, repo, engine, container) = await bootstrap(tester);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const HomeShell(),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      // «الكل» افتراضيًا: الحسابان معًا — مع سهم حالة بجوار كل اسم:
      // العميل رصيده سالب (له) → ▼ أحمر، والمورد موجب (عليه) → ▲ أخضر.
      expect(find.text('عميل الاختبار'), findsOneWidget);
      expect(find.text('مورد الاختبار'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_circle_down), findsOneWidget);
      expect(find.byIcon(Icons.arrow_circle_up), findsOneWidget);
      // لا فلاتر عملة في الرأس ولا فرز أرصدة.
      expect(find.text('كل العملات'), findsNothing);
      expect(find.text('مسدد'), findsNothing);
      // (استقرار CI) كل نقرة شريحة تعيد استعلام الحسابات — نُعطي
      // زمنًا حقيقيًا لsqflite كي يكتمل ثم مضخات لتفريغ النتائج.
      Future<void> settle() async {
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 60)));
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      // (تصحيح 2026-11-03) الشاشة كلها قابلة للسحب بين التصنيفات:
      // في RTL سحب الإصبع لليمين (+X) يكشف الصفحة التالية ← «عملاء».
      // timedDrag يرسل الحركة على خطوات زمنية كما الإصبع الحقيقي.
      await tester.timedDrag(find.text('عميل الاختبار'),
          const Offset(400, 0), const Duration(milliseconds: 300));
      await settle();
      expect(find.text('عميل الاختبار'), findsOneWidget);
      expect(find.text('مورد الاختبار'), findsNothing);

      // «موردين»: المورد فقط (نقر الشريحة) — وسهمه ▲ الأخضر وحده.
      await tester.tap(find.text('موردين'));
      await settle();
      expect(find.text('مورد الاختبار'), findsOneWidget);
      expect(find.text('عميل الاختبار'), findsNothing);
      expect(find.byIcon(Icons.arrow_circle_up), findsOneWidget);
      expect(find.byIcon(Icons.arrow_circle_down), findsNothing);
      // «عملاء»: العميل فقط.
      await tester.tap(find.text('عملاء').first);
      await settle();
      expect(find.text('عميل الاختبار'), findsOneWidget);
      expect(find.text('مورد الاختبار'), findsNothing);
      // العودة إلى «الكل»: الجميع.
      await tester.tap(find.text('الكل'));
      await settle();
      expect(find.text('عميل الاختبار'), findsOneWidget);
      expect(find.text('مورد الاختبار'), findsOneWidget);

      // البحث يُفتح من الأيقونة بجوار الجرس ويُغلق بزر ✕.
      await tester.tap(find.byIcon(Icons.search_rounded));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('بحث بالاسم أو الهاتف أو الملاحظات…'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('بحث بالاسم أو الهاتف أو الملاحظات…'), findsNothing);
      final error = tester.takeException();
      expect(error, isNull);
    } finally {
      await teardown(tester, tmp, db, engine, container);
    }
  });

  testWidgets('QA-SPLASH-01 شاشة البداية: بلا «سجل المبيعات والديون» وخلفية سماوية',
      (tester) async {
    final (tmp, db, repo, engine, container) = await bootstrap(tester);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const SplashScreen(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      // العنوان الرئيسي موجود والوصف القديم مجتث.
      expect(find.text('مدير الحسابات'), findsOneWidget);
      expect(find.text('سجل المبيعات والديون'), findsNothing);
      // الخلفية تدرج سماوي (لون السماء الفاتح موجود في الشجرة).
      final containers = tester
          .widgetList<Container>(find.byType(Container))
          .toList();
      final hasSkyGradient = containers.any((c) {
        final d = c.decoration;
        return d is BoxDecoration &&
            d.gradient is LinearGradient &&
            (d.gradient as LinearGradient)
                .colors
                .any((col) => col == const Color(0xFF7DD3FC));
      });
      expect(hasSkyGradient, isTrue, reason: 'خلفية سماوية متدرجة');
      final error = tester.takeException();
      expect(error, isNull);
      // (استقرار CI) مؤقّت الانتقال في splash (1.7s + مهلتا 2s للقاعدة)
      // يجب أن يستهلك كاملًا بعد هدم الشجرة — وإلا بقي معلقًا في نهاية
      // الاختبار. هدم مبكر ثم تصريف زمني حقيقي+وهمي حتى تكتمل السلسلة
      // وترجع بفحص mounted دون تنقل.
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 400));
      }
    } finally {
      await teardown(tester, tmp, db, engine, container);
    }
  });
}
