import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('حماية سيادة دور المدير وترميم صلاحيات المالك', () {
    late Database db;
    late Repo repo;

    setUp(() async {
      db = await openDatabase(
        inMemoryDatabasePath,
        version: AppDatabase.schemaVersion,
        onCreate: (d, v) => AppDatabase.createSchema(d),
      );
      repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'owner_device_1');
      await repo.initSyncInfra();
      // مسح البيانات التلقائية لتبدأ الاختبارات بسيناريو نقي ومحدد
      await db.delete('users');
      await db.delete('devices');
      await db.delete('sync_meta');
    });

    tearDown(() async {
      await db.close();
    });

    test('1. مالك المنشأة لا يمكن خفض رتبته من قبل تخصيص صلاحيات جهاز عضو', () async {
      // إعداد: جهاز المالك ومستخدم المالك "حمود"
      await db.insert('devices', {
        'id': 'owner_device_1',
        'workspace_id': 'default',
        'name': 'هاتف المدير',
        'is_paired': 1,
        'is_owner': 1,
        'user_id': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('sync_meta', {
        'key': 'workspaceMode',
        'value': 'host',
      });

      // إضافة مستخدم المدير الرئيسي
      await db.insert('users', {
        'id': 1,
        'name': 'حمود',
        'role': 'admin',
        'permissions': 'manage_users,edit_tx,delete_tx,view_reports',
        'is_me': 1,
        'active': 1,
        'workspace_id': 'default',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      // إضافة جهاز عضو وكان بالخطأ مرتبطاً بنفس المعرف 1 (أو لم يكن له مستخدم منفصل)
      await db.insert('devices', {
        'id': 'member_device_2',
        'workspace_id': 'default',
        'name': 'هاتف العضو',
        'is_paired': 1,
        'is_owner': 0,
        'user_id': 1, // خطأ الربط التاريخي
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      // تخصيص صلاحيات للعضو برتبة "عرض فقط" (viewer)
      await repo.setDevicePermissions('member_device_2', UserRole.viewer, {});

      // التحقق الحاسم:
      // مستخدم المدير الرئيسي "حمود" (id=1) يجب أن يظل مديراً (admin) دون أي تغيير!
      final adminUserRow = await db.query('users', where: 'id = 1');
      expect(adminUserRow.first['role'], equals('admin'));
      expect(adminUserRow.first['is_me'], equals(1));

      // والجهاز العضو تم إنشاء مستخدم جديد مخصص له برتبة viewer وفصله عن مستخدم المدير
      final memberDev = await db.query('devices', where: "id = 'member_device_2'");
      final memberUid = memberDev.first['user_id'] as int;
      expect(memberUid, isNot(equals(1)));

      final memberUserRow = await db.query('users', where: 'id = ?', whereArgs: [memberUid]);
      expect(memberUserRow.first['role'], equals('viewer'));
    });

    test('2. الترميم التلقائي لقاعدة البيانات يعيد ترقية المدير إذا خُفضت رتبته سابقاً', () async {
      // محاكاة الحالة المتضررة لدى المستخدم: "حمود" تحول إلى viewer
      await db.insert('devices', {
        'id': 'owner_device_1',
        'workspace_id': 'default',
        'name': 'هاتف المدير',
        'is_paired': 1,
        'is_owner': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('sync_meta', {
        'key': 'workspaceMode',
        'value': 'host',
      });
      await db.insert('users', {
        'id': 1,
        'name': 'حمود',
        'role': 'viewer', // متضرر
        'permissions': '',
        'is_me': 1,
        'active': 1,
        'workspace_id': 'default',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      // استدعاء دالة الترميم التلقائي
      await AppDatabase.repairOwnerAdminStatus(db);

      // يجب أن يعود مديراً مع كامل الصلاحيات
      final repairedUser = await db.query('users', where: 'id = 1');
      expect(repairedUser.first['role'], equals('admin'));
      expect(repairedUser.first['permissions'], contains('manage_users'));

      // currentUser يعيده مديراً
      final cur = await repo.currentUser();
      expect(cur?.role, equals(UserRole.admin));
      expect(cur?.name, equals('حمود'));
    });

    test('3. ترميم اسم المدير وفك ربط أجهزة الأعضاء إن تلوّث اسم المدير باسم العضو', () async {
      // إعداد: جهاز المالك اسمه "حمود"
      await db.insert('devices', {
        'id': 'owner_device_1',
        'workspace_id': 'default',
        'name': 'حمود',
        'is_paired': 1,
        'is_owner': 1,
        'user_id': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await repo.setSetting('sync.deviceName', 'حمود');
      await db.insert('sync_meta', {
        'key': 'workspaceMode',
        'value': 'host',
      });

      // إضافة جهاز عضو اسمه "سالم - كاشير"
      await db.insert('devices', {
        'id': 'member_device_salem',
        'workspace_id': 'default',
        'name': 'سالم - كاشير',
        'is_paired': 1,
        'is_owner': 0,
        'user_id': 1, // خطأ الربط التاريخي
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      // مستخدم المدير id=1 تلوّث اسمه وأصبح "سالم - كاشير"
      await db.insert('users', {
        'id': 1,
        'name': 'سالم - كاشير', // ملوّث باسم العضو
        'role': 'viewer',
        'permissions': '',
        'is_me': 1,
        'active': 1,
        'workspace_id': 'default',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

      // تشغيل الترميم السيادي
      await AppDatabase.repairOwnerAdminStatus(db);

      // 1) فك ربط جهاز سالم العضو إلى معرف مستخدم مستقل
      final memberDev = await db.query('devices', where: "id = 'member_device_salem'");
      expect(memberDev.first['user_id'], isNot(equals(1)));

      // 2) ترميم اسم المدير id=1 ليعود "حمود" ورتبته "admin"
      final adminUserRow = await db.query('users', where: 'id = 1');
      expect(adminUserRow.first['name'], equals('حمود'));
      expect(adminUserRow.first['role'], equals('admin'));

      final cur = await repo.currentUser();
      expect(cur?.name, equals('حمود'));
      expect(cur?.role, equals(UserRole.admin));
    });

    test('4. حل التعارض الذكي Last-Write-Wins: اعتماد الأحدث وحذف القديم دون توقف المزامنة', () async {
      // إعداد حساب محلي بتاريخ سابق
      await db.insert('accounts', {
        'id': 101,
        'name': 'حساب عميل قديم',
        'kind': 'customer',
        'opening_balance': 0,
        'currency': 'YER',
        'archived': 0,
        'deleted_at': '',
        'created_at': '2026-09-28T08:00:00.000',
        'updated_at': '2026-09-28T08:00:00.000',
      });

      // عملية حذف واردة من جهاز آخر في نفس مساحة العمل بتاريخ أحدث (09:00:00)
      final delOp = SyncOperation(
        id: 'op_del_101',
        deviceId: 'member_device_salem',
        workspaceId: repo.requireWorkspaceId,
        userId: 2,
        entityType: EntityKind.account,
        entityId: '101',
        opType: OpKind.delete_,
        version: 2,
        parentOpId: '',
        payload: const {'id': 101},
        deviceTime: '2026-09-28T09:00:00.000',
        timestamp: '2026-09-28T09:00:00.000',
      );

      final resolver = ConflictResolver();
      final applied = await repo.applyRemoteOperation(db, delOp, resolver);
      expect(applied, isTrue);

      // الحساب تم حذفه (اعتماد الأحدث وحذف القديم)
      final accAfter = await db.query('accounts', where: 'id = 101');
      expect(accAfter.first['deleted_at'], equals('2026-09-28T09:00:00.000'));
    });

    test('5. مساحة عمل واحدة فقط للمنشأة وممنوع منعاً باتاً المزامنة خارج المساحة', () async {
      // 1) ربط المنشأة بمساحة عمل واحدة ثابتة
      await repo.bindWorkspaceId('WS-BIZ-MAIN');
      expect(repo.requireWorkspaceId, equals('WS-BIZ-MAIN'));

      // 2) فحص ensureWorkspace: يجب أن تعيد نفس المساحة ولا تنشئ مساحات متعددة
      final resolvedWs = await ensureWorkspace(db, repo: repo);
      expect(resolvedWs, equals('WS-BIZ-MAIN'));
      expect(repo.requireWorkspaceId, equals('WS-BIZ-MAIN'));

      // 3) منع المزامنة خارج المساحة: عملية قادمة بمساحة عمل غريبة تُرفض فوراً
      const alienOp = SyncOperation(
        id: 'op_alien_999',
        deviceId: 'other_dev',
        workspaceId: 'WS-STRANGE-ALIEN', // مساحة أخرى غريبة
        userId: 1,
        entityType: EntityKind.account,
        entityId: '999',
        opType: OpKind.create,
        version: 1,
        parentOpId: '',
        payload: {'id': 999, 'name': 'حساب متجر غريب'},
        deviceTime: '2026-09-28T10:00:00.000',
        timestamp: '2026-09-28T10:00:00.000',
      );

      final resolver = ConflictResolver();
      final applied = await repo.applyRemoteOperation(db, alienOp, resolver);
      expect(applied, isFalse);

      // التأكد من عدم وصول الحساب الغريب للقاعدة المحلية
      final alienAcc = await db.query('accounts', where: 'id = 999');
      expect(alienAcc.isEmpty, isTrue);
    });
  });
}
