// اختبارات دفعة 18: دردشة المجموعة، مزامنة الفئات، إنقاذ العمليات القديمة.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/recorder.dart';
import 'package:nexora_app/data/sync/device_id.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:nexora_app/data/sync/sync_queue.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/cloud_config.dart';

void main() {
  // هذه الحزمة تحاكي سيناريوهات «لا سحابة» — نلغي الرابط الافتراضي
  // المضمن (Zero-Config) حتى تبقى فرضياتها صالحة.
  debugDefaultBackendUrlOverride = '';
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_chat_qa_');
    db = await databaseFactory.openDatabase('${tmp.path}/qa.db',
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ));
    await AppDatabase.createSchema(db);
    AppDatabase.overrideForTest(db);
    repo = Repo();
    await repo.initSyncInfra(); // (دفعة 57) هوية الجهاز إلزامية قبل الكتابة.
    SyncRecorder.onOperationRecorded = null;
    await repo.settings(); // يهيئ deviceId/workspaceId الداخلية.
    await db.delete('sync_queue');
    await db.delete('operations');
  });
  tearDown(() async {
    SyncRecorder.onOperationRecorded = null;
    if (db.isOpen) await db.close();
    await tmp.delete(recursive: true);
  });

  test('QA-CHAT-01 sendGroupMessage يخزن الرسالة ويولّد عملية مزامنة',
      () async {
    // (دفعة 58) الناقل الوحيد سحابي.
    await repo.setSetting('cloudBackendUrl', 'https://qa.firebaseio.com');
    final id = await repo.sendGroupMessage('مرحباً يا مدير');
    final msgs = await repo.groupMessages();
    expect(msgs, hasLength(1));
    expect(msgs.single.body, 'مرحباً يا مدير');
    // عملية message في سجل العمليات + صف cloud في الطابور.
    final ops = await db.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: ['message', '$id']);
    expect(ops, hasLength(1));
    final q = await db.rawQuery(
        "SELECT q.* FROM sync_queue q JOIN operations o "
        "ON o.id = q.operation_id "
        "WHERE q.target = 'cloud' AND o.entity_id = ?",
        ['$id']);
    expect(q, hasLength(1));
    expect(q.single['status'], 'pending');
  });

  test('QA-CHAT-03 رسائل الدردشة صامتة: خارج العدادات والقوائم لكنها تُزامن',
      () async {
    await repo.setSetting('cloudBackendUrl', 'https://qa.firebaseio.com');
    await repo.sendGroupMessage('رسالة صامتة');
    final ops = SyncQueueOps(db);
    // العدادات والقوائم المرئية تتجاهل رسائل الدردشة تماماً.
    expect(await ops.countPending(), 0);
    expect(await ops.activeRows(), isEmpty);
    expect(await ops.countWithError(), 0);
    // لكن صف الطابور موجود فعلاً وسيُدفع للمزامنة كالمعتاد.
    final raw = await db.rawQuery(
        "SELECT COUNT(*) c FROM sync_queue WHERE status = 'pending'");
    expect(raw.first['c'], greaterThan(0));
    final picked = await ops.pickPending(limit: 10, target: 'cloud');
    expect(picked, isNotEmpty);
  });

  test('QA-CHAT-02 تطبيق رسالة واردة ينشئ المحادثة تلقائياً (FK آمن)',
      () async {
    // جهاز آخر يرسل رسالة قبل أن تكون لدينا محادثة المجموعة أصلاً.
    expect(
        await db.query('conversations',
            where: 'id = ?', whereArgs: [Repo.groupConversationId]),
        isEmpty);
    final op = SyncOperation(
      id: 'DEVICE-REMOTE1-1',
      workspaceId: defaultWorkspaceId,
      deviceId: 'DEVICE-REMOTE1',
      userId: null,
      entityType: EntityKind.message,
      entityId: '424242',
      opType: OpKind.create,
      version: 1,
      parentOpId: '',
      payload: {
        'id': 424242,
        'conversation_id': Repo.groupConversationId,
        'workspace_id': defaultWorkspaceId,
        'sender': 'DEVICE-REMOTE1',
        'body': 'رسالة من جهاز عضو',
        'kind': 'text',
        'payload': '',
        'created_at': DateTime.now().toIso8601String(),
        'conv_title': 'دردشة المجموعة',
      },
      deviceTime: DateTime.now().toIso8601String(),
      timestamp: DateTime.now().toIso8601String(),
    );
    final resolver = ConflictResolver();
    final ok = await db.transaction(
        (txn) => repo.applyRemoteOperation(txn, op, resolver));
    expect(ok, isTrue);
    final conv = await db.query('conversations',
        where: 'id = ?', whereArgs: [Repo.groupConversationId]);
    expect(conv, hasLength(1), reason: 'المحادثة تُنشأ تلقائياً من الحمولة');
    final msgs = await repo.groupMessages();
    expect(msgs.single.sender, 'DEVICE-REMOTE1');
  });

  test('QA-CAT-01 إضافة فئة تولّد عملية مزامنة category', () async {
    await repo.setSetting('cloudBackendUrl', 'https://qa.firebaseio.com');
    await repo.addCategory('مشروبات');
    final ops =
        await db.query('operations', where: "entity_type = 'category'");
    expect(ops, hasLength(1));
    final q = await db.query('sync_queue', where: 'target = ?',
        whereArgs: ['cloud']);
    expect(q, isNotEmpty);
  });

  test('QA-BACKFILL-01 عمليات قديمة بلا صف cloud تُدرج عند الإقلاع', () async {
    final ourId = await ensureDeviceId(repo);
    await repo.setSetting('cloudBackendUrl', 'https://qa.firebaseio.com');
    // (2026-09-22) المزامنة السحابية عبر جوجل فقط — بريد مربوط للمدير.
    await repo.setSetting('account.email', 'boss@nexora.test');
    // قرين نشط (بعد ضمان صف مساحة العمل ليتحقق قيد FK).
    await db.insert(
        'workspaces',
        {
          'id': defaultWorkspaceId,
          'name': 'default',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert('devices', {
      'id': 'DEVICE-PEER0001',
      'workspace_id': defaultWorkspaceId,
      'name': 'جهاز قرين',
      'is_paired': 1,
      'is_owner': 0,
      'auth_secret': 's',
      'revoked_at': '',
      'expelled_at': '',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    // عملية قديمة (سُجلت قبل تفعيل LAN) بلا أي صف في الطابور.
    final now = DateTime.now().toIso8601String();
    await db.insert('operations', {
      'id': '$ourId-777',
      'workspace_id': defaultWorkspaceId,
      'device_id': ourId,
      'user_id': null,
      'entity_type': 'transaction',
      'entity_id': '777',
      'op_type': 'create',
      'version': 1,
      'parent_op_id': null,
      'payload': '{}',
      'device_time': now,
      'timestamp': now,
      'synced': 0,
    });
    expect(await db.query('sync_queue'), isEmpty);
    final engine = SyncEngine(repo: repo, dbProvider: () async => db);
    await engine.start();
    engine.stop();
    final q = await db.query('sync_queue',
        where: "target = 'cloud' AND status = 'pending'");
    expect(q.map((r) => r['operation_id']), contains('$ourId-777'),
        reason: 'الإنقاذ عند الإقلاع يعيد إدراج العمليات المنسية');
  });

  test('QA-RECORDER-01 (دفعة 58) وضع member بلا سحابة: لا هدف lan إطلاقاً',
      () async {
    await db.insert(
        'sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await repo.sendGroupMessage('رسالة عضو');
    final q = await db.query('sync_queue', where: "target = 'lan'");
    expect(q, isEmpty,
        reason: 'LAN اجتُث نهائياً — لا هدف lan في الطابور بعد اليوم');
  });

  test('QA-CLOUD-01 لا صفوف cloud بلا خادم سحابي مهيأ', () async {
    await repo.sendGroupMessage('بدون سحابة');
    final cloud = await db.query('sync_queue', where: "target = 'cloud'");
    expect(cloud, isEmpty,
        reason: 'إدراج cloud بلا خادم كان يترك مزامنات عالقة للأبد');
  });
}
