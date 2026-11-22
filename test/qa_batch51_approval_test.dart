// QA — دفعة 51: الاقتران بموافقة المدير.
// - الدعوة الجديدة تحمل PIN من 6 أرقام وصلاحية 15 دقيقة.
// - الجهاز الجديد يدفع طلب انضمام (بالتوكن أو بالـPIN) دون مساس بالبيانات.
// - الحارس الصارم: لا لقطة تُسحب قبل الموافقة (بيانات الجهاز الجديد سليمة).
// - المدير يوافق بدور محدد → roster + users + devices، والجهاز المنتظر
//   يستلم approved ويكمل الترطيب النظيف.
// - الرفض لا يمس بيانات الجهاز الجديد إطلاقاً.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';

class FakeCloudStore {
  final Map<String, Object?> store = {};

  static http.Response _utf8Json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });

  http.Client client() => MockClient((req) async {
        // (إصلاح 2026-09-18) محاكاة Identity Toolkit/securetoken — منذ
        // اعتماد الهوية السحابية الإلزامية (Rules: auth != null) تمر كل
        // مسارات الدعوة/الانضمام أولاً بـ accounts:signUp. بلا هذه
        // الاستجابة كان المحاكي يرجع 'null' لطلبات POST فيفشل إنشاء
        // الهوية وتنهار اختبارات الربط كلها (11 اختباراً).
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
        final v = store[key];
        if (v != null) return _utf8Json(jsonEncode(v), 200);
        final prefix = key.replaceAll('.json', '');
        final children = <String, Object?>{};
        for (final e in store.entries) {
          if (e.key.startsWith('$prefix/')) {
            final child =
                e.key.substring(prefix.length + 1).replaceAll('.json', '');
            children[Uri.decodeComponent(child)] = e.value;
          }
        }
        if (children.isNotEmpty) return _utf8Json(jsonEncode(children), 200);
        return _utf8Json('null', 200);
      });
}

