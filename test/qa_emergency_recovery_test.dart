// 🔒 QA — الاسترداد الطارئ للإدارة (Emergency Ownership Recovery):
// 1) handbackOwnershipToPreviousOwner: المالك الحالي (مستلم تسليم سابق)
//    يعيد الإدارة للمدير السابق بنقرة — عملية سيادية بعلامة handback.
// 2) الاسترداد السيادي للمنشئ: creator_recovery يُقبل على بقية الأجهزة
//    حصراً من الجهاز المطابق لسجل المنشئ الدائم creatorDeviceId.
// 3) الحماية: منتحل بلا سجل منشئ يُرفض؛ وغياب مدير سابق يفشل الإرجاع.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';

void main() {
  // هذه الحزمة تبني فرضياتها على مسار workspaces/default القديم —
  // نثبّت المعرف القديم بدل التوليد العشوائي (المعمارية الصامتة).
  debugForceLegacyWorkspaceId = true;
  late Database db;
  late Directory tmp;

  setUp(() async {
    sqfliteFfiInit();
    tmp = await Directory.systemTemp.createTemp('nexora_emrg_');
    db = await databaseFactoryFfi.openDatabase(p.join(tmp.path, 'e.db'),
        options: OpenDatabaseOptions(
          onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        ));
    await AppDatabase.createSchema(db);
    AppDatabase.overrideForTest(db);
    await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'host'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
    await tmp.delete(recursive: true);
  });

  test(
      'EMRG-01 إرجاع الإدارة للمالك السابق: نقرة واحدة تعيد الملكية '
      'وتبث عملية سيادية بعلامة handback', () async {
    final repo = Repo();
    await repo.initSyncInfra();
    final myId = repo.requireDeviceId;
    final now = DateTime.now().toIso8601String();
    // السيناريو الفعلي: المدير السابق DEV-PREV سلّمنا الإدارة (نحن
    // المالك الآن)، وذاكرة المدير السابق مسجلة من عملية التسليم.
    await db.insert('devices', {
      'id': 'DEV-PREV',
      'workspace_id': 'default',
      'name': 'جهاز المدير الأصلي',
      'platform': 'windows',
      'is_owner': 0,
      'is_paired': 1,
      'auth_secret': '',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert(
        'sync_meta', {'key': 'prevOwnerDeviceId', 'value': 'DEV-PREV'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    expect(await repo.isWorkspaceOwner(), isTrue, reason: 'نحن المالك حالياً');

    final name = await repo.handbackOwnershipToPreviousOwner();
    expect(name, 'جهاز المدير الأصلي');
    // الملكية عادت للمدير السابق فوراً.
    final prev = (await db.query('devices',
            where: 'id = ?', whereArgs: ['DEV-PREV']))
        .first;
    expect(prev['is_owner'], 1, reason: 'owner_device_id عاد للمدير السابق');
    final me = (await db.query('devices',
            where: 'id = ?', whereArgs: [myId]))
        .first;
    expect(me['is_owner'], 0, reason: 'جهازنا صار عضواً');
    // العملية السيادية المبثوثة تحمل handback=true — تُظهر لدى المدير
    // السابق إشعار «لقد تم استلام صلاحية المدير وعادت إليك».
    final ops = await db.query('operations',
        where: "entity_id = 'ownershipTransfer'", orderBy: 'timestamp DESC');
    expect(ops, isNotEmpty);
    final v = jsonDecode(
        '${(jsonDecode('${ops.first['payload']}') as Map)['value']}');
    expect(v['handback'], true);
    expect(v['owner_device_id'], 'DEV-PREV');
  });

  test('EMRG-02 الإرجاع بلا مدير سابق معروف أو من غير المالك: يفشل بوضوح',
      () async {
    final repo = Repo();
    await repo.initSyncInfra();
    // لا ذاكرة prevOwnerDeviceId ولا عمليات نقل سابقة.
    expect(() => repo.handbackOwnershipToPreviousOwner(),
        throwsStateError);
    // ومن جهاز غير مالك: يفشل أيضاً.
    final myId = repo.requireDeviceId;
    await db.update('devices', {'is_owner': 0},
        where: 'id = ?', whereArgs: [myId]);
    expect(() => repo.handbackOwnershipToPreviousOwner(),
        throwsStateError);
  });

  test(
      'EMRG-03 الاسترداد السيادي للمنشئ يُقبل على جهاز ثالث حصراً من '
      'الجهاز المطابق لسجل المنشئ creatorDeviceId', () async {
    // نحن جهاز عضو محايد. المالك الحالي DEV-B، والمنشئ الأصلي DEV-CREATOR.
    final repo = Repo();
    await repo.initSyncInfra();
    final myId = repo.requireDeviceId;
    final now = DateTime.now().toIso8601String();
    await db.update('devices', {'is_owner': 0},
        where: 'id = ?', whereArgs: [myId]);
    for (final (id, owner) in [
      ('DEV-CREATOR', 0),
      ('DEV-B', 1),
      ('DEV-EVIL', 0)
    ]) {
      await db.insert('devices', {
        'id': id,
        'workspace_id': 'default',
        'name': id,
        'platform': 'android',
        'is_owner': owner,
        'is_paired': 1,
        'auth_secret': '',
        'created_at': now,
        'updated_at': now,
      });
    }
    // كاش سجل المنشئ الدائم (يُروى من creator.json السحابية عند الانضمام
    // أو عند الإقلاع).
    await repo.setSetting('creatorDeviceId', 'DEV-CREATOR');

    SyncOperation recoveryOp(String source, String id) => SyncOperation(
          id: id,
          workspaceId: 'default',
          deviceId: source,
          userId: null,
          entityType: EntityKind.setting,
          entityId: 'ownershipTransfer',
          opType: OpKind.settings,
          version: 1,
          parentOpId: '',
          payload: {
            'key': 'ownershipTransfer',
            'value': jsonEncode({
              'owner_device_id': source,
              'owner_user_id': null,
              'previous_owner_device_id': 'DEV-B',
              'creator_recovery': true,
              'at': now,
            }),
          },
          deviceTime: now,
          timestamp: now,
        );

    // منتحل (ليس المنشئ المسجل): استرداده يُرفض والمالك لا يتغير.
    await db.transaction((txn) => repo.applyRemoteOperation(
        txn, recoveryOp('DEV-EVIL', 'OP-CR-EVIL'), ConflictResolver()));
    var b = (await db.query('devices',
            where: 'id = ?', whereArgs: ['DEV-B']))
        .first;
    expect(b['is_owner'], 1, reason: 'انتحال استرداد المنشئ مرفوض');

    // المنشئ الحقيقي: استرداده يُقبل — الملكية تعود إليه فوراً.
    await db.transaction((txn) => repo.applyRemoteOperation(
        txn, recoveryOp('DEV-CREATOR', 'OP-CR-REAL'), ConflictResolver()));
    final creator = (await db.query('devices',
            where: 'id = ?', whereArgs: ['DEV-CREATOR']))
        .first;
    b = (await db.query('devices', where: 'id = ?', whereArgs: ['DEV-B']))
        .first;
    expect(creator['is_owner'], 1,
        reason: 'المنشئ استرد الملكية سيادياً على كل الأجهزة');
    expect(b['is_owner'], 0);
    // العلم الاحتياطي تحدّث أيضاً (توافق أندرويد 7).
    final flag = await db.query('sync_meta',
        where: "key = 'ownerDeviceId'", limit: 1);
    expect('${flag.first['value']}', 'DEV-CREATOR');
  });

  test(
      'EMRG-04 وصول handback لجهاز المدير السابق يقلبه مالكاً من جديد '
      '(نفس المسار السيادي — المصدر هو المالك المعروف)', () async {
    // نحن المدير السابق: سلّمنا الإدارة لـ DEV-B سابقاً ثم أرجعها لنا.
    final repo = Repo();
    await repo.initSyncInfra();
    final myId = repo.requireDeviceId;
    final now = DateTime.now().toIso8601String();
    await db.update('devices', {'is_owner': 0},
        where: 'id = ?', whereArgs: [myId]);
    await db.insert('devices', {
      'id': 'DEV-B',
      'workspace_id': 'default',
      'name': 'المستلم',
      'platform': 'android',
      'is_owner': 1,
      'is_paired': 1,
      'auth_secret': '',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    // عملية الإرجاع كما يبثها DEV-B (المالك الحالي المعروف — مصدر شرعي).
    final op = SyncOperation(
      id: 'OP-HANDBACK-1',
      workspaceId: 'default',
      deviceId: 'DEV-B',
      userId: null,
      entityType: EntityKind.setting,
      entityId: 'ownershipTransfer',
      opType: OpKind.settings,
      version: 1,
      parentOpId: '',
      payload: {
        'key': 'ownershipTransfer',
        'value': jsonEncode({
          'owner_device_id': myId,
          'owner_user_id': null,
          'previous_owner_device_id': 'DEV-B',
          'handback': true,
          'at': now,
        }),
      },
      deviceTime: now,
      timestamp: now,
    );
    final ok = await db.transaction(
        (txn) => repo.applyRemoteOperation(txn, op, ConflictResolver()));
    expect(ok, isTrue);
    expect(await repo.isWorkspaceOwner(), isTrue,
        reason: 'عادت إلينا الإدارة فور وصول عملية الإرجاع');
    expect(await repo.workspaceMode(), 'host',
        reason: 'الوضع صار host — تظهر إدارة المجموعة فوراً');
    final b = (await db.query('devices',
            where: 'id = ?', whereArgs: ['DEV-B']))
        .first;
    expect(b['is_owner'], 0);
  });
}
