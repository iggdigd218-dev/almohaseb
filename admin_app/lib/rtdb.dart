// طبقة الاتصال بقاعدة بيانات Firebase RTDB — تطبيق المدير المستقل.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// مدد خطط الاشتراك المتاحة للتفعيل/التمديد.
enum PlanDuration {
  month('شهر واحد', Duration(days: 30)),
  quarter('3 أشهر', Duration(days: 90)),
  semi('6 أشهر', Duration(days: 180)),
  year('سنة كاملة', Duration(days: 365)),
  lifetime('دائم (مدى الحياة)', Duration(days: 36500));

  final String label;
  final Duration span;
  const PlanDuration(this.label, this.span);
}

/// نتيجة تفعيل ناجحة — للعرض في الرسالة الخضراء.
class ActivationResult {
  final String workspaceId;
  final String planType;
  final int maxDevices;
  final int expiresAtMs;
  final bool lifetime;
  final String clientName;
  final String storeName;
  final String phone;
  final String licenseKey;
  final String deviceId;

  const ActivationResult({
    required this.workspaceId,
    required this.planType,
    required this.maxDevices,
    required this.expiresAtMs,
    required this.lifetime,
    this.clientName = '',
    this.storeName = '',
    this.phone = '',
    this.licenseKey = '',
    this.deviceId = '',
  });
}

/// سجل مشترك للعرض في القائمة.
class SubscriberEntry {
  final String workspaceId;
  final String planType;
  final String status;
  final int maxDevices;
  final int expiresAtMs;
  final int activatedAtMs;
  final String deviceRef; // المعرف/البصمة التي أُدخلت وقت التفعيل.
  final String clientName;
  final String storeName;
  final String phone;
  final String deviceId;
  final String licenseKey;
  final bool isFrozen;
  final Map<String, bool> featureFlags;

  int get expiryDate => expiresAtMs;

  const SubscriberEntry({
    required this.workspaceId,
    required this.planType,
    required this.status,
    required this.maxDevices,
    required this.expiresAtMs,
    required this.activatedAtMs,
    required this.deviceRef,
    this.clientName = '',
    this.storeName = '',
    this.phone = '',
    this.deviceId = '',
    this.licenseKey = '',
    this.isFrozen = false,
    this.featureFlags = const {},
  });

  factory SubscriberEntry.fromSubscriptionMap(
    String wsId,
    Map<dynamic, dynamic> map,
  ) {
    final devId = asStr(map['deviceId'] ??
        map['device_id'] ??
        map['deviceRef'] ??
        map['device_ref'] ??
        '');
    var key =
        asStr(map['licenseKey'] ?? map['license_key'] ?? map['key'] ?? '');
    if (key.isEmpty && devId.isNotEmpty) {
      final clean =
          devId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
      final part = clean.length > 8
          ? clean.substring(clean.length - 8)
          : clean.padRight(8, '0');
      key = 'NX-$part-AUTO';
    } else if (key.isEmpty) {
      key = 'NX-KEY-${DateTime.now().year}';
    }

    final flagsRaw = map['features'] ?? map['feature_flags'];
    final flags = <String, bool>{};
    if (flagsRaw is Map) {
      flagsRaw.forEach((k, v) => flags['$k'] = v == true);
    }

    return SubscriberEntry(
      workspaceId: wsId,
      planType: asStr(map['plan_type'] ?? map['planType'] ?? 'individual'),
      status: asStr(map['status'] ?? 'active'),
      maxDevices: asInt(map['max_devices'] ?? map['maxDevices'], 1),
      expiresAtMs:
          asMs(map['expires_at'] ?? map['expiresAt'] ?? map['expiryDate']),
      activatedAtMs: asMs(map['activated_at'] ?? map['activatedAt']),
      deviceRef: devId,
      clientName: asStr(
          map['clientName'] ?? map['client_name'] ?? map['userName']),
      storeName: asStr(
          map['storeName'] ?? map['store_name'] ?? map['businessName']),
      phone: asStr(
          map['phone'] ?? map['phone_number'] ?? map['whatsapp']),
      deviceId: devId,
      licenseKey: key,
      isFrozen: map['is_frozen'] == true || map['frozen'] == true,
      featureFlags: flags,
    );
  }
}

/// جهاز متصل تابع لمنشأة
class ConnectedDevice {
  final String deviceId;
  final String deviceName;
  final String model;
  final String platform;
  final int linkedAt;
  final int lastSeenAt;

  const ConnectedDevice({
    required this.deviceId,
    this.deviceName = '',
    this.model = '',
    this.platform = '',
    this.linkedAt = 0,
    this.lastSeenAt = 0,
  });

  factory ConnectedDevice.fromJson(String id, Map<dynamic, dynamic> map) {
    return ConnectedDevice(
      deviceId: id,
      deviceName: asStr(map['device_name'] ?? map['deviceName'] ?? id),
      model: asStr(map['model'] ?? map['device_model']),
      platform: asStr(map['platform'] ?? map['os']),
      linkedAt: asMs(map['linked_at'] ??
          map['linkedAt'] ??
          map['created_at'] ??
          map['createdAt']),
      lastSeenAt: asMs(map['last_seen_at'] ??
          map['lastSeenAt'] ??
          map['updated_at'] ??
          map['updatedAt']),
    );
  }
}

/// سجل مدفوعات وتحصيل
class BillingRecord {
  final String id;
  final String workspaceId;
  final String clientName;
  final String storeName;
  final double amount;
  final String currency;
  final String paymentMethod;
  final int durationDays;
  final bool isLifetime;
  final String notes;
  final int timestamp;

  const BillingRecord({
    required this.id,
    required this.workspaceId,
    this.clientName = '',
    this.storeName = '',
    required this.amount,
    this.currency = 'YER',
    this.paymentMethod = 'نقداً',
    this.durationDays = 30,
    this.isLifetime = false,
    this.notes = '',
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'workspace_id': workspaceId,
        'client_name': clientName,
        'store_name': storeName,
        'amount': amount,
        'currency': currency,
        'payment_method': paymentMethod,
        'duration_days': durationDays,
        'is_lifetime': isLifetime,
        'notes': notes,
        'timestamp': timestamp,
      };

  factory BillingRecord.fromJson(String id, Map<dynamic, dynamic> map) {
    return BillingRecord(
      id: id,
      workspaceId: asStr(map['workspace_id']),
      clientName: asStr(map['client_name']),
      storeName: asStr(map['store_name']),
      amount: (map['amount'] is num)
          ? (map['amount'] as num).toDouble()
          : (double.tryParse('${map['amount']}') ?? 0.0),
      currency: asStr(map['currency'] ?? 'YER'),
      paymentMethod: asStr(map['payment_method'] ?? 'نقداً'),
      durationDays: asInt(map['duration_days'], 30),
      isLifetime: map['is_lifetime'] == true,
      notes: asStr(map['notes']),
      timestamp: asMs(map['timestamp']),
    );
  }
}

/// كود تفعيل مسبق الدفع (Voucher)
class VoucherModel {
  final String code;
  final int durationDays;
  final bool isLifetime;
  final int createdAt;
  final bool isUsed;
  final String usedByWs;
  final int usedAt;

  const VoucherModel({
    required this.code,
    required this.durationDays,
    this.isLifetime = false,
    required this.createdAt,
    this.isUsed = false,
    this.usedByWs = '',
    this.usedAt = 0,
  });

