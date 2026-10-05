import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/ui/account_form.dart';
import 'package:nexora_app/ui/tx_form.dart';

final qaDate = DateTime(2026, 9, 6);
Account qaAccount({int id = 1, double opening = 0}) => Account(
      id: id,
      name: 'حساب الاختبار $id',
      kind: AccountKind.customer,
      openingBalance: opening,
      notifyChannel: 'none',
      createdAt: qaDate,
      updatedAt: qaDate,
    );

/// UI tests use a controlled service boundary. Real SQLite is covered separately.
class UiRepo extends Repo {
  List<Account> accountRows = [qaAccount(), qaAccount(id: 2)];
  final submitted = <Tx>[];
  Account? savedAccount;
  Completer<int>? saveGate;
  Object? saveError;
  int saveCalls = 0;
  List<Tx> duplicates = [];

  @override
  Future<List<Account>> accounts(
          {bool includeArchived = false, bool includeDeleted = false}) async =>
      accountRows;
  @override
  Future<List<CurrencyDef>> currencies() async => kDefaultCurrencies;
  @override
  Future<List<Item>> items(
          {String q = '',
          bool includeArchived = false,
          bool includeDeleted = false}) async =>
      [];
  @override
  Future<Map<String, String>> settings() async => {};
  @override
  Future<AppUser?> currentUser() async => null;
  @override
  Future<List<InvoiceLine>> transactionItems(int txId) async => [];
  @override
  Future<List<Tx>> findDuplicates(Tx tx) async => duplicates;
  @override
  Future<int> saveTx(Tx tx, {List<InvoiceLine>? items}) async {
    saveCalls++;
    if (saveError != null) throw saveError!;
    final id = await (saveGate?.future ?? Future.value(tx.id ?? saveCalls));
    submitted.add(tx.copyWith(id: id));
    return id;
  }

  @override
  Future<Tx?> transactionById(int id) async =>
      submitted.where((t) => t.id == id).firstOrNull;
  @override
  Future<int> saveAccount(Account account) async {
    savedAccount = account;
    return account.id ?? 1;
  }
}

Future<void> pumpForm(
  WidgetTester tester,
  UiRepo repo, {
  Size size = const Size(480, 900),
  Widget? form,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
    overrides: [repoProvider.overrideWithValue(repo)],
    child: MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
          body: Consumer(
              builder: (context, ref, _) => Center(
                    child: FilledButton(
                      onPressed: () {
                        if (form != null) {
                          Navigator.of(context).push(
                              MaterialPageRoute<void>(builder: (_) => form));
                        } else {
                          openTxForm(context, ref);
                        }
                      },
                      child: const Text('فتح النموذج'),
                    ),
                  ))),
    ),
  ));
  await tester.tap(find.text('فتح النموذج'));
  await tester.pumpAndSettle();
}

Finder fieldWithLabel(String label) =>
    find.widgetWithText(TextFormField, label);
Finder saveButton() => find.ancestor(
    of: find.text('حفظ العملية'),
    matching: find.byWidgetPredicate((w) => w is FilledButton));
