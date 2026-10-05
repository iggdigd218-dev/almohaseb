// مراجعة مدير الترخيص (2026-09-23) — اختبارات تشخّص العيوب الحقيقية في
// طبقة البيانات: تحويل الحقول، حسم الجهاز بين المساحات، التمديد، العدادات،
// كاش ساعة الخادم، واستعادة الهوية بعد فشل رمز التحديث.
//
// القاعدة: كل اختبار هنا يمرّ على **التنفيذ الحقيقي** (Rtdb.instance عبر
// عميل HTTP مزوّر) لا على نسخة منطقية مكرّرة — نسخة مكرّرة تمرّ حتى لو كان
// الكود الأصلي معطوباً.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:license_admin/rtdb.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, {int code = 200}) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      code,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// طلب مُسجَّل من العميل المزوّر.
class _Req {
  final String method;
  final String path;
  final String auth;
  final String body;
  final String host;
  _Req(this.method, this.path, this.auth, this.body, this.host);
}

/// قاعدة بيانات وهمية تكفي مسارات اللوحة كلها.
class _FakeDb {
  /// معرف المساحة ⇒ {'sub': …, 'roster': …, 'log': …}
  final Map<String, Map<String, Object?>> ws;
  final Map<String, Object?> trials;
  final List<_Req> reqs = [];
  int serverNow;
  int signups = 0;
  bool failSecureToken = false;
  bool failFirstShallow = false;
  bool _shallowFailed = false;

  _FakeDb({required this.ws, Map<String, Object?>? trials, this.serverNow = 1770000000000})
      : trials = trials ?? {};

  int get d30 => const Duration(days: 30).inMilliseconds;

  Future<http.Response> handle(http.Request req) async {
    final url = req.url;
    reqs.add(_Req(req.method, url.path, url.queryParameters['auth'] ?? '',
        req.method == 'GET' ? '' : req.body, url.host));

    if (url.host.contains('identitytoolkit')) {
      signups++;
      return _json({
        'id_token': 'IDTOK-$signups',
        'refresh_token': 'REF-$signups',
        'expires_in': '3600',
      });
    }
    if (url.host.contains('securetoken')) {
      if (failSecureToken) {
        return _json({'error': {'message': 'TOKEN_EXPIRED'}}, code: 400);
      }
      return _json({
        'id_token': 'IDTOK-REFRESH',
        'refresh_token': 'REF-NEW',
        'expires_in': '3600',
        'user_id': 'UID-ADMIN-1',
      });
    }

    final segs =
        url.path.split('/').where((s) => s.isNotEmpty).toList(growable: false);
    final last = segs.isEmpty
        ? ''
        : segs.last.substring(
            0, segs.last.length - (segs.last.endsWith('.json') ? 5 : 0));
    final shallow = url.queryParameters.containsKey('shallow');

    if (segs.length == 1) {
      if (last == 'server_clock') {
        if (req.method == 'PUT') {
          return _json(serverNow);
        }
        return _json(serverNow);
      }
      if (last == 'trials') return _json(trials);
      if (last == 'workspaces') {
        if (shallow) {
          if (failFirstShallow && !_shallowFailed && req.method == 'GET') {
            _shallowFailed = true;
            return _json({'error': 'Permission denied'}, code: 401);
          }
          return _json({for (final k in ws.keys) k: true});
        }
        return _json({for (final k in ws.keys) k: true});
      }
      return _json('null');
    }

    if (segs.first == 'trials') {
      if (req.method == 'PATCH') {
        final m = jsonDecode(req.body) as Map;
        final node = trials[last];
        if (node is Map) {
          trials[last] = {...node, ...m.cast<String, Object?>()};
        } else {
          trials[last] = m.cast<String, Object?>();
        }
        return _json(trials[last]);
      }
      return _json(trials[last] ?? 'null');
    }

    if (segs.first == 'workspaces') {
      final id = Uri.decodeComponent(segs[1]);
      final store = ws[id];
      if (store == null) return _json('null');
      if (segs.length == 2) return _json({for (final k in store.keys) k: true});
      final child = segs[2].endsWith('.json')
          ? segs[2].substring(0, segs[2].length - 5)
          : segs[2];
      if (child == 'subscription') {
        if (req.method == 'PATCH') {
          final m = jsonDecode(req.body) as Map;
          final cur = store['sub'];
          store['sub'] = cur is Map
              ? {...cur.cast<String, Object?>(), ...m.cast<String, Object?>()}
              : m.cast<String, Object?>();
          return _json(store['sub'] as Object);
        }
        final sub = store['sub'];
        return sub == null ? _json('null') : _json(sub);
      }
      if (child == 'roster') {
        final r = store['roster'];
        return r == null ? _json('null') : _json(r);
      }
      if (child == 'admin_log') {
        if (req.method == 'PUT') {
          final key = segs.length > 3 ? segs[3] : '$serverNow';
          final m = jsonDecode(req.body) as Map;
          final log = store['log'];
          final node = log is Map ? Map<String, Object?>.from(log) : <String, Object?>{};
          node[key] = m.cast<String, Object?>();
          store['log'] = node;
          return _json(m);
        }
        final l = store['log'];
        return l == null ? _json('null') : _json(l);
      }
    }
    return _json('null');
  }

