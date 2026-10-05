import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/snapshot_apply.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockCloudStore {
  final Map<String, Object?> store = {};

  static http.Response _utf8Json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });

  http.Client client() => MockClient((req) async {
        if (req.method == 'POST') {
          if (req.url.host.contains('securetoken')) {
            return _utf8Json('{"id_token":"TOK-QA","refresh_token":"REF-QA",'
                '"expires_in":"3600","user_id":"UID-QA-ANON"}', 200);
          }
          return _utf8Json('{"idToken":"TOK-QA","refreshToken":"REF-QA",'
              '"expiresIn":"3600","localId":"UID-QA-ANON"}', 200);
        }
        final key = req.url.path;
        if (req.method == 'PUT') {
          store[key] = jsonDecode(req.body);
          return _utf8Json(req.body, 200);
        }
        if (req.method == 'DELETE') {
          store.remove(key);
          return _utf8Json('null', 200);
        }
        if (req.method == 'GET') {
          if (key.endsWith('.json')) {
            final val = store[key];
            if (val != null) {
              return _utf8Json(jsonEncode(val), 200);
            }
          }
          return _utf8Json('null', 200);
        }
        return _utf8Json('null', 404);
      });
}

void main() {
  debugForceLegacyWorkspaceId = true;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const url = 'https://fake-firebase.firebaseio.com';
  late Directory tmp;
  late Database a;
  late Database b;
  late Repo repoA;
  late Repo repoB;
  final now = DateTime.now().toIso8601String();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_resilience_');
    Future<Database> open(String name) =>
        databaseFactory.openDatabase('${tmp.path}/$name.db',
            options: OpenDatabaseOptions(
                onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON')));
    a = await open('a');
    b = await open('b');
    await AppDatabase.createSchema(a);
    await AppDatabase.createSchema(b);
    repoA = Repo(databaseProvider: () async => a);
    repoB = Repo(databaseProvider: () async => b);
    await repoA.initSyncInfra();
    await repoB.initSyncInfra();
    await repoA.setSetting('cloudBackendUrl', url);
    await repoB.setSetting('cloudBackendUrl', url);
  });

  tearDown(() async {
    await a.close();
    await b.close();
    await tmp.delete(recursive: true);
  });

  test('QA-RESILIENCE-01: pollJoinStatus recovers approved status from roster when joinRequest node is missing',
      () async {
    final cloud = MockCloudStore();
    final ws = repoA.requireWorkspaceId;
    const deviceId = 'dev-member-test-01';

    // نضع الجهاز في سجل roster السحابي معتمد ومقترن
    final rosterKey = '/workspaces/$ws/roster/$deviceId.json';
    cloud.store[rosterKey] = {
      'id': deviceId,
      'is_paired': 1,
      'user_role': 'cashier',
      'updated_at': now,
    };
    await repoB.setSetting('pendingJoin.token', 'INVITE-TOK-123');

    // لا توجد عقدة في /joinRequests/$deviceId.json
    final st = await http.runWithClient(
      () => CloudJoin.pollJoinStatus(
        repoB,
        backendUrl: url,
        deviceId: deviceId,
        workspaceId: ws,
      ),
      cloud.client,
    );

    expect(st['status'], 'approved',
        reason: 'يجب التعافي واعتبار الجهاز approved اعتماداً على سجل roster السحابي');
    expect(st['role'], 'cashier');
    expect(st['token'], 'INVITE-TOK-123');
  });

  test('QA-RESILIENCE-02: fetchJoinRequests does not delete requests of re-joining devices',
      () async {
    final cloud = MockCloudStore();
    final ws = repoA.requireWorkspaceId;
    const deviceId = 'dev-rejoining-02';

    // نضع الجهاز في الأجهزة المحلية لدى المدير أو في الروستر مسبقاً (محاكاة جهاز كان مقترناً ويعيد الربط)
    await a.insert('devices', {
      'id': deviceId,
      'workspace_id': ws,
      'name': 'جهاز سابق',
      'is_paired': 1,
      'is_owner': 0,
      'revoked_at': '',
      'expelled_at': '',
      'last_seen_at': now,
      'created_at': now,
      'updated_at': now,
    });

    final reqPath = '/workspaces/$ws/joinRequests/$deviceId.json';
    cloud.store[reqPath] = {
      'deviceId': deviceId,
      'deviceName': 'جهاز سابق يعيد الربط',
      'status': 'pending',
      'token': 'TOK-REPAIR',
      'requestedAt': now,
    };

    // نضع قائمة الطلبات في السحابة
    final listPath = '/workspaces/$ws/joinRequests.json';
    cloud.store[listPath] = {
      deviceId: cloud.store[reqPath],
    };

    final reqs = await http.runWithClient(
      () => CloudJoin.fetchJoinRequests(
        repoA,
        backendUrl: url,
        workspaceId: ws,
      ),
      cloud.client,
    );

    expect(reqs.length, 1,
        reason: 'الطلب لا يجب أن يُحذف أو يُستبعد ويجب أن يظهر للمدير للموافقة عليه');
    expect(reqs.first['deviceId'], deviceId);
    expect(cloud.store.containsKey(reqPath), isTrue,
        reason: 'عقدة الطلب لا يجوز حذفها تلقائياً من السحابة');
  });

  test('QA-RESILIENCE-03: reconcileWorkspaceBinding fast O(1) returns current workspace if device is in roster',
      () async {
    final cloud = MockCloudStore();
    final ws = repoA.requireWorkspaceId;
    final ourId = repoA.requireDeviceId;

    await repoA.setSetting('sync.workspaceId', ws);
    final rosterKey = '/workspaces/$ws/roster/$ourId.json';
    cloud.store[rosterKey] = {
      'id': ourId,
      'is_paired': 1,
      'updated_at': now,
    };

    final resolved = await http.runWithClient(
      () => CloudJoin.reconcileWorkspaceBinding(
        repoA,
        backendUrl: url,
      ),
      cloud.client,
    );

    expect(resolved, ws);
  });

  test('QA-RESILIENCE-04: isDeviceApprovedInRoster returns true for active paired device',
      () async {
    final cloud = MockCloudStore();
    const ws = 'WS-TEST';
    const devId = 'DEV-001';

    cloud.store['/workspaces/$ws/roster/$devId.json'] = {
      'id': devId,
      'is_paired': 1,
      'revoked_at': '',
      'expelled_at': '',
    };

    final approved = await http.runWithClient(
      () => CloudJoin.isDeviceApprovedInRoster(
        backendUrl: url,
        workspaceId: ws,
        deviceId: devId,
      ),
      cloud.client,
    );

    expect(approved, isTrue);
  });

  test('QA-RESILIENCE-05: Automatic manager recognition by creator device ID and email',
      () async {
    final creatorId = repoA.requireDeviceId;
    // 1) جهاز المنشئ: حتى لو حُوِّل في قاعدة البيانات إلى عضو، يتعرف عليه النظام تلقائياً ويعيده مديراً
    await a.update('devices', {'is_owner': 0}, where: 'id = ?', whereArgs: [creatorId]);
    await a.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);

    // التحقق التلقائي: يتعرف على جهاز المنشئ حتماً بلا أي زر يدوي
    expect(await repoA.isWorkspaceOwner(), isTrue);
    expect(await repoA.workspaceMode(), 'host');
    final me = await repoA.currentUser();
    expect(me?.role.code, 'admin');

    // 2) جهاز عضو آخر (ليس المنشئ وبلا بريد إلكتروني)
    final memberId = repoB.requireDeviceId;
    await repoB.setSetting('creatorDeviceId', 'DIFFERENT-CREATOR-DEVICE');
    await b.update('devices', {'is_owner': 0}, where: 'id = ?', whereArgs: [memberId]);
    await b.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await repoB.setSetting('account.email', '');
    await repoB.setSetting('email', '');

    expect(await repoB.isWorkspaceOwner(), isFalse);
    expect(await repoB.workspaceMode(), 'member');

    // 3) إذا قام هذا الحساب بالتسجيل بالبريد الإلكتروني (البريد خاص بالمدير فقط)
    // يتعين مديراً تلقائياً وفورياً بدون أي زر يدوي
    await repoB.setSetting('account.email', 'manager@test.com');
    expect(await repoB.isWorkspaceOwner(), isTrue);
    expect(await repoB.workspaceMode(), 'host');
  });

  test('QA-RESILIENCE-06: SnapshotApply preserves host owner status and host mode when hostDeviceId matches',
      () async {
    final ourId = repoA.requireDeviceId;
    final ws = repoA.requireWorkspaceId;

    final snap = {
      'hostDeviceId': ourId,
      'workspaceMode': 'member',
      'workspaces': [
        {'id': ws, 'name': 'متجري'}
      ],
      'devices': [
        {'id': ourId, 'workspace_id': ws, 'name': 'جهاز المدير', 'is_owner': 1, 'is_paired': 1}
      ],
      'accounts': [],
      'items': [],
      'users': [],
    };

    // تطبيق اللقطة على جهاز المدير نفسه
    await SnapshotApply.applySnapshot(() async => a, ourId, snap);

    final dev = await a.query('devices', where: 'id = ?', whereArgs: [ourId]);
    expect(dev.first['is_owner'], 1, reason: 'جهاز المالك لا يجوز خفضه إلى عضو أبداً');

    final mode = await a.query('sync_meta', where: "key = 'workspaceMode'");
    expect(mode.first['value'], 'host', reason: 'وضع المالك يجب أن يبقى host');
  });

  test('QA-RESILIENCE-07: SnapshotApply purges email on member device and prevents inheriting manager email',
      () async {
    final managerId = repoA.requireDeviceId;
    final memberId = repoB.requireDeviceId;
    final ws = repoA.requireWorkspaceId;

    // محاكاة لقطة للمدير تحتوي على بريده
    final snap = {
      'hostDeviceId': managerId,
      'workspaceMode': 'member',
      'workspaces': [
        {'id': ws, 'name': 'متجري'}
      ],
      'devices': [
        {'id': managerId, 'workspace_id': ws, 'name': 'جهاز المدير', 'is_owner': 1, 'is_paired': 1}
      ],
      'orgSettings': {
        'businessName': 'متجر القمة',
        'account.email': 'manager@owner.com',
        'profile_email': 'manager@owner.com',
      },
      'accounts': [],
      'items': [],
      'users': [],
    };

    // تطبيق اللقطة على جهاز العضو
    await SnapshotApply.applySnapshot(() async => b, memberId, snap);

    final st = await repoB.settings();
    expect(st['account.email'] ?? '', isEmpty, reason: 'الأعضاء يسجلون بدون بريد ولا يرثون بريد المدير');
    expect(st['profile_email'] ?? '', isEmpty);
    expect(st['businessName'], 'متجر القمة');
    expect(await repoB.isWorkspaceOwner(), isFalse);
    expect(await repoB.workspaceMode(), 'member');
  });

  test('QA-RESILIENCE-08: checkLeaveOrEvicted does not evict member on approved join request or missing roster',
      () async {
    final cloud = MockCloudStore();
    const ws = 'WS-TEST-RES';
    const devId = 'DEV-MEMBER-1';

    // 1) طلب انضمام معتمد (kind = join) — ليس طرداً ولا مغادرة!
    cloud.store['/workspaces/$ws/joinRequests/$devId.json'] = {
      'deviceId': devId,
      'status': 'approved',
      'kind': 'join',
    };
    // السجل مفقود مؤقتاً
    cloud.store.remove('/workspaces/$ws/roster/$devId.json');

    var evicted = await http.runWithClient(
      () => CloudJoin.checkLeaveOrEvicted(
        backendUrl: url,
        workspaceId: ws,
        deviceId: devId,
      ),
      cloud.client,
    );
    expect(evicted, isFalse, reason: 'طلب الانضمام المعتمد أو غياب السجل المؤقت لا يجوز أن يطرد العضو أبداً');

    // 2) طلب مغادرة معتمد (kind = leave) — يطرد العضو رسمياً
    cloud.store['/workspaces/$ws/joinRequests/$devId.json'] = {
      'deviceId': devId,
      'status': 'approved',
      'kind': 'leave',
    };
    evicted = await http.runWithClient(
      () => CloudJoin.checkLeaveOrEvicted(
        backendUrl: url,
        workspaceId: ws,
        deviceId: devId,
      ),
      cloud.client,
    );
    expect(evicted, isTrue, reason: 'موافقة المدير على طلب المغادرة تطرد العضو رسمياً');

    // 3) شاهدة طرد صريحة في /evictions
    cloud.store.remove('/workspaces/$ws/joinRequests/$devId.json');
    cloud.store['/workspaces/$ws/evictions/$devId.json'] = {
      'deviceId': devId,
      'expelled_at': '2026-09-29T10:00:00Z',
    };
    evicted = await http.runWithClient(
      () => CloudJoin.checkLeaveOrEvicted(
        backendUrl: url,
        workspaceId: ws,
        deviceId: devId,
      ),
      cloud.client,
    );
    expect(evicted, isTrue, reason: 'شاهدة الطرد في /evictions تطرد العضو');

    // 4) وسم صريح في السجل السحابي (roster)
    cloud.store.remove('/workspaces/$ws/evictions/$devId.json');
    cloud.store['/workspaces/$ws/roster/$devId.json'] = {
      'id': devId,
      'expelled_at': '2026-09-29T10:00:00Z',
    };
    evicted = await http.runWithClient(
      () => CloudJoin.checkLeaveOrEvicted(
        backendUrl: url,
        workspaceId: ws,
        deviceId: devId,
      ),
      cloud.client,
    );
    expect(evicted, isTrue, reason: 'وسم expelled_at في roster يطرد العضو');
  });

  test('QA-RESILIENCE-09: reconcileRosterWithLocal inserts active cloud roster device into manager devices table',
      () async {
    final cloud = MockCloudStore();
    final ws = repoA.requireWorkspaceId;
    final ownerId = repoA.requireDeviceId;
    const newMemberId = 'DEV-NEW-JOIN';

    // السحابة تضم المدير + عضواً انضم حديثاً
    cloud.store['/workspaces/$ws/roster.json'] = {
      ownerId: {
        'id': ownerId,
        'is_owner': 1,
        'is_paired': 1,
        'revoked_at': '',
        'expelled_at': '',
      },
      newMemberId: {
        'id': newMemberId,
        'name': 'كاشير جديد',
        'is_owner': 0,
        'is_paired': 1,
        'revoked_at': '',
        'expelled_at': '',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
    };

    // قبل المواءمة: المدير لا يملك DEV-NEW-JOIN في قاعدة بياناته
    final before = await a.query('devices', where: 'id = ?', whereArgs: [newMemberId]);
    expect(before, isEmpty);

    // مواءمة المدير للسجل
    await http.runWithClient(
      () => CloudJoin.reconcileRosterWithLocal(
        repoA,
        backendUrl: url,
        workspaceId: ws,
      ),
      cloud.client,
    );

    // بعد المواءمة: العضو أُدرج محلياً ليظهر في إدارة المجموعة ولم يُحذف من السحابة!
    final after = await a.query('devices', where: 'id = ?', whereArgs: [newMemberId]);
    expect(after, isNotEmpty, reason: 'العضو الجديد يجب أن يُدرج محلياً لدى المدير ليظهر في إدارة المجموعة');
    expect(after.first['is_paired'], 1);
    expect(after.first['name'], 'كاشير جديد');

    // والسحابة ما زالت تحتفظ به
    final rosterCloud = cloud.store['/workspaces/$ws/roster.json'] as Map;
    expect(rosterCloud.containsKey(newMemberId), isTrue, reason: 'يُحظر حذف العضو الجديد من السحابة');
  });

  test('QA-RESILIENCE-10: Member device in reconcileWorkspaceBinding remains strictly bound to current business workspace',
      () async {
    final cloud = MockCloudStore();
    const businessWs = 'WS-BUSINESS-STABLE';
    final memberId = repoB.requireDeviceId;

    await repoB.setSetting('account.email', '');
    await repoB.setSetting('email', '');
    await repoB.setSetting('creatorDeviceId', 'DIFFERENT-CREATOR');
    await b.update('devices', {'is_owner': 0}, where: 'id = ?', whereArgs: [memberId]);
    await repoB.setSetting('sync.workspaceId', businessWs);
    await b.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);

    // محاكاة فهرس أجهزة قديم يشير لمساحة أخرى قديمة
    cloud.store['/workspaces/_registry/device_index.json'] = {
      'old-fp': {
        'workspaceId': 'WS-OLD-TEST',
        'role': 'owner',
        'device_id': memberId,
      }
    };

    final resolved = await http.runWithClient(
      () => CloudJoin.reconcileWorkspaceBinding(
        repoB,
        backendUrl: url,
      ),
      cloud.client,
    );

    expect(resolved, businessWs, reason: 'العضو المنضم يجب أن يثبت في مساحة العمل المعتمدة ولا يتنقل إطلاقاً');
  });

  test('QA-RESILIENCE-11: ensureMemberRosterPresence re-publishes missing roster entry to cloud',
      () async {
    final cloud = MockCloudStore();
    const ws = 'WS-BIZ';
    const memberId = 'DEV-M-REPUBLISH';

    // السجل فارغ
    expect(cloud.store['/workspaces/$ws/roster/$memberId.json'], isNull);

    await http.runWithClient(
      () => CloudJoin.ensureMemberRosterPresence(
        backendUrl: url,
        workspaceId: ws,
        deviceId: memberId,
        deviceRow: {
          'id': memberId,
          'name': 'كاشير',
          'is_paired': 1,
          'is_owner': 0,
          'revoked_at': '',
          'expelled_at': '',
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
      ),
      cloud.client,
    );

    // تم إعادة نشر العقدة بنجاح
    expect(cloud.store['/workspaces/$ws/roster/$memberId.json'], isNotNull);
    final row = cloud.store['/workspaces/$ws/roster/$memberId.json'] as Map;
    expect(row['id'], memberId);
    expect(row['is_paired'], 1);
  });
}
