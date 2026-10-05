// QA — دفعة 25 (مُحدَّثة في دفعة 58 بعد اجتثاث LAN):
// 1) سلة المهملات متزامنة: الحذف الوارد يُنشئ صف سلة، والاسترجاع يزيله.
// 2) النسخ الاحتياطية موسومة ببصمة المجموعة ولا تُستورد نسخة غريبة.
// 3) النسخ المحلي متاح بلا صلاحية تصدير، والتصدير الخارجي يُرفض.
// (اختبارات عضو↔عضو عبر LAN حُذفت — الناقل الوحيد اليوم سحابي، ومساره
//  مغطى في qa_cloud_pull_test/qa_batch50_test/qa_group_chat_sync_test.)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database o; // owner (المدير)
  late Database a; // member A
  late Database b; // member B
  late Repo repoO;
  late Repo repoA;
  late Repo repoB;
  const oId = 'DEVICE-QAOWNER0';
  const aId = 'DEVICE-QAMEMBRA';
  const bId = 'DEVICE-QAMEMBRB';
  const oSecret = 'qa-owner-secret';
  const aSecret = 'qa-memberA-secret';
  const bSecret = 'qa-memberB-secret';
  final now = DateTime(2026, 9, 8);

  Future<void> insertDevice(
    Database db,
    String id,
    String secret, {
    bool owner = false,
    int? userId,
  }) async {
    await db.insert(
        'devices',
        {
          'id': id,
          'workspace_id': 'default',
          'name': id.substring(id.length - 1),
          'auth_secret': secret,
          'is_paired': 1,
          'is_owner': owner ? 1 : 0,
          'user_id': userId,
          'created_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_member_');
    o = await databaseFactory.openDatabase('${tmp.path}/o.db');
    a = await databaseFactory.openDatabase('${tmp.path}/a.db');
    b = await databaseFactory.openDatabase('${tmp.path}/b.db');
    for (final db in [o, a, b]) {
      await AppDatabase.createSchema(db);
    }
    repoO = Repo(databaseProvider: () async => o);
    repoA = Repo(databaseProvider: () async => a);
    repoB = Repo(databaseProvider: () async => b);
    await repoO.setSetting('sync.deviceId', oId);
    await repoA.setSetting('sync.deviceId', aId);
    await repoB.setSetting('sync.deviceId', bId);
    await repoO.initSyncInfra();
    await repoA.initSyncInfra();
    await repoB.initSyncInfra();
    await o.update('devices', {'auth_secret': oSecret, 'is_owner': 1},
        where: 'id = ?', whereArgs: [oId]);
    await a.update('devices', {'auth_secret': aSecret, 'is_owner': 0},
        where: 'id = ?', whereArgs: [aId]);
    await b.update('devices', {'auth_secret': bSecret, 'is_owner': 0},
        where: 'id = ?', whereArgs: [bId]);
    for (final db in [o, a, b]) {
      await db.insert(
          'users',
          {
            'id': 1,
            'name': 'QA',
            'role': 'admin',
            'permissions': '',
            'is_me': 1,
            'active': 1,
            'created_at': now.toIso8601String(),
            'updated_at': now.toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await o.update('devices', {'user_id': 1}, where: 'id = ?', whereArgs: [oId]);
    await a.update('devices', {'user_id': 1}, where: 'id = ?', whereArgs: [aId]);
    await b.update('devices', {'user_id': 1}, where: 'id = ?', whereArgs: [bId]);
    await insertDevice(o, aId, aSecret, userId: 1);
    await insertDevice(o, bId, bSecret, userId: 1);
    await insertDevice(a, oId, oSecret, owner: true, userId: 1);
    await insertDevice(a, bId, bSecret, userId: 1);
    await insertDevice(b, oId, oSecret, owner: true, userId: 1);
    await insertDevice(b, aId, aSecret, userId: 1);
  });

  tearDown(() async {
    await o.close();
    await a.close();
    await b.close();
    await tmp.delete(recursive: true);
  });

  Future<SyncOperation> lastOp(Database db, String type, String id) async {
    final rows = await db.query('operations',
        where: 'entity_type = ? AND entity_id = ?', whereArgs: [type, id]);
    return SyncOperation.fromMap(rows.last);
  }

  // (دفعة 58) بديل دفع LAN: تطبيق العملية مباشرة على قاعدة المستقبل —
  // هذا هو نفس المسار الذي يسلكه السحب السحابي عند وصول عملية قرين.
  Future<void> deliver(SyncOperation op, Repo dst, Database dstDb) async {
    final resolver = ConflictResolver();
    final ok = await dstDb.transaction(
        (txn) => dst.applyRemoteOperation(txn, op, resolver));
    expect(ok, isTrue, reason: 'تطبيق العملية الواردة يجب أن ينجح');
  }

  test('QA-MM-04 remote delete mirrors into trash and restore clears it',
      () async {
    // A ينشئ حساباً ويصل إلى B (عبر مسار التطبيق السحابي).
    final accId = await repoA.saveAccount(Account(
        name: 'سيُحذف',
        kind: AccountKind.customer,
        createdAt: now,
        updatedAt: now));
    await deliver(await lastOp(a, 'account', '$accId'), repoB, b);
    expect(await repoB.accounts(), hasLength(1));
    // A يحذفه — لدى B يجب أن يظهر صف في سلة المهملات.
    await repoA.deleteAccount(accId);
    final delOps = await a.query('operations',
        where: "entity_type = 'account' AND entity_id = ? AND op_type = ?",
        whereArgs: ['$accId', 'delete_']);
    await deliver(SyncOperation.fromMap(delOps.last), repoB, b);
    expect(await repoB.accounts(), isEmpty);
    final trashB = await b.query('trash');
    expect(trashB, hasLength(1),
        reason: 'الحذف الوارد يجب أن ينعكس في سلة مهملات B');
    expect('${trashB.single['label']}', contains('سيُحذف'));
    // A يسترجعه من سلته — سلة B يجب أن تُفرَّغ والحساب يعود.
    final trashA = await a.query('trash');
    await repoA.restoreFromTrash(trashA.single['id'] as int);
    final restoreOps = await a.query('operations',
        where: "entity_type = 'account' AND entity_id = ? AND op_type = ?",
        whereArgs: ['$accId', 'restore']);
    await deliver(SyncOperation.fromMap(restoreOps.last), repoB, b);
    expect(await repoB.accounts(), hasLength(1));
    expect(await b.query('trash'), isEmpty,
        reason: 'الاسترجاع الوارد يجب أن يزيل صف السلة المقابل لدى B');
  });

  test('QA-MM-05 backups carry the group fingerprint and foreign imports fail',
      () async {
    // مجموعة A: بصمتها = جهاز المدير oId.
    await a.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final backup = await repoA.exportAll();
    expect(backup['group_fingerprint'], oId);
    // مجموعة B "أخرى": نجعل مالكها جهازاً مختلفاً ثم نحاول الاستيراد.
    await b.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': 'host'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await b.update('devices', {'is_owner': 0}, where: 'id = ?', whereArgs: [oId]);
    await b.update('devices', {'is_owner': 1}, where: 'id = ?', whereArgs: [bId]);
    await expectLater(
      repoB.importAll(backup),
      throwsA(isA<BackupImportException>()),
      reason: 'نسخة من مجموعة أخرى يجب أن تُرفض',
    );
    // النسخة الصادرة من المجموعة نفسها تُقبل.
    final ownBackup = await repoB.exportAll();
    expect(await repoB.importAll(ownBackup), greaterThan(0));
  });

  test('QA-MM-07 local backup export works without export permission',
      () async {
    // مستخدم بلا أي صلاحيات.
    await a.update('users', {'role': 'viewer', 'permissions': ''},
        where: 'id = 1');
    await a.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final payload = await repoA.exportForLocalBackup();
    expect(payload['app'], 'nexora');
    // بينما التصدير العادي (الذي يغادر الجهاز) يُرفض.
    await expectLater(repoA.exportAll(), throwsA(isA<StateError>()));
  });
}