  String get durationLabel {
    if (isLifetime) return 'تفعيل دائم (مدى الحياة)';
    if (durationDays >= 365) return 'سنة كاملة ($durationDays يوماً)';
    if (durationDays >= 90) return '3 أشهر ($durationDays يوماً)';
    return '$durationDays يوماً';
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'duration_days': durationDays,
        'is_lifetime': isLifetime,
        'created_at': createdAt,
        'is_used': isUsed,
        'used_by_ws': usedByWs,
        'used_at': usedAt,
      };

  factory VoucherModel.fromJson(String code, Map<dynamic, dynamic> map) {
    return VoucherModel(
      code: code,
      durationDays: asInt(map['duration_days'] ?? map['durationDays'], 30),
      isLifetime: map['is_lifetime'] == true || map['isLifetime'] == true,
      createdAt: asMs(map['created_at'] ?? map['createdAt']),
      isUsed: map['is_used'] == true || map['isUsed'] == true,
      usedByWs: asStr(map['used_by_ws'] ?? map['usedByWs']),
      usedAt: asMs(map['used_at'] ?? map['usedAt']),
    );
  }
}

/// رسالة دعم فني
class SupportMessage {
  final String id;
  final String sender; // 'client' or 'admin'
  final String text;
  final int timestamp;

  const SupportMessage({
    required this.id,
    required this.sender,
    required this.text,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'sender': sender,
        'text': text,
        'timestamp': timestamp,
      };

  factory SupportMessage.fromJson(String id, Map<dynamic, dynamic> map) {
    return SupportMessage(
      id: id,
      sender: asStr(map['sender'] ?? 'client'),
      text: asStr(map['text']),
      timestamp: asMs(map['timestamp']),
    );
  }
}

/// الرابط الرسمي الإقليمي لقاعدة النظام.
const String kOfficialRtdbUrl = String.fromEnvironment(
  'ADMIN_RTDB_URL',
  defaultValue:
      'https://nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app',
);

/// مفتاح Firebase (Web API Key) لنفس المشروع.
const String kFirebaseApiKey = String.fromEnvironment(
  'ADMIN_FIREBASE_API_KEY',
  defaultValue: 'AIzaSyATvivcsVdgrPbvlwVDAWFHGQ-C3vlFySc',
);

const int kMaxWorkspaceScan = 40;
const int kMaxSubscriberScan = 40;

int asInt(Object? v, [int dflt = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? dflt;
  return dflt;
}

int asMs(Object? v) => asInt(v, 0);

String asStr(Object? v) => v == null ? '' : '$v';

const String kHardcodedAdminRefreshToken =
    'AMf-vBy0fav-UQVlyVGr4fVIz7H0VS-RlxLbzXMVDIwm7kGTfjxUeMAwe1tZkwKx_u8geyYdiETw6yW9i3hmja0oDP3wi_M47tVAS6qiASt88Uw73uQv7tANn3W60_WUodhrQTRxpdpCt4aBPN_vVyXra2jCbanZnWxlEcUTOvdSc9y3Ny2pQ6U';

const String kOfficialAdminUid = 'mTMmR6MDBMZH8nKEbvCntRemkq73';

/// رمز التحديث الدائم لهوية المشرف (Owner) عبر --dart-define وقت البناء مع تضمين الرمز الرسمي افتراضياً.
const String kAdminRefreshTokenDefault = String.fromEnvironment(
  'ADMIN_REFRESH_TOKEN',
  defaultValue: kHardcodedAdminRefreshToken,
);

class Rtdb {
  Rtdb._();
  static final Rtdb instance = Rtdb._();

  final http.Client _client = http.Client();
  http.Client? clientOverride;
  http.Client get _http => clientOverride ?? _client;

  String baseUrl = '';
  String authToken = '';
  String adminRefreshToken = '';
  String adminUid = '';

  static const _kUrl = 'rtdbUrl';
  static const _kAuth = 'rtdbAuth';
  static const _kIdToken = 'rtdbIdToken';
  static const _kRefresh = 'rtdbRefreshToken';
  static const _kExpiry = 'rtdbTokenExpiryMs';
  static const _kAdminRt = 'rtdbAdminRefreshToken';
  static const _kAdminUid = 'rtdbAdminUid';

  String _idToken = '';
  String _refreshToken = '';
  int _expiryMs = 0;
  String lastAuthError = '';
  bool _adminAuthFailed = false;

  static const Duration _clockTtl = Duration(seconds: 45);
  final Stopwatch _clockAge = Stopwatch();
  int _clockMs = 0;

  void resetClockCache() {
    _clockMs = 0;
    _clockAge
      ..stop()
      ..reset();
  }

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    baseUrl = (sp.getString(_kUrl) ?? '').trim();
    if (baseUrl.isEmpty) baseUrl = kOfficialRtdbUrl;
    authToken = (sp.getString(_kAuth) ?? '').trim();
    adminRefreshToken = (sp.getString(_kAdminRt) ?? '').trim();
    if (adminRefreshToken.isEmpty || adminRefreshToken.startsWith('GUEST-')) {
      adminRefreshToken = kAdminRefreshTokenDefault.trim();
    }
    adminUid = sp.getString(_kAdminUid) ?? '';
    _idToken = sp.getString(_kIdToken) ?? '';
    _refreshToken = sp.getString(_kRefresh) ?? '';
    _expiryMs = sp.getInt(_kExpiry) ?? 0;

    // تنظيف أي جلسة زائر/مجهولة سابقة حتى لا يُرسل توكن زائر بدلاً من توكن المشرف الرسمي
    if (adminUid.isNotEmpty && adminUid != kOfficialAdminUid) {
      _idToken = '';
      _expiryMs = 0;
      adminUid = '';
      await sp.remove(_kIdToken);
      await sp.remove(_kExpiry);
      await sp.remove(_kAdminUid);
    }
  }

  Future<void> save(String url, [String auth = '']) async {
    baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty) baseUrl = kOfficialRtdbUrl;
    authToken = auth.trim();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kUrl, baseUrl);
    await sp.setString(_kAuth, authToken);
  }

