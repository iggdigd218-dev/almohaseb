import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/ui/home_shell.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_rbac_test_');
    db = await databaseFactory.openDatabase(
      '${tmp.path}/test_rbac.db',
      options: OpenDatabaseOptions(
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  });

  tearDown(() async {
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('1. تصحيح الدور الافتراضي وإنشاء الصلاحيات (User Creation & Permissions)', () {
    test('إنشاء مستخدم كاشير يحفظ دوره صراحة وينشئ صف user_permissions مقيد', () async {
      // ننشئ المدير أولاً كبذرة
      final adminUser = AppUser(
        name: 'المدير العام',
        role: UserRole.admin,
        isMe: true,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final adminId = await repo.saveUser(adminUser);
      expect(adminId, isPositive);

      // الآن نضيف كاشير جديد بدور cashier صريح
      final cashierUser = AppUser(
        name: 'أحمد الكاشير',
        role: UserRole.cashier,
        isMe: false,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final cashierId = await repo.saveUser(cashierUser);

      // التحقق من جدول users
      final userRows = await db.query('users', where: 'id = ?', whereArgs: [cashierId]);
      expect(userRows, isNotEmpty);
      expect(userRows.first['role'], 'cashier');
      expect(userRows.first['name'], 'أحمد الكاشير');

      // التحقق من إنشاء صف user_permissions المطابق تلقائياً
      final permRows = await db.query(
        'user_permissions',
        where: 'user_id = ?',
        whereArgs: [cashierId],
      );
      expect(permRows, isNotEmpty, reason: 'يجب إنشاء صف في user_permissions فوراً');
      expect(permRows.first['role'], 'cashier');
      expect(permRows.first['can_discount'], 0, reason: 'الخصم مقفل افتراضياً للكاشير');
      expect(permRows.first['can_delete_tx'], 0, reason: 'حذف العمليات مقفل للكاشير');
      expect(permRows.first['can_view_reports'], 0, reason: 'عرض التقارير مقفل للكاشير');
      expect(permRows.first['can_manage_items'], 0, reason: 'إدارة المنتجات مقفلة للكاشير');
    });
  });

  group('2. فصل صلاحية الجهاز عن صلاحية المستخدم (Device Owner vs Active User)', () {
    test('الجهاز is_owner = 1 لا يمنح رتبة مدير إذا كان المستخدم الحالي كاشير', () async {
      // نضمن أن الجهاز مسجل كـ is_owner = 1
      await db.update('devices', {'is_owner': 1});
      expect(await repo.isWorkspaceOwner(), isTrue);

      // إنشاء مستخدم كاشير وتعيينه كمستخدم حالي (is_me = 1)
      final cashier = AppUser(
        name: 'سعيد الكاشير',
        role: UserRole.cashier,
        isMe: true,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      // أول مستخدم بذرة مدير
      await repo.saveUser(AppUser(
        name: 'المدير',
        role: UserRole.admin,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      final cashierId = await repo.saveUser(cashier);
      await repo.setCurrentUser(cashierId);

      // الفحص: currentUser() يجب أن يرجع الكاشير وليس المدير
      final current = await repo.currentUser();
      expect(current, isNotNull);
      expect(current!.name, 'سعيد الكاشير');
      expect(current.role, UserRole.cashier);
      expect(current.role, isNot(UserRole.admin));

      // الفحص: effectivePermissions() يجب ألا تكون full بل مقيدة للكاشير
      final perms = await repo.effectivePermissions();
      expect(perms.isAdmin, isFalse, reason: 'لا يُمنح رتبة مدير لمجرد أن الجهاز is_owner');
      expect(perms.role, 'cashier');
      expect(perms.canDiscount, isFalse);
      expect(perms.canDeleteTx, isFalse);
      expect(perms.canViewReports, isFalse);
      expect(perms.canManageItems, isFalse);

      // الفحص: can('delete_tx') يجب أن تكون false
      expect(await repo.can('delete_tx'), isFalse);
      expect(await repo.can('manage_users'), isFalse);
      expect(await repo.can('add_tx'), isTrue); // الكاشير يضيف عمليات بيع
    });
  });

  group('3. قائمة الدرج وحظر الشاشات المقيدة (Drawer Items & Screen Restrictions)', () {
    test('الكاشير تُحجب عنه شاشات الحسابات والإعدادات والتقارير والنسخ وسلة المهملات', () {
      final cashier = AppUser(
        id: 5,
        name: 'كاشير المحل',
        role: UserRole.cashier,
        permissions: defaultPerms(UserRole.cashier),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final visibleScreens = DrawerItems.of(
        user: cashier,
        isOwner: true, // حتى لو كان الجهاز هو المالك
        workspaceMode: 'standalone',
      );

      // الشاشات المحجوبة عن الكاشير
      expect(visibleScreens.contains(AppScreen.accounts), isFalse, reason: 'الحسابات محجوبة عن الكاشير');
      expect(visibleScreens.contains(AppScreen.transactions), isFalse, reason: 'العمليات محجوبة عن الكاشير');
      expect(visibleScreens.contains(AppScreen.settings), isFalse, reason: 'الإعدادات محجوبة عن الكاشير');
      expect(visibleScreens.contains(AppScreen.reports), isFalse, reason: 'التقارير محجوبة عن الكاشير');
      expect(visibleScreens.contains(AppScreen.inventory), isFalse, reason: 'المخزون محجوب عن الكاشير');
      expect(visibleScreens.contains(AppScreen.trash), isFalse, reason: 'سلة المهملات محجوبة عن الكاشير');
      expect(visibleScreens.contains(AppScreen.backup), isFalse, reason: 'النسخ الاحتياطي محجوب عن الكاشير');
      expect(visibleScreens.contains(AppScreen.group), isFalse, reason: 'إدارة المجموعة محجوبة عن الكاشير');

      // الشاشة المتاحة للكاشير
      expect(visibleScreens.contains(AppScreen.pos), isTrue, reason: 'نقطة البيع متاحة للكاشير');
    });

    test('المدير تظهر له كافة الشاشات والإعدادات', () {
      final admin = AppUser(
        id: 1,
        name: 'المدير العام',
        role: UserRole.admin,
        permissions: defaultPerms(UserRole.admin),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final visibleScreens = DrawerItems.of(
        user: admin,
        isOwner: true,
        workspaceMode: 'standalone',
      );

      expect(visibleScreens.contains(AppScreen.accounts), isTrue);
      expect(visibleScreens.contains(AppScreen.transactions), isTrue);
      expect(visibleScreens.contains(AppScreen.settings), isTrue);
      expect(visibleScreens.contains(AppScreen.reports), isTrue);
      expect(visibleScreens.contains(AppScreen.inventory), isTrue);
      expect(visibleScreens.contains(AppScreen.pos), isTrue);
      expect(visibleScreens.contains(AppScreen.trash), isTrue);
      expect(visibleScreens.contains(AppScreen.backup), isTrue);
    });
  });
}
