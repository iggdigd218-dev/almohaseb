// (3.70 — المرحلة 4) الصلاحيات المحلية RBAC.
//
// المرجع الحصري للملكية والصلاحيات: المستخدم الفعّال في الجلسة الحالية
// (currentSessionUser) مع صلاحياته المحددة — فصل تام عن ملكية العتاد/الجهاز (is_owner).
// الفحص محلي فوري (Offline-Ready): تُحجب أزرار الخصم والحذف والتقارير
// والأصناف والإعدادات عن الكاشير والمستخدم المقيد دون انتظار أي شبكة.
import 'models.dart';

/// الأعلام النافذة للمستخدم الحالي — تُبنى من جدول user_permissions أو
/// تُشتق من الدور/الصلاحيات القديمة كجسر توافق.
class EffectivePermissions {
  final String email;
  final String role;
  final bool canDiscount;
  final bool canDeleteTx;
  final bool canViewReports;
  final bool canManageItems;
  final bool isActive;
  final bool isAdmin;

  const EffectivePermissions({
    required this.email,
    required this.role,
    required this.canDiscount,
    required this.canDeleteTx,
    required this.canViewReports,
    required this.canManageItems,
    required this.isActive,
    required this.isAdmin,
  });

  /// مدير/وكيل: كل شيء مفتوح.
  factory EffectivePermissions.full(String email) => EffectivePermissions(
        email: email,
        role: 'admin',
        canDiscount: true,
        canDeleteTx: true,
        canViewReports: true,
        canManageItems: true,
        isActive: true,
        isAdmin: true,
      );

  /// كاشير أو مستخدم مقيد: أصفار في الصلاحيات الحساسة (fail-closed).
  factory EffectivePermissions.none(String email) => EffectivePermissions(
        email: email,
        role: 'cashier',
        canDiscount: false,
        canDeleteTx: false,
        canViewReports: false,
        canManageItems: false,
        isActive: true,
        isAdmin: false,
      );

  /// صلاحيات مالك الحساب (مدير النظام).
  factory EffectivePermissions.owner(String email) =>
      EffectivePermissions.full(email);

  factory EffectivePermissions.fromRow(Map<String, Object?> r) {
    final role = '${r['role'] ?? ''}'.trim().toLowerCase();
    final admin = role == 'admin' || role == 'agent' || role == 'owner';
    int flag(String k) => (r[k] as int?) ?? 0;
    return EffectivePermissions(
      email: '${r['user_email'] ?? ''}',
      role: role.isEmpty ? 'cashier' : role,
      canDiscount: admin || flag('can_discount') == 1,
      canDeleteTx: admin || flag('can_delete_tx') == 1,
      canViewReports: admin || flag('can_view_reports') == 1,
      canManageItems: admin || flag('can_manage_items') == 1,
      isActive: flag('is_active') == 1,
      isAdmin: admin,
    );
  }
}

/// اشتقاق الأعلام من دور + قائمة صلاحيات النموذج (جسر توافق).
EffectivePermissions deriveFromRolePerms(
    String email, String roleCode, String permsCsv) {
  final cleanRole = roleCode.trim().toLowerCase();
  final perms = permsCsv.split(',').map((e) => e.trim()).toSet();
  final admin = cleanRole == 'admin' || cleanRole == 'agent' || cleanRole == 'owner';
  final advanced = roleGrantsAdvancedCode(cleanRole);
  return EffectivePermissions(
    email: email,
    role: cleanRole.isEmpty ? 'cashier' : cleanRole,
    canDiscount: admin || advanced || perms.contains('can_discount'),
    canDeleteTx: admin || perms.contains('delete_tx'),
    canViewReports: admin || perms.contains('view_reports'),
    canManageItems: admin || advanced || perms.contains('manage_items') || perms.contains('edit_tx'),
    isActive: true,
    isAdmin: admin,
  );
}

bool roleGrantsAdvancedCode(String code) =>
    code == 'admin' || code == 'agent' || code == 'accountant' ||
    code == 'owner';

bool roleGrantsAdvanced(UserRole r) => roleGrantsAdvancedCode(r.code);
