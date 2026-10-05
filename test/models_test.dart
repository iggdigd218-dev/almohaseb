import 'package:flutter_test/flutter_test.dart';

import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/format.dart';
import 'package:nexora_app/core/models.dart';

void main() {
  group('Fmt.phoneDigits', () {
    test('يزيل الرموز ويترك الأرقام فقط', () {
      expect(Fmt.phoneDigits('+967 777-123-456'), '+967777123456');
      expect(Fmt.phoneDigits('(777) 123 456'), '777123456');
      expect(Fmt.phoneDigits(''), '');
    });
  });

  group('Tx defaults', () {
    test('syncState افتراضياً synced', () {
      final now = DateTime.now();
      final tx = Tx(
        type: OpType.inflow,
        amount: 1000,
        date: now,
        createdAt: now,
        updatedAt: now,
      );
      expect(tx.syncState, 'synced');
      expect(tx.status, 'done');
    });

    test('copyWith syncState', () {
      final now = DateTime.now();
      final tx = Tx(
        type: OpType.debit,
        amount: 500,
        date: now,
        createdAt: now,
        updatedAt: now,
      );
      final tx2 = tx.copyWith(syncState: 'pending');
      expect(tx2.syncState, 'pending');
      expect(tx2.amount, 500);
    });

    test('toMap/fromMap roundtrip', () {
      final now = DateTime.parse('2026-09-06T02:00:00Z');
      final tx = Tx(
        type: OpType.revenue,
        amount: 15000,
        date: now,
        createdAt: now,
        updatedAt: now,
        reference: '123',
        syncState: 'pending',
        description: 'فاتورة تجريبية',
        createdByUserId: 10,
        cashierName: 'خالد الكاشير',
      );
      final m = tx.toMap();
      expect(m['sync_state'], 'pending');
      expect(m['created_by_user_id'], 10);
      expect(m['cashier_name'], 'خالد الكاشير');
      final back = Tx.fromMap({...m, 'id': 1});
      expect(back.syncState, 'pending');
      expect(back.amount, 15000);
      expect(back.reference, '123');
      expect(back.createdByUserId, 10);
      expect(back.cashierName, 'خالد الكاشير');
    });
  });

  group('AppUser & Granular Permissions', () {
    test('AppUser has canApplyDiscount permission field', () {
      final user = AppUser(
        id: 1,
        name: 'مدير المتجر',
        email: 'admin@nexora.ye',
        role: UserRole.admin,
        pin: '1234',
        password: '',
        permissions: const {'can_discount': true},
        isMe: true,
        active: true,
        canApplyDiscount: true,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(user.canApplyDiscount, isTrue);
      expect(user.role, UserRole.admin);
    });

    test('Voucher attribution preserves createdByUserId and cashierName', () {
      final now = DateTime.now();
      final v = Voucher(
        number: 'V-101',
        kind: VoucherKind.receipt,
        amount: 25000,
        currency: 'YER',
        statement: 'قبض مبيعات',
        createdByUserId: 15,
        cashierName: 'عمر المحاسب',
        date: now,
        createdAt: now,
        updatedAt: now,
      );
      final m = v.toMap();
      expect(m['created_by_user_id'], 15);
      expect(m['cashier_name'], 'عمر المحاسب');

      final restored = Voucher.fromMap({...m, 'id': 5});
      expect(restored.id, 5);
      expect(restored.createdByUserId, 15);
      expect(restored.cashierName, 'عمر المحاسب');
    });
  });
}
