// QA — (2026-09-22) شروط العضو والمدير الجديدة:
//  ORG: أيقونة المؤسسة إعداد متزامن — يكتبها المدير وتصل الأعضاء.
//  GATE: الأيقونات الجانبية تظهر حسب صلاحية العضو فقط.
//  GATE: «إدارة المجموعة» تظهر للمدير بعد ربط حساب جوجل (ولو مستقلاً).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:nexora_app/ui/home_shell.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// بلاطات لوحة التحكم تحمل أسماءً مشابهة لعناصر الدرج (مثل «العمليات»),
/// فنطابق النص **داخل الدرج فقط** لئيلاً نقيس واجهة أخرى بالخطأ.
Finder inDrawer(String text) => find.descendant(
      of: find.byType(Drawer),
      matching: find.text(text),
    );

/// (استقرار CI) انتظار فتح الدرج فعلياً قبل القياس: على آلات محمّلة
/// قد تتأخر حركة الدرج فتُقاس شجرة قديمة ويسقط الاختبار بلا عطل حقيقي.
Future<void> _waitDrawer(WidgetTester tester, {bool open = true}) async {
  for (var i = 0; i < 40; i++) {
    final visible = find.byType(Drawer).evaluate().isNotEmpty;
    if (visible == open) return;
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  TestWidgetsFlutterBinding.ensureInitialized();
  debugDefaultBackendUrlOverride = '';

  late Directory tmp;
  late Database db;
  late Repo repo;

  Future<void> freshRepo(String tag) async {
    tmp = await Directory.systemTemp.createTemp('nexora_gates_$tag');
    db = await databaseFactory.openDatabase('${tmp.path}/gates.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  }

  Future<void> disposeRepo() async {
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }

  group('أيقونة المؤسسة المتزامنة', () {
    test('ORG-01 setSyncedSetting يكتب الإعداد ويصعّد عملية إعدادات', () async {
      await freshRepo('org1');
      await repo.setSetting('cloudBackendUrl', 'https://qa-gates.example.com');
      await repo.setSetting('account.email', 'boss@gates.test');
      await repo.setSyncedSetting('org.icon.b64', 'QUJDREVG');
      expect((await repo.settings())['org.icon.b64'], 'QUJDREVG');
      final ops = await db.query('operations',
          where: "entity_type = 'setting' AND entity_id = 'org.icon.b64'");
      expect(ops, hasLength(1), reason: 'عملية الإعدادات تُسجل محلياً');
      final q = await db.query('sync_queue',
          where: "target = 'cloud' AND status = 'pending'");
      expect(q, isNotEmpty, reason: 'العملية تُطاب للسحابة');
      await disposeRepo();
    });

    test('ORG-02 عملية أيقونة واردة تُطبق في إعدادات جهاز العضو', () async {
      await freshRepo('org2');
      final now = DateTime.now().toIso8601String();
      final op = SyncOperation(
        id: 'OWNER-orgicon',
        deviceId: 'OWNER-DEV',
        workspaceId: repo.requireWorkspaceId,
        userId: null,
        parentOpId: '',
        entityType: EntityKind.setting,
        entityId: 'org.icon.b64',
        opType: OpKind.settings,
        version: 1,
        payload: {'key': 'org.icon.b64', 'value': 'WFlaT1JH'},
        deviceTime: now,
        timestamp: now,
      );
      await db.transaction((txn) async {
        expect(await repo.applyRemoteOperation(txn, op, ConflictResolver()),
            isTrue);
      });
      expect((await repo.settings())['org.icon.b64'], 'WFlaT1JH',
          reason: 'العضو يستقبل أيقونة المؤسسة التي وضعها المدير');
      await disposeRepo();
    });
  });

  group('الأيقونات الجانبية حسب الصلاحية', () {
    testWidgets('GATE-01 عضو عارض: أيقونات بلا صلاحية مخفية تماماً',
        (tester) async {
      debugDefaultBackendUrlOverride = '';
      await tester.runAsync(() async {
        await initializeDateFormatting('ar');
        await (FontLoader('Tajawal')
              ..addFont(rootBundle.load('assets/fonts/Tajawal-Regular.ttf')))
            .load();
        await freshRepo('gate1');
        // عضو (ليس المالك) بصلاحية عرض التقارير فقط.
        await db.update('devices', {'is_owner': 0});
        await db.insert(
            'sync_meta', {'key': 'workspaceMode', 'value': 'member'},
            conflictAlgorithm: ConflictAlgorithm.replace);
        await db.update('users',
            {'role': 'viewer', 'permissions': 'view_reports'},
            where: 'is_me = 1');
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1600);
      Sfx.setMuted(true);
      final engine = SyncEngine(repo: repo, dbProvider: () async => db);
      try {
        await tester.pumpWidget(ProviderScope(
            overrides: [
              repoProvider.overrideWithValue(repo),
              syncEngineProvider.overrideWithValue(engine),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              locale: const Locale('ar'),
              supportedLocales: const [Locale('ar')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: const HomeShell(),
            )));
        await _settle(tester);
        // افتح الدرج.
        await tester.tap(find.byIcon(Icons.menu).first);
        await _waitDrawer(tester);
        await _settle(tester);
        // بلا صلاحية عمليات: لا «العمليات» ولا «إدارة المنتجات» ولا
        // «السندات» ولا «نقطة البيع» ولا «العملاء» ولا «إدارة المجموعة».
        expect(inDrawer('العمليات'), findsNothing);
        expect(inDrawer('إدارة المنتجات'), findsNothing);
        expect(inDrawer('السندات'), findsNothing);
        expect(inDrawer('نقطة البيع (POS)'), findsNothing);
        expect(inDrawer('الحسابات'), findsNothing);
        expect(inDrawer('إدارة المجموعة'), findsNothing);
        // بصلاحية view_reports: التقارير وسجل النشاط ظاهران.
        expect(inDrawer('التقارير'), findsOneWidget);
        expect(inDrawer('سجل النشاط'), findsOneWidget);
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox.shrink());
        engine.stop();
        await tester.runAsync(disposeRepo);
      }
    });

    testWidgets(
        'GATE-02 مدير مستقل بلا جوجل: «إدارة المجموعة» مخفية — وبعد الربط تظهر',
        (tester) async {
      debugDefaultBackendUrlOverride = '';
      await tester.runAsync(() async {
        await initializeDateFormatting('ar');
        await (FontLoader('Tajawal')
              ..addFont(rootBundle.load('assets/fonts/Tajawal-Regular.ttf')))
            .load();
        await freshRepo('gate2');
        await db.update('devices', {'is_owner': 1});
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1600);
      Sfx.setMuted(true);
      final engine = SyncEngine(repo: repo, dbProvider: () async => db);
      try {
        await tester.pumpWidget(ProviderScope(
            overrides: [
              repoProvider.overrideWithValue(repo),
              syncEngineProvider.overrideWithValue(engine),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              locale: const Locale('ar'),
              supportedLocales: const [Locale('ar')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: const HomeShell(),
            )));
        await _settle(tester);
        await tester.tap(find.byIcon(Icons.menu).first);
        await _waitDrawer(tester);
        await _settle(tester);
        // بلا حساب جوجل: بوابة الأمان تخفي إدارة المجموعة.
        expect(inDrawer('إدارة المجموعة'), findsNothing,
            reason: 'لا إدارة مجموعة قبل ربط حساب جوجل');
        // أغلق الدرج، اربط حساب جوجل، أعد الفتح.
        await tester.tap(find.byIcon(Icons.menu).first, warnIfMissed: false);
        await _settle(tester);
        await tester.runAsync(() async {
          await db.insert('google_auth', {
            'id': 1,
            'google_id': 'g-owner-123',
            'email': 'boss@gates.test',
          });
        });
        // إغلاق الدرج بالنقر على الحاجز (يمين الشاشة) — لا أيقونة إغلاق.
        await tester.tapAt(const Offset(760, 800));
        await _settle(tester);
        await tester.tap(find.byIcon(Icons.menu).first, warnIfMissed: false);
        await _settle(tester);
        // محاكاة ما يفعله التطبيق بعد نجاح الدخول: تحديث المزودات.
        final ctx = tester.element(find.byType(HomeShell));
        ProviderScope.containerOf(ctx)
          ..invalidate(googleLinkedProvider)
          ..invalidate(drawerPhotoProvider);
        await _settle(tester);
        expect(inDrawer('إدارة المجموعة'), findsOneWidget,
            reason: 'بعد إنشاء/ربط حساب جوجل تظهر أيقونة إدارة المجموعة');
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox.shrink());
        engine.stop();
        await tester.runAsync(disposeRepo);
      }
    });
  });
}