  String bodyOf(String method, String pathContains) {
    for (final r in reqs) {
      if (r.method == method && r.path.contains(pathContains)) return r.body;
    }
    return '';
  }

  int count(String pathContains, {String method = ''}) => reqs
      .where((r) =>
          r.path.contains(pathContains) &&
          (method.isEmpty || r.method == method))
      .length;
}

Future<Rtdb> _rtdb(_FakeDb db) async {
  SharedPreferences.setMockInitialValues({});
  final rtdb = Rtdb.instance;
  await rtdb.load();
  rtdb.authToken = '';
  rtdb.resetClockCache();
  rtdb.clientOverride = MockClient(db.handle);
  return rtdb;
}

void main() {
  test('LIC-01 حقول السجل تُقرأ ولو خُزّنت نصوصاً (عرض كل المشتركين)',
      () async {
    // العيب: تعبير max_devices القديم كان يقرأ أولوية العوامل خطأ، فمساحة
    // خُزّنت قيمها كنص («7») كانت تختفي من السجل تماماً (استثناء مُبتلع).
    const now = 1770000000000;
    final db = _FakeDb(ws: {
      'WS-LIVE': {
        'sub': {
          'status': 'active',
          'plan_type': 'enterprise',
          'max_devices': 9,
          'expires_at': now + 2592000000,
        },
        'log': {
          '1': {
            'device_ref': 'DEVICE-A',
            'plan_type': 'enterprise',
            'max_devices': '7',
            'expires_at': '${now + 2592000000}',
            'activated_at': now - 86400000,
          },
        },
      },
      'WS-TEXT': {
        'log': {
          '2': {
            'device_ref': 'DEVICE-B',
            'plan_type': 'enterprise',
            'max_devices': '7',
            'expires_at': '$now',
            'activated_at': now - 172800000,
          },
        },
      },
    });
    final rtdb = await _rtdb(db);

    final list = await rtdb.recentSubscribers();
    final byWs = {for (final e in list) e.workspaceId: e};

    expect(byWs.containsKey('WS-LIVE'), isTrue);
    expect(byWs['WS-LIVE']!.maxDevices, 9,
        reason: 'الحالة الحية تسبق السجل');
    expect(byWs['WS-LIVE']!.expiresAtMs, now + 2592000000);
    expect(byWs.keys, contains('WS-TEXT'),
        reason: 'مساحة بقيم نصية يجب أن تظهر لا أن تختفي');
    expect(byWs['WS-TEXT']!.maxDevices, 7,
        reason: '«7» كنص تُقرأ 7 لا 1 ولا استثناءً');
    expect(byWs['WS-TEXT']!.planType, 'enterprise');
    expect(byWs['WS-TEXT']!.activatedAtMs, now - 172800000);
  });

  test('LIC-02 معرف DEVICE-… يُحسم و يُوسم في فهرس /trials (ربط تلقائي)',
      () async {
    final db = _FakeDb(
      ws: {
        'WS-ONE': {
          'roster': {
            'DEVICE-X': {'last_sync_at': '2026-09-01T10:00:00Z'},
          },
        },
      },
      trials: {
        'FP1111111111111111111111111111': {'workspace_id': 'WS-ONE'},
      },
    );
    final rtdb = await _rtdb(db);

    final ws = await rtdb.resolveWorkspaceId('device-x'); // غير حساس للحالة.
    expect(ws, 'WS-ONE');
    final patch = db.bodyOf('PATCH', 'trials/FP1111111111111111111111111111');
    expect(patch, contains('DEVICE-X'),
        reason: 'الوسم يجعل البحث القادم فورياً من الفهرس');
  });

  test('LIC-03 جهاز في مساحتين ⇒ الأحدث مزامنةً يفوز (لا أول مطابقة)',
      () async {
    final db = _FakeDb(ws: {
      'WS-OLD': {
        'roster': {
          'DEVICE-X': {'last_sync_at': '2026-09-01T10:00:00Z'},
        },
        'sub': {'status': 'active'},
      },
      'WS-NEW': {
        'roster': {
          'DEVICE-X': {'last_sync_at': '2026-09-20T10:00:00Z'},
        },
        'sub': {'status': 'active'},
      },
    });
    final rtdb = await _rtdb(db);

    expect(await rtdb.resolveWorkspaceId('DEVICE-X'), 'WS-NEW',
        reason: 'القديم كان يردّ أول مطابقة فتُفعَّل مساحة ميتة');
  });

  test('LIC-04 تعذّر الحسم ⇒ استثناء يذكر كل المرشحين (لا تخمين صامت)',
      () async {
    final db = _FakeDb(ws: {
      'WS-A': {
        'roster': {
          'DEVICE-X': {'last_sync_at': '2026-09-01T10:00:00Z'},
        },
      },
      'WS-B': {
        'roster': {
          'DEVICE-X': {'last_sync_at': '2026-09-01T10:00:00Z'},
        },
      },
    });
    final rtdb = await _rtdb(db);

    late Object err;
    try {
      await rtdb.resolveWorkspaceId('DEVICE-X');
      fail('كان يجب أن يرفض الحسم');
    } catch (e) {
      err = e;
    }
    final msg = '$err';
    expect(msg, contains('WS-A'));
    expect(msg, contains('WS-B'));
    expect(msg, contains('أكثر من مساحة عمل'));
  });

  test('LIC-05 بصمة التفعيل (32 hex) تردّ مساحة العمل — ومجهولة تُرفض',
      () async {
    final db = _FakeDb(
      ws: {'WS-FP': {'sub': {'status': 'trial'}}},
      trials: {
        'a1b2c3d4e5f60718293a4b5c6d7e8f90': {'workspace_id': 'WS-FP'},
      },
    );
    final rtdb = await _rtdb(db);

    expect(await rtdb.resolveWorkspaceId('a1b2c3d4e5f60718293a4b5c6d7e8f90'),
        'WS-FP');
    expect(
      () => rtdb.resolveWorkspaceId('00000000000000000000000000000000'),
      throwsA(isA<Exception>()),
    );
    expect(() => rtdb.resolveWorkspaceId('   '), throwsA(isA<Exception>()),
        reason: 'مدخل فارغ مرفوض قبل أي طلب شبكة');
  });

  test('LIC-06 التمديد يبني على المتبقي لا على الآن', () async {
    final now = 1770000000000;
    final db = _FakeDb(ws: {
      'WS-EXT': {
        'sub': {
          'status': 'active',
          'plan_type': 'individual',
          'max_devices': 1,
          'expires_at': now + const Duration(days: 10).inMilliseconds,
        },
      },
    });
    final rtdb = await _rtdb(db);

    final r = await rtdb.activate(
      rawInput: 'WS-EXT',
      planType: 'individual',
      duration: PlanDuration.month,
      maxDevices: 1,
      extend: true,
    );

    final expected =
        now + const Duration(days: 10).inMilliseconds + db.d30;
    expect(r.expiresAtMs, closeTo(expected, 1000),
        reason: 'تمديد شهر فوق 10 أيام متبقية = 40 يوماً من الآن');
    expect(db.bodyOf('PUT', 'admin_log'), contains('"extended":true'));
  });

  test('LIC-07 التفعيل يكتب العقد الصحيح + السجل + فهرس /trials', () async {
    final db = _FakeDb(ws: {
      'WS-ACT': {
        'sub': {'status': 'trial', 'device_fingerprint': 'FPABC'},
      },
    }, trials: {
      'FPABC': {'workspace_id': 'WS-ACT'},
    }, serverNow: 1770000000000);
    final rtdb = await _rtdb(db);

    final r = await rtdb.activate(
      rawInput: 'WS-ACT',
      planType: 'enterprise',
      duration: PlanDuration.quarter,
      maxDevices: 5,
    );

    expect(r.workspaceId, 'WS-ACT');
    expect(r.maxDevices, 5);
    expect(r.expiresAtMs, closeTo(1770000000000 + 90 * 86400000, 1000));

    final subBody = db.bodyOf('PATCH', 'subscription');
    expect(subBody, contains('"status":"active"'));
    expect(subBody, contains('"plan_type":"enterprise"'));
    expect(subBody, contains('"max_devices":5'));
    for (final f in const [
      'can_use_categories',
      'can_send_notifications',
      'can_cloud_backup',
      'can_restore_data',
      'can_advanced_search',
      'multi_device_sync',
      'role_permissions',
      'audit_log',
    ]) {
      expect(subBody, contains('"$f":true'),
          reason: 'كل المزايا تُفتح عند التفعيل — $f');
    }

    final log = db.bodyOf('PUT', 'admin_log');
    expect(log, contains('"workspace_id":"WS-ACT"'));
    expect(log, contains('"max_devices":5'));
    expect(subBody, contains('license_admin'),
        reason: 'كل تفعيل موسوم بمصدره الإداري');

    expect(db.bodyOf('PATCH', 'trials/FPABC'), contains('"status":"active"'),
        reason: 'فهرس التجارب مصدر عدّاد «مشتركون مدفوعون»');

    // الفردي يُثبَّت على جهاز واحد مهما أُدخل في حقل السعة.
    final db2 = _FakeDb(ws: {
      'WS-SOLO': {'sub': {'status': 'trial'}},
    });
    final rtdb2 = await _rtdb(db2);
    final solo = await rtdb2.activate(
      rawInput: 'WS-SOLO',
      planType: 'individual',
      duration: PlanDuration.year,
      maxDevices: 5,
    );
    expect(solo.maxDevices, 1);
    expect(db2.bodyOf('PATCH', 'subscription'), contains('"max_devices":1'));

    // والمؤسسة لا تنزل عن جهازين (حد أدنى معقول).
    final db3 = _FakeDb(ws: {
      'WS-ENT2': {'sub': {'status': 'trial'}},
    });
    final rtdb3 = await _rtdb(db3);
    final ent = await rtdb3.activate(
      rawInput: 'WS-ENT2',
      planType: 'enterprise',
      duration: PlanDuration.month,
      maxDevices: 1,
    );
    expect(ent.maxDevices, 2);
  });

  test('LIC-08 العدادات من التنفيذ الحقيقي (مدفوع/تجربة/منتهٍ/بلا خطة)',
      () async {
    const now = 1770000000000;
    final db = _FakeDb(
      ws: {
        'WS-PAID': {
          'sub': {'status': 'active', 'expires_at': now + 86400000},
        },
        'WS-TRIAL': {
          'sub': {'status': 'trial', 'expires_at': now + 86400000},
        },
        'WS-DEAD': {
          'sub': {'status': 'active', 'expires_at': now - 1},
        },
        'WS-NONE': {'roster': {}},
      },
      serverNow: now,
    );
    final rtdb = await _rtdb(db);

    final m = await rtdb.metrics();
    expect(m.totalWorkspaces, 4);
    expect(m.activePaid, 1);
    expect(m.activeTrials, 1);
    expect(m.expired, 1);
    expect(m.noPlan, 1,
        reason: 'الفرق بين الإجمالي ومجموع البطاقات يُشرح لا يُخفى');
  });

  test('LIC-09 ساعة الخادم تُقاس مرة وتُسند بساعة أحادية (كاش)', () async {
    final db = _FakeDb(ws: {}, serverNow: 1770000000000);
    final rtdb = await _rtdb(db);

    final a = await rtdb.serverNowMs();
    final b = await rtdb.serverNowMs();
    expect(a, 1770000000000);
    expect(b, greaterThanOrEqualTo(a));
    expect(db.count('server_clock'), 2,
        reason: 'طلبان فقط (PUT+GET) — لا أربعة لكل عمليتين');

    rtdb.resetClockCache();
    final c = await rtdb.serverNowMs();
    expect(c, greaterThanOrEqualTo(a));
    expect(db.count('server_clock'), 4,
        reason: 'بعد تصفير الكاش يُقاس الخادم من جديد');
  });

  test('LIC-10 مسح المساحات: طلب واحد للمفاتيح + توازٍ محدود', () async {
    final ws = <String, Map<String, Object?>>{};
    for (var i = 0; i < 12; i++) {
      ws['WS-$i'] = {
        'roster': i == 7
            ? {
                'DEVICE-HIT': {'last_sync_at': '2026-09-10T10:00:00Z'},
              }
            : {'DEVICE-OTHER': {}},
      };
    }
    final db = _FakeDb(ws: ws);
    final rtdb = await _rtdb(db);

    expect(await rtdb.resolveWorkspaceId('DEVICE-HIT'), 'WS-7');
    expect(db.count('workspaces.json'), 1,
        reason: 'المسح القديم كان يطلب مفاتيح المساحات مرتين');
  });

  test('ADMIN-12 هوية المدير الثابتة: securetoken لا signUp، وتُحمل في كل طلب',
      () async {
    SharedPreferences.setMockInitialValues({});
    final rtdb = Rtdb.instance;
    await rtdb.load();
    rtdb.authToken = '';
    rtdb.resetClockCache();
    await rtdb.saveAdminRefreshToken('RT-ADMIN-QA');

    final db = _FakeDb(ws: {
      'WS-ADM': {'sub': {'status': 'trial', 'expires_at': 1}},
    });
    rtdb.clientOverride = MockClient(db.handle);

    final m = await rtdb.metrics();
    expect(m.totalWorkspaces, 1);
    expect(rtdb.adminUid, 'UID-ADMIN-1', reason: 'الهوية الثابتة تُلتقط');
    expect(
      db.reqs
          .where((r) => r.path.contains('workspaces'))
          .every((r) => r.auth == 'IDTOK-REFRESH'),
      isTrue,
      reason: 'كل طلب بيانات يحمل توكن المدير');
    expect(db.reqs.any((r) => r.host.contains('identitytoolkit')), isFalse,
        reason: 'لا إنشاء هوية مجهولة مع هوية مدير مضبوطة');
  });

  test('ADMIN-13 بعد 401: إعادة التوقيع بهوية المدير (لا بهوية مجهولة)',
      () async {
    SharedPreferences.setMockInitialValues({});
    final rtdb = Rtdb.instance;
    await rtdb.load();
    rtdb.authToken = '';
    rtdb.resetClockCache();
    await rtdb.saveAdminRefreshToken('RT-ADMIN-QA');

    final db = _FakeDb(ws: {
      'WS-ADM2': {'sub': {'status': 'active', 'expires_at': 1}},
    })
      ..failFirstShallow = true;
    rtdb.clientOverride = MockClient(db.handle);

    final m = await rtdb.metrics();
    expect(m.totalWorkspaces, 1, reason: 'الطلب يُعاد بهوية المدير وينجح');
    expect(rtdb.adminUid, 'UID-ADMIN-1');
    expect(db.reqs.any((r) => r.host.contains('identitytoolkit')), isFalse,
        reason: '');
  });

  test('LIC-11 رمز تحديث تالف ⇒ هوية مجهولة جديدة فوراً (بلا حلقة 401)',
      () async {
    final db = _FakeDb(ws: {
      'WS-AUTH': {'roster': {}},
    })
      ..failSecureToken = true
      ..failFirstShallow = true;
    final rtdb = await _rtdb(db);

    // أول GET يردّ 401 ⇒ إعادة توقيع ⇒ التحديث يفشل ⇒ هوية جديدة ⇒ نجاح.
    final m = await rtdb.metrics();

    expect(m.totalWorkspaces, 1, reason: 'الطلب يُعاد بهوية جديدة وينجح');
    expect(db.signups, 2,
        reason: 'توقيع أول + توقيع بديل بعد سقوط رمز التحديث');
    expect(
      db.reqs
          .where((r) => r.path.endsWith('workspaces.json') && r.auth == 'IDTOK-2')
          .isNotEmpty,
      isTrue,
      reason: 'الطلب الناجح حمل الهوية الجديدة IDTOK-2');
    expect(rtdb.lastAuthError, isNot(contains('TOKEN_EXPIRED')));
  });
}
