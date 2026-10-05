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
import 'package:nexora_app/ui/chat_screen.dart';
import 'package:nexora_app/ui/currencies_screen.dart';
import 'package:nexora_app/ui/dashboard_screen.dart';
import 'package:nexora_app/ui/devices_screen.dart';
import 'package:nexora_app/ui/group_management_screen.dart';
import 'package:nexora_app/ui/inventory_screen.dart';
import 'package:nexora_app/ui/pos_screen.dart';
import 'package:nexora_app/ui/reports_screen.dart';
import 'package:nexora_app/ui/settings_screen.dart';
import 'package:nexora_app/ui/transactions_screen.dart';
import 'package:nexora_app/ui/trash_screen.dart';
import 'package:nexora_app/ui/users_screen.dart';
import 'package:nexora_app/ui/vouchers_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/cloud_config.dart';

void main() {
  // هذه الحزمة تحاكي سيناريوهات «لا سحابة» — نلغي الرابط الافتراضي
  // المضمن (Zero-Config) حتى تبقى فرضياتها صالحة.
  debugDefaultBackendUrlOverride = '';
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  setUpAll(() async {
    await initializeDateFormatting('ar');
    await initializeDateFormatting('en');
    Sfx.setMuted(true);
    await (FontLoader('Tajawal')
          ..addFont(rootBundle.load('assets/fonts/Tajawal-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Tajawal-Bold.ttf')))
        .load();
  });
  final screens = <String, Widget>{
    'dashboard': const DashboardScreen(),
    'accounts': const AccountsScreen(),
    'transactions': const TransactionsScreen(),
    'vouchers': const VouchersScreen(),
    'reports': const ReportsScreen(),
    'inventory': const InventoryScreen(),
    'currencies': const CurrenciesScreen(),
    'chat': const ChatScreen(),
    'group': const GroupManagementScreen(),
    'devices': const DevicesScreen(),
    'users': const UsersScreen(),
    'backup': const BackupScreen(),
    'trash': const TrashScreen(),
    'activity': const ActivityScreen(),
    'settings': const SettingsScreen(),
    'pos': const PosScreen(),
  };
  for (final width in [360.0, 1000.0]) {
    for (final entry in screens.entries) {
      testWidgets(
          'QA-SCREEN ${entry.key} RTL width=$width with real SQLite and Arabic font',
          (tester) async {
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
          await repo.initSyncInfra(); // (دفعة 57) هوية الجهاز إلزامية.
          final now = DateTime(2026, 9, 6);
          final accountId = await repo.saveAccount(Account(
            name: 'عميل الاختبار',
            kind: AccountKind.customer,
            openingBalance: -150,
            notifyChannel: 'none',
            createdAt: now,
            updatedAt: now,
          ));
          await repo.saveTx(Tx(
              accountId: accountId,
              type: OpType.debit,
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
            container.read(usersProvider.future),
            container.read(txPageProvider.future),
            container.read(vouchersProvider.future),
            container.read(recentTxProvider.future),
            container.read(alertsProvider.future),
            container.read(devicesProvider.future),
            container.read(isOwnerProvider.future),
            container.read(countsProvider.future),
            container.read(itemCategoriesProvider.future),
            container.read(itemsProvider.future),
            container.read(inventorySummaryProvider.future),
            container.read(reportDataProvider.future),
            container.read(trashProvider.future),
            container.read(activityProvider.future),
            container.read(conversationsProvider.future),
          ]);
        });
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
          // Native SQLite isolate replies and platform stubs are drained in real
          // async time, then the real widget tree is laid out in the test frame.
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
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 15));
          engine.stop();
          container.dispose();
          await tester.runAsync(() async {
            await db.close();
            await tmp.delete(recursive: true);
          });
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      });
    }
  }
}
