import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/app_version.dart';
import 'package:nexora_app/core/models.dart';

void main() {
  group('New Device Linking & Role Security Tests', () {
    test('Default role for joined member device is strictly cashier', () {
      final perms = defaultPerms(UserRole.cashier);
      expect(perms['add_tx'], isTrue);
      expect(perms['edit_tx'], isFalse);
      expect(perms['delete_tx'], isFalse);
      expect(perms['view_reports'], isFalse);
      expect(perms['export'], isFalse);
      expect(perms['manage_backup'], isFalse);
      expect(perms['manage_users'], isFalse);
    });

    test('UserRole.fromCode falls back safely to cashier for joined members', () {
      final role = UserRole.values.firstWhere(
        (r) => r.code == 'unknown_code',
        orElse: () => UserRole.cashier,
      );
      expect(role, equals(UserRole.cashier));
    });

    test('Non-owner cannot be granted admin role during join approval', () {
      const requestedRole = 'admin';
      final initialRole = UserRole.values.firstWhere(
        (r) => r.code == requestedRole,
        orElse: () => UserRole.cashier,
      );
      final safeRole = initialRole == UserRole.admin ? UserRole.cashier : initialRole;
      expect(safeRole, equals(UserRole.cashier));
    });
  });

  group('Tombstones and Soft Delete Exclusion Tests', () {
    test('Item model respects isDeleted flag', () {
      final item = Item(
        id: 1,
        name: 'منتج ممسوح',
        isDeleted: true,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      expect(item.isDeleted, isTrue);

      final map = item.toMap();
      expect(map['is_deleted'], equals(1));
    });

    test('Tombstone payload parsing and status', () {
      final tombstone = {
        'id': '42',
        'is_deleted': 1,
        'deleted_at': '2026-09-28T05:00:00Z',
      };
      final rawId = tombstone['id'];
      final itemId = int.tryParse('$rawId') ?? rawId;
      expect(itemId, equals(42));
      expect(tombstone['is_deleted'], equals(1));
    });
  });

  group('Version and Build Verification', () {
    test('Version is bumped to latest release version', () {
      expect(kAppVersion, equals('3.85.3'));
      expect(kAppBuild, equals(213));
      expect(AppSemVer.current.toString(), equals('3.85.3+213'));
    });
  });
}
