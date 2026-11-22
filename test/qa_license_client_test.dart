// 🔑 QA — مراجعة مدير الترخيص (جهة العميل) 2026-09-23.
//
// العيوب التي يشخّصها هذا الملف (كلها في مسار الترخيص لا في الواجهة):
//  CL-01/02  مساحة العمل: `workspaces` بـ limit 1 بلا ترتيب ⇒ أول صف =
//            المساحة الشخصية القديمة، حتى بعد ربط الجهاز بمجموعة. فتُقرأ
//            عقدة اشتراك غير التي يدفع إليها الجهاز ويفعّلها الأدمن.
//  CL-03     المقاعد بلا شبكة: كانت تُقرأ من حالة 'none' (max_devices=1)
//            بلا تمييز ⇒ مضيف مجموعة offline يُعرض له مقعد واحد. والجسم
//            كله كان بلا حماية فيصل أي استثناء إلى شارة المقاعد.
//  CL-04     المقاعد الحقيقية من السحابة تُقرأ كما هي.
//  CL-05     عدّ الأجهزة: الطلبات المعلّقة (is_paired=0) تُحتسب مقعداً
//            فتُظهر «3/5» بلا أجهزة فعلية، وتناقض استنتاج الخطة نفسه.
//  CL-06     ترقيع /trials: مفتاح الحساب (uid) قبل مفتاح العتاد — سجلات
//            العملاء المرتبطين بـ Google كانت لا تُرقَّع فيبقى الأدمن
//            عاجزاً عن مطابقة DEVICE-… بها.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/device_license.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/device_id.dart';
import 'package:nexora_app/data/sync/subscription_guard.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// سحابة وهمية تحاكي RTDB (نفس نمط اختبارات المحرك).
class _FakeRtdb {
  final Map<String, Object?> store = {};
  int serverClock = 1770000000000;

