import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  final now = DateTime.now();
  final nowIso = now.toIso8601String();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('phase3_acc_');
    db = await databaseFactory.openDatabase('${tmp.path}/acc_test.db');
    await AppDatabase.createSchema(db);

    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'DEV-PHASE3');
    await repo.initSyncInfra();

    // Setup Admin user
    await db.insert('users', {
      'id': 1,
      'name': 'المدير العام',
      'role': 'admin',
      'permissions': '',
      'is_me': 1,
      'active': 1,
      'created_at': nowIso,
      'updated_at': nowIso,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await db.update('devices', {'user_id': 1, 'is_owner': 1},
        where: 'id = ?', whereArgs: ['DEV-PHASE3']);
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  group('المرحلة 3: النواة المحاسبية والمبيعات والذرّية (POS & Accounting Engine)', () {
    test('1. الذرّية والتراجع الكامل (Atomic Transactions & Rollback)', () async {
      // حفظ العملية المالية وطابور المزامنة معاً
      final tx = Tx(
        type: OpType.revenue,
        amount: 1400,
        currency: 'YER',
        date: now,
        description: 'عملية نقدية رقم 1',
        createdAt: now,
        updatedAt: now,
      );

      final txId = await repo.saveTx(tx);
      expect(txId, isPositive);

      final txRows = await db.query('transactions', where: 'id = ?', whereArgs: [txId]);
      expect(txRows, hasLength(1));

      final opRows = await db.query('operations',
          where: "entity_type = 'tx' AND entity_id = ?", whereArgs: ['$txId']);
      expect(opRows, hasLength(1));

      // محاكاة فشل في معاملة ذرية للتحقق من عدم بقاء أي سجلات يتيمة
      try {
        await db.transaction((txn) async {
          await txn.insert('transactions', {
            'id': 999999,
            'type': 'revenue',
            'amount': 500,
            'currency': 'YER',
            'date': nowIso,
            'created_at': nowIso,
            'updated_at': nowIso,
          });
          // نرمي خطأ عمداً لمحاكاة تعطل خطوة فرعية
          throw Exception('Simulated crash during atomic transaction');
        });
      } catch (_) {}

      // التحقق من تراجع المعاملة بالكامل (Rollback) وعدم وجود سجل 999999
      final rolledBack = await db.query('transactions', where: 'id = ?', whereArgs: [999999]);
      expect(rolledBack, isEmpty, reason: 'يجب التراجع الكامل عند فشل أي خطوة فرعية');
    });


// (دفتر الحسابات الخالص 2026-11-02) حُذف اختبار «3. قيود الكاشير:
    // حظر حذف الفواتير بدون إذن/صلاحية المشرف» — بوابات الصلاحيات (RBAC)
    // اجتُثت بأمر المالك: المالك يملك كل شيء وdeleteTx لم يعد يرفض StateError.
  });
}
