// انحدار لنقل الملكية: بعد تسليم المدير إدارته لجهاز آخر يجب أن
// 1) يصبح الجهاز المستهدف مالكًا (is_owner=1) وله مستخدم بدور مدير،
// 2) يفقد جهاز المدير السابق صلاحية المدير (يصبح عضوًا)،
// 3) لا يفقد الجهاز المستهدف صلاحيته (الخلل القديم: العكس).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
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
    tmp = await Directory.systemTemp.createTemp('nexora_own_');
    db = await databaseFactoryFfi.openDatabase(p.join(tmp.path, 'own.db'),
        options: OpenDatabaseOptions(
          onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        ));
    await AppDatabase.createSchema(db);
    AppDatabase.overrideForTest(db);
    // وضع مستقل يملكه الجهاز A.
    await db.insert('sync_meta',
        {'key': 'workspaceMode', 'value': 'host'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
    await tmp.delete(recursive: true);
  });

  test('نقل الملكية يجعل الجهاز B مديرًا فعليًا و A عضوًا', () async {
    final repoA = Repo();
    await repoA.initSyncInfra();
    final idA = repoA.requireDeviceId;

    // جهاز B مقترن كعضو بلا مستخدم/صلاحيات.
    final now = DateTime.now().toIso8601String();
    await db.insert('devices', {
      'id': 'DEV-B',
      'workspace_id': 'default',
      'name': 'جهاز ب',
      'platform': 'android',
      'is_owner': 0,
      'is_paired': 1,
      'auth_secret': 'secret-b',
      'created_at': now,
      'updated_at': now,
    });

    // A ينقل الملكية لـ B.
    await repoA.transferOwnership('DEV-B');

    // B صار مالكًا.
    final bdev = (await db.query('devices',
        where: 'id = ?', whereArgs: ['DEV-B'])).first;
    expect(bdev['is_owner'], 1);
    expect(bdev['user_id'], isNotNull);

    // A لم يعد مالكًا.
    final adev = (await db.query('devices',
        where: 'id = ?', whereArgs: [idA])).first;
    expect(adev['is_owner'], 0);

    // المستخدم المرتبط بـ B مدير وله صلاحيات كاملة.
    final buid = bdev['user_id'] as int;
    final buser = AppUser.fromMap(
        (await db.query('users', where: 'id = ?', whereArgs: [buid])).first);
    expect(buser.role, UserRole.admin);
    expect(buser.can('manage_users'), isTrue);
    expect(buser.can('add_tx'), isTrue);
  });

  test(
      'وصول عملية ownershipTransfer لجهاز العضو المستلم يقلبه مالكاً '
      'فوراً (is_owner=1 + host + دور admin) بلا إعادة تشغيل', () async {
    // جهاز B (نحن) عضو عادي في مجموعة يملكها DEV-A البعيد.
    final repoB = Repo();
    await repoB.initSyncInfra();
    final idB = repoB.requireDeviceId;
    final now = DateTime.now().toIso8601String();
    // اجعل جهازنا عضواً غير مالك، وأدخل جهاز المدير البعيد كمالك.
    await db.update('devices', {'is_owner': 0}, where: 'id = ?',
        whereArgs: [idB]);
    await db.insert('devices', {
      'id': 'DEV-A',
      'workspace_id': 'default',
      'name': 'جهاز المدير',
      'platform': 'android',
      'is_owner': 1,
      'is_paired': 1,
      'auth_secret': '',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    // مستخدمنا المعيّن: عارض بلا صلاحيات.
    const uid = 777001;
    await db.insert('users', {
      'id': uid,
      'name': 'عضو',
      'role': 'viewer',
      'pin': '',
      'password': '',
      'permissions': '',
      'is_me': 0,
      'active': 1,
      'workspace_id': 'default',
      'deleted_at': '',
      'created_at': now,
      'updated_at': now,
    });
    await db.update('devices', {'user_id': uid}, where: 'id = ?',
        whereArgs: [idB]);
    expect(await repoB.isWorkspaceOwner(), isFalse, reason: 'عضو قبل النقل');

    // العملية السيادية كما يبثها المدير السابق DEV-A عبر السحابة.
    final op = SyncOperation(
      id: 'OP-HANDOVER-1',
      workspaceId: 'default',
      deviceId: 'DEV-A',
      userId: null,
      entityType: EntityKind.setting,
      entityId: 'ownershipTransfer',
      opType: OpKind.settings,
      version: 1,
      parentOpId: '',
      payload: {
        'key': 'ownershipTransfer',
        'value': jsonEncode({
          'owner_device_id': idB,
          'owner_user_id': uid,
          'previous_owner_device_id': 'DEV-A',
          'at': now,
        }),
      },
      deviceTime: now,
      timestamp: now,
    );
    final ok = await db.transaction(
        (txn) => repoB.applyRemoteOperation(txn, op, ConflictResolver()));
    expect(ok, isTrue);

    // 1) نحن المالك الآن — الواجهة سترى isOwnerProvider=true فوراً.
    expect(await repoB.isWorkspaceOwner(), isTrue,
        reason: 'المستلم يصبح مالكاً لحظة تطبيق العملية');
    // 2) الوضع صار host — تظهر إدارة المجموعة وشاشات الأجهزة.
    expect(await repoB.workspaceMode(), 'host');
    // 3) المدير السابق فقد الملكية محلياً.
    final aRow = (await db.query('devices',
        where: 'id = ?', whereArgs: ['DEV-A'])).first;
    expect(aRow['is_owner'], 0);
    // 4) مستخدمنا رُقّي لمدير كامل الصلاحيات.
    final me = AppUser.fromMap(
        (await db.query('users', where: 'id = ?', whereArgs: [uid])).first);
    expect(me.role, UserRole.admin);
    expect(me.can('manage_users'), isTrue);
    // 5) currentUser يعكس المدير — كل بوابات _ensureCan تفتح.
    final cur = await repoB.currentUser();
    expect(cur, isNotNull);
    expect(cur!.role, UserRole.admin);
  });

  test('جهاز عضو لا يستطيع تزوير ownershipTransfer لصالح نفسه', () async {
    final repoB = Repo();
    await repoB.initSyncInfra();
    final idB = repoB.requireDeviceId;
    final now = DateTime.now().toIso8601String();
    await db.update('devices', {'is_owner': 0}, where: 'id = ?',
        whereArgs: [idB]);
    await db.insert('devices', {
      'id': 'DEV-A',
      'workspace_id': 'default',
      'name': 'المدير',
      'platform': 'android',
      'is_owner': 1,
      'is_paired': 1,
      'auth_secret': '',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('devices', {
      'id': 'DEV-EVIL',
      'workspace_id': 'default',
      'name': 'عضو مخادع',
      'platform': 'android',
      'is_owner': 0,
      'is_paired': 1,
      'auth_secret': '',
      'created_at': now,
      'updated_at': now,
    });
    // عملية نقل مزوّرة مصدرها عضو (ليس المالك المعروف محلياً).
    final op = SyncOperation(
      id: 'OP-HANDOVER-FORGED',
      workspaceId: 'default',
      deviceId: 'DEV-EVIL',
      userId: null,
      entityType: EntityKind.setting,
      entityId: 'ownershipTransfer',
      opType: OpKind.settings,
      version: 1,
      parentOpId: '',
      payload: {
        'key': 'ownershipTransfer',
        'value': jsonEncode({
          'owner_device_id': 'DEV-EVIL',
          'owner_user_id': null,
        }),
      },
      deviceTime: now,
      timestamp: now,
    );
    await db.transaction(
        (txn) => repoB.applyRemoteOperation(txn, op, ConflictResolver()));
    // المالك الشرعي لم يتغير.
    final aRow = (await db.query('devices',
        where: 'id = ?', whereArgs: ['DEV-A'])).first;
    expect(aRow['is_owner'], 1, reason: 'التزوير يُرفض — المصدر ليس المالك');
    final evil = (await db.query('devices',
        where: 'id = ?', whereArgs: ['DEV-EVIL'])).first;
    expect(evil['is_owner'], 0);
  });
}
