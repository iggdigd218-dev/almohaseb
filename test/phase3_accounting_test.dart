import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/pos_cart.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  final now = DateTime.now();
  final nowIso = now.toIso8601String();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('phase3_acc_');
    db = await databaseFactory.openDatabase('${tmp.path}/acc_test.db');
    await AppDatabase.createSchema(db);

    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'DEV-PHASE3');
    await repo.initSyncInfra();

    // Setup Admin user
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
        where: 'id = ?', whereArgs: ['DEV-PHASE3']);
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  group('المرحلة 3: النواة المحاسبية والمبيعات والذرّية (POS & Accounting Engine)', () {
    test('1. الذرّية والتراجع الكامل (Atomic Transactions & Rollback)', () async {
      // التأكد من أن حفظ الفاتورة مع بنودها يتم ذرياً
      final item1Id = await repo.saveItem(Item(
        name: 'بيبسي عائلي',
        buyPrice: 500,
        sellPrice: 700,
        quantity: 50,
        createdAt: now,
        updatedAt: now,
      ));

      final lines = [
        InvoiceLine(
          itemId: item1Id,
          name: 'بيبسي عائلي',
          quantity: 2,
          unitPrice: 700,
        ),
      ];

      final tx = Tx(
        type: OpType.revenue,
        amount: 1400,
        currency: 'YER',
        date: now,
        description: 'فاتورة نقدية رقم 1',
        createdAt: now,
        updatedAt: now,
      );

      final txId = await repo.saveTx(tx, items: lines);
      expect(txId, isPositive);

      // التحقق من اكتمال حفظ العملية والسطور وطابور المزامنة معاً
      final txRows = await db.query('transactions', where: 'id = ?', whereArgs: [txId]);
      expect(txRows, hasLength(1));

      final lineRows = await db.query('transaction_items', where: 'tx_id = ?', whereArgs: [txId]);
      expect(lineRows, hasLength(1));

      final opRows = await db.query('operations',
          where: "entity_type = 'tx' AND entity_id = ?", whereArgs: ['$txId']);
      expect(opRows, hasLength(1));

      // محاكاة فشل في معاملة ذرية للتحقق من عدم بقاء أي سجلات يتيمة
      try {
        await db.transaction((txn) async {
          await txn.insert('transactions', {
            'id': 999999,
            'type': 'revenue',
            'amount': 500,
            'currency': 'YER',
            'date': nowIso,
            'created_at': nowIso,
            'updated_at': nowIso,
          });
          // نرمي خطأ عمداً لمحاكاة تعطل خطوة فرعية
          throw Exception('Simulated crash during atomic transaction');
        });
      } catch (_) {}

      // التحقق من تراجع المعاملة بالكامل (Rollback) وعدم وجود سجل 999999
      final rolledBack = await db.query('transactions', where: 'id = ?', whereArgs: [999999]);
      expect(rolledBack, isEmpty, reason: 'يجب التراجع الكامل عند فشل أي خطوة فرعية');
    });

    test('2. العمليات المالية، سقف الخصم ودقة التقريب العشري', () {
      final item = Item(
        id: 1,
        name: 'منتج محاسبي',
        buyPrice: 33.33,
        sellPrice: 50.00,
        quantity: 100,
        createdAt: now,
        updatedAt: now,
      );

      // إنشاء سلة نقطة بيع
      var draft = const PosDraft(
        payment: 'cash',
        paidText: '',
        discountText: '10', // خصم 10%
        discountIsPercent: true,
      );

      final notifier = PosDraftNotifier();
      notifier.restore(draft);
      notifier.addItem(item, allowNegative: false, quantity: 3); // 3 * 50 = 150

      final state = notifier.state;
      expect(state.subtotal, equals(150.0));
      expect(state.discountValue, equals(15.0)); // 10% من 150 = 15
      expect(state.netTotal, equals(135.0));

      // اختبار منع تجاوز الخصم لسقف الفاتورة (مبلغ مقطوع أكبر من الإجمالي)
      notifier.setDiscountIsPercent(false);
      notifier.setDiscount('200'); // خصم 200 على فاتورة بـ 150
      expect(notifier.state.discountValue, equals(150.0),
          reason: 'لا يجوز أن يتجاوز الخصم إجمالي الفاتورة');
      expect(notifier.state.netTotal, equals(0.0));

      // اختبار التقريب المالي للكسور العشرية
      notifier.setDiscountIsPercent(true);
      notifier.setDiscount('12.345'); // نسبة كسرية
      expect(notifier.state.discountValue, isA<double>());
      expect(notifier.state.netTotal, isA<double>());
      expect(notifier.state.netTotal, equals(
          ((150.0 - notifier.state.discountValue) * 100).roundToDouble() / 100.0));
    });

    test('3. قيود الكاشير: حظر حذف الفواتير بدون إذن/صلاحية المشرف', () async {
      // إضافة فاتورة من قبل النظام
      final txId = await repo.saveTx(Tx(
        type: OpType.revenue,
        amount: 800,
        currency: 'YER',
        date: now,
        description: 'فاتورة للمعاينة',
        createdAt: now,
        updatedAt: now,
      ));

      // تبديل المستخدم الحالي إلى كاشير وتصفير is_me للمستخدمين السابقين
      await db.update('users', {'is_me': 0});
      final cashierPerms = defaultPerms(UserRole.cashier);
      final cashierPermStr = cashierPerms.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .join(',');

      await db.insert('users', {
        'id': 2,
        'name': 'كاشير الورديات',
        'role': 'cashier',
        'permissions': cashierPermStr,
        'is_me': 1,
        'active': 1,
        'created_at': nowIso,
        'updated_at': nowIso,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await db.insert('sync_meta', {
        'key': 'workspaceMode',
        'value': 'member',
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // جهاز عضو
      await db.update('devices', {'user_id': 2, 'is_owner': 0},
          where: 'id = ?', whereArgs: ['DEV-PHASE3']);

      // محاولة حذف الفاتورة من قبل الكاشير يجب أن تُحظر برمجيًا
      expect(
        () async => await repo.deleteTx(txId),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('ليس لديك صلاحية'),
        )),
      );

      // الفاتورة ما زالت موجودة وسليمة
      final tx = await repo.transactionById(txId);
      expect(tx, isNotNull);
      expect(tx!.amount, equals(800));
    });
  });
}