void main() {
  // هذه الحزمة تبني فرضياتها على مسار workspaces/default القديم —
  // نثبّت المعرف القديم بدل التوليد العشوائي (المعمارية الصامتة).
  debugForceLegacyWorkspaceId = true;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database a;
  late Database b;
  late Repo repoA; // المدير
  late Repo repoB; // الجهاز الجديد
  final now = DateTime(2026, 9, 11);
  const url = 'https://qa-b51.firebaseio.com';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_b51_');
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
    await repoA.setSetting('cloudCode', 'QA123');
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await tmp.delete(recursive: true);
  });

  test('QA-B51-01 invite carries 6-digit pin and 15-minute expiry', () async {
    final cloud = FakeCloudStore();
    final inv = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    expect(RegExp(r'^\d{6}$').hasMatch(inv.pin), isTrue,
        reason: 'PIN يجب أن يكون 6 أرقام');
    final ttl = inv.expiresAt.difference(DateTime.now());
    expect(ttl.inMinutes <= 15 && ttl.inMinutes >= 13, isTrue,
        reason: 'الصلاحية 15 دقيقة لا 24 ساعة');
    // الدعوة المخزنة سحابياً تحمل الـPIN نفسه.
    final stored = cloud.store.entries
        .firstWhere((e) => e.key.contains('/invites/'))
        .value as Map;
    expect('${stored['pin']}', inv.pin);
  });

  test(
      'QA-B51-02 requestJoin by PIN: pushes pending request, '
      'no local data touched before approval', () async {
    final cloud = FakeCloudStore();
    final inv = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    // بيانات محلية على الجهاز الجديد يجب أن تبقى سليمة قبل الموافقة.
    await repoB.saveAccount(Account(
      name: 'حساب محلي قديم',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    await http.runWithClient(
        () => CloudJoin.requestJoin(repoB,
            backendUrl: url, tokenOrPin: inv.pin, deviceName: 'كاشير الصالة'),
        cloud.client);
    // الطلب وصل السحابة بحالة pending وباسم الجهاز.
    final reqKey = cloud.store.keys
        .firstWhere((k) => k.contains('/joinRequests/'));
    final req = cloud.store[reqKey] as Map;
    expect('${req['status']}', 'pending');
    expect('${req['deviceName']}', 'كاشير الصالة');
    expect('${req['token']}', inv.token, reason: 'PIN يُحل إلى التوكن');
    // الحارس الصارم: بيانات الجهاز الجديد لم تُمس ولم يصبح عضواً.
    final accounts = await b.query('accounts');
    expect(accounts.length, greaterThanOrEqualTo(1));
    expect(await repoB.workspaceMode(), isNot('member'));
    // سياق الانتظار محفوظ للاستئناف.
    final st = await repoB.settings();
    expect(st['pendingJoin.token'], inv.token);
  });

  test('QA-B51-03 approve: role assigned, roster registered, joiner hydrates',
      () async {
    final cloud = FakeCloudStore();
    final inv = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    await http.runWithClient(
        () => CloudJoin.requestJoin(repoB,
            backendUrl: url,
            tokenOrPin: inv.token,
            deviceName: 'جوال المبيعات'),
        cloud.client);
    final reqs = await http.runWithClient(
        () => CloudJoin.fetchJoinRequests(repoA, backendUrl: url),
        cloud.client);
    expect(reqs.length, 1);
    final joinerId = '${reqs.first['deviceId']}';
    // موافقة بدور «محاسب».
    await http.runWithClient(
        () => CloudJoin.approveJoinRequest(repoA,
            backendUrl: url,
            deviceId: joinerId,
            deviceName: 'جوال المبيعات',
            roleCode: 'accountant'),
        cloud.client);
    // المدير محلياً: جهاز مقترن بمستخدم بدور محاسب.
    final dev = await a.query('devices', where: 'id = ?', whereArgs: [joinerId]);
    expect(dev.length, 1);
    final user = await a.query('users',
        where: 'id = ?', whereArgs: [dev.first['user_id']]);
    expect('${user.first['role']}', 'accountant');
    // roster السحابي سُجّل فيه الجهاز الجديد.
    expect(
        cloud.store.keys.any((k) => k.contains('/roster/')), isTrue);
    // الجهاز المنتظر يستطلع فيجد approved بالدور المعيّن.
    final st = await http.runWithClient(
        () => CloudJoin.pollJoinStatus(repoB,
            backendUrl: url, deviceId: joinerId),
        cloud.client);
    expect(st['status'], 'approved');
    expect(st['role'], 'accountant');
    // الترطيب النظيف يكتمل: يصبح عضواً وتُنظف مفاتيح الانتظار.
    await http.runWithClient(
        () => CloudJoin.completeApprovedJoin(repoB,
            backendUrl: url, token: st['token']!),
        cloud.client);
    expect(await repoB.workspaceMode(), 'member');
    final st2 = await repoB.settings();
    expect(st2.containsKey('pendingJoin.token'), isFalse);
    // الطلب حُذف من السحابة (نظافة).
    expect(cloud.store.keys.any((k) => k.contains('/joinRequests/')), isFalse);
  });

  test('QA-B51-04 reject: joiner keeps all local data, never becomes member',
      () async {
    final cloud = FakeCloudStore();
    final inv = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    await repoB.saveAccount(Account(
      name: 'بياناتي الخاصة',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    await http.runWithClient(
        () => CloudJoin.requestJoin(repoB,
            backendUrl: url, tokenOrPin: inv.pin, deviceName: 'جهاز مرفوض'),
        cloud.client);
    final reqs = await http.runWithClient(
        () => CloudJoin.fetchJoinRequests(repoA, backendUrl: url),
        cloud.client);
    final joinerId = '${reqs.first['deviceId']}';
    await http.runWithClient(
        () => CloudJoin.rejectJoinRequest(repoA,
            backendUrl: url, deviceId: joinerId),
        cloud.client);
    final st = await http.runWithClient(
        () => CloudJoin.pollJoinStatus(repoB,
            backendUrl: url, deviceId: joinerId),
        cloud.client);
    expect(st['status'], 'rejected');
    // بيانات الجهاز المرفوض سليمة تماماً.
    final accounts = await b.query('accounts',
        where: 'name = ?', whereArgs: ['بياناتي الخاصة']);
    expect(accounts.length, 1);
    expect(await repoB.workspaceMode(), isNot('member'));
    // الطلبات المعلقة عند المدير أصبحت صفراً (المرفوض لا يظهر).
    final reqs2 = await http.runWithClient(
        () => CloudJoin.fetchJoinRequests(repoA, backendUrl: url),
        cloud.client);
    expect(reqs2, isEmpty);
  });

  test('QA-B51-05 expired invite rejected for PIN entry', () async {
    final cloud = FakeCloudStore();
    final inv = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    // تزوير انتهاء الصلاحية في السحابة.
    final key = cloud.store.keys.firstWhere((k) => k.contains('/invites/'));
    final m = Map<String, Object?>.from(cloud.store[key] as Map);
    m['expiresAt'] =
        DateTime.now().subtract(const Duration(minutes: 1)).toIso8601String();
    cloud.store[key] = m;
    await expectLater(
      http.runWithClient(
          () => CloudJoin.requestJoin(repoB,
              backendUrl: url, tokenOrPin: inv.pin, deviceName: 'متأخر'),
          cloud.client),
      throwsA(isA<CloudJoinException>()),
    );
  });
}
