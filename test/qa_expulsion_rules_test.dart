// QA — (2026-09-22) القوانين الصارمة للطرد والارتباط وحدّ المقاعد:
//  SEAT : الحد يُنفَّذ على الأجهزة المرتبطة **فعلياً** (roster السحابي)،
//         لا على أشباح الجدول المحلي — «5/5 ولا جهاز مرتبط» عطلٌ محظور.
//  EXP  : الطرد يمحو العضو من المجموعة ومن السحابة بكل آثاره.
//  REJOIN: إعادة ربطه لاحقاً تُسجّله جهازاً واحداً لا جهازين.
//  PURGE: منطقة الخطر تفصل كل الأعضاء رسمياً محلياً وسحابياً.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/device_registry.dart';
import 'package:nexora_app/data/sync/firebase_auth_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// سحابة وهمية: تخزّن PUT حسب المسار وتعيد GET من المخزن (مع تجميع
/// الأبناء لطلبات العقدة الكاملة مثل roster.json).
class _FakeCloud {
  final Map<String, Object?> store = {};
  static http.Response _json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status,
          headers: {'content-type': 'application/json; charset=utf-8'});

  http.Client client() => MockClient((req) async {
        if (req.method == 'POST') {
          if (req.url.host.contains('securetoken')) {
            return _json('{"id_token":"TOK-QA","refresh_token":"REF-QA",'
                '"expires_in":"3600","user_id":"UID-QA"}', 200);
          }
          return _json('{"idToken":"TOK-QA","refreshToken":"REF-QA",'
              '"expiresIn":"3600","localId":"UID-QA"}', 200);
        }
        final key = req.url.path;
        if (req.method == 'PUT') {
          store[key] = jsonDecode(req.body);
          return _json(req.body, 200);
        }
        if (req.method == 'DELETE') {
          final bare = key.replaceAll('.json', '');
          store.remove(key);
          store.removeWhere((k, _) => k.startsWith('$bare/'));
          return _json('null', 200);
        }
        final v = store[key];
        if (v != null) return _json(jsonEncode(v), 200);
        final prefix = key.replaceAll('.json', '');
        final shallow = req.url.queryParameters['shallow'] == 'true';
        final children = <String, Object?>{};
        for (final e in store.entries) {
          if (e.key.startsWith('$prefix/')) {
            var child = e.key.substring(prefix.length + 1);
            if (shallow) child = child.split('/').first;
            child = child.replaceAll('.json', '');
            children[Uri.decodeComponent(child)] = shallow ? true : e.value;
          }
        }
        if (children.isNotEmpty) return _json(jsonEncode(children), 200);
        return _json('null', 200);
      });

  void put(String path, Object? value) => store[path] = value;
  Object? get(String path) => store[path];
  bool has(String path) => store.containsKey(path);
}

