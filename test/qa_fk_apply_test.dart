// QA — (2026-09-22) سلامة تطبيق العمليات الواردة: FOREIGN KEY 787
//  FK    : فاتورة تصل قبل حسابها/صنفها لا تُسقط السحب (سجل مؤقت للآباء).
//  ORDER : فرز واعٍ بالتبعية (حسابات ← أصناف ← فواتير ← بنود، والحذف أخيراً).
//  OWNER : المالك لا يظهر له «بلا صلاحية» أبداً + صف صلاحيات فعّال.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/rbac.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Repo repo;
  setUp(() async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
    repo.debugSetWorkspaceId('WS-QA');
  });

  SyncOperation op({
    required EntityKind kind,
    required OpKind type,
    required String id,
    required Map<String, Object?> payload,
  }) =>
      SyncOperation(
        id: 'op-${kind.name}-$id-${type.name}',
        deviceId: 'DEVICE-OTHER',
        workspaceId: 'WS-QA',
        userId: null,
        version: 1,
        parentOpId: '',
        timestamp: DateTime.now().toIso8601String(),
        entityType: kind,
        entityId: id,
        opType: type,
        payload: payload,
        deviceTime: DateTime.now().toIso8601String(),
      );

  test('FK-01 فاتورة قبل حسابها: لا 787 والسحب لا يتوقف', () async {
    final db = await repo.database;
    // لا يوجد حساب 77 محلياً — الفاتورة تصل أولاً (ترتيب عشوائي حقيقي).
    final txOp = op(
      kind: EntityKind.tx,
      type: OpKind.create,
      id: '900',
      payload: {
        'id': 900,
        'workspace_id': 'WS-QA',
        'account_id': 77,
        'type': 'sale',
        'amount': 1500,
        'currency': 'YER',
        'date': DateTime.now().toIso8601String(),
        'status': 'done',
        'sync_state': 'synced',
        'items': [
          {
            'id': 1,
            'workspace_id': 'WS-QA',
            'item_id': 555, // صنف غير موجود أيضاً
            'name': 'صنف وارد',
            'unit': 'حبة',
            'quantity': 2,
            'unit_price': 750,
            'total': 1500,
          }
        ],
      },
    );
    final ok = await db.transaction(
        (txn) => repo.applyRemoteOperation(txn, txOp, ConflictResolver()));
    expect(ok, isTrue, reason: 'العملية تُطبَّق ولا يرتفع FOREIGN KEY 787');

    final rows = await db.query('transactions', where: 'id = ?', whereArgs: [
      int.tryParse('900') ?? '900'
    ]);
    expect(rows.length, 1, reason: 'الفاتورة أُدرجت');
    final stubs = await db.query('accounts', where: 'id = ?', whereArgs: [77]);
    expect(stubs.length, 1, reason: 'سجل مؤقت للحساب المفقود');
    expect(stubs.first['name'], contains('مؤقت'));
    final items = await db.query('items', where: 'id = ?', whereArgs: [555]);
    expect(items.length, 1, reason: 'سجل مؤقت للصنف المفقود');
    final lines =
        await db.query('transaction_items', where: 'tx_id = ?', whereArgs: [
      int.tryParse('900') ?? '900'
    ]);
    expect(lines.length, 1, reason: 'بنود الفاتورة أُدرجت');
  });

  test('FK-02 الحساب الأصلي يستبدل السجل المؤقت لاحقاً', () async {
    final db = await repo.database;
    await db.transaction((txn) => repo.applyRemoteOperation(
        txn,
        op(
          kind: EntityKind.tx,
          type: OpKind.create,
          id: '901',
          payload: {
            'id': 901,
            'workspace_id': 'WS-QA',
            'account_id': 88,
            'type': 'sale',
            'amount': 10,
            'currency': 'YER',
            'date': DateTime.now().toIso8601String(),
          },
        ),
        ConflictResolver()));
    await db.transaction((txn) => repo.applyRemoteOperation(
        txn,
        op(
          kind: EntityKind.account,
          type: OpKind.create,
          id: '88',
          payload: {
            'id': 88,
            'workspace_id': 'WS-QA',
            'name': 'عميل حقيقي',
            'kind': 'customer',
            'notify_channel': 'none',
          },
        ),
        ConflictResolver()));
    final acc = await db.query('accounts', where: 'id = ?', whereArgs: [88]);
    expect(acc.first['name'], 'عميل حقيقي',
        reason: 'السجل الحقيقي يحل محل المؤقت بنفس المعرف');
  });

  test('CAT-DEDUP-01 تصنيف مكرر الاسم لا يرمي UNIQUE constraint failed', () async {
    final db = await repo.database;
    // إضافة تصنيف باسم معين
    await db.insert('item_categories', {
      'id': 10,
      'name': 'إلكترونيات',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });

    // وصول تصنيف بمعرف مختلف لكن بنفس الاسم من جهاز آخر
    final catOp = op(
      kind: EntityKind.itemCategory,
      type: OpKind.create,
      id: '20',
      payload: {
        'id': 20,
        'name': 'إلكترونيات',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
    );

    final ok = await db.transaction(
        (txn) => repo.applyRemoteOperation(txn, catOp, ConflictResolver()));
    expect(ok, isTrue, reason: 'تم تطبيق العملية بنجاح ودون خطأ تعارض');

    final cat20 = await db.query('item_categories', where: 'id = ?', whereArgs: [20]);
    expect(cat20.length, 1);
    expect(cat20.first['name'], contains('إلكترونيات'));
  });

  test('ORDER-01 الفرز بالتبعية: آباء قبل أبناء والحذف أخيراً', () {
    final ops = [
      op(kind: EntityKind.tx, type: OpKind.create, id: '1', payload: {}),
      op(kind: EntityKind.item, type: OpKind.create, id: '2', payload: {}),
      op(kind: EntityKind.account, type: OpKind.delete_, id: '3', payload: {}),
      op(kind: EntityKind.account, type: OpKind.create, id: '4', payload: {}),
      op(kind: EntityKind.itemCategory, type: OpKind.create, id: '5',
          payload: {}),
    ];
    final sorted = sortOperationsByDependency(ops);
    expect(
      sorted.map((o) => o.entityId).toList(),
      ['4', '5', '2', '1', '3'],
      reason: 'حساب ← تصنيف ← صنف ← فاتورة، ثم الحذف أخيراً',
    );
  });

  test('OWNER-01 المالك بلا مستخدم: مدير كامل وصف صلاحيات فعّال', () async {
    final db = await repo.database;
    final devId = repo.requireDeviceId;
    await db.insert('workspaces', {
      'id': 'WS-QA',
      'name': 'مساحة تحقق',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    // التهيئة تُنشئ صف الجهاز — نرفعه إلى مالك (is_owner=1).
    await db.update(
      'devices',
      {
        'workspace_id': 'WS-QA',
        'name': 'جهاز المدير',
        'is_paired': 1,
        'is_owner': 1,
        'revoked_at': '',
        'expelled_at': '',
      },
      where: 'id = ?',
      whereArgs: [devId],
    );
    await repo.setSetting('account.email', 'owner@qa.test');
    await repo.setSetting('account.type', 'enterprise');

    final me = await repo.currentUser();
    expect(me, isNotNull, reason: 'المالك لا يُقفل: لا شارة «بلا صلاحية»');
    expect(me!.role, UserRole.admin);
    final perms = await repo.effectivePermissions();
    expect(perms.isActive, isTrue);
    expect(perms.isAdmin, isTrue);
    expect(perms.canDeleteTx, isTrue);

    final rows =
        await db.query('user_permissions', where: 'user_email = ?', whereArgs: [
      'owner@qa.test'
    ]);
    expect(rows.length, 1, reason: 'صف الصلاحيات يُحقن تلقائياً');
    expect(rows.first['is_active'], 1);
    expect(rows.first['role'], 'admin');
  });

  test('OWNER-02 EffectivePermissions.owner صلاحيات كاملة', () {
    final p = EffectivePermissions.owner('a@b.test');
    expect(p.isAdmin && p.isActive && p.canViewReports, isTrue);
  });

  test('ORDER-02 تسلسل الاستيعاب الصارم: أقسام ← فئات ← أصناف', () {
    final ops = [
      op(kind: EntityKind.item, type: OpKind.create, id: 'item-1', payload: {}),
      op(kind: EntityKind.itemCategory, type: OpKind.create, id: 'cat-1', payload: {}),
      op(kind: EntityKind.section, type: OpKind.create, id: 'sec-1', payload: {}),
    ];
    final sorted = sortOperationsByDependency(ops);
    expect(
      sorted.map((o) => o.entityId).toList(),
      ['sec-1', 'cat-1', 'item-1'],
      reason: 'القسم أولاً ثم الفئة ثم الصنف/المنتج',
    );
  });

  test('CATALOG-SYNC-01 استيعاب صنف بفرز بدون قسم وافتراضات نشط وغير محذوف', () async {
    final db = await repo.database;
    final itemOp = op(
      kind: EntityKind.item,
      type: OpKind.create,
      id: '999',
      payload: {
        'id': 999,
        'name': 'منتج سحابي جديد',
        'buy_price': 100,
        'sell_price': 150,
      },
    );
    final ok = await db.transaction(
        (txn) => repo.applyRemoteOperation(txn, itemOp, ConflictResolver()));
    expect(ok, isTrue);

    final items = await repo.items();
    final item = items.firstWhere((i) => i.id == 999);
    expect(item.name, 'منتج سحابي جديد');
    expect(item.isDeleted, isFalse);
    expect(item.isActive, isTrue);
    expect(item.category, isEmpty);
    expect(item.categoryId, isNull);
  });
}