Future<void> enterAmount(WidgetTester tester, String value) async {
  await tester.enterText(fieldWithLabel('المبلغ *'), value);
  await tester.ensureVisible(saveButton());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ar');
    await initializeDateFormatting('en');
    Sfx.setMuted(true);
  });

  testWidgets('QA-SAVE-01 valid amount submits once and closes the real form',
      (tester) async {
    final repo = UiRepo();
    await pumpForm(tester, repo);
    await enterAmount(tester, '٥٠٠');
    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    expect(repo.saveCalls, 1);
    expect(repo.submitted.single.amount, 500);
    expect(repo.submitted.single.accountId, 1);
    expect(find.byType(TxForm), findsNothing);
  });

  testWidgets(
      'QA-SAVE-02 two taps within one frame cannot create duplicate writes',
      (tester) async {
    final repo = UiRepo()..saveGate = Completer<int>();
    await pumpForm(tester, repo);
    await enterAmount(tester, '500');
    await tester.tap(saveButton());
    await tester.tap(saveButton());
    await tester.pump(const Duration(milliseconds: 70));
    final calls = repo.saveCalls;
    repo.saveGate!.complete(41);
    await tester.pumpAndSettle();
    expect(calls, 1,
        reason: 'The guard must be acquired before the first await.');
    expect(repo.submitted, hasLength(1));
  });

  for (final value in ['', '0', '-5', '1.2.3']) {
    testWidgets('QA-SAVE-03 invalid amount "$value" never reaches service',
        (tester) async {
      final repo = UiRepo();
      await pumpForm(tester, repo);
      await enterAmount(tester, value);
      await tester.tap(saveButton());
      await tester.pumpAndSettle();
      expect(repo.saveCalls, 0);
      expect(find.byType(TxForm), findsOneWidget);
      expect(find.text('مبلغ غير صالح'), findsWidgets);
    });
  }

  testWidgets('QA-SAVE-04 database rejection leaves form available to retry',
      (tester) async {
    final repo = UiRepo()..saveError = StateError('QA database rejected write');
    await pumpForm(tester, repo);
    await enterAmount(tester, '500');
    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    expect(find.byType(TxForm), findsOneWidget);
    expect(find.textContaining('QA database rejected write'), findsOneWidget);
    expect(tester.widget<FilledButton>(saveButton()).onPressed, isNotNull);
    expect(repo.submitted, isEmpty);
  });

  testWidgets('QA-SAVE-05 system back cannot dismiss while write is pending',
      (tester) async {
    final repo = UiRepo()..saveGate = Completer<int>();
    await pumpForm(tester, repo);
    await enterAmount(tester, '500');
    await tester.tap(saveButton());
    await tester.pump(const Duration(milliseconds: 70));
    await Navigator.of(tester.element(find.byType(TxForm))).maybePop();
    await tester.pump(const Duration(milliseconds: 400));
    final stayed = find.byType(TxForm).evaluate().isNotEmpty;
    repo.saveGate!.complete(51);
    await tester.pumpAndSettle();
    expect(stayed, isTrue);
  });

  testWidgets(
      'QA-SAVE-06 slow write must not expose retry while original write is running',
      (tester) async {
    final repo = UiRepo()..saveGate = Completer<int>();
    await pumpForm(tester, repo);
    await enterAmount(tester, '500');
    await tester.tap(saveButton());
    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump(const Duration(seconds: 11));
    // Inspect only the form: the route behind it has its own enabled button.
    final retry = find.descendant(
        of: find.byType(TxForm),
        matching: find.byWidgetPredicate((w) => w is FilledButton));
    final enabled = retry
        .evaluate()
        .any((e) => (e.widget as FilledButton).onPressed != null);
    repo.saveGate!.complete(61);
    await tester.pumpAndSettle();
    expect(enabled, isFalse,
        reason: 'timeout does not cancel Future/SQLite commit');
    expect(repo.saveCalls, 1);
  });

  testWidgets('QA-SAVE-07 no notification channel must not claim receipt sent',
      (tester) async {
    final repo = UiRepo();
    await pumpForm(tester, repo);
    await enterAmount(tester, '500');
    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    expect(find.textContaining('وإرسال السند'), findsNothing);
  });

  testWidgets(
      'QA-SAVE-08 empty accounts displays guidance rather than save control',
      (tester) async {
    final repo = UiRepo()..accountRows = [];
    await pumpForm(tester, repo);
    expect(find.text('لا توجد حسابات'), findsOneWidget);
    expect(saveButton(), findsNothing);
    expect(repo.saveCalls, 0);
  });

  testWidgets(
      'QA-ACCOUNT-01 editing a negative opening balance preserves its sign',
      (tester) async {
    final repo = UiRepo();
    final account = qaAccount(opening: -500);
    await pumpForm(tester, repo, form: AccountFormScreen(existing: account));
    final button = find.ancestor(
        of: find.text('حفظ التعديلات'),
        matching: find.byWidgetPredicate((w) => w is FilledButton));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(repo.savedAccount?.openingBalance, -500);
  });

  for (final width in [320.0, 360.0, 480.0]) {
    testWidgets('QA-RTL-01 transaction form fits width $width', (tester) async {
      final repo = UiRepo();
      await pumpForm(tester, repo, size: Size(width, 780));
      expect(Directionality.of(tester.element(find.byType(TxForm))),
          TextDirection.rtl);
      final layoutError = tester.takeException();
      if (layoutError != null) debugDumpRenderTree();
      expect(layoutError, isNull);
      await tester.ensureVisible(saveButton());
      expect(tester.takeException(), isNull);
    });
  }
}
