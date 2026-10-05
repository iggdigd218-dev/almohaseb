import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/account_workspace.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/firebase_auth_service.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  const url = 'https://qa-email-sync.europe-west1.firebasedatabase.app';
  const managerAccount = FirebaseAccount(
    uid: 'UID-MGR-999',
    email: 'Manager.Store@Example.com',
    displayName: 'المدير العام',
  );

  setUp(() async {
    debugForceLegacyWorkspaceId = false;
    debugDefaultBackendUrlOverride = url;
    tmp = await Directory.systemTemp.createTemp('qa_email_sync_');
    db = await databaseFactory.openDatabase(
      '${tmp.path}/test.db',
      options: OpenDatabaseOptions(
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      ),
    );
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

  MockClient makeMockCloud(Map<String, Object?> store) => MockClient((req) async {
        final p = req.url.path;
        if (req.method == 'PUT') {
          store[p] = jsonDecode(req.body);
          return http.Response.bytes(utf8.encode(req.body), 200);
        }
        if (req.method == 'DELETE') {
          store.remove(p);
          return http.Response.bytes(utf8.encode('null'), 200);
        }
        final val = store[p];
        if (val == null) {
          return http.Response.bytes(utf8.encode('null'), 200);
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(val)),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

  test('EMAIL-01 مساحة العمل ترتبط بالبريد الإلكتروني وتفهرس بـ emails_index', () async {
    final store = <String, Object?>{};
    final client = makeMockCloud(store);

    final outcome = await http.runWithClient(
      () => AccountWorkspace.linkAccountOnly(repo,
          backendUrl: url, account: managerAccount),
      () => client,
    );

    expect(outcome, AccountLinkOutcome.migrated);
    final ws = repo.requireWorkspaceId;
    final emailKey = AccountWorkspace.emailToKey(managerAccount.email);

    // التحقق من إنشاء الفهرس السحابي للبريد
    final emailIndex = store['/workspaces/_registry/emails_index/$emailKey.json'] as Map?;
    expect(emailIndex, isNotNull);
    expect(emailIndex!['workspaceId'], ws);
    expect(emailIndex['email'], managerAccount.email.trim().toLowerCase());

    // التحقق من كتابة بيانات المساحة meta
    final meta = store['/workspaces/$ws/meta.json'] as Map?;
    expect(meta, isNotNull);
    expect(meta!['owner_email'], managerAccount.email.trim().toLowerCase());

    // التحقق من جدول workspaces المحلي
    final rows = await db.query('workspaces', where: 'id = ?', whereArgs: [ws]);
    expect(rows.isNotEmpty, isTrue);
    expect(rows.first['owner_email'], managerAccount.email.trim().toLowerCase());
  });

  test('EMAIL-02 نفس البريد يسترجع المساحة السابقة وبياناتها بالكامل عند إعادة التثبيت', () async {
    const existingWs = 'WS-SAVED-WORKSPACE-101';
    final emailKey = AccountWorkspace.emailToKey(managerAccount.email);

    final store = <String, Object?>{
      '/workspaces/_registry/emails_index/$emailKey.json': {
        'workspaceId': existingWs,
        'email': managerAccount.email.trim().toLowerCase(),
      },
      '/workspaces/$existingWs/backup.json': {
        'payload': {
          'app': 'nexora',
          'format': 'nexora-backup',
          'db_version': 1,
          'created_at': DateTime.now().toIso8601String(),
          'group_fingerprint': '',
          'workspace_mode': 'host',
          'data': {
            'accounts': [
              {
                'id': 555,
                'workspace_id': existingWs,
                'name': 'عميل مسترجع من السحابة',
                'kind': 'customer',
                'phone': '777123456',
                'notify_channel': 'none',
                'archived': 0,
                'deleted_at': '',
                'created_at': DateTime.now().toIso8601String(),
                'updated_at': DateTime.now().toIso8601String(),
              }
            ],
          },
        },
      },
    };
    final client = makeMockCloud(store);

    // محاكاة جهاز جديد تم تثبيت التطبيق عليه خام (يملك مساحة محلية عشوائية مختلفة)
    final freshWs = repo.requireWorkspaceId;
    expect(freshWs, isNot(existingWs));

    final outcome = await http.runWithClient(
      () => AccountWorkspace.linkAccountOnly(repo,
          backendUrl: url, account: managerAccount),
      () => client,
    );

    expect(outcome, AccountLinkOutcome.switched);
    expect(repo.requireWorkspaceId, existingWs,
        reason: 'يجب أن يعتمد التطبيق مساحة البريد السابقة دون إنشاء مساحة جديدة');

    // التحقق من استرجاع البيانات بدون نقصان
    final accounts = await repo.accounts();
    expect(accounts.any((a) => a.id == 555 && a.name == 'عميل مسترجع من السحابة'), isTrue);

    // التحقق من صفة المدير
    expect(await repo.isWorkspaceOwner(), isTrue);
    expect(await repo.workspaceMode(), 'host');
  });

  test('EMAIL-03 منع وجود أكثر من مدير — المدير واحد فقط والأعضاء is_owner=0', () async {
    await repo.setSetting('account.email', managerAccount.email);
    await repo.restoreManagerOwnership();

    // إدراج أجهزة أعضاء وهمية
    final now = DateTime.now().toIso8601String();
    await db.insert('devices', {
      'id': 'DEV-MEMBER-1',
      'workspace_id': repo.requireWorkspaceId,
      'name': 'جهاز الكاشير 1',
      'is_owner': 1, // محاولة غير شرعية لصفة المدير
      'is_paired': 1,
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('devices', {
      'id': 'DEV-MEMBER-2',
      'workspace_id': repo.requireWorkspaceId,
      'name': 'جهاز الكاشير 2',
      'is_owner': 0,
      'is_paired': 1,
      'created_at': now,
      'updated_at': now,
    });

    // استدعاء حارس التثبيت السيادي
    await repo.checkAndAutoPromoteManager();

    final owners = await db.query('devices', where: 'is_owner = 1');
    expect(owners.length, 1, reason: 'يمنع منعاً باتاً وجود أكثر من مدير في المجموعة');
    expect(owners.first['id'], repo.requireDeviceId);

    final memberDev = await db.query('devices', where: "id = 'DEV-MEMBER-1'");
    expect(memberDev.first['is_owner'], 0, reason: 'أجهزة الأعضاء لا تكون مدراء أبداً');
  });

  test('EMAIL-04 تطهير المساحات المحلية التي لا ترتبط ببريد إلكتروني', () async {
    final activeWs = repo.requireWorkspaceId;
    final now = DateTime.now().toIso8601String();

    // إدراج مساحات يتيمة بدون بريد
    await db.insert('workspaces', {
      'id': 'WS-ORPHAN-1',
      'name': 'مساحة مجهولة 1',
      'owner_google_id': '',
      'owner_email': '',
      'owner_name': '',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('workspaces', {
      'id': 'WS-ORPHAN-2',
      'name': 'مساحة مجهولة 2',
      'owner_google_id': '',
      'owner_email': '   ',
      'owner_name': '',
      'created_at': now,
      'updated_at': now,
    });

    await repo.setSetting('account.email', 'manager@test.com');
    await db.update('workspaces', {'owner_email': 'manager@test.com'},
        where: 'id = ?', whereArgs: [activeWs]);

    await repo.purgeNonEmailWorkspaces();

    final remaining = await db.query('workspaces');
    expect(remaining.length, 1);
    expect(remaining.first['id'], activeWs);
    expect(remaining.first['owner_email'], 'manager@test.com');
  });

  test('EMAIL-05 رفض العمليات القادمة من مساحات أخرى لحماية العزل السيادي', () async {
    final activeWs = repo.requireWorkspaceId;
    final resolver = ConflictResolver();

    // عملية تنتمي لنفس المساحة
    final opSame = SyncOperation(
      id: 'OP-SAME-1',
      deviceId: 'PEER-DEV-1',
      workspaceId: activeWs,
      userId: 1,
      parentOpId: '',
      entityType: EntityKind.account,
      entityId: '777',
      opType: OpKind.create,
      version: 1,
      payload: {
        'id': 777,
        'workspace_id': activeWs,
        'name': 'عميل داخل المساحة',
        'kind': 'customer',
      },
      deviceTime: DateTime.now().toIso8601String(),
      timestamp: DateTime.now().toIso8601String(),
    );

    // عملية تنتمي لمساحة غريبة أخرى
    final opAlien = SyncOperation(
      id: 'OP-ALIEN-1',
      deviceId: 'PEER-DEV-2',
      workspaceId: 'WS-DIFFERENT-ORGANIZATION',
      userId: 1,
      parentOpId: '',
      entityType: EntityKind.account,
      entityId: '888',
      opType: OpKind.create,
      version: 1,
      payload: {
        'id': 888,
        'workspace_id': 'WS-DIFFERENT-ORGANIZATION',
        'name': 'عميل مساحة غريبة',
        'kind': 'customer',
      },
      deviceTime: DateTime.now().toIso8601String(),
      timestamp: DateTime.now().toIso8601String(),
    );

    final okSame = await repo.applyRemoteOperation(db, opSame, resolver);
    final okAlien = await repo.applyRemoteOperation(db, opAlien, resolver);

    expect(okSame, isTrue);
    expect(okAlien, isFalse, reason: 'ممنوع المزامنة خارج مساحة العمل الواحدة للمنشأة');
  });

  test('EMAIL-06 تعافي المزامنة بعد انقطاع طويل وترتيب التبعيات بدون أخطاء', () async {
    final ws = repo.requireWorkspaceId;
    final resolver = ConflictResolver();
    final now = DateTime.now().toIso8601String();

    // ترتيب العمليات السحابية: فاتورة قبل الصنف والحساب (محاكاة وصول غير مرتب)
    final opTx = SyncOperation(
      id: 'OP-TX-1',
      deviceId: 'PEER-OFFLINE',
      workspaceId: ws,
      userId: 1,
      parentOpId: '',
      entityType: EntityKind.tx,
      entityId: '999',
      opType: OpKind.create,
      version: 1,
      payload: {
        'id': 999,
        'workspace_id': ws,
        'account_id': 990,
        'type': 'sale',
        'amount': 1500.0,
        'date': now,
        'status': 'done',
        'sync_state': 'synced',
        'items': [
          {
            'item_id': 880,
            'name': 'صنف فاصوليا',
            'quantity': 2,
            'unit_price': 750.0,
          }
        ],
      },
      deviceTime: now,
      timestamp: now,
    );

    // تطبيق العملية يجب أن ينجح بفضل ensureForeignParents والـ Stub Rows
    final applied = await repo.applyRemoteOperation(db, opTx, resolver);
    expect(applied, isTrue, reason: 'يجب تطبيق العملية وإنشاء سجلات مؤقتة لمنع Foreign Key Exception');

    // التحقق من إنشاء الحساب المؤقت والصنف المؤقت
    final acc = await db.query('accounts', where: 'id = ?', whereArgs: [990]);
    expect(acc.isNotEmpty, isTrue);
    expect(acc.first['name'], contains('مؤقت'));

    final tx = await db.query('transactions', where: 'id = ?', whereArgs: [999]);
    expect(tx.isNotEmpty, isTrue);
    expect(tx.first['amount'], 1500.0);
  });
}
