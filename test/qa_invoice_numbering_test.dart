// طلب المستخدم: معرّف الفاتورة (id) لا يجب أن يكون متسلسلًا — يكفي أن يكون
// فريدًا عالميًا حتى لا يتصادم بين الأجهزة. أما الرقم المتسلسل فيبقى للعرض
// فقط على صورة العملية / إشعار العميل (حقل reference).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/ids.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  final now = DateTime(2026, 9, 6);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_numbering_');
    db = await databaseFactory.openDatabase('${tmp.path}/a.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra(); // (دفعة 57) هوية الجهاز إلزامية قبل الكتابة.
  });
  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<int> saveSale(String ref) => repo.saveTx(Tx(
        accountId: null,
        type: OpType.revenue,
        amount: 50,
        reference: ref,
        date: now,
        createdAt: now,
        updatedAt: now,
      ));

  test('معرّفات الفواتير فريدة وغير متسلسلة', () async {
    final ids = <int>[];
    for (var i = 0; i < 5; i++) {
      ids.add(await saveSale(''));
    }
    expect(ids.toSet(), hasLength(5), reason: 'كل معرّف يجب أن يكون فريدًا');
    expect(ids.first, greaterThan(1000000),
        reason: 'المعرّف عالمي وليس عدّادًا يبدأ من 1');
    // ليست متسلسلة بفارق 1.
    expect(ids[1] - ids[0], isNot(1));
  });

  test('newGlobalId لا يكرر نفسه حتى في نفس الميلي ثانية', () {
    final ids = List.generate(5000, (_) => newGlobalId());
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('الرقم المعروض على الإيصال يبقى متسلسلًا 1، 2، 3', () async {
    for (var i = 1; i <= 3; i++) {
      expect(await repo.nextTxNumber(), '$i');
    }
  });

  test('العدّاد التسلسلي يستأنف من آخر رقم مرجعي وليس من المعرّف', () async {
    await saveSale('7');
    expect(await repo.nextTxNumber(), '8');
  });

  test('البيع النقدي بدون عميل يُحفظ بحساب فارغ لا بصفر', () async {
    final id = await repo.saveTx(Tx(
      accountId: 0,
      type: OpType.revenue,
      amount: 120,
      description: 'فاتورة مبيعات نقدية',
      date: now,
      createdAt: now,
      updatedAt: now,
    ));
    final rows =
        await db.query('transactions', where: 'id = ?', whereArgs: [id]);
    expect(rows.single['account_id'], isNull);
  });
}
