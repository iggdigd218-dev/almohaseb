// 🔒 QA — محرك الفترة التجريبية (SubscriptionGuard):
// - التفعيل يحسب expires_at خادمياً = created_at + kTrialDuration بالضبط.
// - القرار بوقت الخادم حصراً: تقديم ساعة الهاتف لا يؤثر إطلاقاً.
// - منع التصفير: نفس البصمة العتادية تستأنف سجلها الأول حتى مع مساحة جديدة.
// - البوابة isBlocked: مفتوحة أثناء التجربة، مقفلة بعد الانتهاء،
//   ومفتوحة دائماً مع اشتراك مدفوع (active).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/subscription_guard.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// سحابة وهمية تحاكي RTDB: تستبدل {".sv":"timestamp"} بساعة خادم قابلة
/// للتحكم — نقدّمها ونؤخرها في الاختبارات بمعزل تام عن ساعة الجهاز.
class _FakeRtdb {
  final Map<String, Object?> store = {};

  /// «ساعة الخادم» — نتحكم بها يدوياً في كل اختبار.
  int serverClock = 1770000000000; // نقطة صفر ثابتة.

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
        if (req.method == 'DELETE') {
          store.remove(key);
          return _json('null', 200);
        }
        final v = store[key];
        return _json(v == null ? 'null' : jsonEncode(v), 200);
      });
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  const url = 'https://qa-trial.firebaseio.com';
  // مدة التجربة الفعلية من المحرك نفسه (30 يوماً حالياً) — الاختبارات
  // تتوافق تلقائياً مع أي تعديل مستقبلي للمدة.
  final dayMs = kTrialDuration.inMilliseconds;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_trial_');
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

  test('TRIAL-01 التفعيل يحسب expires_at خادمياً = created_at + مدة التجربة',
      () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    final st = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsA'),
        cloud.client);
    expect(st.status, 'trial');
    expect(st.createdAtMs, cloud.serverClock,
        reason: 'created_at من ختم الخادم لا من ساعة الهاتف');
    expect(st.expiresAtMs, cloud.serverClock + dayMs,
        reason: 'المدة تطابق kTrialDuration بالضبط محسوبة خادمياً');
    expect(st.expired, isFalse);
    expect(st.remaining.inHours, kTrialDuration.inHours,
        reason: 'المدة كاملة متبقية لحظة التفعيل (ساعة الخادم لم تتحرك)');
    // العقدة السحابية بالحقول المطلوبة كاملة.
    final rec = cloud.store.entries
        .firstWhere((e) => e.key.contains('/wsA/subscription'))
        .value as Map;
    expect(rec['status'], 'trial');
    expect(rec['is_active'], true);
    expect('${rec['device_fingerprint']}'.length, 32);
    // فهرس البصمة العالمي كُتب أيضاً (صمّام منع التصفير).
    expect(cloud.store.keys.any((k) => k.contains('/trials/')), isTrue);
  });

  test('TRIAL-02 القرار بوقت الخادم حصراً — تقديم ساعة الهاتف لا يؤثر',
      () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsB'),
        cloud.client);
    // «قدّم المستخدم ساعة هاتفه سنة كاملة» — لا شيء في الحارس يقرأ
    // DateTime.now()، فالحالة تُقرّر بساعة الخادم التي لم تتحرك.
    var st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsB', force: true),
        cloud.client);
    expect(st.expired, isFalse,
        reason: 'ساعة الخادم لم تتقدم — التجربة سارية مهما عبث الهاتف');
    // الآن يتقدم الخادم فعلياً بما يتجاوز المدة كاملة ⇒ الانتهاء الحقيقي.
    cloud.serverClock += dayMs + 60 * 60 * 1000;
    st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsB', force: true),
        cloud.client);
    expect(st.expired, isTrue, reason: 'server_ts >= expires_at');
    expect(st.remainingMs, 0);
  });

  test('TRIAL-03 منع التصفير: مساحة جديدة بنفس البصمة تستأنف السجل الأول',
      () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    final first = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'ws-old'),
        cloud.client);
    // «حذف التطبيق وأنشأ مساحة عمل جديدة» بعد 20 ساعة.
    cloud.serverClock += 20 * 60 * 60 * 1000;
    cloud.store.removeWhere((k, _) => k.contains('/ws-old/'));
    final resumed = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'ws-new'),
        cloud.client);
    expect(resumed.createdAtMs, first.createdAtMs,
        reason: 'فهرس /trials/\$fp أعاد السجل الأصلي — لا عدّاد جديد');
    expect(resumed.expiresAtMs, first.expiresAtMs,
        reason: 'expires_at الأصلي محفوظ — استُهلكت 20 ساعة فعلاً');
    expect(resumed.remaining.inHours,
        lessThanOrEqualTo(kTrialDuration.inHours - 20));
    // وبتجاوز كامل المتبقي تكون منتهية رغم «المساحة الجديدة».
    cloud.serverClock += dayMs - 20 * 60 * 60 * 1000 + 60 * 60 * 1000;
    final after = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-new', force: true),
        cloud.client);
    expect(after.expired, isTrue);
  });

  test('TRIAL-04 البوابة isBlocked: مفتوحة أثناء التجربة، مقفلة بعدها، '
      'ومفتوحة دائماً مع اشتراك active', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsC'),
        cloud.client);
    // أثناء التجربة: غير محظور.
    expect(
        await http.runWithClient(
            () => SubscriptionGuard.isBlocked(repo,
                backendUrl: url, workspaceId: 'wsC'),
            cloud.client),
        isFalse);
    // بعد الانتهاء: محظور.
    cloud.serverClock += dayMs + 60000;
    SubscriptionGuard.debugReset(); // تجاوز الكاش.
    expect(
        await http.runWithClient(
            () => SubscriptionGuard.isBlocked(repo,
                backendUrl: url, workspaceId: 'wsC'),
            cloud.client),
        isTrue,
        reason: 'انتهاء التجربة يقفل السحابة');
    // ترقية لاشتراك مدفوع (يفعلها المدير/الخادم): status=active يفتح كل شيء.
    final key = cloud.store.keys
        .firstWhere((k) => k.contains('/wsC/subscription'));
    final rec = Map<String, Object?>.from(cloud.store[key] as Map);
    rec['status'] = 'active';
    cloud.store[key] = rec;
    SubscriptionGuard.debugReset();
    expect(
        await http.runWithClient(
            () => SubscriptionGuard.isBlocked(repo,
                backendUrl: url, workspaceId: 'wsC'),
            cloud.client),
        isFalse,
        reason: 'الاشتراك المدفوع يتجاوز فحص الانتهاء');
  });

  test(
      'TRIAL-06 (ترحيل القدامى) مساحة مسجلة مسبقاً بلا عقدة اشتراك: '
      'الفحص عند الإقلاع ينشئها تلقائياً بختم الخادم + مدة التجربة', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    // مستخدم قديم: بياناته السحابية موجودة منذ زمن لكن لا عقدة subscription.
    cloud.store['/workspaces/ws-legacy/roster/DEV-1.json'] = {'name': 'قديم'};
    expect(
        cloud.store.keys.any((k) => k.contains('/ws-legacy/subscription')),
        isFalse);
    // إقلاع التطبيق = check قسري — التهيئة الكسولة تنشئ العقدة.
    final st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-legacy', force: true),
        cloud.client);
    expect(st.status, 'trial');
    expect(st.createdAtMs, cloud.serverClock,
        reason: 'created_at = لحظة الفتح الحالية بتوقيت الخادم');
    expect(st.expiresAtMs, cloud.serverClock + dayMs,
        reason: 'expires_at يمتد 24 ساعة من لحظة الفتح');
    expect(
        cloud.store.keys.any((k) => k.contains('/ws-legacy/subscription')),
        isTrue,
        reason: 'العقدة أُنشئت في السحابة');
    // بيانات المستخدم القديم لم تُمسّ.
    expect(cloud.store['/workspaces/ws-legacy/roster/DEV-1.json'], isNotNull);
  });

  test(
      'TRIAL-07 (منع التكرار) العقدة المهيأة لا يُعاد تصفيرها أبداً — '
      'إقلاعات متكررة وensureTrialStarted صريح لا يحركان العداد', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    // التهيئة الأولى لمستخدم قديم.
    final first = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-legacy2', force: true),
        cloud.client);
    // «أعاد فتح التطبيق» بعد 10 ساعات — إقلاع جديد + فحص قسري.
    cloud.serverClock += 10 * 60 * 60 * 1000;
    SubscriptionGuard.debugReset();
    final second = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-legacy2', force: true),
        cloud.client);
    expect(second.createdAtMs, first.createdAtMs,
        reason: 'لا إعادة تهيئة — نفس ختم البداية');
    expect(second.expiresAtMs, first.expiresAtMs,
        reason: 'العد التنازلي مستمر بلا تصفير');
    expect(second.remaining.inHours,
        lessThanOrEqualTo(kTrialDuration.inHours - 10));
    // وحتى استدعاء التفعيل الصريح لا يصفّر.
    final third = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'ws-legacy2'),
        cloud.client);
    expect(third.expiresAtMs, first.expiresAtMs);
  });

  test(
      'TRIAL-08 (متانة الترحيل) عقدة نصف مكتوبة — created_at موجود بلا '
      'expires_at: تُصلَّح من الختم الأصلي دون تصفير', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    // انقطاع سابق خلّف عقدة ناقصة عمرها 6 ساعات.
    final origCreated = cloud.serverClock - 6 * 60 * 60 * 1000;
    cloud.store['/workspaces/ws-broken/subscription.json'] = {
      'status': 'trial',
      'created_at': origCreated,
      'expires_at': 0,
      'is_active': true,
    };
    final st = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'ws-broken'),
        cloud.client);
    expect(st.createdAtMs, origCreated,
        reason: 'الإصلاح من الختم الأصلي لا من الآن');
    expect(st.expiresAtMs, origCreated + dayMs);
    expect(st.remaining.inHours,
        lessThanOrEqualTo(kTrialDuration.inHours - 6),
        reason: 'استُهلكت 6 ساعات فعلاً — لا تصفير');
  });

  test(
      'TRIAL-09 (استمرارية العداد) الحالة تُثبّت محلياً بعد فحص ناجح، '
      'وتُسترجع عند إقلاع جديد بلا شبكة — الشريط لا يختفي', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    // فحص ناجح يثبت الحالة محلياً.
    final st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-persist', force: true),
        cloud.client);
    expect(st.status, 'trial');
    final saved = (await repo.settings())['subCachedState'] ?? '';
    expect(saved, isNotEmpty, reason: 'الحالة ثُبّتت في settings');
    // «أُغلق التطبيق وفُتح بلا شبكة»: كاش الذاكرة صُفّر والشبكة ترمي.
    SubscriptionGuard.debugReset();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => throw Exception('offline');
    final offlineClient = MockClient((_) async =>
        throw Exception('offline'));
    final restored = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-persist', force: true),
        () => offlineClient);
    expect(restored.status, 'trial',
        reason: 'الحالة المثبّتة استُرجعت — العداد يظهر فور الإقلاع');
    expect(restored.expiresAtMs, st.expiresAtMs,
        reason: 'نفس expires_at الخادمي — لا تغيير بلا شبكة');
    expect(restored.expired, isFalse);
  });

  test(
      'TRIAL-10 (تجدد العداد) بين الفحوصات السحابية يُسنَد وقت الخادم '
      'المرجعي بساعة أحادية — العداد يتناقص لا يتجمد', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    final st1 = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-live', force: true),
        cloud.client);
    // قراءة كاش (بلا force وداخل TTL): وقت الخادم المُسنَد لا يقل عن
    // قيمة آخر فحص (الإسناد للأمام فقط بساعة Stopwatch).
    final st2 = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'ws-live'),
        cloud.client);
    expect(st2.serverNowMs, greaterThanOrEqualTo(st1.serverNowMs));
    expect(st2.expiresAtMs, st1.expiresAtMs);
    expect(st2.remainingMs, lessThanOrEqualTo(st1.remainingMs),
        reason: 'المتبقي لا يزيد بين قراءتين متتاليتين');
  });

  test('TRIAL-05 دقة الحساب: الحدود الدقيقة قبل/عند/بعد لحظة الانتهاء',
      () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride =
        (_) async => cloud.serverClock;
    final st0 = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsD'),
        cloud.client);
    final expires = st0.expiresAtMs;
    // قبل الانتهاء بملي ثانية واحدة: سارية.
    cloud.serverClock = expires - 1;
    SubscriptionGuard.debugReset();
    var st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsD', force: true),
        cloud.client);
    expect(st.expired, isFalse);
    expect(st.remainingMs, 1);
    // عند اللحظة تماماً (>=): منتهية.
    cloud.serverClock = expires;
    SubscriptionGuard.debugReset();
    st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsD', force: true),
        cloud.client);
    expect(st.expired, isTrue, reason: 'server_ts >= expires_at بالضبط');
  });

  // ==================== (الخطط المزدوجة) فردي/مؤسسات ====================

  test('PLAN-01 الاستنتاج التلقائي: مساحة منفردة = فردي بمقعد واحد وكل '
      'المزايا مفتوحة أثناء التجربة', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride = (_) async => cloud.serverClock;
    final st = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsP1'),
        cloud.client);
    expect(st.planType, 'individual');
    expect(st.maxDevices, 1);
    // كل المزايا مفتوحة أثناء التجربة.
    expect(st.featureUnlocked((f) => f.canUseCategories), isTrue);
    expect(st.featureUnlocked((f) => f.canCloudBackup), isTrue);
    // العقدة السحابية تحمل المخطط الكامل.
    final rec = cloud.store.entries
        .firstWhere((e) => e.key.contains('/wsP1/subscription'))
        .value as Map;
    expect(rec['plan_type'], 'individual');
    expect(rec['max_devices'], 1);
    expect((rec['features'] as Map)['can_use_categories'], true);
    expect((rec['features'] as Map)['audit_log'], true);
  });

  test('PLAN-02 انتهاء التجربة (فردي غير مشترك): المزايا المدفوعة تُقفل '
      'والعمل المحلي الأساسي يستمر', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride = (_) async => cloud.serverClock;
    await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsP2'),
        cloud.client);
    cloud.serverClock += dayMs + 1000; // تجاوز الانتهاء.
    SubscriptionGuard.debugReset();
    final st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsP2', force: true),
        cloud.client);
    expect(st.expired, isTrue);
    expect(st.isSubscribed, isFalse);
    // كل بوابات المزايا المدفوعة مقفلة.
    expect(st.featureUnlocked((f) => f.canUseCategories), isFalse);
    expect(st.featureUnlocked((f) => f.canSendNotifications), isFalse);
    expect(st.featureUnlocked((f) => f.canCloudBackup), isFalse);
    expect(st.featureUnlocked((f) => f.canRestoreData), isFalse);
    expect(st.featureUnlocked((f) => f.canAdvancedSearch), isFalse);
  });

  test('PLAN-03 الترقية للمؤسسات عند فتح كود ربط: plan_type يتحول '
      'و max_devices يرتفع دون المساس بعداد التجربة', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride = (_) async => cloud.serverClock;
    final st0 = await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsP3'),
        cloud.client);
    expect(st0.planType, 'individual');
    await http.runWithClient(
        () => SubscriptionGuard.promoteToEnterprise(repo,
            backendUrl: url, workspaceId: 'wsP3'),
        cloud.client);
    final st1 = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsP3', force: true),
        cloud.client);
    expect(st1.planType, 'enterprise');
    expect(st1.maxDevices, kDefaultEnterpriseSeats);
    // العداد الزمني لم يُمس: نفس created_at/expires_at.
    expect(st1.createdAtMs, st0.createdAtMs,
        reason: 'الترقية لا تعيد ضبط بداية التجربة');
    expect(st1.expiresAtMs, st0.expiresAtMs,
        reason: 'الترقية لا تمدد ولا تقلص مدة التجربة');
    // الترقية idempotent: استدعاء ثانٍ لا يغير شيئاً.
    await http.runWithClient(
        () => SubscriptionGuard.promoteToEnterprise(repo,
            backendUrl: url, workspaceId: 'wsP3', maxDevices: 3),
        cloud.client);
    final rec = cloud.store.entries
        .firstWhere((e) => e.key.contains('/wsP3/subscription'))
        .value as Map;
    expect(rec['max_devices'], kDefaultEnterpriseSeats,
        reason: 'الترقية المكررة لا تخفض المقاعد');
  });

  test('PLAN-04 التفعيل المدفوع يفتح كل المزايا فوراً دون مسح بيانات '
      '(الترقية في المكان)', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride = (_) async => cloud.serverClock;
    await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsP4'),
        cloud.client);
    cloud.serverClock += dayMs + 1000; // انتهت التجربة.
    // المشغل يفعّل الاشتراك سحابياً (كما يفعل بعد الدفع عبر واتساب).
    final key = cloud.store.keys
        .firstWhere((k) => k.contains('/wsP4/subscription'));
    final rec = Map<String, dynamic>.from(cloud.store[key] as Map);
    rec['status'] = 'active';
    rec['expires_at'] = cloud.serverClock + 30 * dayMs;
    cloud.store[key] = rec;
    SubscriptionGuard.debugReset();
    final st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsP4', force: true),
        cloud.client);
    expect(st.isSubscribed, isTrue);
    expect(st.expired, isFalse);
    expect(st.featureUnlocked((f) => f.canUseCategories), isTrue,
        reason: 'التفعيل يفتح المزايا فوراً على نفس العقدة — لا مسح ولا '
            'إعادة تثبيت');
    final blocked = await http.runWithClient(
        () => SubscriptionGuard.isBlocked(repo,
            backendUrl: url, workspaceId: 'wsP4'),
        cloud.client);
    expect(blocked, isFalse, reason: 'المزامنة تعود فور التفعيل');
  });

  test('PLAN-05 مؤسسة منتهية: isBlocked يجمّد المزامنة فوراً '
      '(العمل المحلي محفوظ خارج هذه البوابة)', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride = (_) async => cloud.serverClock;
    await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsP5'),
        cloud.client);
    await http.runWithClient(
        () => SubscriptionGuard.promoteToEnterprise(repo,
            backendUrl: url, workspaceId: 'wsP5'),
        cloud.client);
    cloud.serverClock += dayMs + 1000;
    SubscriptionGuard.debugReset();
    final blocked = await http.runWithClient(
        () => SubscriptionGuard.isBlocked(repo,
            backendUrl: url, workspaceId: 'wsP5'),
        cloud.client);
    expect(blocked, isTrue,
        reason: 'انتهاء باقة المؤسسات = تجميد SyncEngine فوراً');
    // ميزة المزامنة متعددة الأجهزة مقفلة أيضاً.
    final st = await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsP5', force: true),
        cloud.client);
    expect(st.planType, 'enterprise');
    expect(st.featureUnlocked((f) => f.multiDeviceSync), isFalse);
  });

  test('PLAN-06 الحالة المثبّتة محلياً تحفظ الخطة والمقاعد والمزايا '
      'وتُسترجع دون شبكة', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride = (_) async => cloud.serverClock;
    await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsP6'),
        cloud.client);
    await http.runWithClient(
        () => SubscriptionGuard.promoteToEnterprise(repo,
            backendUrl: url, workspaceId: 'wsP6'),
        cloud.client);
    await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsP6', force: true),
        cloud.client);
    // قراءة الكاش المحلي مباشرة (كما يفعل البانر عند الإقلاع دون شبكة).
    final raw = (await repo.settings())['subCachedState'] ?? '';
    expect(raw, isNotEmpty);
    final m = jsonDecode(raw) as Map;
    expect(m['plan_type'], 'enterprise');
    expect(m['max_devices'], kDefaultEnterpriseSeats);
    expect((m['features'] as Map)['can_cloud_backup'], true);
  });

  test('PLAN-07 (كشف التلاعب) إرجاع ساعة الهاتف دون شبكة = قفل فوري '
      'للمزايا حتى فحص سحابي حقيقي', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride = (_) async => cloud.serverClock;
    await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsP7'),
        cloud.client);
    // فحص ناجح يثبّت الحالة محلياً (device_ms = الآن الحقيقي).
    await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsP7', force: true),
        cloud.client);
    final raw = (await repo.settings())['subCachedState'] ?? '';
    expect(raw, isNotEmpty);
    // محاكاة إرجاع الساعة: نعدل device_ms المخزن ليكون في «مستقبل»
    // الجهاز (ساعة الهاتف الآن أقدم منه بأكثر من هامش الدقيقتين).
    final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    m['device_ms'] =
        DateTime.now().millisecondsSinceEpoch + 3 * 60 * 60 * 1000;
    await repo.setSetting('subCachedState', jsonEncode(m));
    // استرجاع دون شبكة (كما يفعل البانر عند الإقلاع بلا إنترنت).
    final st = await SubscriptionGuard.debugLoadPersisted(repo);
    expect(st, isNotNull);
    expect(st!.expired, isTrue,
        reason: 'التراجع الزمني المكشوف يقفل الجلسة المحلية فوراً');
    expect(st.featureUnlocked((f) => f.canCloudBackup), isFalse,
        reason: 'المزايا المدفوعة مقفلة حتى فحص سحابي حقيقي');
  });

  test('PLAN-08 (مطابقة الأدمن) عقدة /trials تحمل device_id صراحة عند '
      'التفعيل وتُرقَّع للسجلات القديمة عند الفحص', () async {
    final cloud = _FakeRtdb();
    SubscriptionGuard.debugServerNowOverride = (_) async => cloud.serverClock;
    await http.runWithClient(
        () => SubscriptionGuard.ensureTrialStarted(repo,
            backendUrl: url, workspaceId: 'wsP8'),
        cloud.client);
    // (أ) سجل التفعيل الجديد يحمل device_id بصيغة DEVICE-…
    final key = cloud.store.keys.firstWhere((k) => k.contains('/trials/'));
    final rec = Map<String, dynamic>.from(cloud.store[key] as Map);
    final devId = '${rec['device_id'] ?? ''}';
    expect(devId, startsWith('DEVICE-'),
        reason: 'تطبيق الأدمن يطابق DEVICE-… مباشرة من الفهرس');
    expect(rec['workspace_id'], 'wsP8');
    // (ب) الترقيع: سجل قديم بلا device_id يُرقّع عند أول فحص ناجح.
    rec.remove('device_id');
    cloud.store[key] = rec;
    SubscriptionGuard.debugReset();
    await http.runWithClient(
        () => SubscriptionGuard.check(repo,
            backendUrl: url, workspaceId: 'wsP8', force: true),
        cloud.client);
    // الترقيع غير متزامن (unawaited) — نمهله دورة.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final patched = Map<String, dynamic>.from(cloud.store[key] as Map);
    expect('${patched['device_id'] ?? ''}', startsWith('DEVICE-'),
        reason: 'السجلات القديمة تصبح قابلة للمطابقة دون إعادة تفعيل');
  });

  // ═══════ (دفعة 65-ب) الختم بدل الحظر ═══════
  // القاعدة الجديدة: لا ميزة تُحجب عن الحساب المقيد — المخرجات تُوسم فقط.
  group('(دفعة 65-ب) الختم بدل الحظر', () {
    SubscriptionState state({
      required String status,
      required int expiresAtMs,
      required int serverNowMs,
    }) =>
        SubscriptionState(
          status: status,
          createdAtMs: 0,
          expiresAtMs: expiresAtMs,
          isActive: true,
          deviceFingerprint: 'fp',
          serverNowMs: serverNowMs,
        );

    test('حساب محلي بلا سحابة: موسوم — لا محجوب', () {
      final sub = state(status: 'none', expiresAtMs: 0, serverNowMs: 1000);
      expect(FeatureAccessGuard.isRestricted(sub), isTrue);
      expect(FeatureAccessGuard.accessLevel(sub, Feature.whatsappClaims),
          FeatureAccess.watermarked);
      expect(FeatureAccessGuard.shouldWatermark(sub, Feature.reportsExport),
          isTrue);
    });

    test('تجربة منتهية: موسوم — لا محجوب', () {
      final sub = state(status: 'trial', expiresAtMs: 1000, serverNowMs: 2000);
      expect(FeatureAccessGuard.isRestricted(sub), isTrue);
      expect(FeatureAccessGuard.accessLevel(sub, Feature.storeLogo),
          FeatureAccess.watermarked,
          reason: 'الشعارات الجمالية مسموحة وموسومة — لا تُحجب');
    });

    test('اشتراك مدفوع فعّال: وصول كامل بلا ختم', () {
      final sub = state(status: 'active', expiresAtMs: 1000, serverNowMs: 2000);
      expect(FeatureAccessGuard.isRestricted(sub), isFalse);
      expect(FeatureAccessGuard.accessLevel(sub, Feature.whatsappClaims),
          FeatureAccess.full);
      expect(FeatureAccessGuard.shouldWatermark(sub, Feature.reportsExport),
          isFalse);
    });

    test('تجربة سارية: وصول كامل بلا ختم', () {
      final sub = state(status: 'trial', expiresAtMs: 5000, serverNowMs: 2000);
      expect(FeatureAccessGuard.isRestricted(sub), isFalse);
      expect(FeatureAccessGuard.accessLevel(sub, Feature.reportsExport),
          FeatureAccess.full);
    });

    test('نص الختم ثابت ويحمل اسم التطبيق', () {
      expect(kWatermarkText, isNotEmpty);
      expect(kWatermarkText, contains('سجل الحسابات'));
    });
  });
}
