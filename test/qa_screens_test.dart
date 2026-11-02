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
      final now = DateTime(2026, 9, 6);
      final accountId = await repo.saveAccount(Account(
        name: 'عميل الاختبار',
        kind: AccountKind.customer,
        openingBalance: -150,
        notifyChannel: 'none',
        createdAt: now,
        updatedAt: now,
      ));
      // دفعة (credit = -1) على افتتاحية -150 → الرصيد -650 أي «عليكم».
      await repo.saveTx(Tx(
          accountId: accountId,
          type: OpType.credit,
          amount: 500,
          date: now,
          createdAt: now,
          updatedAt: now));
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
      // شريط البحث الخاص بشاشة العملاء ظاهر — أي أننا داخلها مباشرة.
      expect(find.text('بحث بالاسم أو الهاتف أو الملاحظات…'), findsOneWidget);
      // لا وجود لبطاقات الملخص العلوية القديمة.
      expect(find.text('اسحب البطاقات للتبديل بين العملات'), findsNothing);
      // البطاقة النحيفة السفلية: ملخص عليكم/لكم فوق الشريط السفلي.
      expect(find.text('عليكم'), findsWidgets);
      expect(find.text('لكم'), findsWidgets);
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

  testWidgets('QA-ACCOUNTS-01 سحب قائمة العملاء يمينًا/يسارًا يبدّل التصنيف',
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
      // «الكل» نشط افتراضيًا وعميل الاختبار ظاهر (رصيده عليه 650).
      expect(find.text('عميل الاختبار'), findsOneWidget);
      // في RTL (PageView باتجاه left): سحب الإصبع لليمين يقدّم الصفحة
      // التالية ← «عليكم». timedDrag يرسل الحركة على خطوات زمنية كما
      // يفعل الإصبع الحقيقي — drag بنقرة واحدة لا يكسب ساحة الإيماءات.
      await tester.timedDrag(find.text('عميل الاختبار'),
          const Offset(400, 0), const Duration(milliseconds: 300));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // عميل عليه دين → يبقى ظاهرًا في «عليكم».
      expect(find.text('عميل الاختبار'), findsOneWidget);
      // سحب آخر → «لكم» — لا عملاء لنا → القائمة فارغة.
      await tester.timedDrag(find.byType(PageView).first,
          const Offset(400, 0), const Duration(milliseconds: 300));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('عميل الاختبار'), findsNothing);
      // النقر على شريحة «الكل» يعيد الجميع.
      await tester.tap(find.text('الكل'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('عميل الاختبار'), findsOneWidget);
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
