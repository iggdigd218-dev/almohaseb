// (معمارية حساب Google) مصادقة Firebase عبر REST — بدون SDK إضافي.
//
// google_sign_in يجلب idToken من حساب Google، وهذه الخدمة تبادله مع
// Firebase Identity Toolkit (accounts:signInWithIdp) فيصدر uid الرسمي
// نفسه الذي تصدره حزمة firebase_auth تماماً — فيصبح هوية المؤسسة
// الدائمة عبر الأجهزة: مساحة العمل WS-{uid} والترخيص مربوطان به.
//
// Offline-First: الجلسة تُحفظ محلياً (settings) بعد أول دخول ناجح —
// التطبيق يعمل كاملاً بلا إنترنت ولا يُطلب تسجيل الدخول في كل مرة.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/auth_config.dart';
import '../repository.dart';
import 'device_id.dart';

class FirebaseAccount {
  final String uid; // localId — معرف المستخدم الرسمي في Firebase
  final String email;
  final String displayName;

  /// توكن الهوية **الصادر عن Firebase** بعد الاستبدال (`accounts:signInWithIdp`).
  /// ⚠️ ليس توكن Google الخام: إرسال الخام في `?auth=` ترفضه RTDB بـ 401.
  final String idToken;
  final String refreshToken;
  final int expiresInSeconds;

  const FirebaseAccount({
    required this.uid,
    required this.email,
    this.displayName = '',
    this.idToken = '',
    this.refreshToken = '',
    this.expiresInSeconds = 0,
  });
}

class FirebaseAuthRest {
  FirebaseAuthRest._();

  static const uidKey = 'account.uid';
  static const emailKey = 'account.email';
  static const nameKey = 'account.name';

  // ══════ (401) جلسة الحساب: توكن Firebase بعد استبدال توكن Google ══════
  // قبل هذا الإصلاح كان الاستبدال يُستخرج `localId` فقط ويُهمل `idToken`،
  // فيبقى `?auth=` يحمل توكن الهوية **المجهولة** للجهاز — وهو ليس مالك
  // المساحة، فترفض القواعد كل كتابة تتطلب صلاحية المالك (إنشاء دعوة،
  // invite_index، members) بـ 401.
  static const accountIdTokenKey = 'account.idToken';
  static const accountRefreshKey = 'account.refreshToken';
  static const accountExpiryKey = 'account.expiryMs';

  static String? _accountUid;
  static String? _accountIdToken;
  static String? _accountRefreshToken;
  static int _accountExpiryMs = 0;

  /// هل توجد جلسة حساب Google مُستبدلة؟ (بلا انتظار شبكة)
  static bool get hasAccountSession =>
      _accountIdToken != null && _accountIdToken!.isNotEmpty;

  static bool get _accountTokenValid =>
      hasAccountSession &&
      DateTime.now().millisecondsSinceEpoch < _accountExpiryMs;

  /// الهوية المجهولة للجهاز (قبل/بلا ربط حساب Google).
  static String get anonymousUid => _anonUid ?? '';

