// QA — إصلاح: أيقونة «فتح شاشة المبيعات» داخل نافذة تسجيل عملية كانت
// لا تستجيب إلا من زر شاشة العمليات (كانت تعتمد على إشارة 'open_pos'
// يلتقطها المستدعي)؛ الآن تفتح نقطة البيع بنفسها من أي مكان.
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
import 'package:nexora_app/ui/pos_screen.dart';
import 'package:nexora_app/ui/tx_form.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUpAll(() async {
    await initializeDateFormatting('ar');
    Sfx.setMuted(true);
    await (FontLoader('Tajawal')
          ..addFont(rootBundle.load('assets/fonts/Tajawal-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Tajawal-Bold.ttf')))
        .load();
  });

  testWidgets('QA-POS-SHORTCUT tapping sales tile in TxForm opens PosScreen',
      (tester) async {
    late Directory tmp;
    late Database db;
    late Repo repo;
    late SyncEngine engine;
    late ProviderContainer container;
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('nexora_pos_sc_');
      db = await databaseFactory.openDatabase('${tmp.path}/ui.db',
          options: OpenDatabaseOptions(
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          ));
      await AppDatabase.createSchema(db);
      repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra(); // (دفعة 57) هوية الجهاز إلزامية قبل الكتابة.
      final now = DateTime(2026, 9, 9);
      await repo.saveAccount(Account(
        name: 'عميل الاختبار',
        kind: AccountKind.customer,
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
        container.read(allAccountsProvider.future),
        container.read(currenciesProvider.future),
        container.read(currentUserProvider.future),
        container.read(itemCategoriesProvider.future),
        container.read(itemsProvider.future),
      ]);
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const Scaffold(body: TxForm()),
        ),
      ));
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      // النوع الافتراضي «عليه (دين)» يُظهر اختصار الفاتورة.
      final tile = find.text('فتح شاشة المبيعات لإضافة الفاتورة');
      expect(tile, findsOneWidget);
      await tester.ensureVisible(tile);
      await tester.pump();
      await tester.tap(tile);
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 120));
      }
      // شاشة المبيعات فُتحت فعلاً والنموذج أُغلق.
      expect(find.byType(PosScreen), findsOneWidget);
      expect(find.byType(TxForm), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      engine.stop();
      container.dispose();
      await tester.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    }
  });
}