  Future<void> saveAdminRefreshToken(String rt) async {
    adminRefreshToken = rt.trim().replaceAll(RegExp(r'\s+'), '');
    _adminAuthFailed = false;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kAdminRt, adminRefreshToken);
    _idToken = '';
    _expiryMs = 0;
    if (adminRefreshToken.isNotEmpty) {
      final tok = await _signInAsAdmin();
      if (tok.isEmpty || adminUid.isEmpty) {
        throw Exception(lastAuthError.isNotEmpty
            ? lastAuthError
            : 'فشل توثيق رمز المدير مع خادم الهوية');
      }
    }
  }

  bool get configured => baseUrl.isNotEmpty;

  bool get _tokenAlive =>
      _idToken.isNotEmpty &&
      DateTime.now().millisecondsSinceEpoch < (_expiryMs - 60000);

  Future<String> _ensureAuth({bool force = false, bool retried = false}) async {
    // 1. تصحيح أي رمز تحديث أُلصق في authToken
    if (authToken.trim().startsWith('AMf-')) {
      final rt = authToken.trim();
      authToken = '';
      if (adminRefreshToken.isEmpty) {
        adminRefreshToken = rt.replaceAll(RegExp(r'\s+'), '');
      }
    }
    if (authToken.trim().isNotEmpty) return authToken.trim();

    if (adminRefreshToken.isEmpty || adminRefreshToken.startsWith('GUEST-')) {
      adminRefreshToken = kAdminRefreshTokenDefault.trim();
    }

    // 2. إذا وُجد رمز المشرف: الأولوية المطلقة لهوية المشرف الرسمية
    if (adminRefreshToken.isNotEmpty && !_adminAuthFailed) {
      if (!force && _tokenAlive && adminUid == kOfficialAdminUid) {
        return _idToken;
      }
      final adminTok = await _signInAsAdmin();
      if (adminTok.isNotEmpty) return adminTok;
    }

    // 3. التراجع للهوية المجهولة فقط عند غياب رمز المشرف تماماً
    if (!force && _tokenAlive) return _idToken;
    final refresh = force && _refreshToken.isNotEmpty;
    try {
      final body = refresh
          ? {'grant_type': 'refresh_token', 'refresh_token': _refreshToken}
          : {'returnSecureToken': true};
      final uri = refresh
          ? Uri.https('securetoken.googleapis.com', '/v1/token',
              {'key': kFirebaseApiKey})
          : Uri.https('identitytoolkit.googleapis.com', '/v1/accounts:signUp',
              {'key': kFirebaseApiKey});
      final res = await _http
          .post(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        if (refresh && !retried) {
          _refreshToken = '';
          _idToken = '';
          _expiryMs = 0;
          return await _ensureAuth(force: true, retried: true);
        }
        lastAuthError =
            'تعذّر إنشاء هوية الدخول (${res.statusCode}) — تحقق من الاتصال.';
        return _idToken;
      }
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return _idToken;
      _idToken = '${m['id_token'] ?? m['idToken'] ?? ''}';
      _refreshToken = '${m['refresh_token'] ?? m['refreshToken'] ?? ''}';
      final exp = '${m['expires_in'] ?? m['expiresIn'] ?? '3600'}';
      _expiryMs = DateTime.now().millisecondsSinceEpoch +
          (int.tryParse(exp) ?? 3600) * 1000;
      lastAuthError = '';
      await _persistSession();
    } catch (e) {
      lastAuthError = 'تعذّر الاتصال بخادم الهوية: $e';
    }
    return _idToken;
  }

  Future<String> _signInAsAdmin() async {
    try {
      var tokenToUse =
          adminRefreshToken.trim().replaceAll(RegExp(r'\s+'), '');
      if (tokenToUse.isEmpty || tokenToUse.startsWith('GUEST-')) {
        tokenToUse = kAdminRefreshTokenDefault.trim();
      }
      if (tokenToUse.isEmpty) return _idToken;

      final res = await _http
          .post(
              Uri.https('securetoken.googleapis.com', '/v1/token',
                  {'key': kFirebaseApiKey}),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'grant_type': 'refresh_token',
                'refresh_token': tokenToUse,
              }))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        lastAuthError =
            'رفض خادم الهوية رمز المدير (${res.statusCode}: ${res.body}).';
        _adminAuthFailed = true;
        return '';
      }
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return _idToken;
      _idToken = asStr(m['id_token']);
      final rt = asStr(m['refresh_token']);
      if (rt.isNotEmpty) {
        adminRefreshToken = rt;
        final sp = await SharedPreferences.getInstance();
        await sp.setString(_kAdminRt, adminRefreshToken);
      }
      final uid = asStr(m['user_id']);
      if (uid.isNotEmpty) adminUid = uid;
      final exp = '${m['expires_in'] ?? '3600'}';
      _expiryMs = DateTime.now().millisecondsSinceEpoch +
          (int.tryParse(exp) ?? 3600) * 1000;
      lastAuthError = '';
      await _persistSession();
      if (adminUid.isNotEmpty) {
        final sp = await SharedPreferences.getInstance();
        await sp.setString(_kAdminUid, adminUid);
      }
      return _idToken;
    } catch (e) {
      lastAuthError = 'تعذّر توقيع هوية المدير: $e';
      return '';
    }
  }

  Future<void> _persistSession() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kIdToken, _idToken);
      await sp.setString(_kRefresh, _refreshToken);
      await sp.setInt(_kExpiry, _expiryMs);
      if (adminRefreshToken.isNotEmpty) {
        await sp.setString(_kAdminRt, adminRefreshToken);
      }
    } catch (_) {}
  }

  Future<Uri> _u(String path,
      [Map<String, String>? q, String? tokenOverride]) async {
    final clean = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final map = <String, String>{};
    if (q != null) map.addAll(q);
    final tok = tokenOverride ?? await _ensureAuth();
    if (tok.isNotEmpty) map['auth'] = tok;
    final qs = map.isEmpty
        ? ''
        : '?${map.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&')}';
    return Uri.parse('$clean/$path.json$qs');
  }

  Future<String> _reauth() async {
    _idToken = '';
    _expiryMs = 0;
    adminUid = '';
    return await _ensureAuth(force: true);
  }

  Exception _fail(String op, String path, int code, String body) {
    var reason = 'رمز الاستجابة $code';
    try {
      final m = jsonDecode(body);
      if (m is Map && m['error'] != null) reason = '${m['error']}';
    } catch (_) {}
    return Exception('فشلت $op في مسار $path ($code): $reason');
  }

  Future<dynamic> _get(String path, [Map<String, String>? q]) async {
    var r = await _http.get(await _u(path, q)).timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      final fresh = await _reauth();
      if (fresh.isNotEmpty) {
        r = await _http
            .get(await _u(path, q, fresh))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) {
      throw _fail('قراءة', path, r.statusCode, r.body);
    }
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<void> _patch(String path, Map<String, dynamic> body) async {
    var r = await _http
        .patch(await _u(path), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      final fresh = await _reauth();
      if (fresh.isNotEmpty) {
        r = await _http
            .patch(await _u(path, null, fresh), body: jsonEncode(body))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode != 200) {
      throw _fail('كتابة', path, r.statusCode, r.body);
    }
  }

  Future<void> _put(String path, Object body) async {
    var r = await _http
        .put(await _u(path), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      final fresh = await _reauth();
      if (fresh.isNotEmpty) {
        r = await _http
            .put(await _u(path, null, fresh), body: jsonEncode(body))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode != 200) {
      throw _fail('كتابة', path, r.statusCode, r.body);
    }
  }

  Future<void> _delete(String path) async {
    var r = await _http
        .delete(await _u(path))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode == 401 || r.statusCode == 403) {
      final fresh = await _reauth();
      if (fresh.isNotEmpty) {
        r = await _http
            .delete(await _u(path, null, fresh))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (r.statusCode != 200 && r.statusCode != 204) {
      throw _fail('حذف', path, r.statusCode, r.body);
    }
  }

  // Public CRUD operations for external callers
  Future<dynamic> getJson(String path) => _get(path);
  Future<void> patchJson(String path, Map<String, dynamic> data) =>
      _patch(path, data);
  Future<void> putJson(String path, dynamic data) => _put(path, data);
  Future<void> deleteJson(String path) => _delete(path);

  static const Duration kClockTtl = _clockTtl;

  Future<int> serverNowMs({bool force = false}) async {
    if (!force && _clockMs > 0 && _clockAge.elapsed < _clockTtl) {
      return _clockMs + _clockAge.elapsedMilliseconds;
    }
    await _put('server_clock', {'.sv': 'timestamp'});
    final v = await _get('server_clock');
    final ms = asMs(v);
    if (ms <= 0) throw Exception('تعذّر قراءة ساعة الخادم');
    _clockMs = ms;
    _clockAge
      ..reset()
      ..start();
    return ms;
  }

  Future<List<T>> _gather<T>(List<Future<T?> Function()> tasks,
      {int limit = 6}) async {
    if (tasks.isEmpty) return const [];
    final out = List<T?>.filled(tasks.length, null);
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= tasks.length) return;
        try {
          out[i] = await tasks[i]();
        } catch (_) {}
      }
    }

    final workers = limit < tasks.length ? limit : tasks.length;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return out.whereType<T>().toList();
  }

  Future<_DevHit?> _scanWorkspaceForDevice(String ws, String devId) async {
    final enc = Uri.encodeComponent(ws);
    // (1) سجل إداري سابق بنفس المعرف.
    try {
      final logs = await _get('workspaces/$enc/admin_log');
      if (logs is Map) {
        for (final v in logs.values) {
          if (v is Map && asStr(v['device_ref']).trim().toUpperCase() == devId) {
            return _DevHit(ws: ws, planned: 1, viaLog: true);
          }
        }
      }
    } catch (_) {}

    // (2) roster أجهزة المساحة.
    try {
      final roster = await _get('workspaces/$enc/roster');
      if (roster is Map) {
        for (final e in roster.entries) {
          if ('${e.key}'.toUpperCase() != devId) continue;
          final row = e.value is Map ? e.value as Map : const {};
          Map? sub;
          try {
            final s = await _get('workspaces/$enc/subscription');
            if (s is Map) sub = s;
          } catch (_) {}
          return _DevHit(
            ws: ws,
            sync: _msOf(row['last_sync_at']),
            seen: _msOf(row['last_seen_at']),
            upd: _msOf(row['updated_at']),
            owner: asInt(row['is_owner']),
            planned: (sub != null && asStr(sub['plan_type']).isNotEmpty) ? 1 : 0,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  static int _msOf(Object? v) =>
      DateTime.tryParse(asStr(v))?.millisecondsSinceEpoch ?? asMs(v);

  /// تحويل المدخل إلى معرف مساحة عمل — يقبل ثلاثة أشكال تلقائياً:
  ///  1) بصمة التفعيل (32 خانة hex) ⇒ فهرس trials/(fp).
  ///  2) معرف الجهاز (DEVICE-XXXXXXXX) ⇒ بحث في roster كل المساحات.
  ///  3) معرف مساحة العمل مباشرة ⇒ تحقق من وجود العقدة.
  Future<String> resolveWorkspaceId(String input) async {
    final id = input.trim();
    if (id.isEmpty) throw Exception('أدخل معرف الجهاز أو مساحة العمل أولاً');

    // (1) بصمة تفعيل 32-hex.
    if (RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(id)) {
      final t = await _get('trials/${Uri.encodeComponent(id)}');
      if (t is Map && asStr(t['workspace_id']).isNotEmpty) {
        return asStr(t['workspace_id']);
      }
      throw Exception('لم يُعثر على مساحة عمل مرتبطة بهذه البصمة.\n'
          'تأكد أن العميل فتح التطبيق مرة واحدة على الأقل بعد التثبيت.');
    }

    // (2) معرف جهاز DEVICE-… ⇒ بحث متعدد الطبقات + ربط تلقائي:
    //     (أ) فهرس /trials (device_id)، (ب) مسح متوازٍ محدود لسجلات
    //     التفعيل وroster كل مساحة، (ج) الربط التلقائي عند مرشح وحيد.
    //     عند العثور عبر مسار غير مفهرس نكتب device_id في /trials
    //     ليكون البحث القادم فورياً.
    if (RegExp(r'^DEVICE-', caseSensitive: false).hasMatch(id)) {
      final devId = id.toUpperCase();

      // (أ) فهرس التجارب — أرخص مسح، ويجمع مرشحي الربط التلقائي.
      final trials = await _get('trials');
      final unlabeled = <String>{}; // مساحات بلا device_id في فهرسها.
      if (trials is Map) {
        for (final v in trials.values) {
          if (v is! Map) continue;
          final ws = asStr(v['workspace_id']);
          if (asStr(v['device_id']).toUpperCase() == devId && ws.isNotEmpty) {
            return ws;
          }
          if (ws.isNotEmpty && asStr(v['device_id']).isEmpty) {
            unlabeled.add(ws);
          }
        }
      }

      // (ب) مسح المساحات — **طلب واحد** لمفاتيح المساحات (كان يُطلق مرتين
      // في الشكل القديم) ثم مسح متوازٍ بسقف [kMaxWorkspaceScan].
      final keys = await _get('workspaces', {'shallow': 'true'});
      final wsKeys = keys is Map
          ? keys.keys.map((k) => '$k').take(kMaxWorkspaceScan).toList()
          : <String>[];

      final hits = await _gather<_DevHit>(
        [for (final ws in wsKeys) () => _scanWorkspaceForDevice(ws, devId)],
      );

      if (hits.length == 1) {
        final ws = hits.first.ws;
        await _linkDeviceToWorkspace(deviceId: devId, workspaceId: ws);
        return ws;
      }
      if (hits.length > 1) {
        hits.sort(_DevHit.rank);
        final best = hits.first;
        final runnerUp = hits[1];
        final decided = best.sync > runnerUp.sync ||
            best.seen > runnerUp.seen ||
            best.planned > runnerUp.planned;
        final ws = best.ws;
        if (decided) {
          await _linkDeviceToWorkspace(deviceId: devId, workspaceId: ws);
          return ws;
        }
        throw Exception(
            'هذا الجهاز موجود في أكثر من مساحة عمل ولا يمكن الحسم تلقائياً:\n'
            '${hits.map((h) => '• ${h.ws}').join('\n')}\n'
            'ألصق معرف المساحة الصحيح مباشرة، أو بصمة التفعيل (32 خانة) من '
            'رسالة العميل.');
      }

      // (ج) الربط التلقائي — الجهاز الفردي لا يظهر في أي roster وسجله
      // القديم في /trials بلا device_id بعد:
      //   • مساحة وحيدة في القاعدة كلها ⇒ هي مساحة العميل حتماً.
      //   • أو مرشح وحيد غير موسوم في الفهرس ⇒ نربطه به فوراً.
      if (wsKeys.length == 1) {
        await _linkDeviceToWorkspace(
            deviceId: devId, workspaceId: wsKeys.first);
        return wsKeys.first;
      }
      if (unlabeled.length == 1) {
        final ws = unlabeled.first;
        await _linkDeviceToWorkspace(deviceId: devId, workspaceId: ws);
        return ws;
      }

      throw Exception(unlabeled.length > 1
          ? 'المعرف غير موسوم بعد ويوجد ${unlabeled.length} عملاء غير '
              'موسومين — لا يمكن الحسم تلقائياً.\n'
              'ألصق «بصمة التفعيل» (32 خانة) من رسالة العميل، أو اطلب منه '
              'فتح التطبيق مرة واحدة بعد التحديث ليُوسم تلقائياً.'
          : 'لم يُعثر على جهاز بهذا المعرف في أي مساحة عمل.\n'
              'جرّب لصق «بصمة التفعيل» من رسالة العميل بدلاً منه.');
    }

    // (3) معرف مساحة مباشر — نتحقق من وجود عقدة الاشتراك أو المساحة.
    final sub = await _get('workspaces/${Uri.encodeComponent(id)}/subscription');
    if (sub != null) return id;
    final ws =
        await _get('workspaces/${Uri.encodeComponent(id)}', {'shallow': 'true'});
    if (ws != null) return id;
    throw Exception('لا توجد مساحة عمل بهذا المعرف في قاعدة البيانات.');
  }

  /// (الربط التلقائي) وسم سجل /trials الخاص بالمساحة بمعرف الجهاز —
  /// البحث القادم بنفس المعرف يصبح فورياً من الفهرس. تحسيني: فشله
  /// لا يمنع إتمام التفعيل الجاري.
  Future<void> _linkDeviceToWorkspace({
    required String deviceId,
    required String workspaceId,
  }) async {
    try {
      final trials = await _get('trials');
      if (trials is! Map) return;
      for (final e in trials.entries) {
        final v = e.value;
        if (v is Map && asStr(v['workspace_id']) == workspaceId) {
          if (asStr(v['device_id']).isEmpty) {
            await _patch('trials/${Uri.encodeComponent('${e.key}')}',
                {'device_id': deviceId});
          }
          return;
        }
      }
    } catch (_) {}
  }

  Future<ActivationResult> activate({
    required String rawInput,
    required String planType,
    required PlanDuration duration,
    required int maxDevices,
    bool extend = false,
    String clientName = '',
    String storeName = '',
    String phone = '',
    String licenseKey = '',
  }) async {
    final plan = planType == 'enterprise' ? 'enterprise' : 'individual';
    final seats = plan == 'enterprise' ? (maxDevices < 2 ? 2 : maxDevices) : 1;
    final ws = await resolveWorkspaceId(rawInput);
    final now = await serverNowMs();
    final lifetime = duration == PlanDuration.lifetime;
    final enc = Uri.encodeComponent(ws);

    int base = now;
    if (extend) {
      final cur = await _get('workspaces/$enc/subscription');
      if (cur is Map) {
        final curExp = asMs(cur['expires_at']);
        if (curExp > now) base = curExp;
      }
    }
    final expires = base + duration.span.inMilliseconds;

    final subPayload = <String, dynamic>{
      'status': 'active',
      'is_active': true,
      'plan_type': plan,
      'max_devices': seats,
      'expires_at': expires,
      'activated_at': now,
      'updated_at': now,
      'activated_by': 'license_admin',
      'features': {
        'can_use_categories': true,
        'can_send_notifications': true,
        'can_cloud_backup': true,
        'can_restore_data': true,
        'can_advanced_search': true,
        'multi_device_sync': true,
        'role_permissions': true,
        'audit_log': true,
        'cloud_sync': true,
        'cloud_backup': true,
        'multi_branch': true,
        'multi_user': true,
        'advanced_invoicing': true,
      },
    };
    if (clientName.trim().isNotEmpty) {
      subPayload['clientName'] = clientName.trim();
      subPayload['client_name'] = clientName.trim();
    }
    if (storeName.trim().isNotEmpty) {
      subPayload['storeName'] = storeName.trim();
      subPayload['store_name'] = storeName.trim();
    }
    if (phone.trim().isNotEmpty) {
      subPayload['phone'] = phone.trim();
      subPayload['phone_number'] = phone.trim();
    }
    if (licenseKey.trim().isNotEmpty) {
      subPayload['licenseKey'] = licenseKey.trim();
      subPayload['license_key'] = licenseKey.trim();
    }

    await _patch('workspaces/$enc/subscription', subPayload);

    try {
      final cur = await _get('workspaces/$enc/subscription');
      final fp = cur is Map ? asStr(cur['device_fingerprint']) : '';
      if (fp.isNotEmpty) {
        await _patch('trials/${Uri.encodeComponent(fp)}', {
          'status': 'active',
          'expires_at': expires,
          'workspace_id': ws,
        });
      }
    } catch (_) {}

    try {
      await _put('workspaces/$enc/admin_log/$now', {
        'workspace_id': ws,
        'device_ref': rawInput.trim(),
        'plan_type': plan,
        'max_devices': seats,
        'expires_at': expires,
        'activated_at': now,
        'updated_at': now,
        'lifetime': lifetime,
        if (extend) 'extended': true,
        if (clientName.trim().isNotEmpty) 'client_name': clientName.trim(),
        if (storeName.trim().isNotEmpty) 'store_name': storeName.trim(),
        if (phone.trim().isNotEmpty) 'phone': phone.trim(),
        if (licenseKey.trim().isNotEmpty) 'license_key': licenseKey.trim(),
      });
    } catch (_) {}

    return ActivationResult(
      workspaceId: ws,
      planType: plan,
      maxDevices: seats,
      expiresAtMs: expires,
      lifetime: lifetime,
      clientName: clientName,
      storeName: storeName,
      phone: phone,
      licenseKey: licenseKey,
      deviceId: rawInput.trim(),
    );
  }

  Future<List<SubscriberEntry>> recentSubscribers({int limit = 30}) async {
    final keys = await _get('workspaces', {'shallow': 'true'});
    if (keys is! Map || keys.isEmpty) return const [];
    final wsKeys =
        keys.keys.map((k) => '$k').take(kMaxSubscriberScan).toList();

    final rows = await _gather<List<SubscriberEntry>>(
      [for (final ws in wsKeys) () => _readWorkspaceEntries(ws)],
    );
    final raw = rows.expand((r) => r).toList();
    // ترتيب: الحسابات الفعالة أولاً، ثم الأطول مدة والأحدث نشاطاً
    raw.sort((a, b) {
      final aActive = a.status == 'active' ? 1 : 0;
      final bActive = b.status == 'active' ? 1 : 0;
      final cmp = bActive.compareTo(aActive);
      if (cmp != 0) return cmp;
      final expCmp = b.expiresAtMs.compareTo(a.expiresAtMs);
      if (expCmp != 0) return expCmp;
      return b.activatedAtMs.compareTo(a.activatedAtMs);
    });

    // دمج التكرارات تلقائياً: إذا ظهر نفس المتجر بنفس الهاتف أو نفس الجهاز،
    // نُبقي السجل الأحدث والفعال فقط ونستبعد النسخ الميتة الناتجة عن تكرار التثبيت.
    final seenKeys = <String>{};
    final out = <SubscriberEntry>[];

    for (final entry in raw) {
      if (seenKeys.contains('ws:${entry.workspaceId}')) continue;

      final dev = entry.deviceId.trim().toUpperCase();
      final storeName = entry.storeName.trim();
      final phone = entry.phone.trim();
      final storePhone = '${storeName}_$phone';

      if (dev.isNotEmpty && dev.startsWith('DEVICE-')) {
        if (seenKeys.contains('dev:$dev')) continue;
        seenKeys.add('dev:$dev');
      }

      if (storeName.isNotEmpty && phone.isNotEmpty) {
        if (seenKeys.contains('sp:$storePhone')) continue;
        seenKeys.add('sp:$storePhone');
      }

      seenKeys.add('ws:${entry.workspaceId}');
      out.add(entry);
    }

    return out.take(limit).toList();
  }

  Future<List<SubscriberEntry>> _readWorkspaceEntries(String ws) async {
    final enc = Uri.encodeComponent(ws);
    Map? live;
    try {
      final sub = await _get('workspaces/$enc/subscription');
      if (sub is Map) live = sub;
    } catch (_) {}

    String storeFallback = asStr(live?['storeName'] ??
        live?['store_name'] ??
        live?['businessName']);
    String clientFallback = asStr(live?['clientName'] ??
        live?['client_name'] ??
        live?['userName']);
    String phoneFallback = asStr(live?['phone'] ??
        live?['phone_number'] ??
        live?['whatsapp']);
    String devIdFallback = asStr(live?['deviceId'] ??
        live?['device_id'] ??
        live?['deviceRef'] ??
        live?['device_ref']);

    // استخراج تكميلي من الأجهزة المتصلة إن كانت بيانات المنشأة فارغة
    if (storeFallback.isEmpty || clientFallback.isEmpty || phoneFallback.isEmpty || devIdFallback.isEmpty) {
      try {
        final devs = await _get('workspaces/$enc/devices');
        if (devs is Map && devs.isNotEmpty) {
          for (final dv in devs.values) {
            if (dv is Map) {
              if (storeFallback.isEmpty) {
                storeFallback = asStr(dv['storeName'] ?? dv['store_name']);
              }
              if (clientFallback.isEmpty) {
                clientFallback = asStr(dv['clientName'] ??
                    dv['client_name'] ??
                    dv['deviceName'] ??
                    dv['device_name']);
              }
              if (phoneFallback.isEmpty) {
                phoneFallback = asStr(dv['phone'] ?? dv['phone_number']);
              }
              if (devIdFallback.isEmpty) {
                devIdFallback = asStr(dv['deviceId'] ?? dv['device_id']);
              }
            }
          }
        }
      } catch (_) {}
    }

    // استخراج تكميلي من طلبات التفعيل إن كانت ما زالت فارغة
    if (storeFallback.isEmpty || clientFallback.isEmpty || phoneFallback.isEmpty || devIdFallback.isEmpty) {
      try {
        final req = await _get('workspaces/$enc/license_request');
        if (req is Map) {
          if (storeFallback.isEmpty) {
            storeFallback = asStr(req['storeName'] ?? req['store_name']);
          }
          if (clientFallback.isEmpty) {
            clientFallback = asStr(req['clientName'] ?? req['client_name']);
          }
          if (phoneFallback.isEmpty) {
            phoneFallback = asStr(req['phone']);
          }
          if (devIdFallback.isEmpty) {
            devIdFallback = asStr(req['deviceId'] ?? req['device_id']);
          }
        }
      } catch (_) {}
    }

    try {
      final logs = await _get('workspaces/$enc/admin_log');
      if (logs is Map) {
        final out = <SubscriberEntry>[];
        for (final e in logs.entries) {
          final v = e.value;
          if (v is! Map) continue;
          final devRef = asStr(v['device_ref'] ??
              live?['device_id'] ??
              live?['deviceId'] ??
              devIdFallback);

          final resolvedStore = asStr(live?['storeName'] ??
              live?['store_name'] ??
              v['store_name'] ??
              v['storeName'] ??
              storeFallback);
          final resolvedClient = asStr(live?['clientName'] ??
              live?['client_name'] ??
              v['client_name'] ??
              v['clientName'] ??
              clientFallback);
          final resolvedPhone = asStr(live?['phone'] ??
              live?['phone_number'] ??
              v['phone'] ??
              v['phone_number'] ??
              phoneFallback);

          out.add(SubscriberEntry(
            workspaceId: ws,
            planType: _pick(live?['plan_type'], v['plan_type'], 'individual'),
            status: _pick(live?['status'], null, 'active'),
            maxDevices: asInt(
                _firstNum(live?['max_devices'], v['max_devices']), 1),
            expiresAtMs: asMs(
                _firstNum(live?['expires_at'], v['expires_at'])),
            activatedAtMs: asMs(v['activated_at']) > 0
                ? asMs(v['activated_at'])
                : asMs(e.key),
            deviceRef: devRef,
            clientName: resolvedClient,
            storeName: resolvedStore,
            phone: resolvedPhone,
            deviceId: devRef,
            licenseKey: asStr(live?['licenseKey'] ??
                live?['license_key'] ??
                v['license_key'] ??
                v['licenseKey']),
            isFrozen: live?['is_frozen'] == true || live?['frozen'] == true,
            featureFlags: (live?['features'] is Map)
                ? (live!['features'] as Map)
                    .map((k, val) => MapEntry('$k', val == true))
                : const {},
          ));
        }
        return out;
      }
    } catch (_) {}
    if (live != null) {
      final baseEntry = SubscriberEntry.fromSubscriptionMap(ws, live);
      return [
        SubscriberEntry(
          workspaceId: baseEntry.workspaceId,
          planType: baseEntry.planType,
          status: baseEntry.status,
          maxDevices: baseEntry.maxDevices,
          expiresAtMs: baseEntry.expiresAtMs,
          activatedAtMs: baseEntry.activatedAtMs,
          deviceRef: baseEntry.deviceRef.isNotEmpty ? baseEntry.deviceRef : devIdFallback,
          clientName: baseEntry.clientName.isNotEmpty ? baseEntry.clientName : clientFallback,
          storeName: baseEntry.storeName.isNotEmpty ? baseEntry.storeName : storeFallback,
          phone: baseEntry.phone.isNotEmpty ? baseEntry.phone : phoneFallback,
          deviceId: baseEntry.deviceId.isNotEmpty ? baseEntry.deviceId : devIdFallback,
          licenseKey: baseEntry.licenseKey,
          isFrozen: baseEntry.isFrozen,
          featureFlags: baseEntry.featureFlags,
        ),
      ];
    }
    return const [];
  }

  // ==================== أفعال التحكم عن بعد (Remote Actions) ====================

  /// 2. القفل والتعليق الفوري (Kill Switch / Freeze)
  Future<void> toggleFreezeSubscriber(String wsId, bool freeze) async {
    final enc = Uri.encodeComponent(wsId);
    await _patch('workspaces/$enc/subscription', {
      'is_frozen': freeze,
      'frozen_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 2. فك ارتباط المعرف (Unlink Device ID)
  Future<void> unlinkSubscriberDevice(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    await _patch('workspaces/$enc/subscription', {
      'device_id': '',
      'deviceId': '',
      'unlinked_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 3. مفاتيح الميزات والسقوف (Dynamic Feature Flags & Limits)
  Future<void> updateFeatureFlags(
    String wsId,
    Map<String, bool> flags, {
    int? maxDevices,
  }) async {
    final enc = Uri.encodeComponent(wsId);
    final payload = <String, dynamic>{
      'features': flags,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (maxDevices != null) {
      payload['max_devices'] = maxDevices;
    }
    await _patch('workspaces/$enc/subscription', payload);
  }

  /// 4. الأجهزة المتصلة وطرد جهاز (Multi-Device Management)
  Future<List<ConnectedDevice>> getConnectedDevices(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    final res = await _get('workspaces/$enc/devices');
    if (res is! Map) return [];
    return res.entries
        .map((e) => ConnectedDevice.fromJson('${e.key}', e.value as Map))
        .toList();
  }

  Future<void> kickDevice(String wsId, String deviceId) async {
    final enc = Uri.encodeComponent(wsId);
    final devEnc = Uri.encodeComponent(deviceId);
    await _delete('workspaces/$enc/devices/$devEnc');
    await _put('workspaces/$enc/revoked_devices/$devEnc', {
      'kicked_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 5. أمر النسخ الفوري عن بعد (Remote Instant Backup)
  Future<void> requestInstantBackup(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    await _patch('workspaces/$enc/remote_commands', {
      'request_backup': true,
      'requested_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 1. إرسال إشعار وتنبيه موجه لعميل محدد (Direct Push Alert)
  Future<void> sendTargetedNotification(
    String wsId, {
    required String title,
    required String body,
    bool isModal = false,
  }) async {
    final enc = Uri.encodeComponent(wsId);
    final now = DateTime.now().millisecondsSinceEpoch;
    await _put('workspaces/$enc/notifications/$now', {
      'id': '$now',
      'title': title,
      'body': body,
      'is_modal': isModal,
      'created_at': now,
      'read': false,
    });
  }

  /// 7. تسجيل الدفع والتحصيل (Billing & CRM)
  Future<void> recordBillingPayment(BillingRecord record) async {
    final enc = Uri.encodeComponent(record.workspaceId);
    await _put(
        'workspaces/$enc/billing_records/${record.id}', record.toJson());
    await _put('billing_records/${record.id}', record.toJson());
  }

  Future<List<BillingRecord>> getBillingHistory(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    final res = await _get('workspaces/$enc/billing_records');
    if (res is! Map) return [];
    final list = res.entries
        .map((e) => BillingRecord.fromJson('${e.key}', e.value as Map))
        .toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  /// 6. توليد واستعراض أكواد التفعيل (Vouchers)
  Future<void> generateVouchers({
    required int durationDays,
    bool isLifetime = false,
    int count = 5,
  }) async {
    final rnd = Random();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < count; i++) {
      final part1 = rnd.nextInt(9000) + 1000;
      final part2 = rnd.nextInt(9000) + 1000;
      final part3 = rnd.nextInt(9000) + 1000;
      final code = 'VCH-$part1-$part2-$part3';
      final voucher = VoucherModel(
        code: code,
        durationDays: durationDays,
        isLifetime: isLifetime,
        createdAt: now,
      );
      await _put('vouchers/$code', voucher.toJson());
    }
  }

  Future<List<VoucherModel>> getVouchers() async {
    final res = await _get('vouchers');
    if (res is! Map) return [];
    final list = res.entries
        .map((e) => VoucherModel.fromJson('${e.key}', e.value as Map))
        .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> deleteVoucher(String code) async {
    await _delete('vouchers/${Uri.encodeComponent(code)}');
  }

  /// 8. صندوق وارد الدعم الفني (Support Inbox)
  Future<List<Map<String, dynamic>>> getSupportConversations() async {
    final res = await _get('support_chats');
    if (res is! Map) return [];
    final out = <Map<String, dynamic>>[];
    for (final e in res.entries) {
      final ws = '${e.key}';
      final val = e.value;
      if (val is! Map) continue;
      final meta = (val['meta'] is Map) ? val['meta'] as Map : null;
      final msgs = val['messages'];

      String lastMsg = '';
      int lastTs = 0;
      if (msgs is Map && msgs.isNotEmpty) {
        final sorted = msgs.entries.toList()
          ..sort((a, b) => asMs((a.value as Map)['timestamp'] ??
                  (a.value as Map)['created_at'])
              .compareTo(asMs((b.value as Map)['timestamp'] ??
                  (b.value as Map)['created_at'])));
        final lastEntry = sorted.last.value as Map;
        lastMsg = asStr(lastEntry['text']);
        lastTs = asMs(lastEntry['timestamp'] ??
            lastEntry['created_at'] ??
            lastEntry['createdAt']);
      } else {
        lastMsg = asStr(meta?['lastMessage'] ??
            meta?['last_message'] ??
            val['lastMessage'] ??
            val['last_message']);
        lastTs = asMs(meta?['updatedAt'] ??
            meta?['updated_at'] ??
            val['updatedAt'] ??
            val['updated_at']);
      }

      String storeName = asStr(meta?['storeName'] ??
          meta?['store_name'] ??
          val['storeName'] ??
          val['store_name']);
      String clientName = asStr(meta?['clientName'] ??
          meta?['client_name'] ??
          val['clientName'] ??
          val['client_name']);
      String phone = asStr(meta?['phone'] ?? val['phone']);

      // إذا لم تكن موجودة في meta أو الجذر، نستخرجها من رسائل العميل
      if ((storeName.isEmpty || clientName.isEmpty || phone.isEmpty) &&
          msgs is Map) {
        for (final m in msgs.values) {
          if (m is Map) {
            if (storeName.isEmpty) {
              storeName = asStr(m['storeName'] ?? m['store_name']);
            }
            if (clientName.isEmpty) {
              clientName = asStr(m['clientName'] ??
                  m['client_name'] ??
                  m['senderName'] ??
                  m['sender_name']);
            }
            if (phone.isEmpty) phone = asStr(m['phone']);
          }
        }
      }

      // إذا ما زالت فارغة، نحاول قراءة اشتراك المنشأة
      if (storeName.isEmpty || clientName.isEmpty || phone.isEmpty) {
        try {
          final sub = await _get(
              'workspaces/${Uri.encodeComponent(ws)}/subscription');
          if (sub is Map) {
            if (storeName.isEmpty) {
              storeName = asStr(sub['storeName'] ??
                  sub['store_name'] ??
                  sub['businessName']);
            }
            if (clientName.isEmpty) {
              clientName = asStr(sub['clientName'] ??
                  sub['client_name'] ??
                  sub['userName']);
            }
            if (phone.isEmpty) {
              phone = asStr(sub['phone'] ?? sub['phone_number']);
            }
          }
        } catch (_) {}
      }

      final unread = val['unread_by_admin'] == true ||
          val['unreadByAdmin'] == true ||
          meta?['unread_by_admin'] == true ||
          meta?['unreadByAdmin'] == true;

      out.add({
        'workspaceId': ws,
        'storeName': storeName.isNotEmpty ? storeName : ws,
        'clientName': clientName,
        'phone': phone,
        'unreadByAdmin': unread,
        'lastMessage': lastMsg,
        'lastTimestamp': lastTs,
      });
    }
    out.sort((a, b) =>
        (b['lastTimestamp'] as int).compareTo(a['lastTimestamp'] as int));
    return out;
  }

  Future<List<SupportMessage>> getSupportMessages(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    final res = await _get('support_chats/$enc/messages');
    if (res is! Map) return [];
    final list = res.entries
        .map((e) => SupportMessage.fromJson('${e.key}', e.value as Map))
        .toList();
    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return list;
  }

  Future<void> sendSupportReply(String wsId, String text) async {
    final enc = Uri.encodeComponent(wsId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgId = 'admin_$now';
    final payload = {
      'id': msgId,
      'sender': 'admin',
      'senderName': 'فريق الدعم الفني',
      'sender_name': 'فريق الدعم الفني',
      'text': text,
      'timestamp': now,
      'created_at': now,
      'createdAt': now,
      'isRead': false,
      'is_read': false,
    };
    await _put('support_chats/$enc/messages/$msgId', payload);
    final patch = {
      'unread_by_client': true,
      'unreadByClient': true,
      'unread_by_admin': false,
      'unreadByAdmin': false,
      'last_reply_at': now,
      'last_message': text,
      'lastMessage': text,
      'last_sender': 'admin',
      'lastSender': 'admin',
      'updated_at': now,
      'updatedAt': now,
    };
    await _patch('support_chats/$enc', patch);
    await _patch('support_chats/$enc/meta', patch);
  }

  Future<void> markSupportChatRead(String wsId) async {
    final enc = Uri.encodeComponent(wsId);
    final patch = {
      'unread_by_admin': false,
      'unreadByAdmin': false,
    };
    await _patch('support_chats/$enc', patch);
    await _patch('support_chats/$enc/meta', patch);
  }

  /// 1. إرسال تنبيه جماعي شامل (Broadcast Alert)
  Future<void> sendBroadcastNotification({
    required String title,
    required String body,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = {
      'id': '$now',
      'title': title,
      'body': body,
      'is_modal': false,
      'isModal': false,
      'created_at': now,
      'createdAt': now,
      'timestamp': {'.sv': 'timestamp'},
    };
    await _put('system/broadcast_notifications/$now', payload);
    await _put('system/broadcast_alerts/$now', payload);
  }

  /// 2. وضع الصيانة السحابي (Cloud Maintenance Mode)
  Future<void> setMaintenanceMode({
    required bool active,
    required String message,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = {
      'is_active': active,
      'isActive': active,
      'message': message,
      'updated_at': now,
      'updatedAt': now,
    };
    await _patch('system/maintenance', payload);
    await _patch('system/maintenance_mode', payload);
  }

  Future<Map<String, dynamic>?> getMaintenanceMode() async {
    final res = await _get('system/maintenance');
    if (res is Map) return Map<String, dynamic>.from(res);
    final res2 = await _get('system/maintenance_mode');
    if (res2 is Map) return Map<String, dynamic>.from(res2);
    return null;
  }

  /// 2. فرض التحديث الإجباري (Force Update Policy)
  Future<void> setForceUpdateMinVersion(int minBuild, String minVersion) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = {
      'min_build': minBuild,
      'min_version': minVersion,
      'minBuild': minBuild,
      'minVersion': minVersion,
      'updated_at': now,
      'updatedAt': now,
    };
    await _patch('system/force_update', payload);
    await _patch('system/version_policy', payload);
  }

  Future<Map<String, dynamic>?> getForceUpdatePolicy() async {
    final res = await _get('system/force_update');
    if (res is Map) return Map<String, dynamic>.from(res);
    final res2 = await _get('system/version_policy');
    if (res2 is Map) return Map<String, dynamic>.from(res2);
    return null;
  }

  /// 10. فترة بقاء ومحو رسائل المجموعات (Chat Retention & Purge)
  Future<void> setGroupChatRetentionDays(int days) async {
    await _patch('system/chat_policy', {
      'retention_days': days,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<int> getGroupChatRetentionDays() async {
    final res = await _get('system/chat_policy');
    if (res is Map && res['retention_days'] != null) {
      return asInt(res['retention_days'], 7);
    }
    return 7;
  }

  Future<int> purgeOldGroupChatMessages(int retentionDays) async {
    final cutoff = DateTime.now().millisecondsSinceEpoch -
        (retentionDays * 86400 * 1000);
    int purgedCount = 0;
    try {
      final keys = await _get('workspaces', {'shallow': 'true'});
      if (keys is Map) {
        for (final ws in keys.keys) {
          final enc = Uri.encodeComponent('$ws');
          final msgs = await _get('workspaces/$enc/group_chat_messages');
          if (msgs is Map) {
            for (final m in msgs.entries) {
              final val = m.value;
              if (val is Map && asMs(val['timestamp']) < cutoff) {
                await _delete('workspaces/$enc/group_chat_messages/${m.key}');
                purgedCount++;
              }
            }
          }
        }
      }
    } catch (_) {}
    return purgedCount;
  }
}

class _DevHit {
  final String ws;
  final int sync;
  final int seen;
  final int upd;
  final int owner;
  final int planned;
  final bool viaLog;

  const _DevHit({
    required this.ws,
    this.sync = 0,
    this.seen = 0,
    this.upd = 0,
    this.owner = 0,
    this.planned = 0,
    this.viaLog = false,
  });

  static int rank(_DevHit a, _DevHit b) {
    var c = b.sync.compareTo(a.sync);
    if (c != 0) return c;
    c = b.seen.compareTo(a.seen);
    if (c != 0) return c;
    c = b.upd.compareTo(a.upd);
    if (c != 0) return c;
    c = b.owner.compareTo(a.owner);
    if (c != 0) return c;
    return b.planned.compareTo(a.planned);
  }
}

class AdminMetrics {
  final int totalWorkspaces;
  final int activePaid;
  final int activeTrials;
  final int expired;
  final int noPlan;
  final int expiringIn7Days;
  final double monthlyRevenue;
  final double totalRevenue;

  const AdminMetrics({
    required this.totalWorkspaces,
    required this.activePaid,
    required this.activeTrials,
    required this.expired,
    this.noPlan = 0,
    this.expiringIn7Days = 0,
    this.monthlyRevenue = 0.0,
    this.totalRevenue = 0.0,
  });
}

extension RtdbMetrics on Rtdb {
  Future<AdminMetrics> metrics() async {
    final keys = await _get('workspaces', {'shallow': 'true'});
    if (keys is! Map || keys.isEmpty) {
      return const AdminMetrics(
          totalWorkspaces: 0, activePaid: 0, activeTrials: 0, expired: 0);
    }
    final now = await serverNowMs();

    final trialIdx = await _get('trials');
    final byWs = <String, Map>{};
    if (trialIdx is Map) {
      for (final v in trialIdx.values) {
        if (v is Map) {
          final ws = asStr(v['workspace_id']);
          if (ws.isNotEmpty) byWs[ws] = v;
        }
      }
    }
    final missing =
        keys.keys.map((k) => '$k').where((w) => !byWs.containsKey(w)).toList();
    if (missing.isNotEmpty) {
      await _gather<Map?>(
        [
          for (final ws in missing.take(25))
            () async {
              final enc = Uri.encodeComponent(ws);
              final sub = await _get('workspaces/$enc/subscription');
              if (sub is Map) {
                byWs[ws] = sub;
                return sub;
              }
              return null;
            }
        ],
      );
    }

    int paid = 0, trials = 0, expired = 0, noPlan = 0, expiringIn7Days = 0;
    const sevenDaysMs = 7 * 86400 * 1000;
    for (final ws in keys.keys) {
      final sub = byWs['$ws'];
      if (sub == null) {
        noPlan++;
        continue;
      }
      final status = asStr(sub['status']);
      final exp = asMs(sub['expires_at']);
      final alive = exp > now;
      if (status == 'active' && alive) {
        paid++;
        if (exp - now <= sevenDaysMs &&
            exp < DateTime(2090).millisecondsSinceEpoch) {
          expiringIn7Days++;
        }
      } else if (status == 'trial' && alive) {
        trials++;
        if (exp - now <= sevenDaysMs) {
          expiringIn7Days++;
        }
      } else {
        expired++;
      }
    }

    double monthlyRev = 0.0;
    double totalRev = 0.0;
    try {
      final bills = await _get('billing_records');
      if (bills is Map) {
        final monthAgo = now - (30 * 86400 * 1000);
        for (final b in bills.values) {
          if (b is Map) {
            final amt = (b['amount'] is num)
                ? (b['amount'] as num).toDouble()
                : 0.0;
            final ts = asMs(b['timestamp']);
            totalRev += amt;
            if (ts >= monthAgo) {
              monthlyRev += amt;
            }
          }
        }
      }
    } catch (_) {}

    return AdminMetrics(
      totalWorkspaces: keys.length,
      activePaid: paid,
      activeTrials: trials,
      expired: expired,
      noPlan: noPlan,
      expiringIn7Days: expiringIn7Days,
      monthlyRevenue: monthlyRev,
      totalRevenue: totalRev,
    );
  }
}

String _pick(dynamic a, dynamic b, String dflt) {
  final sa = asStr(a);
  if (sa.isNotEmpty) return sa;
  final sb = asStr(b);
  if (sb.isNotEmpty) return sb;
  return dflt;
}

Object? _firstNum(Object? a, Object? b) {
  if (a != null && asStr(a).trim().isNotEmpty) return a;
  return b;
}
