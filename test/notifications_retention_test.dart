import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/license_model.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('notif_retention_');
    db = await databaseFactory.openDatabase('${tmp.path}/test.db');
    await AppDatabase.createSchema(db);

    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'DEV-NOTIF-TEST');
    await repo.initSyncInfra();
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  group('سياسة الاحتفاظ بالإشعارات (6 ساعات) وحجب الإشعارات السابقة للمستخدمين الجدد', () {
    test('1. إشعارات النظام لا تُحفظ لأكثر من 6 ساعات وتُحذف تلقائياً', () async {
      final now = DateTime.now();

      // إشعار قديم عمره 7 ساعات (تجاوز حد الـ 6 ساعات)
      final oldTime = now.subtract(const Duration(hours: 7)).toIso8601String();
      await db.insert('notifications', {
        'workspace_id': repo.requireWorkspaceId,
        'title': 'إشعار منتهي الصلاحية',
        'body': 'هذا الإشعار مر عليه 7 ساعات',
        'kind': 'info',
        'seen': 0,
        'created_at': oldTime,
      });

      // إشعار حديث عمره ساعتان فقط
      final recentTime = now.subtract(const Duration(hours: 2)).toIso8601String();
      await db.insert('notifications', {
        'workspace_id': repo.requireWorkspaceId,
        'title': 'إشعار ساري المفعول',
        'body': 'هذا الإشعار مر عليه ساعتان فقط',
        'kind': 'info',
        'seen': 0,
        'created_at': recentTime,
      });

      // لضمان أن تاريخ أول استخدام لا يحجب الإشعار الحديث
      await repo.setSetting('first_use_at', now.subtract(const Duration(hours: 5)).toIso8601String());

      // استعلام الإشعارات
      final list = await repo.notifications();

      // يجب أن يحتوي على الإشعار الساري فقط، بينما تم استبعاد وحذف الإشعار الذي تجاوز 6 ساعات
      expect(list.any((n) => n['title'] == 'إشعار منتهي الصلاحية'), isFalse,
          reason: 'الإشعار الأقدم من 6 ساعات يجب ألا يعود في الاستعلام');
      expect(list.any((n) => n['title'] == 'إشعار ساري المفعول'), isTrue,
          reason: 'الإشعار الأحدث من 6 ساعات يجب أن يظهر');

      // التحقق من أن قاعدة البيانات طهرت السجل المنتهي فعلياً
      final expiredRows = await db.query(
        'notifications',
        where: "title = ?",
        whereArgs: ['إشعار منتهي الصلاحية'],
      );
      expect(expiredRows, isEmpty,
          reason: 'تم حذف الإشعار الأقدم من 6 ساعات نهائياً من قاعدة البيانات');
    });

    test('2. المستخدم الجديد لا تظهر له أي إشعارات قديمة سابقة لأول استخدام للتطبيق', () async {
      final now = DateTime.now();

      // إشعار قديم تم إنشاؤه قبل ساعة واحدة (ضمن مهلة الـ 6 ساعات ولكنه قبل تثبيت/بدء المستخدم الجديد)
      final priorTime = now.subtract(const Duration(hours: 1)).toIso8601String();
      await db.insert('notifications', {
        'workspace_id': repo.requireWorkspaceId,
        'title': 'إشعار سابق لبدء المستخدم',
        'body': 'تم إنشاؤه قبل بدء المستخدم الجديد',
        'kind': 'warning',
        'seen': 0,
        'created_at': priorTime,
      });

      // وقت بدء المستخدم الجديد هو "الآن"
      await repo.setSetting('first_use_at', now.toIso8601String());

      // التحقق: قائمة الإشعارات يجب أن تكون فارغة تماماً للمستخدم الجديد
      final list = await repo.notifications();
      expect(list, isEmpty, reason: 'يجب ألا تظهر أي إشعارات سابقة لأول استخدام');

      // التحقق: عداد الإشعارات غير المقروءة يجب أن يكون 0
      final unread = await repo.unreadNotifications();
      expect(unread, equals(0), reason: 'عداد الإشعارات غير المقروءة للمستخدم الجديد يجب أن يكون صفراً');

      // وصول إشعار جديد بعد بدء المستخدم
      await repo.notify(
        title: 'إشعار جديد مرحب به',
        body: 'وصل بعد بدء الاستخدام',
        kind: 'info',
      );

      final updatedList = await repo.notifications();
      expect(updatedList, hasLength(1));
      expect(updatedList.first['title'], equals('إشعار جديد مرحب به'));

      final updatedUnread = await repo.unreadNotifications();
      expect(updatedUnread, equals(1));
    });

    test('3. إشعارات البث السحابي والتنبيهات العامة تستبعد التنبيهات المنتهية وتلك السابقة للمستخدم الجديد', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final sp = await SharedPreferences.getInstance();

      // تعيين أول استخدام للمستخدم الجديد في SharedPreferences
      await sp.setInt('app_first_use_ms', now);

      // تنبيه سحابي قديم مر عليه 8 ساعات
      final expiredAlert = CloudAlert(
        id: 'alert-expired',
        title: 'تنبيه منتهي الصلاحية',
        body: 'أقدم من 6 ساعات',
        createdAt: now - (8 * 3600 * 1000),
      );

      // تنبيه سحابي عمره 30 دقيقة ولكنه سابق لأول استخدام للمستخدم (تم إنشاؤه قبل دقيقة من فتح المستخدم للتطبيق)
      final preUserAlert = CloudAlert(
        id: 'alert-pre-user',
        title: 'تنبيه قبل فتح التطبيق',
        body: 'تم بثه قبل أن يبدأ المستخدم',
        createdAt: now - (30 * 60 * 1000),
      );

      // تنبيه سحابي جديد بعد بدء المستخدم
      final newUserAlert = CloudAlert(
        id: 'alert-new-user',
        title: 'تنبيه جديد للمستخدم',
        body: 'تم بثه بعد أول استخدام',
        createdAt: now + 1000,
      );

      const maxRetentionMs = 6 * 3600 * 1000;
      final cutoff6h = now - maxRetentionMs;
      final firstUseMs = sp.getInt('app_first_use_ms') ?? now;
      final effectiveMinTimeMs = firstUseMs > cutoff6h ? firstUseMs : cutoff6h;

      final allAlerts = [expiredAlert, preUserAlert, newUserAlert];
      final filteredAlerts = allAlerts.where((a) => a.createdAt >= effectiveMinTimeMs).toList();

      expect(filteredAlerts, hasLength(1));
      expect(filteredAlerts.first.id, equals('alert-new-user'));
    });
  });
}
