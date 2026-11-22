import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/ui/account_form.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUpAll(() async {
    await initializeDateFormatting('ar');
    Sfx.setMuted(true);
  });

  Widget wrap(Repo repo, Widget child) => ProviderScope(
        overrides: [repoProvider.overrideWithValue(repo)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: child,
        ),
      );

  testWidgets('زر جلب جهة الاتصال يظهر بجانب حقل الاسم', (tester) async {
    late Database db;
    late Repo repo;
    await tester.runAsync(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 1,
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
            onCreate: (d, _) => AppDatabase.createSchema(d),
          ));
      repo = Repo(databaseProvider: () async => db);
    });
    await tester.pumpWidget(wrap(repo, const AccountFormScreen()));
    await _drain(tester);
    expect(find.widgetWithText(TextFormField, 'اسم الحساب *'), findsWidgets);
    // زر جلب جهة الاتصال.
    expect(find.byIcon(Icons.contacts_rounded), findsWidgets);
    // لم يعد هناك زر اتصال/رسائل بجانب حقل الرقم.
    expect(find.byIcon(Icons.sms), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => db.close());
  });
}
