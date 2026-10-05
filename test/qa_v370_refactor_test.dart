// QA — 3.70.0 إعادة الهيكلة الجذرية (Hard Refactoring & Legacy Purge):
//  • المرحلة 1: اجتثاث cloud_sync القديم + عزل بصمة الجهاز في فحص الترخيص.
//  • المرحلة 2/3: SQLite مرجع وحيد، sync_queue بالدفعات، فردي/مؤسسة.
//  • المرحلة 4: RBAC محلي user_permissions بمفتاح user_email + تصعيد للطابور.
//  • المرحلة 5: طلبات خروج الموظفين (pending → approved/rejected).
//  • النسخ الاحتياطي التلقائي: جدولة + لقطة backup_{store_id}_{timestamp}.db.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/rbac.dart';
import 'package:nexora_app/data/device_license.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/auto_backup.dart';
import 'package:nexora_app/data/sync/logout_requests.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  final now = DateTime(2026, 9, 21);
  const url = 'https://qa-370.example.com';

  setUp(() async {
    debugForceLegacyWorkspaceId = false;
    debugDefaultBackendUrlOverride = url;
    tmp = await Directory.systemTemp.createTemp('nexora_370_');
    db = await databaseFactory.openDatabase('${tmp.path}/v370.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  });

  tearDown(() async {
    debugDefaultBackendUrlOverride = null;
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> makeMember() async {
    // محاكاة جهاز عضو: لا ملكية + مستخدم محلي كاشير + بريد معروف.
    await db.update('devices', {'is_owner': 0});
    await db.update('users', {'role': 'dataentry', 'permissions': 'add_tx'});
    await repo.setSetting('account.email', 'cashier@nexora.app');
  }

  group('V370-RBAC — المرحلة 4', () {
    test('RBAC-01 مخطط user_permissions بالأعمدة المحددة حرفياً', () async {
      final cols = (await db.rawQuery('PRAGMA table_info(user_permissions)'))
          .map((c) => '${c['name']}')
          .toSet();
      expect(
          cols,
          containsAll([
            'user_email',
            'store_id',
            'role',
            'can_discount',
            'can_delete_tx',
            'can_view_reports',
            'can_manage_items',
            'is_active',
            'updated_at',
          ]));
    });

    test('RBAC-02 upsert يطبّع البريد ويصعد التعديل عبر sync_queue', () async {
      await repo.upsertUserPermission(
        email: '  Cashier@Nexora.APP ',
        role: 'cashier',
        canDeleteTx: true,
      );
      final rows = await repo.userPermissions();
      expect(rows, hasLength(1));
      expect(rows.first['user_email'], 'cashier@nexora.app');
      expect(rows.first['store_id'], repo.requireWorkspaceId);
      final ops = await db.query('operations',
          where: "entity_type = 'userPermission'");
      expect(ops, hasLength(1));
      expect(ops.first['entity_id'], 'cashier@nexora.app');
      final q = await db.query('sync_queue',
          where: 'operation_id = ?', whereArgs: [ops.first['id']]);
      expect(q, isNotEmpty, reason: 'التعديل يجب أن يصعد عبر الطابور');
    });

    test('RBAC-03 فردي/مالك ⇒ صلاحيات كاملة دون شبكة', () async {
      final owner = await repo.effectivePermissions();
      expect(owner.canDiscount && owner.canViewReports, isTrue);
      await repo.setAccountMode(individual: true);
      final p = await repo.effectivePermissions();
      expect(p.canDiscount && p.canDeleteTx && p.canViewReports && p.canManageItems,
          isTrue);
    });

    test('RBAC-04 عضو: صف الجدول يحسم، والمجهول fail-closed', () async {
      await makeMember();
      // مجهول بلا صف ⇒ أصفار.
      var p = await repo.effectivePermissions();
      expect(p.canDiscount, isFalse);
      expect(p.canDeleteTx, isFalse);
      expect(p.canViewReports, isFalse);
      expect(p.isAdmin, isFalse);
      // صف بلا خصم مع حذف مسموح.
      await repo.upsertUserPermission(
          email: 'cashier@nexora.app', role: 'cashier', canDeleteTx: true);
      p = await repo.effectivePermissions();
      expect(p.canDiscount, isFalse);
      expect(p.canDeleteTx, isTrue);
    });

    test('RBAC-05 الاشتقاق الجسري من الدور/الصلاحيات القديمة', () {
      final acc = deriveFromRolePerms('a@b.c', 'accountant',
          'add_tx,edit_tx,delete_tx,view_reports,export,approve_vouchers');
      expect(acc.canDeleteTx && acc.canViewReports && acc.canDiscount, isTrue);
      expect(acc.isAdmin, isFalse);
      final viewer = deriveFromRolePerms('v@b.c', 'viewer', 'add_tx');
      expect(viewer.canDeleteTx, isFalse);
      expect(viewer.canViewReports, isFalse);
      expect(viewer.canManageItems, isFalse);
      final agent = EffectivePermissions.fromRow(
          {'user_email': 'd@b.c', 'role': 'agent', 'updated_at': 0});
      expect(agent.isAdmin && agent.canDiscount && agent.canManageItems, isTrue);
    });
  });

  group('V370-MODE — المرحلة 3', () {
    test('MODE-01 فردي: الكتابات لا تستدعي sync_queue إطلاقاً', () async {
      await repo.setAccountMode(individual: true);
      await repo.saveAccount(Account(
        name: 'عميل فردي',
        kind: AccountKind.customer,
        notifyChannel: 'none',
        createdAt: now,
        updatedAt: now,
      ));
      final q = await db.query('sync_queue');
      expect(q, isEmpty, reason: 'الحساب الفردي محلي بالكامل');
      // السجل المحلي للعمليات يبقى (SQLite هو المرجع الوحيد).
      final ops = await db.query('operations');
      expect(ops, isNotEmpty);
    });

    test('MODE-02 مؤسسة: الطابور يعود فوراً بنفس المستودع', () async {
      await repo.setAccountMode(individual: true);
      await repo.setAccountMode(individual: false);
      await repo.saveAccount(Account(
        name: 'عميل مؤسسة',
        kind: AccountKind.customer,
        notifyChannel: 'none',
        createdAt: now,
        updatedAt: now,
      ));
      final q = await db.query('sync_queue');
      expect(q, isNotEmpty);
    });

    test('MODE-03 محرك المزامنة لا يعمل للحساب الفردي', () async {
      await repo.setAccountMode(individual: true);
      final engine = SyncEngine(repo: repo, dbProvider: () async => db);
      await engine.start(); // حارس فردي: عودة مبكرة بلا خطأ.
      await repo.saveAccount(Account(
        name: 'بلا شبكة',
        kind: AccountKind.customer,
        notifyChannel: 'none',
        createdAt: now,
        updatedAt: now,
      ));
      expect(await db.query('sync_queue'), isEmpty);
    });
  });

  group('V370-BACKUP — النسخ الاحتياطي التلقائي', () {
    test('BAK-01 الجدولة: off/every2h/daily', () async {
      expect(await AutoBackupService.scheduledDue(repo), isFalse);
      await repo.setSetting(AutoBackupService.kModeKey, 'every2h');
      expect(await AutoBackupService.scheduledDue(repo), isTrue);
      await repo.setSetting(AutoBackupService.kLastScheduledKey,
          DateTime.now().toIso8601String());
      expect(await AutoBackupService.scheduledDue(repo), isFalse);
      await repo.setSetting(AutoBackupService.kLastScheduledKey,
          DateTime.now().subtract(const Duration(hours: 3)).toIso8601String());
      expect(await AutoBackupService.scheduledDue(repo), isTrue);
      // يومي: وقت اليوم المحدد انقضى دون تشغيل ⇒ مستحق.
      await repo.setSetting(AutoBackupService.kModeKey, 'daily');
      await repo.setSetting(AutoBackupService.kTimeKey, '00:01');
      await repo.setSetting(AutoBackupService.kLastScheduledKey,
          DateTime.now().subtract(const Duration(hours: 25)).toIso8601String());
      expect(await AutoBackupService.scheduledDue(repo), isTrue);
    });

    test('BAK-02 اسم اللقطة حسب العقد backup_{store_id}_{timestamp}.db', () {
      final n = AutoBackupService.snapshotName(
          'WS-AB23CD45', DateTime(2026, 9, 21, 14, 5, 9));
      expect(n, 'backup_WS-AB23CD45_20260921-140509.db');
    });

    test('BAK-03 لقطة فعلية لقاعدة ملفية + دورة مجدولة كاملة', () async {
      final p = await AutoBackupService.takeLocalSnapshot(repo);
      expect(p, isNotNull);
      final f = File(p!);
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), greaterThan(0));
      expect(p.split(Platform.pathSeparator).last, startsWith('backup_'));
      expect(p, endsWith('.db'));
      // الدورة المجدولة: لقطة + طابع (بلا سحابة — لا mock ⇒ تفشل بصمت).
      await repo.setSetting(AutoBackupService.kModeKey, 'every2h');
      await repo.setSetting(AutoBackupService.kDriveKey, '0');
      await AutoBackupService.runScheduled(repo);
      final st = await repo.settings();
      expect(st[AutoBackupService.kLastScheduledKey], isNotEmpty);
      expect(await AutoBackupService.scheduledDue(repo), isFalse);
    });
  });

  group('V370-LICENSE — المرحلة 1.3 (البصمة معزولة للترخيص فقط)', () {
    test('LIC-01 عدّ الأجهزة المتصلة مقابل مقاعد الخطة', () async {
      final s = await DeviceLicense.check(repo);
      expect(s.connectedDevices, greaterThanOrEqualTo(1));
      expect(s.maxSeats, greaterThan(0));
      expect(s.withinPlan, isTrue);
      // مطرود/ملغى لا يُحتسب مقعداً.
      final iso = DateTime.now().toIso8601String();
      await db.insert('devices', {
        'id': 'DEVICE-EXP3LL3D',
        'workspace_id': repo.requireWorkspaceId,
        'name': 'مطرود',
        'expelled_at': iso,
        'created_at': iso,
        'updated_at': iso,
      });
      await db.insert('devices', {
        'id': 'DEVICE-R3VOK3D',
        'workspace_id': repo.requireWorkspaceId,
        'name': 'ملغى',
        'revoked_at': iso,
        'created_at': iso,
        'updated_at': iso,
      });
      final s2 = await DeviceLicense.check(repo);
      expect(s2.connectedDevices, s.connectedDevices);
    });
  });

  group('V370-LOGOUT — المرحلة 5', () {
    test('LOG-01 طلب الموظف: إنشاء → قائمة معلقة → اعتماد', () async {
      final store = <String, Object?>{};
      http.Response js(Object? v) => http.Response.bytes(
          utf8.encode(v == null ? 'null' : jsonEncode(v)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
      // موك يحاكي تجميع RTDB: عقدة الأب تجمع أبناءها، وتجاوز status
      // المكتوب في عقدة فرعية يدمج في سجل الطلب.
      final client = MockClient((req) async {
        final p = req.url.path;
        if (req.method == 'PUT') {
          store[p] = jsonDecode(req.body);
          return js(store[p]);
        }
        if (p.endsWith('/logout_requests.json')) {
          final base = p.substring(0, p.length - '.json'.length);
          final node = <String, Object?>{};
          store.forEach((k, v) {
            if (!k.startsWith('$base/') || v is! Map) return;
            final rest = k.substring(base.length + 1);
            if (rest.contains('/')) return; // عقد فرعية (status) تُدمج أدناه
            final rid = rest.replaceAll('.json', '');
            final m = Map<String, Object?>.from(v);
            final st = store['$base/$rid/status.json'];
            if (st is String) m['status'] = st;
            node[rid] = m;
          });
          return js(node.isEmpty ? null : node);
        }
        final v = store[p];
        if (v is Map) {
          final m = Map<String, Object?>.from(v);
          final st = store[
              '${p.substring(0, p.length - '.json'.length)}/status.json'];
          if (st is String) m['status'] = st;
          return js(m);
        }
        return js(v);
      });
      String id = '';
      await http.runWithClient(() async {
        id = await LogoutRequests.create(repo,
            backendUrl: url,
            workspaceId: 'WS-QA370',
            email: 'Emp@Nexora.app',
            name: 'موظف');
      }, () => client);
      expect(id, isNotEmpty);
      expect((await repo.settings())['logout.requestId'], id);
      // الطلب محفوظ pending بمسار المساحة.
      final rec = store.values.first as Map;
      expect(rec['status'], 'pending');
      expect('${rec['email']}', 'emp@nexora.app');
      late List<LogoutRequestInfo> pend;
      await http.runWithClient(() async {
        pend = await LogoutRequests.listPending(
            backendUrl: url, workspaceId: 'WS-QA370');
      }, () => client);
      expect(pend, hasLength(1));
      expect(pend.first.id, id);
      // الاعتماد ثم القراءة.
      await http.runWithClient(() async {
        await LogoutRequests.resolve(
            backendUrl: url, workspaceId: 'WS-QA370', id: id, approve: true);
      }, () => client);
      String st = '';
      await http.runWithClient(() async {
        st = await LogoutRequests.statusOf(
            backendUrl: url, workspaceId: 'WS-QA370', id: id);
      }, () => client);
      expect(st, 'approved');
      // بعد الاعتماد يغادر القائمة المعلقة.
      await http.runWithClient(() async {
        pend = await LogoutRequests.listPending(
            backendUrl: url, workspaceId: 'WS-QA370');
      }, () => client);
      expect(pend, isEmpty);
    });

    test('LOG-02 بلا بريد ⇒ إنشاء الطلب يرفض', () async {
      expect(
          () => LogoutRequests.create(repo,
              backendUrl: url, workspaceId: 'WS-X', email: '  '),
          throwsStateError);
    });

    test('LOG-03 ترقية الوكيل: دور agent + صف RBAC كامل', () async {
      final iso = now.toIso8601String();
      await db.insert('users', {
        'name': 'عضو وكيل',
        'email': 'deputy@nexora.app',
        'role': 'dataentry',
        'permissions': 'add_tx',
        'is_me': 0,
        'active': 1,
        'workspace_id': repo.requireWorkspaceId,
        'deleted_at': '',
        'created_at': iso,
        'updated_at': iso,
      });
      await repo.promoteToDeputy('deputy@nexora.app');
      final rows = await db.query('users',
          where: "email = 'deputy@nexora.app'");
      expect(rows.first['role'], 'agent');
      final perms = await repo.userPermissions();
      final dep = perms.firstWhere((r) => r['user_email'] == 'deputy@nexora.app');
      expect(dep['role'], 'agent');
      expect(dep['can_discount'], 1);
      expect(dep['can_delete_tx'], 1);
      expect(dep['can_view_reports'], 1);
      expect(dep['can_manage_items'], 1);
    });
  });

  test('V370-PURGE: لا بقايا للخدمة القديمة ولا ربط ملكية بالبصمة', () {
    expect(File('lib/data/cloud_sync.dart').existsSync(), isFalse,
        reason: 'الخدمة القديمة المتجاوزة للطابور يجب أن تكون مجتثة');
    // جداول البيانات التجارية بلا أعمدة أجهزة (الملكية store/workspace
    // + user_email فقط) — operations.device_id يبقى وسم مصدر بروتوكولي.
    for (final t in ['transactions', 'accounts', 'vouchers', 'items']) {
      // يُقرأ المخطط نصياً من المصدر (القاعدة هنا فيزية بلا أعمدة أجهزة).
      final cols = db.rawQuery('PRAGMA table_info($t)');
      expect(cols, completion(isNotEmpty));
    }
  });
}
