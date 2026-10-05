// QA — إلغاء (حذف) عمليات من طابور المزامنة:
// - cancelRows يعلّم الصفوف cancelled فتختفي من activeRows/pickPending/العدادات.
// - الصف الملغى لا يعود للطابور عبر إنقاذ العمليات (INSERT OR IGNORE).
// - الصفوف المكتملة (synced) لا تُلغى.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/sync/sync_queue.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late SyncQueueOps q;
  final now = DateTime(2026, 9, 9).toIso8601String();

  Future<void> insertOp(String id) async {
    await db.insert('operations', {
      'id': id,
      'workspace_id': 'default',
      'device_id': 'DEV-A',
      'entity_type': 'account',
      'entity_id': '1',
      'op_type': 'create',
      'payload': '{}',
      'version': 1,
      'parent_op_id': '',
      'timestamp': now,
      'device_time': now,
      'synced': 0,
    });
  }

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchema(db);
    q = SyncQueueOps(db);
    await insertOp('OP-1');
    await insertOp('OP-2');
    await insertOp('OP-3');
  });

  tearDown(() async => db.close());

  test('QA-CANCEL-01 cancelled rows leave active lists and counters',
      () async {
    final id1 = await q.enqueue('OP-1', target: 'lan');
    final id2 = await q.enqueue('OP-2', target: 'lan');
    await q.markFailed(id2, 'network down'); // فاشلة (pending مع خطأ)
    expect(await q.activeRows(), hasLength(2));
    expect(await q.countPending(), 2);
    expect(await q.countWithError(), 1);

    // إلغاء الاثنتين: المنتظرة والفاشلة.
    final n = await q.cancelRows([id1, id2]);
    expect(n, 2);
    expect(await q.activeRows(), isEmpty);
    expect(await q.countPending(), 0);
    expect(await q.countWithError(), 0);
    expect(await q.pickPending(target: 'lan'), isEmpty);
  });

  test('QA-CANCEL-02 synced rows cannot be cancelled', () async {
    final id = await q.enqueue('OP-3', target: 'lan');
    await db.update('sync_queue', {'status': 'synced'},
        where: 'id = ?', whereArgs: [id]);
    expect(await q.cancelRows([id]), 0);
    final row = await db
        .query('sync_queue', where: 'id = ?', whereArgs: [id], limit: 1);
    expect(row.single['status'], 'synced');
  });

  test('QA-CANCEL-03 backfill INSERT OR IGNORE cannot resurrect a cancelled row',
      () async {
    final id = await q.enqueue('OP-1', target: 'lan');
    await q.cancelRows([id]);
    // نفس منطق الإنقاذ في SyncEngine._backfillMissedLanOps.
    await db.rawInsert('''
      INSERT OR IGNORE INTO sync_queue
        (operation_id, status, target, attempts, last_error, next_try_at,
         created_at, updated_at)
      SELECT o.id, 'pending', 'lan', 0, '', '', ?, ?
      FROM operations o
      WHERE o.device_id = 'DEV-A'
        AND NOT EXISTS (
          SELECT 1 FROM sync_queue q
          WHERE q.operation_id = o.id AND q.target = 'lan'
        )
    ''', [now, now]);
    final rows = await db.query('sync_queue',
        where: "operation_id = 'OP-1' AND target = 'lan'");
    expect(rows, hasLength(1), reason: 'UNIQUE يمنع صفاً ثانياً');
    expect(rows.single['status'], 'cancelled');
    // retryNow الجماعية لا تمس الصف الملغى.
    await q.retryNow();
    final after = await db.query('sync_queue',
        where: "operation_id = 'OP-1' AND target = 'lan'");
    expect(after.single['status'], 'cancelled');
  });
}
