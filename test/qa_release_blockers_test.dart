// Acceptance tests for unresolved release blockers. They intentionally remain
// in the normal test suite: a green build must not conceal these failures.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/cloud_firebase_transport.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database a;
  late Database b;
  late Repo repoA;
  late Repo repoB;
  final now = DateTime(2026, 9, 6);
  Account account(String name) => Account(
      name: name,
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now);
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_blocker_');
    Future<Database> open(String name) =>
        databaseFactory.openDatabase('${tmp.path}/$name.db',
            options: OpenDatabaseOptions(
                onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON')));
    a = await open('a');
    b = await open('b');
    await AppDatabase.createSchema(a);
    await AppDatabase.createSchema(b);
    repoA = Repo(databaseProvider: () async => a);
    repoB = Repo(databaseProvider: () async => b);
    // (دفعة 57) هوية الجهاز إلزامية قبل الكتابة.
    await repoA.initSyncInfra();
    await repoB.initSyncInfra();
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await tmp.delete(recursive: true);
  });

  test(
      'QA-BLOCKER-01 independent offline accounts with colliding integer IDs both survive sync',
      () async {
    final idA = await repoA.saveAccount(account('عميل الجهاز أ'));
    await repoB.saveAccount(account('عميل الجهاز ب'));
    final op = SyncOperation(
        id: 'qa-independent-create',
        deviceId: 'DEVICE-A',
        workspaceId: 'default',
        userId: null,
        entityType: EntityKind.account,
        entityId: '$idA',
        opType: OpKind.create,
        version: 1,
        parentOpId: '',
        payload: (await repoA.account(idA))!.toMap(),
        deviceTime: now.toIso8601String(),
        timestamp:
            DateTime.now().add(const Duration(minutes: 1)).toIso8601String());
    await b.transaction(
        (txn) => repoB.applyRemoteOperation(txn, op, ConflictResolver()));
    expect((await repoB.accounts()).map((a) => a.name).toSet(),
        containsAll(['عميل الجهاز أ', 'عميل الجهاز ب']));
  });

  test('QA-BLOCKER-02 incremental transaction sync carries its invoice lines',
      () async {
    final id = await repoA.saveAccount(account('عميل الفاتورة'));
    final txId = await repoA.saveTx(
        Tx(
            accountId: id,
            type: OpType.debit,
            amount: 10,
            date: now,
            createdAt: now,
            updatedAt: now),
        items: [
          const InvoiceLine(name: 'صنف اختباري', quantity: 2, unitPrice: 5),
        ]);
    final ops = await a.query('operations', orderBy: 'timestamp, rowid');
    for (final row in ops) {
      await b.transaction((txn) => repoB.applyRemoteOperation(
          txn, SyncOperation.fromMap(row), ConflictResolver()));
    }
    expect(await repoB.transactions(), hasLength(1));
    expect(await repoB.transactionItems(txId), hasLength(1));
  });

  test(
      'QA-BLOCKER-03 anonymous cash POS payload accepted by UI can save on a real FK-enabled DB',
      () async {
    // Mirrors PosScreen._completeSale: cash + no selected customer sends ID 0.
    await repoA.saveTx(Tx(
        accountId: 0,
        amount: 100,
        type: OpType.revenue,
        description: 'فاتورة مبيعات نقدية',
        date: now,
        createdAt: now,
        updatedAt: now));
    expect(await repoA.transactions(), hasLength(1));
  });

  test(
      'QA-BLOCKER-04 Firebase cursor filters by numeric server_ts '
      '(clock-drift immune), accepts legacy ISO cursor values', () async {
    final ms = now.millisecondsSinceEpoch;
    await a.insert('sync_meta', {'key': 'lastCloudTs:default', 'value': '$ms'});
    Uri? requested;
    final transport = CloudFirebaseTransport.validated(
        repo: repoA,
        dbProvider: () async => a,
        backendUrl: 'https://qa-only.firebaseio.com',
        workspaceId: 'default');
    await http.runWithClient(
        () => transport.pull(),
        () => MockClient((request) async {
              requested = request.url;
              return http.Response('null', 200);
            }));
    // منذ المرحلة 5: الترشيح بختم خادم فيربيس الرقمي حصراً — لا ISO من
    // ساعات الهواتف (overlap ثانيتين كما كان).
    expect(requested!.queryParameters['orderBy'], jsonEncode('server_ts'));
    expect(requested!.queryParameters['startAt'], '${ms - 2000}');

    // التوافق الخلفي: مؤشر قديم بصيغة ISO يُقرأ ويُحوَّل رقمياً.
    final iso = DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();
    await a.update('sync_meta', {'value': iso},
        where: 'key = ?', whereArgs: ['lastCloudTs:default']);
    await http.runWithClient(
        () => transport.pull(),
        () => MockClient((request) async {
              requested = request.url;
              return http.Response('null', 200);
            }));
    expect(requested!.queryParameters['startAt'], '${ms - 2000}',
        reason: 'قيمة ISO قديمة تُفهم وتتحول لملي ثانية');
  });
}