  /// تبادل idToken الخاص بـ Google مع Firebase للحصول على uid الرسمي.
  /// يعيد null عند غياب المفاتيح أو فشل الشبكة/التبادل.
  static Future<FirebaseAccount?> signInWithGoogleIdToken(
      String googleIdToken) async {
    final key = effectiveFirebaseApiKey;
    if (key.isEmpty || googleIdToken.isEmpty) return null;
    try {
      final uri = Uri.parse(
          'https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp'
          '?key=$key');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'postBody':
                  'id_token=$googleIdToken&providerId=google.com',
              'requestUri': 'http://localhost',
              'returnSecureToken': true,
              'returnIdpCredential': true,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return null;
      final uid = '${m['localId'] ?? ''}'.trim();
      if (uid.isEmpty) return null;
      return FirebaseAccount(
        uid: uid,
        email: '${m['email'] ?? ''}',
        displayName: '${m['displayName'] ?? ''}',
        // (401) التوكن هو ثمرة الاستبدال — به وحده تعترف قواعد RTDB.
        idToken: '${m['idToken'] ?? ''}'.trim(),
        refreshToken: '${m['refreshToken'] ?? ''}'.trim(),
        expiresInSeconds: int.tryParse('${m['expiresIn'] ?? ''}') ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// حفظ الجلسة محلياً — تبقى صالحة بلا إنترنت (لا انتهاء محلي).
  static Future<void> saveSession(Repo repo, FirebaseAccount a) async {
    _repo ??= repo;
    await repo.setSetting(uidKey, a.uid);
    await repo.setSetting(emailKey, a.email);
    await repo.setSetting(nameKey, a.displayName);
    // تثبيت هوية وصفة المدير والمالك السيادي الكامل فور تسجيل الدخول
    await repo.restoreManagerOwnership();
    await repo.checkAndAutoPromoteManager();
    await repo.ensureSelfPermissionRow(roleCode: 'admin');
    // (401) توكن الحساب هو الذي يمنح صلاحية المالك — يُحفظ ويُستخدم فوراً.
    if (a.idToken.isNotEmpty) {
      _accountUid = a.uid;
      _accountIdToken = a.idToken;
      _accountRefreshToken = a.refreshToken.isEmpty ? null : a.refreshToken;
      _accountExpiryMs = _computeExpiryMs(a.expiresInSeconds);
      await _persistAccount();
    }
  }

  /// uid المحفوظ محلياً ('' إن لم يسجل الدخول بعد).
  static Future<String> savedUid(Repo repo) async =>
      ((await repo.settings())[uidKey] ?? '').trim();

  static Future<String> savedEmail(Repo repo) async =>
      ((await repo.settings())[emailKey] ?? '').trim();

  static Future<void> clearSession(Repo repo) async {
    await repo.setSetting(uidKey, '');
    await repo.setSetting(emailKey, '');
    await repo.setSetting(nameKey, '');
    _accountUid = null;
    _accountIdToken = null;
    _accountRefreshToken = null;
    _accountExpiryMs = 0;
    await repo.setSetting(accountIdTokenKey, '');
    await repo.setSetting(accountRefreshKey, '');
    await repo.setSetting(accountExpiryKey, '0');
  }

  // ══════ (المرحلة 2) مصادقة مجهولة صامتة — هوية جهاز دائمة ══════
  //
  // الهدف: كل طلب إلى RTDB يحمل `?auth=<idToken>` صالحاً، فتستطيع قواعد
  // الأمان الاعتماد على `auth.uid` بدل ترك القاعدة مفتوحة للعامة.
  //
  // تُنفَّذ عبر Identity Toolkit REST (نفس عائلة `accounts:signInWithIdp`
  // المستخدمة أعلاه): `accounts:signUp` بلا بيانات = حساب مجهول حقيقي،
  // فيصدر `localId` و`idToken` مطابقين تماماً لما يصدره Firebase Anonymous
  // Auth — بلا SDK، وبلا الحاجة إلى `Firebase.initializeApp()` أو ملفات
  // `google-services.json` / `GoogleService-Info.plist`.

  static const anonUidKey = 'cloud.anon.uid';
  static const _anonIdTokenKey = 'cloud.anon.idToken';
  static const _anonRefreshKey = 'cloud.anon.refresh';
  static const _anonExpiryKey = 'cloud.anon.expiryMs';
  /// (دفعة 65) نطاق الهوية المجهولة: مساحة العمل + بصمة الجهاز.
  static const _anonScopeKey = 'cloud.anon.scope';

  static String? _anonUid;
  static String? _anonIdToken;
  static String? _anonRefreshToken;
  static int _anonExpiryMs = 0;
  static bool _anonStarted = false;
  static Repo? _repo;

  /// (دفعة 65) مسح الهوية المجهولة بالكامل (من الذاكرة والتخزين) مع
  /// إعادة تعيين حالة الإقلاع — فتُصدر الجلسة التالية uid جديداً كلياً.
  ///
  /// تُستخدم عند الانضمام إلى مؤسسة أو تبديل الحساب: الموظف يبدأ بهوية
  /// سحابية مستقلة لا ترث بصمته القديمة، فإذا حُظر لا يعود بهوية سابقة،
  /// ولا تتداخل عضويته في `/members` مع حسابه الشخصي.
  static Future<void> resetAnonymousSession(Repo repo) async {
    await repo.setSetting(anonUidKey, '');
    await repo.setSetting(_anonIdTokenKey, '');
    await repo.setSetting(_anonRefreshKey, '');
    await repo.setSetting(_anonExpiryKey, '0');
    await repo.setSetting(_anonScopeKey, '');
    _anonUid = null;
    _anonIdToken = null;
    _anonRefreshToken = null;
    _anonExpiryMs = 0;
    _anonStarted = false;
    _repo = repo;
  }

  /// (دفعة 65) يضمن أن الهوية المجهولة **مقترنة بمساحة العمل الحالية
  /// وبصمة الجهاز**: إن تغيّرت المساحة (أو الجهاز) عن النطاق المحفوظ
  /// تُهمَل الهوية القديمة ويُصدر Firebase uid جديداً مستقلاً.
  ///
  /// قبل الانضمام: (مساحة شخصية، بصمة الموظف).
  /// بعد الانضمام: (مساحة المتجر، بصمة الموظف) ← نطاق مختلف ← هوية جديدة.
  static Future<void> ensureScopedAnonymous(
      Repo repo, String workspaceId) async {
    try {
      final deviceId = await ensureDeviceId(repo);
      final scope = '${workspaceId.trim()}|$deviceId';
      final saved = ((await repo.settings())[_anonScopeKey] ?? '').trim();
      if (saved != scope) {
        await resetAnonymousSession(repo);
        await repo.setSetting(_anonScopeKey, scope);
      }
    } catch (_) {
      // بصمة الجهاز غير متاحة (بيئة اختبار/ويب) — يُتجاوز بلا أثر.
    }
  }

  /// uid الفعّال لهذا الجهاز: **حساب Google إن سُجّل**، وإلا الهوية المجهولة.
  /// (401) هذا هو مفتاح عقدة `/members/{uid}` التي تستند إليها قواعد الأمان.
  static String get currentUid {
    final au = _accountUid;
    if (au != null && au.isNotEmpty) return au;
    return _anonUid ?? '';
  }

  /// التوكن الجاهز في الذاكرة الآن (بلا انتظار شبكة) — جلسة الحساب أولاً ثم
  /// الهوية المجهولة. يُستخدم لتوقيع طلبات `cloud_join` المتزامنة مسارها.
  static String? get cachedIdToken {
    if (_accountTokenValid) return _accountIdToken;
    if (hasValidToken) return _anonIdToken;
    return null;
  }

  /// هل لدينا توكن هوية صالح الآن (بلا انتظار)؟
  static bool get hasValidToken =>
      _anonIdToken != null &&
      _anonIdToken!.isNotEmpty &&
      DateTime.now().millisecondsSinceEpoch < _anonExpiryMs;

  /// (للاختبارات) حقن توكن وهمي لتفادي حظر الشبكة والـ 401.
  static void setMockTokenForTest({String? token, String? uid}) {
    _anonIdToken = token ?? 'TOK-QA';
    _anonUid = uid ?? 'UID-QA';
    _anonExpiryMs = DateTime.now().millisecondsSinceEpoch + 86400000;
  }

  /// (للاختبارات) تنظيف التوكنات المحقونة.
  static void clearMockForTest() {
    _anonIdToken = null;
    _anonUid = null;
    _anonExpiryMs = 0;
    _accountIdToken = null;
    _accountUid = null;
    _accountExpiryMs = 0;
    _anonStarted = false;
  }

  /// التوكن الصالح لإرفاقه بطلبات RTDB (`?auth=`) — يجدّده عند الحاجة.
  /// يعيد null فقط إن تعذّرت الشبكة نهائياً ولا يوجد توكن محفوظ.
  static Future<String?> cloudIdToken() async {
    // (401) الأولوية لجلسة الحساب: توكن Firebase الناتج عن استبدال توكن
    // Google هو الوحيد الذي يملك صلاحية المالك على مساحته.
    if (hasAccountSession) {
      if (_accountTokenValid) return _accountIdToken;
      final fresh = await _refreshAccountToken();
      if (fresh != null) return fresh;
      // تعذّر التجديد → نُكمل بالهوية المجهولة كيلا يُرسل طلب بلا مصادقة.
    }
    if (hasValidToken) return _anonIdToken;
    await _ensureFreshToken();
    return hasValidToken ? _anonIdToken : null;
  }

  /// (401/403) تحديث قسري للتوكن ثم إعادته — لإعادة محاولة واحدة فقط.
  static Future<String?> forceRefreshToken() async {
    if (hasAccountSession) {
      _accountExpiryMs = 0;
      final fresh = await _refreshAccountToken();
      if (fresh != null) return fresh;
    }
    _anonExpiryMs = 0;
    await _ensureFreshToken();
    return hasValidToken ? _anonIdToken : null;
  }

  /// تهيئة صامتة تماماً: بلا نافذة، بلا إذن، بلا تأخير مرئي.
  /// تُستدعى مرة واحدة من `main()` **قبل** أي اتصال بـ RTDB.
  static Future<void> initSilentAuth(Repo repo) async {
    _repo = repo;
    if (_anonStarted) return;
    _anonStarted = true;
    if (effectiveFirebaseApiKey.isEmpty) return;
    try {
      final st = await repo.settings();
      final savedUid = (st[anonUidKey] ?? '').trim();
      final savedRefresh = (st[_anonRefreshKey] ?? '').trim();
      final savedToken = (st[_anonIdTokenKey] ?? '').trim();
      if (savedUid.isNotEmpty) {
        // الهوية المجهولة ثابتة عبر إعادة التشغيل — نفس auth.uid دائماً،
        // فلا تنكسر القواعد ولا تُفقد العضوية في /members.
        _anonUid = savedUid;
        _anonRefreshToken = savedRefresh.isEmpty ? null : savedRefresh;
        _anonIdToken = savedToken.isEmpty ? null : savedToken;
        _anonExpiryMs = int.tryParse(st[_anonExpiryKey] ?? '') ?? 0;
      }
      // (401) استعادة جلسة الحساب: نفس auth.uid بعد إعادة التشغيل، فتبقى
      // صلاحية المالك قائمة ولا تُرفض كتاباته على مساحته.
      final accUid = (st[uidKey] ?? '').trim();
      final accTok = (st[accountIdTokenKey] ?? '').trim();
      if (accUid.isNotEmpty && accTok.isNotEmpty) {
        _accountUid = accUid;
        _accountIdToken = accTok;
        final accRefresh = (st[accountRefreshKey] ?? '').trim();
        _accountRefreshToken = accRefresh.isEmpty ? null : accRefresh;
        _accountExpiryMs = int.tryParse(st[accountExpiryKey] ?? '') ?? 0;
      }
      if (_accountTokenValid) return;
      if (hasAccountSession) {
        await _refreshAccountToken();
        if (_accountTokenValid) return;
      }
      if (hasValidToken) return;
      await _ensureFreshToken();
    } catch (_) {
      // الشبكة غائبة عند أول إقلاع: يُستأنف تلقائياً عند أول طلب سحابي
      // عبر `cloudIdToken()` — لا نُسقط الإقلاع أبداً.
    }
  }

  static Future<void> _ensureFreshToken() async {
    final key = effectiveFirebaseApiKey;
    if (key.isEmpty) return;
    final refresh = _anonRefreshToken;
    if (refresh != null && refresh.isNotEmpty && await _refreshAnonymous(key)) {
      return;
    }
    await _createAnonymous(key);
  }

  /// إنشاء حساب مجهول: `accounts:signUp` بلا بريد/كلمة سر.
  static Future<bool> _createAnonymous(String key) async {
    try {
      final res = await http
          .post(
            Uri.parse('https://identitytoolkit.googleapis.com/v1/'
                'accounts:signUp?key=$key'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'returnSecureToken': true}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return false;
      final tok = '${m['idToken'] ?? ''}'.trim();
      final uid = '${m['localId'] ?? ''}'.trim();
      if (tok.isEmpty || uid.isEmpty) return false;
      _anonIdToken = tok;
      _anonUid = uid;
      final refresh = '${m['refreshToken'] ?? ''}'.trim();
      _anonRefreshToken = refresh.isEmpty ? null : refresh;
      _setExpiry(int.tryParse('${m['expiresIn'] ?? ''}') ?? 3600);
      await _persist();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// تحديث التوكن عبر `securetoken` باستخدام الـ refresh token.
  static Future<bool> _refreshAnonymous(String key) async {
    try {
      final res = await http
          .post(
            Uri.parse('https://securetoken.googleapis.com/v1/token?key=$key'),
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: 'grant_type=refresh_token&refresh_token='
                '${Uri.encodeComponent(_anonRefreshToken ?? '')}',
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return false;
      final tok = '${m['id_token'] ?? ''}'.trim();
      if (tok.isEmpty) return false;
      _anonIdToken = tok;
      final uid = '${m['user_id'] ?? ''}'.trim();
      if (uid.isNotEmpty) _anonUid = uid;
      final refresh = '${m['refresh_token'] ?? ''}'.trim();
      if (refresh.isNotEmpty) _anonRefreshToken = refresh;
      _setExpiry(int.tryParse('${m['expires_in'] ?? ''}') ?? 3600);
      await _persist();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// (401) تجديد توكن الحساب عبر `securetoken` بـ refresh token.
  static Future<String?> _refreshAccountToken() async {
    final key = effectiveFirebaseApiKey;
    final refresh = _accountRefreshToken;
    if (key.isEmpty || refresh == null || refresh.isEmpty) return null;
    try {
      final res = await http
          .post(
            Uri.parse('https://securetoken.googleapis.com/v1/token?key=$key'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'grant_type=refresh_token&refresh_token='
                '${Uri.encodeComponent(refresh)}',
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final m = jsonDecode(utf8.decode(res.bodyBytes));
      if (m is! Map) return null;
      final tok = '${m['id_token'] ?? ''}'.trim();
      if (tok.isEmpty) return null;
      _accountIdToken = tok;
      final uid = '${m['user_id'] ?? ''}'.trim();
      if (uid.isNotEmpty) _accountUid = uid;
      final rt = '${m['refresh_token'] ?? ''}'.trim();
      if (rt.isNotEmpty) _accountRefreshToken = rt;
      _accountExpiryMs =
          _computeExpiryMs(int.tryParse('${m['expires_in'] ?? ''}') ?? 3600);
      await _persistAccount();
      return tok;
    } catch (_) {
      return null;
    }
  }

  /// انتهاء صالح مع هامش أمان (دقيقة) — موحّد للحساب والمجهول.
  static int _computeExpiryMs(int seconds) =>
      DateTime.now().millisecondsSinceEpoch +
      ((seconds > 0 ? seconds : 3600) * 1000) -
      const Duration(minutes: 1).inMilliseconds;

  /// حفظ جلسة الحساب (توكن + هوية) في الإعدادات.
  static Future<void> _persistAccount() async {
    final repo = _repo;
    if (repo == null) return;
    try {
      await repo.setSetting(accountIdTokenKey, _accountIdToken ?? '');
      await repo.setSetting(accountRefreshKey, _accountRefreshToken ?? '');
      await repo.setSetting(accountExpiryKey, '$_accountExpiryMs');
      if (_accountUid != null) await repo.setSetting(uidKey, _accountUid!);
    } catch (_) {}
  }

  /// هامش أمان دقيقة قبل انتهاء الصلاحية الحقيقي.
  static void _setExpiry(int seconds) {
    _anonExpiryMs = DateTime.now().millisecondsSinceEpoch +
        (seconds * 1000) -
        const Duration(minutes: 1).inMilliseconds;
  }

  static Future<void> _persist() async {
    final repo = _repo;
    if (repo == null) return;
    try {
      await repo.setSetting(anonUidKey, _anonUid ?? '');
      await repo.setSetting(_anonIdTokenKey, _anonIdToken ?? '');
      await repo.setSetting(_anonRefreshKey, _anonRefreshToken ?? '');
      await repo.setSetting(_anonExpiryKey, '$_anonExpiryMs');
    } catch (_) {}
  }
}
