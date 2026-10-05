import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
  late Database db;
  late Repo repo;
  final now = DateTime.now();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('phase1_inv_');
    db = await databaseFactory.openDatabase('${tmp.path}/test.db');
    await AppDatabase.createSchema(db);

    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'DEV-PHASE1');
    await repo.initSyncInfra();

    // Setup single admin user
    final nowIso = now.toIso8601String();
    await db.insert('users', {
      'id': 1,
      'name': 'المدير العام',
      'role': 'admin',
      'permissions': '',
      'is_me': 1,
      'active': 1,
      'created_at': nowIso,
      'updated_at': nowIso,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.update('devices', {'user_id': 1, 'is_owner': 1},
        where: 'id = ?', whereArgs: ['DEV-PHASE1']);
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  group('المرحلة 1: المخزن والمنتجات والحذف المنطقي وتطهير المخلفات', () {
    test('1. الحذف المنطقي للصنف يخفيه تماماً من استعلامات العرض والإدارة',
        () async {
      // إضافة صنف جديد
      final itemId = await repo.saveItem(Item(
        name: 'منتج تجريبي 1',
        sku: 'SKU-001',
        buyPrice: 100,
        sellPrice: 150,
        quantity: 10,
        createdAt: now,
        updatedAt: now,
      ));

      // التأكد من ظهوره في الاستعلام العام
      var allItems = await repo.items();
      expect(allItems.any((i) => i.id == itemId), isTrue);
      expect((await repo.counts())['items'], equals(1));
      expect(await repo.item(itemId), isNotNull);

      // حذف الصنف
      await repo.deleteItem(itemId);

      // التحقق الصارم: الصنف يختفي تماماً من repo.items()
      allItems = await repo.items();
      expect(allItems.any((i) => i.id == itemId), isFalse);

      // التحقق الصارم: الصنف لا يُعاد بواسطة repo.item(id)
      final deletedItem = await repo.item(itemId);
      expect(deletedItem, isNull);

      // التحقق الصارم: عداد الأصناف في counts لا يتضمن الصنف المحذوف
      final c = await repo.counts();
      expect(c['items'], equals(0));

      // التأكد من تسجيله في سلة المهملات
      final trashRows = await db.query('trash',
          where: "store = 'items'", limit: 1);
      expect(trashRows, hasLength(1));
      expect(trashRows.first['label'], contains('منتج تجريبي 1'));
    });

    test('2. منع إعادة إحياء الصنف المحذوف عبر عمليات مزامنة قديمة واردة (Tombstones)',
        () async {
      final itemId = await repo.saveItem(Item(
        name: 'منتج محصن ضد الإحياء',
        sku: 'SKU-TOMB',
        buyPrice: 50,
        sellPrice: 80,
        quantity: 5,
        createdAt: now,
        updatedAt: now,
      ));

      // حذف الصنف محلياً
      await repo.deleteItem(itemId);
      expect(await repo.items(), isEmpty);

      // محاكاة وصول عملية تحديث أو إنشاء قديمة للصنف من السحابة
      final staleOp = SyncOperation(
        id: 'op-stale-update',
        deviceId: 'DEV-REMOTE',
        workspaceId: repo.requireWorkspaceId,
        userId: 1,
        entityType: EntityKind.item,
        entityId: '$itemId',
        opType: OpKind.update,
        version: 1,
        parentOpId: '',
        payload: {
          'id': itemId,
          'name': 'منتج محصن ضد الإحياء - معدل قديماً',
          'sell_price': 90,
          'quantity': 20,
        },
        deviceTime: now.subtract(const Duration(minutes: 5)).toIso8601String(),
        timestamp: now.subtract(const Duration(minutes: 5)).toIso8601String(),
      );

      await db.transaction((txn) async {
        await repo.applyRemoteOperation(txn, staleOp, ConflictResolver());
      });

      // التحقق الصارم: الصنف يظل محذوفاً ولا يظهر في المخزن
      final itemsAfterStale = await repo.items();
      expect(itemsAfterStale.any((i) => i.id == itemId), isFalse);
      expect(await repo.item(itemId), isNull);
    });

    test('3. تطبيق عمليات الحذف السحابية الواردة كشواهد قبور تطهر الصنف',
        () async {
      // إدراج صنف محلياً
      final itemId = await repo.saveItem(Item(
        name: 'صنف سيحذف سحابياً',
        sku: 'SKU-CLOUD-DEL',
        buyPrice: 200,
        sellPrice: 250,
        quantity: 15,
        createdAt: now,
        updatedAt: now,
      ));

      expect(await repo.items(), hasLength(1));

      // محاكاة وصول opType = delete_ من السحابة
      final delOp = SyncOperation(
        id: 'op-cloud-delete',
        deviceId: 'DEV-REMOTE-OWNER',
        workspaceId: repo.requireWorkspaceId,
        userId: 1,
        entityType: EntityKind.item,
        entityId: '$itemId',
        opType: OpKind.delete_,
        version: 2,
        parentOpId: '',
        payload: {
          'id': itemId,
          'name': 'صنف سيحذف سحابياً',
          'is_deleted': 1,
          'deleted_at': now.toIso8601String(),
        },
        deviceTime: now.toIso8601String(),
        timestamp: now.toIso8601String(),
      );

      await db.transaction((txn) async {
        await repo.applyRemoteOperation(txn, delOp, ConflictResolver());
      });

      // التحقق: الصنف اختفى فوراً من الأصناف النشطة
      final activeItems = await repo.items();
      expect(activeItems.isEmpty, isTrue);

      // التحقق: تدوينه في سلة المهملات المحلية
      final trash = await db.query('trash');
      expect(trash.any((t) => '${t['label']}'.contains('صنف سيحذف سحابياً')), isTrue);
    });
  });
}
