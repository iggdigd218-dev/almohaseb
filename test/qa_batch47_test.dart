// QA — دفعة 47: محرك المزامنة الصامت + هندسة سطح المكتب:
// - roleDisplayName: لقب الدور «المدير (اسم الجهاز)» في كل واجهات المزامنة.
// - roleDisplayNameOf في SyncEngine يقرأ الدور من قاعدة البيانات.
// - كاشف «نافذة الخطر»: يبثّ عند عمليات عالقة قديمة ويصمت عند الصفاء.
// - heldInvoicesProvider: تعليق/استئناف فواتير POS (اختصار F12).
// - deviceSyncStatusProvider يحمل roleCode وlastSyncAt للقائمة عالية المستوى.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/pos_cart.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('لقب الدور الموحد roleDisplayName', () {
    test('المالك دائماً «المدير (الاسم)» حتى بلا دور', () {
      expect(
        roleDisplayName(roleCode: '', isOwner: true, deviceName: 'جهاز أحمد'),
        'المدير (جهاز أحمد)',
      );
    });

    test('كل دور يأخذ لقبه الصحيح', () {
      expect(
        roleDisplayName(
            roleCode: 'admin', isOwner: false, deviceName: 'مكتب'),
        'المدير (مكتب)',
      );
      expect(
        roleDisplayName(
            roleCode: 'accountant', isOwner: false, deviceName: 'كاشير 1'),
        'الكاشير (كاشير 1)',
      );
      expect(
        roleDisplayName(
            roleCode: 'dataentry', isOwner: false, deviceName: 'مدخل'),
        'مدخل البيانات (مدخل)',
      );
      expect(
        roleDisplayName(
            roleCode: 'agent', isOwner: false, deviceName: 'فرع'),
        'الشريك / الوكيل (فرع)',
      );
    });

    test('بلا دور وبلا ملكية: الاسم فقط بلا لقب', () {
      expect(
        roleDisplayName(
            roleCode: 'viewer', isOwner: false, deviceName: 'زائر'),
        'زائر',
      );
      expect(
        roleDisplayName(roleCode: '', isOwner: false, deviceName: '  '),
        'جهاز',
      );
    });
  });

  group('SyncEngine.roleDisplayNameOf من قاعدة البيانات', () {
    late Database db;
    late Repo repo;
    late SyncEngine engine;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await AppDatabase.createSchema(db);
      repo = Repo(databaseProvider: () async => db);
      engine = SyncEngine(repo: repo, dbProvider: () async => db);
    });

    tearDown(() async {
      engine.stop();
      await db.close();
    });

    test('يجلب الاسم والدور من devices/users', () async {
      final uid = await db.insert('users', {
        'name': 'كاشير الفرع',
        'role': UserRole.accountant.code,
        'permissions': 'add_tx',
        'is_me': 0,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('devices', {
        'id': 'DEV-CASHIER',
        'workspace_id': 'default',
        'name': 'جهاز الكاشير',
        'is_owner': 0,
        'is_paired': 1,
        'user_id': uid,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      expect(await engine.roleDisplayNameOf('DEV-CASHIER', ''),
          'الكاشير (جهاز الكاشير)');
    });

    test('المالك يظهر «المدير (…)» ولو بلا مستخدم مرتبط', () async {
      await db.insert('devices', {
        'id': 'DEV-OWNER',
        'workspace_id': 'default',
        'name': 'جهاز المدير',
        'is_owner': 1,
        'is_paired': 1,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      expect(await engine.roleDisplayNameOf('DEV-OWNER', ''),
          'المدير (جهاز المدير)');
    });

    test('جهاز مجهول: الاسم الاحتياطي يُستخدم', () async {
      expect(await engine.roleDisplayNameOf('NOPE', 'اسم احتياطي'),
          'اسم احتياطي');
      expect(await engine.roleDisplayNameOf('NOPE', ''), 'جهاز');
    });
  });

  group('نافذة الخطر — كاشف تباين السجلات', () {
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
    });

    tearDown(() async {
      SyncEngine.onSyncDanger = null;
      engine.stop();
      await db.close();
    });

    Future<void> seedStuckOp({required Duration age, int attempts = 9}) async {
      final t = DateTime.now().subtract(age).toIso8601String();
      await db.insert('operations', {
        'id': 'OP-STUCK',
        'workspace_id': 'default',
        'device_id': 'DEV-A',
        'entity_type': 'tx',
        'entity_id': '1',
        'op_type': 'create',
        'payload': '{}',
        'version': 1,
        'parent_op_id': '',
        'timestamp': t,
        'device_time': t,
        'synced': 0,
      });
      await db.insert('sync_queue', {
        'operation_id': 'OP-STUCK',
        'status': 'failed',
        'target': 'lan',
        'attempts': attempts,
        'last_error': 'peer unreachable',
        'created_at': t,
        'updated_at': t,
      });
    }

    test('وضع مستقل: لا خطر أبداً حتى مع صفوف قديمة', () async {
      await seedStuckOp(age: const Duration(hours: 2));
      await engine.debugCheckDangerState();
      expect(dangerLog.whereType<String>(), isEmpty);
    });

    test('داخل مجموعة: عمليات عالقة قديمة تفجّر التنبيه بالعربية',
        () async {
      await db.insert('sync_meta',
          {'key': 'workspaceMode', 'value': 'member'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await seedStuckOp(age: const Duration(hours: 1));
      await engine.debugCheckDangerState();
      expect(dangerLog.whereType<String>(), isNotEmpty,
          reason: 'عالقة منذ ساعة مع 9 محاولات — يجب أن يُبث الخطر');
      expect(dangerLog.whereType<String>().first, contains('تنبيه خطير'));
      expect(dangerLog.whereType<String>().first, contains('تباين الأرصدة'));
    });

    test('زوال الحالة يبثّ null لإخفاء البانر', () async {
      await db.insert('sync_meta',
          {'key': 'workspaceMode', 'value': 'member'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await seedStuckOp(age: const Duration(hours: 1));
      await engine.debugCheckDangerState();
      expect(dangerLog.whereType<String>(), isNotEmpty);
      // الطابور صفا (سُلّمت العمليات).
      await db.update('sync_queue', {'status': 'synced'});
      await engine.debugCheckDangerState();
      expect(dangerLog.last, isNull,
          reason: 'يجب بث null عند استعادة سلامة المزامنة');
    });

    test('عمليات حديثة (< العتبة): لا إنذار كاذب', () async {
      await db.insert('sync_meta',
          {'key': 'workspaceMode', 'value': 'member'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await seedStuckOp(age: const Duration(seconds: 30), attempts: 2);
      await engine.debugCheckDangerState();
      expect(dangerLog.whereType<String>(), isEmpty);
    });
  });

  group('تعليق الفواتير heldInvoicesProvider (F12)', () {
    test('تعليق ثم استئناف يعيد نفس المسودة', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final item = Item(
        name: 'صنف تجريبي',
        sku: 'X1',
        unit: 'حبة',
        buyPrice: 500,
        sellPrice: 800,
        quantity: 10,
        createdAt: DateTime(2026, 9, 10),
        updatedAt: DateTime(2026, 9, 10),
        id: 7,
      );
      final ctl = container.read(posDraftProvider.notifier);
      ctl.addItem(item, allowNegative: false);
      ctl.addItem(item, allowNegative: false);
      final draft = container.read(posDraftProvider);
      expect(draft.itemCount, 2);

      // علّق: خزّن المسودة وأفرغ.
      container.read(heldInvoicesProvider.notifier).state = [draft];
      ctl.clear();
      expect(container.read(posDraftProvider).cart, isEmpty);

      // استأنف: استعادة كاملة.
      final held = container.read(heldInvoicesProvider);
      expect(held, hasLength(1));
      ctl.restore(held.first);
      final restored = container.read(posDraftProvider);
      expect(restored.itemCount, 2);
      expect(restored.cart[7]?.unitPrice, 800);
      expect(restored.netTotal, 1600);
    });
  });

  group('deviceSyncStatusProvider — قائمة عالية المستوى', () {
    test('displayName يعتمد على الدور وlastSyncAt يُقرأ من devices.last_sync_at',
        () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(() => db.close());
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEV-ME');
      final uid = await db.insert('users', {
        'name': 'مدخل',
        'role': UserRole.dataentry.code,
        'permissions': 'add_tx',
        'is_me': 0,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.insert('devices', {
        'id': 'DEV-PEER',
        'workspace_id': 'default',
        'name': 'لابتوب',
        'is_owner': 0,
        'is_paired': 1,
        'user_id': uid,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      // (دفعة 58) لا op_deliveries — «آخر مزامنة» تُقرأ من last_sync_at.
      final ts = DateTime(2026, 9, 10, 8, 30).toIso8601String();
      await db.update('devices', {'last_sync_at': ts},
          where: 'id = ?', whereArgs: ['DEV-PEER']);
      final engine = SyncEngine(repo: repo, dbProvider: () async => db);
      addTearDown(engine.stop);
      final container = ProviderContainer(overrides: [
        repoProvider.overrideWithValue(repo),
        syncEngineProvider.overrideWithValue(engine),
      ]);
      addTearDown(container.dispose);
      final list = await container.read(deviceSyncStatusProvider.future);
      expect(list, hasLength(1));
      expect(list.single.displayName, 'مدخل البيانات (لابتوب)');
      expect(list.single.lastSyncAt, ts);
      expect(list.single.fullySynced, isTrue);
    });
  });
}
