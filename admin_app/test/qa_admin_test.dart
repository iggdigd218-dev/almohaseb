// اختبارات منطق مدير التراخيص: حساب المدد + تحويل المعرفات +
// (2026-09-22) قانون الهوية: كل طلب لقاعدة البيانات يُوقَّع بهوية صالحة،
// وسجل التفعيل يكتب داخل مساحة العمل لا في العقدة العامة المحجوبة.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:license_admin/rtdb.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  test('ADMIN-01 مدد الخطط صحيحة بالمللي ثانية', () {
    expect(PlanDuration.month.span.inDays, 30);
    expect(PlanDuration.quarter.span.inDays, 90);
    expect(PlanDuration.year.span.inDays, 365);
    expect(PlanDuration.lifetime.span.inDays, 36500);
  });

  test('ADMIN-02 نمط بصمة التفعيل: 32 خانة hex فقط', () {
    final re = RegExp(r'^[0-9a-fA-F]{32}$');
    expect(re.hasMatch('a1b2c3d4e5f60718293a4b5c6d7e8f90'), isTrue);
    expect(re.hasMatch('ws-1755'), isFalse);
    expect(re.hasMatch(''), isFalse);
    expect(re.hasMatch('a1b2c3d4e5f60718293a4b5c6d7e8f9'), isFalse);
  });

  test('ADMIN-04 معرف الجهاز DEVICE-… يُلتقط بالنمط الموسع (أي لاحقة)', () {
    final re = RegExp(r'^DEVICE-', caseSensitive: false);
    expect(re.hasMatch('DEVICE-SSBGXYMEUBZ6'), isTrue,
        reason: 'معرف العميل الفعلي من رسالة الواتساب');
    expect(re.hasMatch('device-abc123'), isTrue, reason: 'غير حساس للحالة');
    expect(re.hasMatch('DEVICE-XY'), isTrue,
        reason: 'لا حد أدنى للطول — الحسم في البحث لا في النمط');
    expect(re.hasMatch('ws-1755'), isFalse);
    expect(re.hasMatch('a1b2c3d4e5f60718293a4b5c6d7e8f90'), isFalse);
  });

  test('ADMIN-05 الرابط والمفتاح مضبوطان — يعمل فور التثبيت', () {
    expect(kOfficialRtdbUrl, startsWith('https://'),
        reason: 'الرابط الرسمي فارغ كان أول سبب لتعطّل اللوحة');
    expect(kOfficialRtdbUrl, contains('firebasedatabase.app'));
    expect(kFirebaseApiKey.isNotEmpty, isTrue,
        reason: 'المفتاح لازم للهوية المجهولة التي تشترطها القواعد');
  });

  test('ADMIN-06 كل طلب بيانات يُوقَّع بهوية (auth != null)', () async {
    SharedPreferences.setMockInitialValues({});
    final rtdb = Rtdb.instance;
    await rtdb.load();
    expect(rtdb.configured, isTrue,
        reason: 'اللوحة مهيأة افتراضياً بلا إعداد يدوي');

    final seen = <Uri>[];
    final client = MockClient((req) async {
      seen.add(req.url);
      if (req.url.host.contains('identitytoolkit') ||
          req.url.host.contains('securetoken')) {
        return _json({
          'idToken': 'IDTOK-QA',
          'refreshToken': 'REF-QA',
          'expiresIn': '3600',
          'localId': 'UID-QA',
        });
      }
      if (req.url.path.endsWith('server_clock.json')) {
        return _json(1770000000000);
      }
      if (req.url.path.contains('workspaces')) {
        if (req.url.queryParameters.containsKey('shallow')) {
          return _json({'WS-A': true});
        }
        return _json({'status': 'active', 'expires_at': 1770000000000});
      }
      return _json('null');
    });

    rtdb.clientOverride = client;
    await rtdb.metrics();

    final dataCalls =
        seen.where((u) => u.path.contains('workspaces')).toList();
    expect(dataCalls, isNotEmpty);
    expect(dataCalls.every((u) => u.queryParameters['auth'] == 'IDTOK-QA'),
        isTrue,
        reason: 'كل قراءة/كتابة تحمل ?auth= — وإلا رفضتها القواعد 401');
    expect(seen.any((u) => u.host.contains('identitytoolkit')), isTrue,
        reason: 'إنشاء هوية مجهولة تلقائياً عند أول استخدام');
  });

  test('ADMIN-07 سجل التفعيل داخل مساحة العمل لا في /admin المحجوبة',
      () async {
    SharedPreferences.setMockInitialValues({});
    final rtdb = Rtdb.instance;
    await rtdb.load();
    final writes = <String>[];
    final client = MockClient((req) async {
      if (req.url.host.contains('identitytoolkit') ||
          req.url.host.contains('securetoken')) {
        return _json({
          'idToken': 'IDTOK-QA',
          'refreshToken': 'REF-QA',
          'expiresIn': '3600'
        });
      }
      if (req.method != 'GET') writes.add(req.url.path);
      if (req.url.path.endsWith('server_clock.json')) {
        return _json(1770000000000);
      }
      if (req.url.path.contains('subscription')) {
        return _json({'status': 'trial', 'expires_at': 1770000000000});
      }
      return _json('null');
    });

    rtdb.clientOverride = client;
    final res = await rtdb.activate(
      rawInput: 'WS-QA-ADMIN',
      planType: 'enterprise',
      duration: PlanDuration.month,
      maxDevices: 5,
    );

    expect(res.workspaceId, 'WS-QA-ADMIN');
    expect(res.maxDevices, 5);
    expect(writes.any((p) => p.contains('workspaces/WS-QA-ADMIN/admin_log')),
        isTrue,
        reason: 'السجل داخل المساحة — مسموح بقواعد workspaces');
    expect(writes.any((p) => p.startsWith('/admin')), isFalse,
        reason: '/admin محجوبة بالقواعد (الافتراضي رفض) — ممنوع الكتابة فيها');
  });

  test('ADMIN-03 تصنيف العدادات: مدفوع/تجربة/منتهٍ بساعة الخادم', () {
    const now = 1770000000000;
    expect(classify('active', now + 1000, now), 'paid');
    expect(classify('trial', now + 1000, now), 'trial');
    expect(classify('trial', now, now), 'expired',
        reason: 'الانتهاء عند اللحظة تماماً = منتهٍ');
    expect(classify('active', now - 1, now), 'expired',
        reason: 'اشتراك مدفوع منتهي الصلاحية = فئة منتهية');
    expect(classify('', 0, now), 'expired');
  });
}

// ملاحظة: تصنيف العدادات (paid/trial/expired) يُختبر منطقياً هنا
// بمحاكاة نفس شروط RtdbMetrics.metrics().
String classify(String status, int expiresAt, int now) {
  final alive = expiresAt > now;
  if (status == 'active' && alive) return 'paid';
  if (status == 'trial' && alive) return 'trial';
  return 'expired';
}

