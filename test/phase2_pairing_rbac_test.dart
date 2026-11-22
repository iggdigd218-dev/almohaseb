import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/snapshot_apply.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  final now = DateTime.now().toIso8601String();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('phase2_rbac_');
    db = await databaseFactory.openDatabase('${tmp.path}/member_device.db');
    await AppDatabase.createSchema(db);

    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'MEMBER-DEV-001');
    await repo.initSyncInfra();

    // نضع بيانات قديمة محلية على الجهاز قبل الانضمام (ملف شخصي قديم وكاش)
    await repo.setSetting('businessName', 'دكان محلي قديم سيُمسح');
    await repo.setSetting('phone', '777000111');
    await repo.setSetting('user_name', 'مستخدم قديم');
    await repo.setSetting('profile_name', 'اسم محلي قديم');
    await repo.setSetting('logo', '/old/path/logo.png');
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  group('المرحلة 2: تطهير بيانات الجهاز المنضم وعزل الصلاحيات (Pairing & RBAC)', () {
    test('1. عند انضمام الجهاز يتم تطهير المخلفات القديمة تماماً ووراثة بيانات المنشأة كمرآة',
        () async {
      // تجهيز لقطة المنشأة من السحابة/المدير
      final workspaceSnapshot = <String, Object?>{
        'workspaces': [
          {'id': 'WS-ENTERPRISE-99', 'name': 'مؤسسة النور للتجارة'}
        ],
        'users': [
          {
            'id': 100,
            'name': 'المالك العام',
            'role': 'admin',
            'permissions': '',
            'is_me': 1,
            'active': 1,
            'workspace_id': 'WS-ENTERPRISE-99',
            'created_at': now,
            'updated_at': now,
          }
        ],
        'devices': [
          {
            'id': 'OWNER-DEV-HOST',
            'workspace_id': 'WS-ENTERPRISE-99',
            'name': 'جهاز المالك',
            'is_owner': 1,
            'is_paired': 1,
            'user_id': 100,
            'created_at': now,
            'updated_at': now,
          }
        ],
        'orgSettings': {
          'businessName': 'مؤسسة النور للتجارة الحديثة',
          'phone': '777999888',
          'address': 'صنعاء - شارع الستين',
          'org.icon.b64': 'base64_logo_data_example',
        },
      };

      // تطبيق اللقطة (SnapshotApply) كما يحدث عند الانضمام السحابي
      await SnapshotApply.applySnapshot(
        () async => db,
        'MEMBER-DEV-001',
        workspaceSnapshot,
      );

      // التحقق الصارم: مسح أي إعدادات ومخلفات قديمة
      final st = await repo.settings();
      expect(st['user_name'], isNull);
      expect(st['profile_name'], isNull);
      expect(st['logo'], isNull);

      // التحقق الصارم: وراثة بيانات المنشأة المعتمدة حصراً
      expect(st['businessName'], equals('مؤسسة النور للتجارة الحديثة'));
      expect(st['phone'], equals('777999888'));
      expect(st['address'], equals('صنعاء - شارع الستين'));
      expect(st['org.icon.b64'], equals('base64_logo_data_example'));

      // التحقق الصارم: الجهاز المنضم مسجل كعضو وليس كمالك
      final isOwner = await repo.isWorkspaceOwner();
      expect(isOwner, isFalse);

      final mode = await repo.workspaceMode();
      expect(mode, equals('member'));
    });

    test('2. تثبيت رتبة الكاشير الصارمة للجهاز المنضم ومنع تصعيد الصلاحيات',
        () async {
      // تطبيق الانضمام
      final workspaceSnapshot = <String, Object?>{
        'workspaces': [
          {'id': 'WS-MAIN', 'name': 'الفرع الرئيسي'}
        ],
        'users': [
          {
            'id': 1,
            'name': 'المدير',
            'role': 'admin',
            'is_me': 1,
            'active': 1,
            'created_at': now,
            'updated_at': now,
          }
        ],
        'devices': [
          {
            'id': 'OWNER-DEV',
            'workspace_id': 'WS-MAIN',
            'name': 'الرئيسي',
            'is_owner': 1,
            'is_paired': 1,
            'user_id': 1,
            'created_at': now,
            'updated_at': now,
          }
        ],
        'orgSettings': {'businessName': 'الفرع الرئيسي'},
      };

      await SnapshotApply.applySnapshot(
        () async => db,
        'MEMBER-DEV-001',
        workspaceSnapshot,
      );

      // إنشاء المستخدم الخاص بالجهاز المنضم برتبة كاشير كما يفعل CloudJoin
      final cashierPerms = defaultPerms(UserRole.cashier);
      final cashierPermStr = cashierPerms.entries
          .where((e) => e.value)
          .map((e) => e.key)
          .join(',');

      final memberUid = await db.insert('users', {
        'name': 'كاشير الفرع',
        'role': 'cashier',
        'permissions': cashierPermStr,
        'is_me': 1,
        'active': 1,
        'workspace_id': 'WS-MAIN',
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await db.update(
        'devices',
        {'user_id': memberUid, 'is_owner': 0},
        where: 'id = ?',
        whereArgs: ['MEMBER-DEV-001'],
      );

      // التحقق الصارم: المستخدم الحالي هو كاشير وليس مدير
      final currentUser = await repo.currentUser();
      expect(currentUser, isNotNull);
      expect(currentUser!.role, equals(UserRole.cashier));
      expect(currentUser.isMe, isTrue);

      // التحقق الصارم: صلاحيات الإدارة محجوبة تماماً عن الكاشير
      expect(currentUser.can('manage_users'), isFalse);
      expect(currentUser.can('delete_tx'), isFalse);
      expect(currentUser.can('export'), isFalse);
      expect(currentUser.can('manage_backup'), isFalse);
      expect(currentUser.can('view_reports'), isFalse);

      // لكن لديه صلاحيات البيع الأساسية
      expect(currentUser.can('add_tx'), isTrue);
    });
  });
}
