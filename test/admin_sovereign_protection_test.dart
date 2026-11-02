import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/database.dart';
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