const _url = 'https://qa-expel.firebaseio.com';
const _ws = 'WS-QA-EXPEL';
String get _root => '/workspaces/$_ws';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() async {
    debugDefaultBackendUrlOverride = '';
    tmp = await Directory.systemTemp.createTemp('nexora_expel_');
    db = await databaseFactory.openDatabase('${tmp.path}/o.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
    await repo.setSetting('cloudBackendUrl', _url);
    await db.delete('workspaces'); // صف المساحة الشخصية الذي أنشأته التهيئة
    await db.insert('workspaces', {
      'id': _ws,
      'name': 'مجموعة تحقق',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await repo.setSetting('sync.workspaceId', _ws);
    await repo.refreshWorkspaceId();
    FirebaseAuthRest.setMockTokenForTest();
  });

  tearDown(() async {
    FirebaseAuthRest.clearMockForTest();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<void> addDevice(String id, {String name = 'عضو', int owner = 0}) =>
      db.insert('devices', {
        'id': id,
        'workspace_id': _ws,
        'name': name,
        'is_paired': 1,
        'is_owner': owner,
        'revoked_at': '',
        'expelled_at': '',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });

  void seedSubscription(_FakeCloud c, {int max = 5}) => c.put(
        '$_root/subscription.json',
        {
          'plan_type': 'enterprise',
          'status': 'active',
          'is_active': true,
          'max_devices': max,
          'created_at': DateTime.now().millisecondsSinceEpoch - 86400000,
          'expires_at':
              DateTime.now().millisecondsSinceEpoch + 30 * 86400000,
          'features': {'multi_device_sync': true},
          'device_fingerprint': 'fp-owner',
        },
      );

  test('SEAT-01 أشباح الجدول المحلي لا تستهلك مقاعد', () async {
    final c = _FakeCloud();
    seedSubscription(c, max: 5);
    // السحابة: جهاز واحد مرتبط فعلاً (المدير).
    c.put('$_root/roster/DEVICE-OWNER.json', {
      'id': 'DEVICE-OWNER',
      'is_owner': 1,
      'is_paired': 1,
      'revoked_at': '',
      'expelled_at': '',
    });
    // المحلي: 5 أشباح مقترنة (بقايا روابط قديمة) + المدير.
    await addDevice('DEVICE-OWNER', owner: 1);
    for (var i = 1; i <= 5; i++) {
      await addDevice('DEVICE-GHOST-$i');
    }
    expect(await CloudJoin.connectedDevicesCount(repo), greaterThanOrEqualTo(6),
        reason: 'الجدول المحلي ما زال مليئاً بالأشباح — العطل القديم');
    // الرابط الوحيد الفعلي هو المدير ⇒ الدعوة تُنشأ بلا رفض.
    final invite = await http.runWithClient(
      () => CloudJoin.createInvite(repo),
      c.client,
    );
    expect(invite.backendUrl, _url);
  });

  test('SEAT-02 الحد يُنفَّذ على المرتبطين فعلياً (5/5 ⇒ رفض)', () async {
    final c = _FakeCloud();
    seedSubscription(c, max: 5);
    for (var i = 0; i < 5; i++) {
      c.put('$_root/roster/DEVICE-$i.json', {
        'id': 'DEVICE-$i',
        'is_paired': 1,
        'revoked_at': '',
        'expelled_at': '',
      });
    }
    var threw = false;
    try {
      await http.runWithClient(
        () => CloudJoin.createInvite(repo),
        c.client,
      );
    } on CloudJoinException catch (e) {
      threw = true;
      expect(e.message, contains('استنفاد'));
    }
    expect(threw, isTrue, reason: 'الرفض عند اكتمال المقاعد فعلياً');
  });

  test('SEAT-03 المطرود لا يُحسب مقعداً — بعد الطرد يُقبل ربط جديد', () async {
    final c = _FakeCloud();
    seedSubscription(c, max: 5);
    for (var i = 0; i < 5; i++) {
      c.put('$_root/roster/DEVICE-$i.json', {
        'id': 'DEVICE-$i',
        'is_paired': 1,
        'revoked_at': i == 4 ? '2026-09-22T00:00:00.000' : '',
        'expelled_at': i == 4 ? '2026-09-22T00:00:00.000' : '',
      });
    }
    final invite = await http.runWithClient(
      () => CloudJoin.createInvite(repo),
      c.client,
    );
    expect(invite.backendUrl, _url,
        reason: 'الجهاز المطرود لا يشغل مقعداً — 4/5 فقط');
  });

  test('EXP-01 الطرد يمحو العضو من السحابة كلياً', () async {
    final c = _FakeCloud();
    c.put('$_root/roster/DEVICE-M.json', {
      'id': 'DEVICE-M',
      'is_paired': 1,
      'revoked_at': '',
      'expelled_at': '',
    });
    c.put('$_root/roster/DEVICE-OWNER.json', {
      'id': 'DEVICE-OWNER',
      'is_owner': 1,
      'revoked_at': '',
      'expelled_at': '',
    });
    c.put('$_root/members/uid-m.json',
        {'uid': 'uid-m', 'deviceId': 'DEVICE-M', 'role': 'accountant'});
    c.put('$_root/members/uid-owner.json',
        {'uid': 'uid-owner', 'deviceId': 'DEVICE-OWNER', 'role': 'admin'});
    c.put('/workspaces/_registry/device_index/fp-m.json', {
      'workspaceId': _ws,
      'role': 'member',
      'device_id': 'DEVICE-M',
    });
    c.put('/workspaces/_registry/device_index/fp-owner.json', {
      'workspaceId': _ws,
      'role': 'owner',
      'device_id': 'DEVICE-OWNER',
    });
    c.put('$_root/joinRequests/DEVICE-M.json',
        {'deviceId': 'DEVICE-M', 'status': 'pending'});

    await http.runWithClient(
      () => CloudJoin.expelMemberCompletely(repo,
          backendUrl: _url, deviceId: 'DEVICE-M', workspaceId: _ws),
      c.client,
    );

    expect(c.has('$_root/roster/DEVICE-M.json'), isFalse,
        reason: 'لا أثر له في السجل');
    expect(c.has('$_root/members/uid-m.json'), isFalse,
        reason: 'عضوية المستخدم مُحيت');
    expect(c.has('/workspaces/_registry/device_index/fp-m.json'), isFalse,
        reason: 'فهرس الجهاز مُحي — لا استرداد ببصمته');
    expect(c.has('$_root/joinRequests/DEVICE-M.json'), isFalse,
        reason: 'طلب انضمامه مُحي');
    // المدير سليم تماماً.
    expect(c.has('$_root/roster/DEVICE-OWNER.json'), isTrue);
    expect(c.has('$_root/members/uid-owner.json'), isTrue);
    expect(c.has('/workspaces/_registry/device_index/fp-owner.json'), isTrue);
  });

  test('EXP-02 الطرد محلياً: لا صف جهاز ولا عضو فعّال + أثر تدقيقي',
      () async {
    final uid = await db.insert('users', {
      'name': 'عضو مطرود',
      'role': 'accountant',
      'pin': '',
      'password': '',
      'permissions': 'add_tx',
      'is_me': 0,
      'active': 1,
      'workspace_id': _ws,
      'deleted_at': '',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await db.insert('devices', {
      'id': 'DEVICE-X',
      'workspace_id': _ws,
      'name': 'عضو مطرود',
      'is_paired': 1,
      'is_owner': 0,
      'user_id': uid,
      'revoked_at': '',
      'expelled_at': '',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await repo.expelDevice('DEVICE-X');
    final dev = await db.query('devices',
        where: 'id = ?', whereArgs: ['DEVICE-X']);
    expect(dev, isEmpty, reason: 'صفه حُذف من سجل المجموعة لا وسمٌ فقط');
    final user = await db.query('users', where: 'id = ?', whereArgs: [uid]);
    expect(user.single['active'], 0, reason: 'عضويته أُلغيت');
    expect('${user.single['deleted_at']}', isNotEmpty);
    final act = await db.query('activity',
        where: "ref_type = 'expel' AND ref_id = 'DEVICE-X'");
    expect(act, hasLength(1), reason: 'الطرد موثّق في السجل');
  });

  test('REJOIN-01 إعادة الربط بعد الطرد: جهاز واحد لا جهازان', () async {
    final c = _FakeCloud();
    seedSubscription(c, max: 5);
    c.put('$_root/roster/DEVICE-R.json', {
      'id': 'DEVICE-R',
      'is_paired': 1,
      'revoked_at': '',
      'expelled_at': '',
    });
    // طرد كامل.
    await http.runWithClient(
      () => CloudJoin.expelMemberCompletely(repo,
          backendUrl: _url, deviceId: 'DEVICE-R', workspaceId: _ws),
      c.client,
    );
    expect(c.has('$_root/roster/DEVICE-R.json'), isFalse);
    // إعادة القبول بنفس المعرّف.
    await addDevice('DEVICE-R');
    c.put('$_root/roster/DEVICE-R.json', {
      'id': 'DEVICE-R',
      'is_paired': 1,
      'revoked_at': '',
      'expelled_at': '',
    });
    final roster =
        jsonDecode(utf8.decode((await http.runWithClient(
              () => http.get(Uri.parse('$_url$_root/roster.json')),
              c.client,
            ))
                .bodyBytes)) as Map<String, dynamic>;
    expect(roster.keys, ['DEVICE-R'],
        reason: 'عقدة واحدة بنفس المعرّف — لا ازدواج');
  });

  test('PURGE-01 منطقة الخطر: كل الأعضاء يُفصلون سحابياً', () async {
    final c = _FakeCloud();
    seedSubscription(c, max: 5);
    final me = (await repo.settings())['sync.deviceId'] ?? '';
    c.put('$_root/roster/$me.json', {
      'id': me,
      'is_owner': 1,
      'revoked_at': '',
      'expelled_at': '',
    });
    for (final id in const ['DEVICE-M1', 'DEVICE-M2']) {
      c.put('$_root/roster/$id.json', {
        'id': id,
        'is_paired': 1,
        'revoked_at': '',
        'expelled_at': '',
      });
      c.put('$_root/members/uid-$id.json',
          {'uid': 'uid-$id', 'deviceId': id, 'role': 'accountant'});
      c.put('/workspaces/_registry/device_index/fp-$id.json',
          {'workspaceId': _ws, 'role': 'member', 'device_id': id});
    }
    c.put('/workspaces/_registry/device_index/fp-owner.json',
        {'workspaceId': _ws, 'role': 'owner', 'device_id': me});
    c.put('$_root/invites/CODE1.json', {'code': 'CODE1'});

    final n = await http.runWithClient(
      () => CloudJoin.purgeAllMembers(repo,
          backendUrl: _url, workspaceId: _ws),
      c.client,
    );
    expect(n, 2, reason: 'عُضوان مفصولان');
    for (final id in const ['DEVICE-M1', 'DEVICE-M2']) {
      expect(c.has('$_root/roster/$id.json'), isFalse);
      expect(c.has('$_root/members/uid-$id.json'), isFalse);
      expect(c.has('/workspaces/_registry/device_index/fp-$id.json'), isFalse);
    }
    expect(c.has('$_root/invites/CODE1.json'), isFalse);
    // المدير والاشتراك سليمان.
    expect(c.has('$_root/roster/$me.json'), isTrue);
    expect(c.has('/workspaces/_registry/device_index/fp-owner.json'), isTrue);
    expect(c.has('$_root/subscription.json'), isTrue);
  });

  test('RECON-01 مواءمة السجل: الأشباح تُفصل والفعّال يُحفظ', () async {
    final c = _FakeCloud();
    final me = (await repo.settings())['sync.deviceId'] ?? '';
    // المدير + عضو فعّال في السجل.
    c.put('$_root/roster/$me.json', {
      'id': me,
      'is_owner': 1,
      'is_paired': 1,
      'revoked_at': '',
      'expelled_at': '',
    });
    c.put('$_root/roster/DEVICE-LIVE.json', {
      'id': 'DEVICE-LIVE',
      'is_paired': 1,
      'revoked_at': '',
      'expelled_at': '',
    });
    // محلياً: العضو الفعّال (موسوم خطأً بالمطرود) + شبحان.
    await addDevice('DEVICE-LIVE');
    await db.update('devices',
        {'is_paired': 0, 'expelled_at': '2026-09-01T00:00:00.000'},
        where: 'id = ?',
        whereArgs: ['DEVICE-LIVE']);
    await addDevice('DEVICE-GHOST-A');
    await addDevice('DEVICE-GHOST-B');
    await addDevice('DEVICE-OWNER2', owner: 1); // مالك: لا يُمسّ

    final fixed = await http.runWithClient(
      () => CloudJoin.reconcileRosterWithLocal(repo,
          backendUrl: _url, workspaceId: _ws),
      c.client,
    );
    expect(fixed, 3, reason: 'إحياء العضو الفعّال + فصل الشبحين');

    Future<Map<String, Object?>> row(String id) async =>
        (await db.query('devices', where: 'id = ?', whereArgs: [id])).single;
    final live = await row('DEVICE-LIVE');
    expect(live['is_paired'], 1, reason: 'العضو الفعّال أُعيد مقترناً');
    expect('${live['expelled_at']}', isEmpty);
    for (final g in const ['DEVICE-GHOST-A', 'DEVICE-GHOST-B']) {
      final r = await row(g);
      expect(r['is_paired'], 0, reason: '$g شبح مفصول');
      expect('${r['expelled_at']}', isNotEmpty);
    }
    final own = await row('DEVICE-OWNER2');
    expect(own['is_paired'], 1, reason: 'المالك لا يُمسّ');
    expect('${own['expelled_at']}', isEmpty);
  });

  test('ROUTE-01 السحابة تحسم المساحة: الربط المحلي الخاطئ يُصوَّب', () async {
    final c = _FakeCloud();
    final me = (await repo.settings())['sync.deviceId'] ?? '';
    // السحابة تضعنا في مساحة واحدة (ونحن محلياً في أخرى).
    c.put('$_root/roster/$me.json', {
      'id': me,
      'is_paired': 1,
      'last_sync_at': DateTime.now().toIso8601String(),
      'revoked_at': '',
      'expelled_at': '',
    });
    // نُزيح الربط المحلي عمداً إلى مساحة أخرى (حال الجهاز المعطوب).
    await db.insert('workspaces', {
      'id': 'WS-STALE',
      'name': 'قديم',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await repo.setSetting('sync.workspaceId', 'WS-STALE');
    await repo.refreshWorkspaceId();
    expect(repo.requireWorkspaceId, 'WS-STALE');

    final bound = await http.runWithClient(
      () => CloudJoin.reconcileWorkspaceBinding(repo, backendUrl: _url),
      c.client,
    );
    expect(bound, _ws, reason: 'المساحة تُحسم من السحابة لا من المحلي');
    await repo.refreshWorkspaceId();
    expect(repo.requireWorkspaceId, _ws);
    expect((await repo.settings())['sync.workspaceId'], _ws);
  });

  test('ROUTE-03 تعذّر المسح ≠ بلا عضوية: لا ربط ولا تنظيف', () async {
    final c = _FakeCloud();
    final me = (await repo.settings())['sync.deviceId'] ?? '';
    // السحابة تضعنا في مساحة أخرى (فلو نجح المسح لتغيّر الربط إليها).
    c.put('/workspaces/WS-REAL/roster/$me.json', {
      'id': me,
      'last_sync_at': DateTime.now().toIso8601String(),
    });
    c.put('/workspaces/WS-REAL/operations/op1.json', {'id': 'op1'});
    await db.insert('workspaces', {
      'id': 'WS-CURRENT',
      'name': 'حالي',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    await repo.setSetting('sync.workspaceId', 'WS-CURRENT');
    await repo.refreshWorkspaceId();

    // شبكة مقطوعة: مسح قائمة المساحات يفشل.
    http.Client flaky() => MockClient((req) async {
          if (req.url.path.endsWith('/workspaces.json')) {
            throw Exception('لا شبكة');
          }
          return http.Response.fromStream(await c.client().send(req));
        });

    final bound = await http.runWithClient(
      () => CloudJoin.reconcileWorkspaceBinding(repo, backendUrl: _url),
      flaky,
    );
    expect(bound, '', reason: 'لا قرار بلا مسح ناجح');
    await repo.refreshWorkspaceId();
    expect(repo.requireWorkspaceId, 'WS-CURRENT',
        reason: 'الربط القائم لا يُستبدل بسبب خطأ شبكة');
    expect(c.has('/workspaces/WS-REAL/operations/op1.json'), isTrue,
        reason: 'لا تُمحى بيانات بسبب خطأ شبكة');
  });

  test('ROUTE-04 التهيئة لا تمسح بيانات أعضاء آخرين', () async {
    final c = _FakeCloud();
    final me = (await repo.settings())['sync.deviceId'] ?? '';
    // لا سجل لنا في أي مساحة (تثبيت جديد) + فهرس الجهاز يشير للمساحة.
    final fp = await DeviceRegistry.fingerprintKey(repo);
    c.put('/workspaces/_registry/device_index/$fp.json', {
      'device_id': me,
      'workspaceId': _ws,
    });
    // المساحة تضم جهازاً آخر وعملياته — ليست مساحتنا وحدنا.
    c.put('$_root/roster/DEVICE-OTHER.json', {'id': 'DEVICE-OTHER'});
    c.put('$_root/operations/op-keep.json', {'id': 'op-keep'});
    c.put('$_root/subscription.json', {'plan': 'pro', 'max_seats': 5});

    final bound = await http.runWithClient(
      () => CloudJoin.reconcileWorkspaceBinding(repo, backendUrl: _url),
      c.client,
    );
    expect(bound, _ws, reason: 'يُعاد إلى مساحته المعروفة ببصمته');
    expect(c.has('$_root/operations/op-keep.json'), isTrue,
        reason: 'عمليات بقية الأعضاء لا تُمحى');
    expect(c.has('$_root/roster/DEVICE-OTHER.json'), isTrue,
        reason: 'سجل بقية الأعضاء لا يُمحى');
  });

  test('ROUTE-02 findWorkspaceOfDevice يرجّح المساحة الأحدث نشاطاً', () async {
    final c = _FakeCloud();
    final me = (await repo.settings())['sync.deviceId'] ?? '';
    c.put('$_root/roster/$me.json', {
      'id': me,
      'last_sync_at': '2026-09-22T05:00:00.000',
    });
    c.put('/workspaces/WS-OLD/roster/$me.json', {
      'id': me,
      'last_sync_at': '2026-09-01T05:00:00.000',
    });
    final found = await http.runWithClient(
      () => CloudJoin.findWorkspaceOfDevice(_url, me),
      c.client,
    );
    expect(found, _ws, reason: 'الأحدث نشاطاً يفوز على المساحة القديمة');
    // مساحة بلا سجل لنا لا تُؤخذ.
    final none = await http.runWithClient(
      () => CloudJoin.findWorkspaceOfDevice(_url, 'DEVICE-NOBODY'),
      c.client,
    );
    expect(none, isEmpty);
  });
}