  static http.Response _json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });

  Object? _replaceSv(Object? v) {
    if (v is Map) {
      if (v.length == 1 && v['.sv'] == 'timestamp') return serverClock;
      return {for (final e in v.entries) e.key: _replaceSv(e.value)};
    }
    if (v is List) return v.map(_replaceSv).toList();
    return v;
  }

  http.Client client() => MockClient((req) async {
        final key = req.url.path;
        if (req.method == 'PUT') {
          final decoded = _replaceSv(jsonDecode(req.body));
          store[key] = decoded;
          return _json(jsonEncode(decoded), 200);
        }
        if (req.method == 'PATCH') {
          final prev = store[key];
          final patch = _replaceSv(jsonDecode(req.body));
          final merged = prev is Map && patch is Map
              ? <String, Object?>{...prev, ...patch}
              : patch;
          store[key] = merged;
          return _json(jsonEncode(merged), 200);
        }
        final v = store[key];
        return _json(v == null ? 'null' : jsonEncode(v), 200);
      });

  /// عميل يمثّل انقطاع الشبكة التام.
  static http.Client offline() =>
      MockClient((req) async => throw const SocketException('offline'));
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  const url = 'https://qa-license.firebaseio.com';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_lic_');
    db = await databaseFactory.openDatabase('${tmp.path}/qa.db');
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
    SubscriptionGuard.debugReset();
    SubscriptionGuard.debugServerNowOverride = null;
  });

  tearDown(() async {
    SubscriptionGuard.debugReset();
    SubscriptionGuard.debugServerNowOverride = null;
    if (db.isOpen) await db.close();
    await tmp.delete(recursive: true);
  });

  Future<void> setMode(String mode) => db.insert(
      'sync_meta', {'key': 'workspaceMode', 'value': mode},
      conflictAlgorithm: ConflictAlgorithm.replace);

  test(
      'CL-01 معرف مساحة العمل للترخيص = المساحة المرتبطة لا أول صف بلا ترتيب',
      () async {
    final own = repo.requireWorkspaceId;
    // ربط الجهاز بمجموعة (كما يفعل cloud_join عند الانضمام).
    await repo.bindWorkspaceId('WS-GROUP01');

    final firstRow = '${(await db.query('workspaces', limit: 1)).first['id']}';
    expect(await SubscriptionGuard.workspaceIdFor(repo), 'WS-GROUP01');
    expect(firstRow, isNot('WS-GROUP01'),
        reason: 'أول صف بلا ترتيب = المساحة الشخصية القديمة — هذا هو العيب');
    expect(firstRow, own);
  });

  test('CL-02 الترخيص يُقرأ من عقدة المساحة المرتبطة (عضو مجموعة)', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride = (_) async => cloud.serverClock;
    // اشتراك مدفوع على مساحة المجموعة فقط.
    cloud.store['/workspaces/WS-GROUP02/subscription.json'] = {
      'status': 'active',
      'plan_type': 'enterprise',
      'max_devices': 3,
      'created_at': cloud.serverClock,
      'expires_at': cloud.serverClock + 30 * 86400000,
      'is_active': true,
    };
    await repo.setSetting('cloudBackendUrl', url);
    await repo.bindWorkspaceId('WS-GROUP02');

    final st = await http.runWithClient(
        () async => SubscriptionGuard.check(repo,
            backendUrl: url,
            workspaceId: await SubscriptionGuard.workspaceIdFor(repo),
            force: true),
        cloud.client);
    expect(st.isSubscribed, isTrue,
        reason: 'الاشتراك المفعّل على مساحة المجموعة يجب أن يُرى');

    // توثيق العيب: القراءة بأول صف تعطي عقدة أخرى (لا عقدة ⇒ تجربة جديدة).
    final wrongWs = '${(await db.query('workspaces', limit: 1)).first['id']}';
    final wrong = await http.runWithClient(
        () async => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: wrongWs, force: true),
        cloud.client);
    expect(wrong.isSubscribed, isFalse);
  });

  test('CL-03 المقاعد بلا شبكة: فردي 1 • مضيف مجموعة 5 • بلا استثناء',
      () async {
    await repo.setSetting('cloudBackendUrl', url);
    final s = await http.runWithClient(
        () => DeviceLicense.check(repo), _FakeRtdb.offline);
    expect(s.maxSeats, 1,
        reason: 'الفردي مقعد واحد — والحد غير معروف فلا يُبنى عليه منع');
    expect(s.resolved, isFalse, reason: 'لا حالة معروفة ⇒ لا يُبنى عليها منع');
    expect(s.withinPlan, isTrue);
    expect(s.connectedDevices, greaterThanOrEqualTo(1));

    // مجموعة محلية بلا شبكة ⇒ مقاعد المؤسسة الافتراضية.
    await setMode('host');
    SubscriptionGuard.debugReset();
    final s2 = await http.runWithClient(
        () => DeviceLicense.check(repo), _FakeRtdb.offline);
    expect(s2.maxSeats, kDefaultEnterpriseSeats,
        reason: 'مضيف مجموعة: القديم كان يعطيه مقعداً واحداً (حالة none)');
  });

  test('CL-04 المقاعد من السحابة تُقرأ كما هي (مؤسسة بـ 3 مقاعد)', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride = (_) async => cloud.serverClock;
    final ws = repo.requireWorkspaceId;
    cloud.store['/workspaces/$ws/subscription.json'] = {
      'status': 'active',
      'plan_type': 'enterprise',
      'max_devices': 3,
      'created_at': cloud.serverClock,
      'expires_at': cloud.serverClock + 30 * 86400000,
      'is_active': true,
    };
    await repo.setSetting('cloudBackendUrl', url);
    final s = await http.runWithClient(
        () => DeviceLicense.check(repo), cloud.client);
    expect(s.maxSeats, 3);
    expect(s.resolved, isTrue);
    expect(s.withinPlan, isTrue);
  });

  test('CL-05 عدّ الأجهزة: المعلّق (غير المقترن) لا يستهلك مقعداً', () async {
    await repo.setSetting('cloudBackendUrl', url);
    final base = await http.runWithClient(
        () => DeviceLicense.check(repo), _FakeRtdb.offline);
    expect(base.connectedDevices, 1, reason: 'الجهاز المحلي وحده مقترن');

    final iso = DateTime.now().toIso8601String();
    final ws = repo.requireWorkspaceId;
    await db.insert('devices', {
      'id': 'DEVICE-PENDING1',
      'workspace_id': ws,
      'name': 'طلب معلق',
      'is_paired': 0, // لم يُعتمد بعد
      'created_at': iso,
      'updated_at': iso,
    });
    final afterPending = await http.runWithClient(
        () => DeviceLicense.check(repo), _FakeRtdb.offline);
    expect(afterPending.connectedDevices, base.connectedDevices,
        reason: 'الطلب المعلّق ليس جهازاً متصلاً — احتسابه كان يُضخّم العدّاد');

    await db.insert('devices', {
      'id': 'DEVICE-PAIRED01',
      'workspace_id': ws,
      'name': 'قرين مقترن',
      'is_paired': 1,
      'created_at': iso,
      'updated_at': iso,
    });
    final afterPeer = await http.runWithClient(
        () => DeviceLicense.check(repo), _FakeRtdb.offline);
    expect(afterPeer.connectedDevices, base.connectedDevices + 1);
  });

  test('CL-06 ترقيع /trials: مفتاح الحساب يفوز على مفتاح العتاد', () async {
    final devId = await ensureDeviceId(repo);
    final raw = await hardwareFingerprintRaw() ?? 'fallback:$devId';
    final hwFp = SubscriptionGuard.fingerprintHash(raw);
    const uid = 'google-uid-qa-123';
    final uidFp = SubscriptionGuard.fingerprintHash('uid:$uid');

    // (أ) بلا حساب: عقدة العتاد تُرقَّع.
    final cloudA = _FakeRtdb();
    cloudA.store['/trials/$hwFp.json'] = {
      'workspace_id': 'WS-BF-A',
      'status': 'trial',
      'device_id': '',
    };
    await http.runWithClient(
        () => SubscriptionGuard.debugBackfillTrialDeviceId(repo, url),
        cloudA.client);
    expect(
        '${(cloudA.store['/trials/$hwFp.json'] as Map)['device_id']}', devId);

    // (ب) بحساب Google: عقدة **الحساب** تُرقَّع — القديم كان يرقّع العتاد
    //     فقط فيبقى سجل العميل المرتبط بلا device_id.
    SubscriptionGuard.debugReset();
    await repo.setSetting('account.uid', uid);
    final cloudB = _FakeRtdb();
    cloudB.store['/trials/$uidFp.json'] = {
      'workspace_id': 'WS-BF-B',
      'status': 'active',
    };
    cloudB.store['/trials/$hwFp.json'] = {
      'workspace_id': 'WS-BF-B',
      'status': 'active',
    };
    await http.runWithClient(
        () => SubscriptionGuard.debugBackfillTrialDeviceId(repo, url),
        cloudB.client);
    expect(
        '${(cloudB.store['/trials/$uidFp.json'] as Map)['device_id']}', devId,
        reason: 'سجل الحساب هو الذي يقرأه التطبيق — يجب أن يحمل المعرف');
  });

  test('CL-07 مدة التجربة ثابتة ومعلنة (30 يوماً)', () {
    expect(kTrialDuration.inDays, 30);
    expect(DeviceLicense.check, isA<Function>());
  });
}
