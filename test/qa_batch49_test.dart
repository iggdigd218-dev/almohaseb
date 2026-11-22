// QA — دفعة 49: بانر الخطر القابل للحل + دقة حساب التباين:
// - triggerImmediateSync يصفّر backoff ويدفع المعلّق ويعيد فحص الخطر فوراً.
// - نجاح الدفع يبثّ null عبر onSyncDanger (إخفاء تلقائي للبانر).
// - حساب التباين: عمليات مميّزة لا صفوف طابور (lan+cloud لا يضاعف العدد)،
//   والكيانات الصامتة (رسائل الدردشة) مستبعدة.
// - resumeBackoff يصفّر next_try_at فيدفع فور عودة الاتصال.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:nexora_app/data/sync/sync_queue.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late Repo repo;
  late SyncEngine engine;
  final dangerLog = <String?>[];

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    engine = SyncEngine(repo: repo, dbProvider: () async => db);
    dangerLog.clear();
    SyncEngine.onSyncDanger = dangerLog.add;
    await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  });

  tearDown(() async {
    SyncEngine.onSyncDanger = null;
    engine.stop();
    await db.close();
  });

  Future<void> seedOp(
    String opId, {
    required Duration age,
    String entityType = 'tx',
    List<String> targets = const ['lan'],
    String status = 'failed',
    int attempts = 9,
  }) async {
    final t = DateTime.now().subtract(age).toIso8601String();
    await db.insert('operations', {
      'id': opId,
      'workspace_id': 'default',
      'device_id': 'DEV-A',
      'entity_type': entityType,
      'entity_id': '1',
      'op_type': 'create',
      'payload': '{}',
      'version': 1,
      'parent_op_id': '',
      'timestamp': t,
      'device_time': t,
      'synced': 0,
    });
    for (final target in targets) {
      await db.insert('sync_queue', {
        'operation_id': opId,
        'status': status,
        'target': target,
        'attempts': attempts,
        'last_error': 'peer unreachable',
        'next_try_at': DateTime.now()
            .add(const Duration(minutes: 2))
            .toIso8601String(),
        'created_at': t,
        'updated_at': t,
      });
    }
  }

  group('دقة حساب التباين في نافذة الخطر', () {
    test('عملية واحدة بهدفين lan+cloud تُحسب مرة واحدة لا مرتين', () async {
      await seedOp('OP-1',
          age: const Duration(hours: 1), targets: ['lan', 'cloud']);
      await engine.debugCheckDangerState();
      final msg = dangerLog.whereType<String>().first;
      expect(msg, contains('1 عملية'));
      expect(msg, isNot(contains('2 عملية')));
    });

    test('رسائل الدردشة الصامتة لا تُفجّر الخطر إطلاقاً', () async {
      await seedOp('OP-MSG',
          age: const Duration(hours: 2), entityType: 'message');
      await seedOp('OP-CONV',
          age: const Duration(hours: 2), entityType: 'conversation');
      await engine.debugCheckDangerState();
      expect(dangerLog.whereType<String>(), isEmpty,
          reason: 'الكيانات الصامتة ليست خطراً مالياً');
    });

    test('عمر العالقة يُقرأ حياً من القاعدة: زوال القديمة يُخفي البانر',
        () async {
      await seedOp('OP-OLD', age: const Duration(hours: 1));
      await engine.debugCheckDangerState();
      expect(dangerLog.whereType<String>(), isNotEmpty);
      // عولجت القديمة (synced) وبقيت واحدة حديثة فقط.
      await db.update('sync_queue', {'status': 'synced'},
          where: "operation_id = 'OP-OLD'");
      await seedOp('OP-NEW', age: const Duration(seconds: 10), attempts: 0);
      dangerLog.clear();
      await engine.debugCheckDangerState();
      expect(dangerLog, contains(null),
          reason: 'دون العتبة — يجب بث null لإخفاء البانر');
    });
  });

  group('triggerImmediateSync — الحل المباشر من البانر', () {
    test('يصفّر backoff والمحاولات لكل الصفوف غير المكتملة', () async {
      await seedOp('OP-STUCK', age: const Duration(hours: 1));
      await engine.triggerImmediateSync();
      final rows = await db.query('sync_queue',
          where: "operation_id = 'OP-STUCK'");
      for (final r in rows) {
        expect(r['status'], 'pending');
        expect(r['attempts'], 0);
        expect(r['next_try_at'], '');
      }
    });

    test('نجاح التفريغ يبثّ null فيختفي البانر تلقائياً', () async {
      await seedOp('OP-STUCK', age: const Duration(hours: 1));
      await engine.debugCheckDangerState();
      expect(dangerLog.whereType<String>(), isNotEmpty);
      // محاكاة نجاح الدفع: الطابور فرغ.
      await db.update('sync_queue', {'status': 'synced'});
      dangerLog.clear();
      await engine.triggerImmediateSync();
      expect(dangerLog, contains(null),
          reason: 'triggerImmediateSync يعيد الفحص فوراً بعد الدفع');
    });
  });

  group('resumeBackoff — التدفق التلقائي عند عودة الاتصال', () {
    test('يصفّر next_try_at دون المساس بعدد المحاولات', () async {
      await seedOp('OP-WAIT', age: const Duration(minutes: 5),
          status: 'pending', attempts: 3);
      final q = SyncQueueOps(db);
      await q.resumeBackoff();
      final r = (await db.query('sync_queue',
              where: "operation_id = 'OP-WAIT'"))
          .first;
      expect(r['next_try_at'], '');
      expect(r['attempts'], 3, reason: 'التاريخ يبقى لأغراض التشخيص');
    });

    test('بعد التصفير يلتقطها pickPending فوراً', () async {
      await seedOp('OP-WAIT', age: const Duration(minutes: 5),
          status: 'pending');
      final q = SyncQueueOps(db);
      expect(await q.pickPending(target: 'lan'), isEmpty,
          reason: 'next_try_at في المستقبل — محتجزة');
      await q.resumeBackoff();
      expect((await q.pickPending(target: 'lan')).length, 1,
          reason: 'التصفير يجعلها قابلة للدفع في الدورة الفورية');
    });
  });
}
