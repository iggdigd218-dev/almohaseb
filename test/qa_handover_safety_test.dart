// 🔒 QA — عطل أندرويد 7 وصمام أمان التسليم:
// 1) isWorkspaceOwner محصّنة: غياب صف الجهاز مؤقتاً لا يخفي «إدارة
//    المجموعة» — العلم الاحتياطي ownerDeviceId في sync_meta يحسم.
// 2) فحص جاهزية المستلم قبل التسليم (transferReadinessCheck).
// 3) استرجاع الإدارة خلال 24 ساعة (reclaimOwnershipAvailable/reclaim)
//    والعملية السيادية المعاكسة تُقبل على بقية الأجهزة (reclaim=true).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/app_version.dart';
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
    tmp = await Directory.systemTemp.createTemp('nexora_safe_');
    db = await databaseFactoryFfi.openDatabase(p.join(tmp.path, 'safe.db'),
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
      'SAFE-01 (أندرويد 7) غياب صف الجهاز مؤقتاً لا يسقط الملكية — '
      'العلم الاحتياطي ownerDeviceId يحسم', () async {
    final repo = Repo();
    await repo.initSyncInfra();
    final id = repo.requireDeviceId;
    expect(await repo.isWorkspaceOwner(), isTrue);
    // سباق مصالحة roster على جهاز بطيء: صف جهازنا يُحذف لحظياً قبل
    // إعادة إدراجه — القراءة القديمة كانت تعيد true افتراضياً لكن أي
    // منطق لاحق يعتمد على العلم الاحتياطي المكتوب ذرياً.
    await db.insert('sync_meta', {'key': 'ownerDeviceId', 'value': id},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await db.delete('devices', where: 'id = ?', whereArgs: [id]);
    expect(await repo.isWorkspaceOwner(), isTrue,
        reason: 'العلم الاحتياطي يؤكد ملكيتنا رغم غياب الصف');
    // ولو كان العلم لجهاز آخر: لسنا المالك.
    await db.insert('sync_meta', {'key': 'ownerDeviceId', 'value': 'OTHER'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    expect(await repo.isWorkspaceOwner(), isFalse,
        reason: 'العلم يشير لغيرنا — لا ندّعي الملكية');
  });

  test('SAFE-02 فحص جاهزية المستلم: تحذيرات للجهاز الغائب/القديم/المطرود',
      () async {
    final repo = Repo();
    await repo.initSyncInfra();
    final now = DateTime.now().toIso8601String();
    final old = DateTime.now()
        .subtract(const Duration(hours: 5))
        .toIso8601String();
    // جهاز جاهز تماماً: مقترن، ظهر حديثاً، نفس الإصدار.
    await db.insert('devices', {
      'id': 'DEV-READY',
      'workspace_id': 'default',
      'name': 'جاهز',
      'platform': 'android',
      'is_owner': 0,
      'is_paired': 1,
      'app_version': kAppVersion,
      'last_seen_at': now,
      'auth_secret': '',
      'created_at': now,
      'updated_at': now,
    });
    expect(await repo.transferReadinessCheck('DEV-READY'), isEmpty,
        reason: 'لا تحذيرات لجهاز جاهز');
    // جهاز أندرويد 7 بإصدار تطبيق قديم وغائب منذ 5 ساعات.
    await db.insert('devices', {
      'id': 'DEV-OLD',
      'workspace_id': 'default',
      'name': 'قديم',
      'platform': 'android',
      'is_owner': 0,
      'is_paired': 1,
      'app_version': '3.40.0',
      'last_seen_at': old,
      'auth_secret': '',
      'created_at': now,
      'updated_at': now,
    });
    final warns = await repo.transferReadinessCheck('DEV-OLD');
    expect(warns.length, 2, reason: 'تحذير الغياب + تحذير الإصدار');
    expect(warns.join(), contains('أكثر من ساعة'));
    expect(warns.join(), contains('3.40.0'));
    // جهاز غير موجود إطلاقاً.
    final missing = await repo.transferReadinessCheck('NO-SUCH');
    expect(missing.single, contains('غير موجود'));
  });

  test(
      'SAFE-03 استرجاع الإدارة: متاح للمدير السابق خلال 24 ساعة، '
      'وينفَّذ كاملاً (ملكية + host + إبطال بيانات الاسترجاع)', () async {
    final repo = Repo();
    await repo.initSyncInfra();
    final myId = repo.requireDeviceId;
    final now = DateTime.now().toIso8601String();
    await db.insert('devices', {
      'id': 'DEV-N7',
      'workspace_id': 'default',
      'name': 'هاتف أندرويد 7',
      'platform': 'android',
      'is_owner': 0,
      'is_paired': 1,
      'auth_secret': '',
      'created_at': now,
      'updated_at': now,
    });
    // التسليم: يصبح DEV-N7 المالك ونحن عضو، وتُكتب بيانات الاسترجاع.
    await repo.transferOwnership('DEV-N7');
    expect(await repo.isWorkspaceOwner(), isFalse);
    final saved = (await repo.settings())['ownershipHandover'] ?? '';
    expect(saved, isNotEmpty, reason: 'بيانات الاسترجاع حُفظت مع التسليم');
    expect(jsonDecode(saved)['new_owner_device_id'], 'DEV-N7');
    // العلم الاحتياطي كُتب ذرياً داخل معاملة التسليم.
    final flag = await db.query('sync_meta',
        where: 'key = ?', whereArgs: ['ownerDeviceId'], limit: 1);
    expect('${flag.first['value']}', 'DEV-N7');
    // الصمام متاح لنا (المدير السابق، خلال المهلة).
    expect(await repo.reclaimOwnershipAvailable(), isTrue);
    // تنفيذ الاسترجاع بعد «تعثر التفعيل» على الجهاز القديم.
    await repo.reclaimOwnership();
    expect(await repo.isWorkspaceOwner(), isTrue,
        reason: 'استعدنا الملكية محلياً');
    expect(await repo.workspaceMode(), 'host');
    final n7 = (await db.query('devices',
            where: 'id = ?', whereArgs: ['DEV-N7']))
        .first;
    expect(n7['is_owner'], 0, reason: 'الجهاز المتعثر عاد عضواً');
    // بيانات الاسترجاع أُبطلت — لا يُستخدم الصمام مرتين.
    expect((await repo.settings())['ownershipHandover'] ?? '', isEmpty);
    expect(await repo.reclaimOwnershipAvailable(), isFalse);
    // والعملية السيادية المعاكسة في الطابور تحمل reclaim=true.
    final ops = await db.query('operations',
        where: "entity_id = 'ownershipTransfer'", orderBy: 'timestamp DESC');
    expect(ops, isNotEmpty);
    final payload = jsonDecode('${ops.first['payload']}');
    final value = jsonDecode('${payload['value']}');
    expect(value['reclaim'], true);
    expect(value['owner_device_id'], myId);
  });

  test(
      'SAFE-04 الاسترجاع منقضي المهلة أو من غير المدير السابق: مرفوض',
      () async {
    final repo = Repo();
    await repo.initSyncInfra();
    final myId = repo.requireDeviceId;
    await db.update('devices', {'is_owner': 0},
        where: 'id = ?', whereArgs: [myId]);
    // بيانات تسليم عمرها 25 ساعة — المهلة 24 ساعة فقط.
    final stale = DateTime.now()
        .subtract(const Duration(hours: 25))
        .toIso8601String();
    await repo.setSetting(
        'ownershipHandover',
        jsonEncode({
          'previous_owner_device_id': myId,
          'new_owner_device_id': 'DEV-X',
          'at': stale,
        }));
    expect(await repo.reclaimOwnershipAvailable(), isFalse,
        reason: 'انقضت مهلة الـ 24 ساعة');
    expect(() => repo.reclaimOwnership(), throwsStateError);
    // بيانات تسليم لجهاز سابق آخر (لسنا نحن المدير السابق).
    await repo.setSetting(
        'ownershipHandover',
        jsonEncode({
          'previous_owner_device_id': 'SOMEONE-ELSE',
          'new_owner_device_id': 'DEV-X',
          'at': DateTime.now().toIso8601String(),
        }));
    expect(await repo.reclaimOwnershipAvailable(), isFalse,
        reason: 'لسنا المدير السابق في هذا التسليم');
  });

  test(
      'SAFE-05 عملية الاسترجاع السيادية تُقبل على جهاز ثالث من المدير '
      'السابق الحقيقي فقط — وتُرفض من منتحل', () async {
    // نحن جهاز عضو محايد (C). المالك الحالي DEV-B (بعد تسليم من DEV-A).
    final repo = Repo();
    await repo.initSyncInfra();
    final myId = repo.requireDeviceId;
    final now = DateTime.now().toIso8601String();
    await db.update('devices', {'is_owner': 0},
        where: 'id = ?', whereArgs: [myId]);
    for (final (id, owner) in [('DEV-A', 0), ('DEV-B', 1), ('DEV-EVIL', 0)]) {
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
    // ذاكرة المدير السابق (تُكتب عند تطبيق التسليم الأول A→B).
    await db.insert('sync_meta', {'key': 'prevOwnerDeviceId', 'value': 'DEV-A'},
        conflictAlgorithm: ConflictAlgorithm.replace);

    SyncOperation reclaimOp(String source, String id) => SyncOperation(
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
              'reclaim': true,
              'at': now,
            }),
          },
          deviceTime: now,
          timestamp: now,
        );

    // منتحل (ليس المدير السابق المسجل): استرجاعه يُرفض.
    await db.transaction((txn) => repo.applyRemoteOperation(
        txn, reclaimOp('DEV-EVIL', 'OP-RECLAIM-EVIL'), ConflictResolver()));
    var bRow = (await db.query('devices',
            where: 'id = ?', whereArgs: ['DEV-B']))
        .first;
    expect(bRow['is_owner'], 1, reason: 'انتحال الاسترجاع مرفوض');

    // المدير السابق الحقيقي DEV-A: استرجاعه يُقبل ويقلب الملكية.
    await db.transaction((txn) => repo.applyRemoteOperation(
        txn, reclaimOp('DEV-A', 'OP-RECLAIM-REAL'), ConflictResolver()));
    bRow = (await db.query('devices', where: 'id = ?', whereArgs: ['DEV-B']))
        .first;
    final aRow = (await db.query('devices',
            where: 'id = ?', whereArgs: ['DEV-A']))
        .first;
    expect(aRow['is_owner'], 1, reason: 'المدير السابق استعاد الملكية');
    expect(bRow['is_owner'], 0);
    // ذاكرة الاسترجاع أُبطلت بعد استخدامها مرة واحدة.
    final mem = await db.query('sync_meta',
        where: 'key = ?', whereArgs: ['prevOwnerDeviceId']);
    expect(mem, isEmpty);
  });
}
