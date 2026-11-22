import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/sync_queue.dart';
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
    tmp = await Directory.systemTemp.createTemp('phase4_sync_');
    db = await databaseFactory.openDatabase('${tmp.path}/sync_test.db');
    await AppDatabase.createSchema(db);

    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'DEV-PHASE4');
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
        where: 'id = ?', whereArgs: ['DEV-PHASE4']);
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  group('المرحلة 4: المزامنة اللحظية والتعافي الذاتي (SyncEngine & Network Resilience)', () {
    test('1. صمود طابور المزامنة (sync_queue) عند انقطاع الشبكة وإعادة المحاولة',
        () async {
      final queue = SyncQueueOps(db);

      await db.insert('operations', {
        'id': 'op-network-test',
        'device_id': 'DEV-PHASE4',
        'workspace_id': repo.requireWorkspaceId,
        'user_id': 1,
        'entity_type': 'item',
        'entity_id': '10',
        'op_type': 'create',
        'payload': '{}',
        'device_time': nowIso,
        'timestamp': nowIso,
      });

      // إدراج عملية في طابور المزامنة
      final qId = await queue.enqueue('op-network-test');
      expect(qId, isPositive);

      // التحقق من الحالة الابتدائية: معلّقة (pending) و 0 محاولات
      final pendingCount = await queue.countPending();
      expect(pendingCount, equals(1));
      final pending = await queue.pickPending();
      expect(pending.any((r) => r['operation_id'] == 'op-network-test'), isTrue);

      // محاكاة انقطاع الاتصال وفشل الإرسال (Network Drop)
      await queue.markFailed(qId, 'SocketException: Network is unreachable');

      // التحقق الصارم: العملية لا تُحذف ولا تُعتبر فشلاً نهائياً، بل تبقى معلقة بمحاولة مجدولة
      final failedRow = await db.query('sync_queue', where: 'id = ?', whereArgs: [qId]);
      expect(failedRow.first['status'], equals(SyncStatus.pending.name));
      expect(failedRow.first['attempts'], equals(1));
      expect('${failedRow.first['last_error']}', contains('Network is unreachable'));
      expect('${failedRow.first['next_try_at']}', isNotEmpty);

      // محاكاة عودة الشبكة ونجاح الإرسال
      await queue.markSynced(qId);

      // التحقق من اكتمال المزامنة بنجاح
      final syncedRow = await db.query('sync_queue', where: 'id = ?', whereArgs: [qId]);
      expect(syncedRow.first['status'], equals(SyncStatus.synced.name));
      expect(syncedRow.first['last_error'], isEmpty);
    });

  });
}
