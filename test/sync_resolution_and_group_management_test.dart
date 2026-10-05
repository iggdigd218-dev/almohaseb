import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/sync_diagnostics.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  final nowIso = DateTime.now().toIso8601String();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sync_res_test_');
    db = await databaseFactory.openDatabase('${tmp.path}/test.db');
    await AppDatabase.createSchema(db);

    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'DEV-MAIN');
    await repo.initSyncInfra();

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
        where: 'id = ?', whereArgs: ['DEV-MAIN']);
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  group('اختبارات حل تعثر المزامنة وحذف العمليات المتعارضة', () {
    test('1. جلب العمليات العالقة غير المتزامنة مع تفاصيلها وأسبابها', () async {
      // إدراج عملية في operations وطابور المزامنة sync_queue مع خطأ
      await db.insert('operations', {
        'id': 'op-001',
        'device_id': 'DEV-MAIN',
        'workspace_id': 'ws-main',
        'entity_type': 'account',
        'entity_id': '101',
        'op_type': 'create',
        'payload': '{"name":"عميل تجريبي"}',
        'device_time': nowIso,
        'timestamp': '1000',
      });

      await db.insert('sync_queue', {
        'operation_id': 'op-001',
        'target': 'cloud',
        'status': 'failed',
        'attempts': 3,
        'last_error': 'UNIQUE constraint failed: accounts.name',
        'created_at': nowIso,
        'updated_at': nowIso,
      });

      final ops = await repo.getUnsyncedOperationsWithDetails();
      expect(ops.length, equals(1));
      expect(ops.first['operation_id'], equals('op-001'));
      expect(ops.first['entity_type'], equals('account'));
      expect(ops.first['status'], equals('failed'));
      expect(ops.first['last_error'], contains('UNIQUE constraint failed'));
    });

    test('2. حذف وفك العمليات المتعارضة يلغي الطابور العالق ويصفّر التشخيص', () async {
      await db.insert('operations', {
        'id': 'op-002',
        'device_id': 'DEV-MAIN',
        'workspace_id': 'ws-main',
        'entity_type': 'tx',
        'entity_id': '501',
        'op_type': 'create',
        'payload': '{"total":5000}',
        'device_time': nowIso,
        'timestamp': '1001',
      });

      await db.insert('sync_queue', {
        'operation_id': 'op-002',
        'target': 'cloud',
        'status': 'failed',
        'attempts': 5,
        'last_error': 'SocketException: Network is unreachable',
        'created_at': nowIso,
        'updated_at': nowIso,
      });

      // وسم التشخيص بوجود خطأ
      SyncDiagnostics.instance.setCatalogMismatch(true);

      // تنفيذ حذف العمليات المتعارضة
      final cancelled = await repo.cancelConflictingOperations();
      expect(cancelled, equals(1));

      // التأكد من إلغاء الصف في sync_queue
      final rows = await db.query('sync_queue',
          where: 'operation_id = ?', whereArgs: ['op-002']);
      expect(rows.first['status'], equals('cancelled'));

      // التأكد من تصفير التشخيص
      final diag = SyncDiagnostics.instance.snapshot;
      expect(diag.catalogMismatch, isFalse);
      expect(diag.failedCount, equals(0));
    });

    test('3. التحقق من وجود المستخدمين والأجهزة في قاعدة البيانات للشاشة الموحدة', () async {
      // إدراج مستخدم إضافي (كاشير)
      await db.insert('users', {
        'id': 2,
        'name': 'كاشير الصباح',
        'role': 'cashier',
        'permissions': '',
        'is_me': 0,
        'active': 1,
        'created_at': nowIso,
        'updated_at': nowIso,
      });

      final users = await repo.users();
      expect(users.length, equals(2));
      expect(users.any((u) => u.name == 'كاشير الصباح'), isTrue);

      final devices = await repo.devices();
      expect(devices.isNotEmpty, isTrue);
    });
  });
}
