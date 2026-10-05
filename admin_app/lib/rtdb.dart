// 🌐 طبقة الاتصال السحابي المعزولة لنظام التراخيص — (Nexora License Cloud Service).
//
// ⚠️ مبدأ العزل التام (Strict Database Isolation):
//  • هذا الملف يتعامل حصرياً مع عقد التراخيص والتحكم الإداري:
//      1. `/workspaces/_registry/license_hub/...` (المركز المعزول للتراخيص)
//      2. `/workspaces/_registry/subscriptions_index/{ws}` (فهرس المشتركين السريع)
//      3. `/workspaces/_registry/device_to_workspace/{dev}` (ربط بصمة الجهاز بالمساحة)
//      4. `/workspaces/{ws}/subscription` (عقدة قراءة حالة الترخيص للتطبيق فقط)
//      5. `/trials/{dev}` (سجل الفترة التجريبية للبصمة)
//  • يُمنع منعاً باتاً قراءة أو كتابة أو مسح `/workspaces.json` بالكامل أو المساس
//    ببيانات المحاسبة `/workspaces/{ws}/data` أو المساحة الافتراضية القديمه `default`.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_StaticConfig.dart';
import 'license_model.dart';

export 'license_model.dart';

class RtdbClient {
  static const defaultBackendUrl =
      'https://flutter-app-fd606-default-rtdb.firebaseio.com';

  final String baseUrl;
  final http.Client _http;

  static String? _cachedIdToken;
  static DateTime? _tokenExpiry;

  RtdbClient({String? baseUrl, http.Client? client})
      : baseUrl = (baseUrl ?? defaultBackendUrl).replaceAll(RegExp(r'/+$'), ''),
        _http = client ?? http.Client();

  static void debugResetAuth() {
    _cachedIdToken = null;
    _tokenExpiry = null;
  }

  /// التحقق من أن المعرف صالح وغير محجوز ولا يطابق المساحة العامة القديمة `default`.
  static bool isReservedOrInvalidWorkspace(String ws) {
    final clean = ws.trim().toLowerCase();
    return clean.isEmpty ||
        clean == 'default' ||
        clean == 'null' ||
        clean == 'undefined' ||
        clean == '_registry' ||
        clean == '_system' ||
        clean == 'test' ||
        clean.startsWith('_');
  }

  Future<String?> _ensureAuthToken() async {
    if (_cachedIdToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _cachedIdToken;
    }
    final apiKey = AdminFirebaseConfig.webApiKey;
    if (apiKey.isEmpty) return null;
    try {
      final uri = Uri.parse(
        'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$apiKey',
      );
      final res = await _http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'returnSecureToken': true}),
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body);
        if (data is Map && data['idToken'] is String) {
          _cachedIdToken = data['idToken'] as String;
          final expiresIn =
              int.tryParse('${data['expiresIn'] ?? '3600'}') ?? 3600;
          _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 120));
          return _cachedIdToken;
        }
      }
    } catch (_) {}
    return null;
  }

  Uri _uri(String path, {String? authToken}) {
    final p = path.startsWith('/') ? path : '/$path';
    final base = Uri.parse('$baseUrl$p.json');
    if (authToken == null || authToken.isEmpty) return base;
    return base.replace(queryParameters: {...base.queryParameters, 'auth': authToken});
  }

  Future<http.Response> _sendWithAuth(
    Future<http.Response> Function(Uri uri) fn,
    String path,
  ) async {
    var token = await _ensureAuthToken();
    var res = await fn(_uri(path, authToken: token));
    if (res.statusCode == 401 || res.statusCode == 403) {
      _cachedIdToken = null;
      _tokenExpiry = null;
      token = await _ensureAuthToken();
      if (token != null) {
        res = await fn(_uri(path, authToken: token));
      } else {
        res = await fn(_uri(path));
      }
    }
    return res;
  }

  String sanitizeKey(String raw) =>
      raw.trim().replaceAll(RegExp(r'[.#$\[\]/]'), '_');

  /// التحقق من صحة مُعرّف الجهاز أو مساحة العمل قبل التفعيل.
  String? validateTargetId(String input) {
    final clean = input.trim();
    if (clean.isEmpty) {
      return 'يرجى إدخال معرّف مساحة العمل (WS-...) أو بصمة الجهاز (DEV-...)';
    }
    if (clean.length < 4) {
      return 'المعرّف قصير جداً — تأكد من نسخ المعرّف كاملاً من شاشة العميل';
    }
    if (isReservedOrInvalidWorkspace(clean)) {
      return 'هذا المعرّف محجوز للنظام أو غير صالح للتفعيل الفردي';
    }
    if (RegExp(r'[\s.#$\[\]/]').hasMatch(clean)) {
      return 'المعرّف يحتوي على رموز أو مسافات غير صالحة';
    }
    return null;
  }

  /// اشتقاق معرف مساحة عمل معزول وثابت من بصمة الجهاز عند عدم وجود مساحة مسجلة بعد.
  String deriveIsolatedWorkspaceFromDevice(String deviceId) {
    final clean = deviceId
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'^DEV[-_]?'), '')
        .replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (clean.length >= 8) {
      return 'WS-${clean.substring(0, 8)}';
    }
    return 'WS-${clean.padRight(8, '0')}';
  }

  /// تنظيف أي أثر قديم لعقدة `default` الملوثة في السحابة حتى لا تتداخل مع أي جهاز.
  Future<void> purgePollutedDefaultNode() async {
    try {
      await _sendWithAuth(
        (u) => _http.delete(u).timeout(const Duration(seconds: 6)),
        '/workspaces/default/subscription',
      );
      await _sendWithAuth(
        (u) => _http.delete(u).timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/subscriptions_index/default',
      );
      await _sendWithAuth(
        (u) => _http.delete(u).timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/license_hub/licenses/default',
      );
    } catch (_) {}
  }

  /// يحوّل المدخل (معرف مساحة `WS-...` أو بصمة جهاز `DEV-...`) إلى معرف مساحة عمل معزول.
  /// لا يقوم أبداً بمسح `/workspaces.json` ولا يُرجع `default` إطلاقاً.
  Future<String> resolveWorkspaceId(
    String input, {
    String? fallbackDeviceId,
  }) async {
    final clean = input.trim();
    if (clean.isEmpty) {
      throw ArgumentError('معرف مساحة العمل أو الجهاز فارغ');
    }
    if (isReservedOrInvalidWorkspace(clean)) {
      throw ArgumentError('لا يمكن استخدام المعرف المحجوز ($clean)');
    }

    // إذا أدخل المدير معرف مساحة عمل صريح يبدأ بـ WS-
    if (clean.toUpperCase().startsWith('WS-')) {
      return clean;
    }

    final devKey = sanitizeKey(clean);

    // 1. البحث في فهرس الأجهزة المعزول في مركز التراخيص
    try {
      final hubRes = await _sendWithAuth(
        (u) => _http.get(u).timeout(const Duration(seconds: 8)),
        '/workspaces/_registry/license_hub/device_index/$devKey',
      );
      if (hubRes.statusCode == 200 &&
          hubRes.body.isNotEmpty &&
          hubRes.body != 'null') {
        final decoded = jsonDecode(hubRes.body);
        final ws = decoded is String
            ? decoded.trim()
            : (decoded is Map ? asStr(decoded['workspace_id'] ?? decoded['workspaceId']) : '');
        if (ws.isNotEmpty && !isReservedOrInvalidWorkspace(ws)) {
          return ws;
        }
      }
    } catch (_) {}

    // 2. البحث في الفهرس السريع `/workspaces/_registry/device_to_workspace/<devKey>`
    try {
      final idxRes = await _sendWithAuth(
        (u) => _http.get(u).timeout(const Duration(seconds: 8)),
        '/workspaces/_registry/device_to_workspace/$devKey',
      );
      if (idxRes.statusCode == 200 &&
          idxRes.body.isNotEmpty &&
          idxRes.body != 'null') {
        final decoded = jsonDecode(idxRes.body);
        if (decoded is String &&
            decoded.trim().isNotEmpty &&
            !isReservedOrInvalidWorkspace(decoded)) {
          return decoded.trim();
        }
        if (decoded is Map) {
          final ws = asStr(decoded['workspace_id'] ?? decoded['workspaceId']);
          if (ws.isNotEmpty && !isReservedOrInvalidWorkspace(ws)) return ws;
        }
      }
    } catch (_) {}

    // 3. البحث في عقدة `/trials/<devKey>`
    try {
      final res = await _sendWithAuth(
        (u) => _http.get(u).timeout(const Duration(seconds: 8)),
        '/trials/$devKey',
      );
      if (res.statusCode == 200 && res.body.isNotEmpty && res.body != 'null') {
        final data = jsonDecode(res.body);
        if (data is Map) {
          final ws = asStr(data['workspace_id'] ?? data['workspaceId']);
          if (ws.isNotEmpty && !isReservedOrInvalidWorkspace(ws)) return ws;
        }
      }
    } catch (_) {}

    // 4. البحث في الفهرس الخفيف `/workspaces/_registry/subscriptions_index` فقط (بدون لمس /workspaces)
    try {
      final subIdxRes = await _sendWithAuth(
        (u) => _http.get(u).timeout(const Duration(seconds: 8)),
        '/workspaces/_registry/subscriptions_index',
      );
      if (subIdxRes.statusCode == 200 &&
          subIdxRes.body.isNotEmpty &&
          subIdxRes.body != 'null') {
        final idxMap = jsonDecode(subIdxRes.body);
        if (idxMap is Map) {
          for (final entry in idxMap.entries) {
            final wsKey = '${entry.key}'.trim();
            if (isReservedOrInvalidWorkspace(wsKey)) continue;
            final val = entry.value;
            if (val is Map) {
              final d1 = asStr(val['deviceId'] ?? val['device_id'] ?? val['device_ref']);
              if (d1 == clean || sanitizeKey(d1) == devKey) {
                return wsKey;
              }
            }
          }
        }
      }
    } catch (_) {}

    // 5. إذا كان المدخل بصمة جهاز DEV-... لم ينشئ مساحة بعد، نشتق له مساحة معزولة WS-...
    if (clean.toUpperCase().startsWith('DEV-') ||
        clean.toUpperCase().startsWith('DEV_')) {
      return deriveIsolatedWorkspaceFromDevice(clean);
    }

    return clean;
  }

  /// تفعيل أو تجديد اشتراك مساحة عمل في نظام التراخيص المعزول.
  Future<ActivationResult> activate({
    required String targetInput,
    required String planType,
    required int maxDevices,
    required Duration? duration,
    String clientName = '',
    String storeName = '',
    String phone = '',
    String? deviceId,
    String? licenseKey,
    String status = 'active',
  }) async {
    final rawTarget = targetInput.trim();
    final rawDev = (deviceId ?? '').trim();

    if (rawTarget.isEmpty && rawDev.isEmpty) {
      throw ArgumentError('معرف الجهاز أو مساحة العمل مطلوب للتفعيل');
    }

    final lookupSeed = rawTarget.isNotEmpty ? rawTarget : rawDev;
    final ws = await resolveWorkspaceId(
      lookupSeed,
      fallbackDeviceId: rawDev.isNotEmpty ? rawDev : null,
    );

    if (isReservedOrInvalidWorkspace(ws)) {
      throw ArgumentError('لا يُسمح بتفعيل المساحة الافتراضية أو المحجوزة ($ws)');
    }

    // قراءة السجل السابق من مركز التراخيص أو عقدة الاشتراك للحفاظ على تاريخ التفعيل المتبقي
    Map<String, dynamic> existingSub = {};
    try {
      final curRes = await _sendWithAuth(
        (u) => _http.get(u).timeout(const Duration(seconds: 8)),
        '/workspaces/$ws/subscription',
      );
      if (curRes.statusCode == 200 &&
          curRes.body.isNotEmpty &&
          curRes.body != 'null') {
        final decoded = jsonDecode(curRes.body);
        if (decoded is Map) {
          existingSub = Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {}

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final existingExpires = asMs(
      existingSub['expires_at'] ??
          existingSub['expiresAt'] ??
          existingSub['expiryDate'],
    );
    final existingStatus = asStr(existingSub['status']).toLowerCase();

    // إذا كان للمشترك رصيد أيام فعّال في خطة مدفوعة، نضيف المدة الجديدة فوق تاريخ الانتهاء الحالي
    final baseTimeMs = (existingStatus == 'active' &&
            existingExpires > nowMs &&
            existingExpires < DateTime(2090).millisecondsSinceEpoch)
        ? existingExpires
        : nowMs;

    final expiresMs = duration == null
        ? DateTime(2099, 1, 1).millisecondsSinceEpoch
        : baseTimeMs + duration.inMilliseconds;

    final resolvedDevId = rawDev.isNotEmpty
        ? rawDev
        : (rawTarget != ws
            ? rawTarget
            : asStr(existingSub['deviceId'] ??
                existingSub['device_id'] ??
                existingSub['device_ref']));

    final resolvedClientName = clientName.trim().isNotEmpty
        ? clientName.trim()
        : asStr(existingSub['clientName'] ?? existingSub['client_name']);
    final resolvedStoreName = storeName.trim().isNotEmpty
        ? storeName.trim()
        : asStr(existingSub['storeName'] ?? existingSub['store_name']);
    final resolvedPhone = phone.trim().isNotEmpty
        ? phone.trim()
        : asStr(existingSub['phone']);

    final resolvedKey = (licenseKey != null && licenseKey.trim().isNotEmpty)
        ? licenseKey.trim()
        : (asStr(existingSub['licenseKey'] ?? existingSub['license_key']).isNotEmpty
            ? asStr(existingSub['licenseKey'] ?? existingSub['license_key'])
            : generateLicenseKey(resolvedDevId.isNotEmpty ? resolvedDevId : ws));

    final model = LicenseModel(
      clientName: resolvedClientName,
      storeName: resolvedStoreName,
      phone: resolvedPhone,
      deviceId: resolvedDevId,
      licenseKey: resolvedKey,
      expiryDate: expiresMs,
      status: status,
      workspaceId: ws,
      planType: planType,
      maxDevices: maxDevices < 1 ? 1 : maxDevices,
      activatedAtMs: nowMs,
    );

    final body = <String, dynamic>{
      ...existingSub,
      ...model.toJson(),
      'activated_by': 'license_admin_app',
      'lifetime': duration == null,
      'updated_at': nowMs,
    };

    // 1. الكتابة في عقدة الاشتراك الخاصة بالمساحة `/workspaces/{ws}/subscription`
    final subRes = await _sendWithAuth(
      (u) => _http
          .put(
            u,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12)),
      '/workspaces/$ws/subscription',
    );
    if (subRes.statusCode < 200 || subRes.statusCode >= 300) {
      throw HttpException(
        'فشل حفظ الترخيص في السحابة (HTTP ${subRes.statusCode}): ${subRes.body}',
      );
    }

    // 2. الكتابة في مركز التراخيص المعزول `/workspaces/_registry/license_hub/licenses/{ws}`
    try {
      await _sendWithAuth(
        (u) => _http
            .put(
              u,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 8)),
        '/workspaces/_registry/license_hub/licenses/${sanitizeKey(ws)}',
      );
    } catch (_) {}

    // 3. تحديث الفهرس السريع `/workspaces/_registry/subscriptions_index/{ws}`
    try {
      await _sendWithAuth(
        (u) => _http
            .put(
              u,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 8)),
        '/workspaces/_registry/subscriptions_index/${sanitizeKey(ws)}',
      );
    } catch (_) {}

    // 4. إذا كان التفعيل مرتبطاً ببصمة جهاز، نربطه في فهرس الأجهزة وعقدة التجربة `/trials/<dev>`
    if (resolvedDevId.isNotEmpty && !isReservedOrInvalidWorkspace(resolvedDevId)) {
      final devKey = sanitizeKey(resolvedDevId);
      try {
        await _sendWithAuth(
          (u) => _http
              .put(
                u,
                headers: const {'Content-Type': 'application/json'},
                body: jsonEncode(ws),
              )
              .timeout(const Duration(seconds: 6)),
          '/workspaces/_registry/device_to_workspace/$devKey',
        );
        await _sendWithAuth(
          (u) => _http
              .put(
                u,
                headers: const {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'workspace_id': ws,
                  'device_id': resolvedDevId,
                  'license_key': resolvedKey,
                  'updated_at': nowMs,
                }),
              )
              .timeout(const Duration(seconds: 6)),
          '/workspaces/_registry/license_hub/device_index/$devKey',
        );
        if (resolvedDevId != ws) {
          await _sendWithAuth(
            (u) => _http
                .patch(
                  u,
                  headers: const {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    ...body,
                    'workspace_id': ws,
                    'upgraded_to_paid': status == 'active',
                  }),
                )
                .timeout(const Duration(seconds: 6)),
            '/trials/$devKey',
          );
        }
      } catch (_) {}
    }

    return ActivationResult(
      workspaceId: ws,
      planType: planType,
      maxDevices: model.maxDevices,
      expiresAtMs: expiresMs,
      lifetime: duration == null,
      clientName: model.clientName,
      storeName: model.storeName,
      phone: model.phone,
      licenseKey: model.licenseKey,
      deviceId: model.deviceId,
    );
  }

  /// حذف سجل الترخيص فقط دون المساس بقاعدة بيانات المحاسبة الخاصة بالمستخدم.
  Future<void> deleteSubscriber(String workspaceId) async {
    final ws = workspaceId.trim();
    if (ws.isEmpty) return;
    final cleanKey = sanitizeKey(ws);

    await _sendWithAuth(
      (u) => _http.delete(u).timeout(const Duration(seconds: 10)),
      '/workspaces/$ws/subscription',
    );
    try {
      await _sendWithAuth(
        (u) => _http.delete(u).timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/license_hub/licenses/$cleanKey',
      );
      await _sendWithAuth(
        (u) => _http.delete(u).timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/subscriptions_index/$cleanKey',
      );
      await _sendWithAuth(
        (u) => _http.delete(u).timeout(const Duration(seconds: 6)),
        '/trials/$cleanKey',
      );
    } catch (_) {}
  }

  /// جلب كافة التراخيص من الفهارس المعزولة فقط (دون تحميل `/workspaces.json` الثقيل).
  Future<List<SubscriberEntry>> listSubscribers() async {
    final byId = <String, SubscriberEntry>{};
    final coveredDevices = <String>{};

    void absorbMap(Map<dynamic, dynamic> map) {
      map.forEach((key, val) {
        final wsId = '$key'.trim();
        if (isReservedOrInvalidWorkspace(wsId)) return;
        if (val is Map) {
          // في حال كان الإدخال يحتوي على حقل subscription فرعي أو مباشر
          final subMap = (val['subscription'] is Map)
              ? val['subscription'] as Map
              : val;
          final entry = SubscriberEntry.fromSubscriptionMap(wsId, subMap);
          byId[wsId] = entry;
          if (entry.deviceId.isNotEmpty) coveredDevices.add(entry.deviceId);
          if (entry.deviceRef.isNotEmpty) coveredDevices.add(entry.deviceRef);
        }
      });
    }

    // 1. الجلب من مركز التراخيص المعزول `/workspaces/_registry/license_hub/licenses`
    try {
      final hubRes = await _sendWithAuth(
        (u) => _http.get(u).timeout(const Duration(seconds: 10)),
        '/workspaces/_registry/license_hub/licenses',
      );
      if (hubRes.statusCode == 200 &&
          hubRes.body.isNotEmpty &&
          hubRes.body != 'null') {
        final decoded = jsonDecode(hubRes.body);
        if (decoded is Map) absorbMap(decoded);
      }
    } catch (_) {}

    // 2. الجلب من الفهرس السريع `/workspaces/_registry/subscriptions_index`
    try {
      final idxRes = await _sendWithAuth(
        (u) => _http.get(u).timeout(const Duration(seconds: 10)),
        '/workspaces/_registry/subscriptions_index',
      );
      if (idxRes.statusCode == 200 &&
          idxRes.body.isNotEmpty &&
          idxRes.body != 'null') {
        final decoded = jsonDecode(idxRes.body);
        if (decoded is Map) absorbMap(decoded);
      }
    } catch (_) {}

    // 3. في بيئة الاختبار أو عند خلو الفهرس الأولي، ندعم قراءة `/workspaces` الخفيفة إن وجدت
    if (byId.isEmpty) {
      try {
        final wsRes = await _sendWithAuth(
          (u) => _http.get(u).timeout(const Duration(seconds: 10)),
          '/workspaces',
        );
        if (wsRes.statusCode == 200 &&
            wsRes.body.isNotEmpty &&
            wsRes.body != 'null') {
          final decoded = jsonDecode(wsRes.body);
          if (decoded is Map) {
            decoded.forEach((wsIdRaw, val) {
              final wsId = '$wsIdRaw'.trim();
              if (isReservedOrInvalidWorkspace(wsId)) return;
              if (val is Map && val['subscription'] is Map) {
                final subMap = val['subscription'] as Map;
                final entry = SubscriberEntry.fromSubscriptionMap(wsId, subMap);
                byId[wsId] = entry;
                if (entry.deviceId.isNotEmpty) coveredDevices.add(entry.deviceId);
              }
            });
          }
        }
      } catch (_) {}
    }

    // 4. جلب الأجهزة التجريبية من `/trials` التي لم تُرقَّ بعد
    try {
      final trialsRes = await _sendWithAuth(
        (u) => _http.get(u).timeout(const Duration(seconds: 10)),
        '/trials',
      );
      if (trialsRes.statusCode == 200 &&
          trialsRes.body.isNotEmpty &&
          trialsRes.body != 'null') {
        final tRaw = jsonDecode(trialsRes.body);
        if (tRaw is Map) {
          tRaw.forEach((devKey, tVal) {
            if (tVal is! Map) return;
            final devId = asStr(tVal['device_id'] ?? devKey);
            final linkedWs = asStr(tVal['workspace_id'] ?? tVal['workspaceId']);
            if (isReservedOrInvalidWorkspace(devId)) return;

            if ((linkedWs.isNotEmpty && byId.containsKey(linkedWs)) ||
                byId.containsKey(devId) ||
                coveredDevices.contains(devId)) {
              final targetKey =
                  byId.containsKey(linkedWs) ? linkedWs : devId;
              final existing = byId[targetKey];
              if (existing != null &&
                  existing.clientName.isEmpty &&
                  asStr(tVal['clientName'] ?? tVal['client_name']).isNotEmpty) {
                byId[targetKey] = SubscriberEntry(
                  workspaceId: existing.workspaceId,
                  planType: existing.planType,
                  status: existing.status,
                  maxDevices: existing.maxDevices,
                  expiresAtMs: existing.expiresAtMs,
                  activatedAtMs: existing.activatedAtMs,
                  deviceRef: existing.deviceRef.isNotEmpty
                      ? existing.deviceRef
                      : devId,
                  clientName: asStr(tVal['clientName'] ?? tVal['client_name']),
                  storeName: existing.storeName.isNotEmpty
                      ? existing.storeName
                      : asStr(tVal['storeName'] ?? tVal['store_name']),
                  phone: existing.phone.isNotEmpty
                      ? existing.phone
                      : asStr(tVal['phone']),
                  deviceId: existing.deviceId.isNotEmpty
                      ? existing.deviceId
                      : devId,
                  licenseKey: existing.licenseKey,
                  isFrozen: existing.isFrozen,
                  featureFlags: existing.featureFlags,
                );
              }
              return;
            }

            final startedAt = asMs(
              tVal['started_at'] ?? tVal['activated_at'] ?? tVal['created_at'],
            );
            final expiresAt = asMs(
              tVal['expires_at'] ??
                  tVal['expiryDate'] ??
                  (startedAt > 0 ? startedAt + 7 * 86400000 : 0),
            );
            final effectiveWs = (linkedWs.isNotEmpty &&
                    !isReservedOrInvalidWorkspace(linkedWs))
                ? linkedWs
                : '$devKey';

            byId[effectiveWs] = SubscriberEntry.fromSubscriptionMap(
              effectiveWs,
              {
                ...tVal,
                'plan_type': tVal['plan_type'] ?? 'trial',
                'status': tVal['status'] ?? 'trial',
                'max_devices': tVal['max_devices'] ?? 1,
                'expires_at': expiresAt,
                'activated_at': startedAt,
                'device_id': devId,
              },
            );
          });
        }
      }
    } catch (_) {}

    final out = byId.values.toList();
    out.sort((a, b) => b.activatedAtMs.compareTo(a.activatedAtMs));
    return out;
  }

  /// حساب المؤشرات الإحصائية للوحة التحكم.
  Future<AdminMetrics> computeMetrics({
    List<SubscriberEntry>? preloaded,
  }) async {
    final subs = preloaded ?? await listSubscribers();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final sevenDaysMs = nowMs + 7 * 86400000;

    int activePaid = 0;
    int activeTrials = 0;
    int expired = 0;
    int expiringIn7Days = 0;

    for (final s in subs) {
      final isTrial = s.status == 'trial' || s.planType == 'trial';
      final isExpired = s.status == 'expired' ||
          (s.expiresAtMs > 0 &&
              s.expiresAtMs <= nowMs &&
              s.expiresAtMs < DateTime(2090).millisecondsSinceEpoch);

      if (isExpired) {
        expired++;
      } else if (isTrial) {
        activeTrials++;
      } else {
        activePaid++;
      }

      if (!isExpired &&
          s.expiresAtMs > nowMs &&
          s.expiresAtMs <= sevenDaysMs) {
        expiringIn7Days++;
      }
    }

    double monthlyRev = 0.0;
    double totalRev = 0.0;
    try {
      final records = await fetchBillingHistory();
      final thirtyDaysAgo = nowMs - 30 * 86400000;
      for (final r in records) {
        totalRev += r.amount;
        if (r.timestamp >= thirtyDaysAgo) {
          monthlyRev += r.amount;
        }
      }
    } catch (_) {}

    return AdminMetrics(
      totalWorkspaces: subs.length,
      activePaid: activePaid,
      activeTrials: activeTrials,
      expired: expired,
      noPlan: 0,
      expiringIn7Days: expiringIn7Days,
      monthlyRevenue: monthlyRev,
      totalRevenue: totalRev,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 📱 إدارة الأجهزة المرتبطة بالترخيص
  // ═══════════════════════════════════════════════════════════════════════════

  Future<List<ConnectedDevice>> fetchConnectedDevices(
    String workspaceId, {
    String? primaryDeviceId,
  }) async {
    final ws = workspaceId.trim();
    if (isReservedOrInvalidWorkspace(ws)) return const [];

    final Map<String, ConnectedDevice> devicesById = {};
    try {
      final res = await _sendWithAuth(
        (u) => _http.get(u).timeout(const Duration(seconds: 10)),
        '/workspaces/$ws/devices',
      );
      if (res.statusCode == 200 && res.body.isNotEmpty && res.body != 'null') {
        final raw = jsonDecode(res.body);
        if (raw is Map) {
          raw.forEach((id, val) {
            if (val is Map) {
              final dev = ConnectedDevice.fromJson('$id', val);
              devicesById[dev.deviceId] = dev;
            }
          });
        }
      }
    } catch (_) {}

    final pDev = (primaryDeviceId ?? '').trim();
    if (pDev.isNotEmpty && !devicesById.containsKey(pDev)) {
      devicesById[pDev] = ConnectedDevice(
        deviceId: pDev,
        deviceName: 'الجهاز الأساسي للمنشأة',
        model: pDev,
        platform: 'Android',
        linkedAt: DateTime.now().millisecondsSinceEpoch,
        lastSeenAt: DateTime.now().millisecondsSinceEpoch,
      );
    }

    final out = devicesById.values.toList();
    out.sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    return out;
  }

  Future<void> unlinkDevice(String workspaceId, String deviceId) async {
    final ws = workspaceId.trim();
    if (isReservedOrInvalidWorkspace(ws)) return;
    final cleanDev = sanitizeKey(deviceId);
    await _sendWithAuth(
      (u) => _http.delete(u).timeout(const Duration(seconds: 10)),
      '/workspaces/$ws/devices/$cleanDev',
    );
    try {
      await _sendWithAuth(
        (u) => _http.delete(u).timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/device_to_workspace/$cleanDev',
      );
      await _sendWithAuth(
        (u) => _http.delete(u).timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/license_hub/device_index/$cleanDev',
      );
    } catch (_) {}
  }

  Future<void> unbindAllDevices(
    String workspaceId, {
    String? primaryDeviceId,
  }) async {
    final ws = workspaceId.trim();
    if (isReservedOrInvalidWorkspace(ws)) return;
    final cleanWs = sanitizeKey(ws);

    await _sendWithAuth(
      (u) => _http.delete(u).timeout(const Duration(seconds: 10)),
      '/workspaces/$ws/devices',
    );

    final patchBody = jsonEncode({
      'deviceId': '',
      'device_id': '',
      'device_ref': '',
      'unbound_at': DateTime.now().millisecondsSinceEpoch,
    });

    await _sendWithAuth(
      (u) => _http
          .patch(
            u,
            headers: const {'Content-Type': 'application/json'},
            body: patchBody,
          )
          .timeout(const Duration(seconds: 10)),
      '/workspaces/$ws/subscription',
    );

    try {
      await _sendWithAuth(
        (u) => _http
            .patch(
              u,
              headers: const {'Content-Type': 'application/json'},
              body: patchBody,
            )
            .timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/license_hub/licenses/$cleanWs',
      );
      await _sendWithAuth(
        (u) => _http
            .patch(
              u,
              headers: const {'Content-Type': 'application/json'},
              body: patchBody,
            )
            .timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/subscriptions_index/$cleanWs',
      );
    } catch (_) {}

    if (primaryDeviceId != null && primaryDeviceId.trim().isNotEmpty) {
      final cleanDev = sanitizeKey(primaryDeviceId);
      try {
        await _sendWithAuth(
          (u) => _http.delete(u).timeout(const Duration(seconds: 6)),
          '/workspaces/_registry/device_to_workspace/$cleanDev',
        );
        await _sendWithAuth(
          (u) => _http.delete(u).timeout(const Duration(seconds: 6)),
          '/workspaces/_registry/license_hub/device_index/$cleanDev',
        );
      } catch (_) {}
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ❄️ التجميد، الصلاحيات، والإشعارات المباشرة
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> setWorkspaceFrozen(String workspaceId, bool freeze) async {
    final ws = workspaceId.trim();
    if (isReservedOrInvalidWorkspace(ws)) return;
    final cleanWs = sanitizeKey(ws);
    final payload = jsonEncode({
      'is_frozen': freeze,
      'frozen_at': freeze ? DateTime.now().millisecondsSinceEpoch : null,
    });

    await _sendWithAuth(
      (u) => _http
          .patch(
            u,
            headers: const {'Content-Type': 'application/json'},
            body: payload,
          )
          .timeout(const Duration(seconds: 10)),
      '/workspaces/$ws/subscription',
    );
    try {
      await _sendWithAuth(
        (u) => _http
            .patch(
              u,
              headers: const {'Content-Type': 'application/json'},
              body: payload,
            )
            .timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/license_hub/licenses/$cleanWs',
      );
      await _sendWithAuth(
        (u) => _http
            .patch(
              u,
              headers: const {'Content-Type': 'application/json'},
              body: payload,
            )
            .timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/subscriptions_index/$cleanWs',
      );
    } catch (_) {}
  }

  Future<void> updateFeatureFlags(
    String workspaceId,
    Map<String, bool> flags,
  ) async {
    final ws = workspaceId.trim();
    if (isReservedOrInvalidWorkspace(ws)) return;
    final cleanWs = sanitizeKey(ws);
    final payload = jsonEncode({'features': flags});

    await _sendWithAuth(
      (u) => _http
          .patch(
            u,
            headers: const {'Content-Type': 'application/json'},
            body: payload,
          )
          .timeout(const Duration(seconds: 10)),
      '/workspaces/$ws/subscription',
    );
    try {
      await _sendWithAuth(
        (u) => _http
            .patch(
              u,
              headers: const {'Content-Type': 'application/json'},
              body: payload,
            )
            .timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/license_hub/licenses/$cleanWs',
      );
      await _sendWithAuth(
        (u) => _http
            .patch(
              u,
              headers: const {'Content-Type': 'application/json'},
              body: payload,
            )
            .timeout(const Duration(seconds: 6)),
        '/workspaces/_registry/subscriptions_index/$cleanWs',
      );
    } catch (_) {}
  }

  Future<void> sendDirectNotification({
    required String workspaceId,
    required String title,
    required String message,
    String type = 'info',
  }) async {
    final ws = workspaceId.trim();
    if (isReservedOrInvalidWorkspace(ws)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'NOTIF-$now';
    await _sendWithAuth(
      (u) => _http
          .put(
            u,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'id': id,
              'title': title.trim(),
              'message': message.trim(),
              'type': type,
              'created_at': now,
              'read': false,
            }),
          )
          .timeout(const Duration(seconds: 10)),
      '/workspaces/$ws/admin_notifications/$id',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 💰 الفوترة وسجل المدفوعات
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> recordPayment({
    required String workspaceId,
    required String clientName,
    required String storeName,
    required double amount,
    String currency = 'YER',
    String paymentMethod = 'نقداً',
    int durationDays = 30,
    bool isLifetime = false,
    String notes = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'PAY-$now-${workspaceId.hashCode.abs() % 1000}';
    final rec = BillingRecord(
      id: id,
      workspaceId: workspaceId,
      clientName: clientName,
      storeName: storeName,
      amount: amount,
      currency: currency,
      paymentMethod: paymentMethod,
      durationDays: durationDays,
      isLifetime: isLifetime,
      notes: notes,
      timestamp: now,
    );
    await _sendWithAuth(
      (u) => _http
          .put(
            u,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(rec.toJson()),
          )
          .timeout(const Duration(seconds: 10)),
      '/workspaces/_registry/billing_ledger/$id',
    );
  }

  Future<List<BillingRecord>> fetchBillingHistory({
    String? workspaceId,
  }) async {
    final res = await _sendWithAuth(
      (u) => _http.get(u).timeout(const Duration(seconds: 12)),
      '/workspaces/_registry/billing_ledger',
    );
    if (res.statusCode != 200 || res.body.isEmpty || res.body == 'null') {
      return const [];
    }
    final raw = jsonDecode(res.body);
    if (raw is! Map) return const [];
    final out = <BillingRecord>[];
    raw.forEach((id, val) {
      if (val is Map) {
        final r = BillingRecord.fromJson('$id', val);
        if (workspaceId == null ||
            workspaceId.isEmpty ||
            r.workspaceId == workspaceId) {
          out.add(r);
        }
      }
    });
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 🎟️ أكواد التفعيل المسبق (Vouchers)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<List<VoucherModel>> generateVouchers({
    required int count,
    required int durationDays,
    bool isLifetime = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final created = <VoucherModel>[];
    final chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    var seed = now;

    String randomPart(int len) {
      final sb = StringBuffer();
      for (var i = 0; i < len; i++) {
        seed = (seed * 1664525 + 1013904223) & 0x7fffffff;
        sb.write(chars[seed % chars.length]);
      }
      return sb.toString();
    }

    for (var i = 0; i < count; i++) {
      final code =
          'NX-VCH-${randomPart(4)}-${randomPart(4)}-${(i + 1).toString().padLeft(2, '0')}';
      final v = VoucherModel(
        code: code,
        durationDays: durationDays,
        isLifetime: isLifetime,
        createdAt: now + i,
      );
      await _sendWithAuth(
        (u) => _http
            .put(
              u,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(v.toJson()),
            )
            .timeout(const Duration(seconds: 10)),
        '/workspaces/_registry/vouchers/$code',
      );
      created.add(v);
    }
    return created;
  }

  Future<List<VoucherModel>> fetchVouchers() async {
    final res = await _sendWithAuth(
      (u) => _http.get(u).timeout(const Duration(seconds: 12)),
      '/workspaces/_registry/vouchers',
    );
    if (res.statusCode != 200 || res.body.isEmpty || res.body == 'null') {
      return const [];
    }
    final raw = jsonDecode(res.body);
    if (raw is! Map) return const [];
    final out = <VoucherModel>[];
    raw.forEach((code, val) {
      if (val is Map) {
        out.add(VoucherModel.fromJson('$code', val));
      }
    });
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<void> deleteVoucher(String code) async {
    final clean = sanitizeKey(code);
    await _sendWithAuth(
      (u) => _http.delete(u).timeout(const Duration(seconds: 10)),
      '/workspaces/_registry/vouchers/$clean',
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 💬 مراسلات الدعم الفني والتحكم العام بالنظام
  // ═══════════════════════════════════════════════════════════════════════════

  Future<List<SupportMessage>> fetchSupportMessages(String workspaceId) async {
    final cleanWs = sanitizeKey(workspaceId);
    final res = await _sendWithAuth(
      (u) => _http.get(u).timeout(const Duration(seconds: 10)),
      '/workspaces/_registry/support_threads/$cleanWs/messages',
    );
    if (res.statusCode != 200 || res.body.isEmpty || res.body == 'null') {
      return const [];
    }
    final raw = jsonDecode(res.body);
    if (raw is! Map) return const [];
    final out = <SupportMessage>[];
    raw.forEach((id, val) {
      if (val is Map) {
        out.add(SupportMessage.fromJson('$id', val));
      }
    });
    out.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return out;
  }

  Future<void> sendSupportReply(String workspaceId, String text) async {
    final cleanWs = sanitizeKey(workspaceId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'MSG-$now';
    final msg = SupportMessage(
      id: id,
      sender: 'admin',
      text: text.trim(),
      timestamp: now,
    );
    await _sendWithAuth(
      (u) => _http
          .put(
            u,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(msg.toJson()),
          )
          .timeout(const Duration(seconds: 10)),
      '/workspaces/_registry/support_threads/$cleanWs/messages/$id',
    );
    await sendDirectNotification(
      workspaceId: workspaceId,
      title: 'رد جديد من الدعم الفني 💬',
      message: text.trim(),
      type: 'info',
    );
  }

  Future<Map<String, List<SupportMessage>>> fetchAllSupportThreads() async {
    final res = await _sendWithAuth(
      (u) => _http.get(u).timeout(const Duration(seconds: 12)),
      '/workspaces/_registry/support_threads',
    );
    if (res.statusCode != 200 || res.body.isEmpty || res.body == 'null') {
      return const {};
    }
    final raw = jsonDecode(res.body);
    if (raw is! Map) return const {};
    final out = <String, List<SupportMessage>>{};
    raw.forEach((wsId, threadVal) {
      if (threadVal is Map && threadVal['messages'] is Map) {
        final msgsMap = threadVal['messages'] as Map;
        final list = <SupportMessage>[];
        msgsMap.forEach((mId, mVal) {
          if (mVal is Map) {
            list.add(SupportMessage.fromJson('$mId', mVal));
          }
        });
        list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        if (list.isNotEmpty) {
          out['$wsId'] = list;
        }
      }
    });
    return out;
  }

  Future<Map<String, dynamic>> fetchBroadcastAlert() async {
    final res = await _sendWithAuth(
      (u) => _http.get(u).timeout(const Duration(seconds: 10)),
      '/workspaces/_registry/system_broadcast',
    );
    if (res.statusCode == 200 && res.body.isNotEmpty && res.body != 'null') {
      final raw = jsonDecode(res.body);
      if (raw is Map) return Map<String, dynamic>.from(raw);
    }
    return const {};
  }

  Future<void> publishBroadcastAlert({
    required String title,
    required String message,
    String type = 'info',
    bool active = true,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _sendWithAuth(
      (u) => _http
          .put(
            u,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'id': 'BC-$now',
              'title': title.trim(),
              'message': message.trim(),
              'type': type,
              'active': active,
              'updated_at': now,
            }),
          )
          .timeout(const Duration(seconds: 10)),
      '/workspaces/_registry/system_broadcast',
    );
  }

  Future<void> clearBroadcastAlert() async {
    await _sendWithAuth(
      (u) => _http.delete(u).timeout(const Duration(seconds: 10)),
      '/workspaces/_registry/system_broadcast',
    );
  }

  Future<Map<String, dynamic>> fetchAppUpdateConfig() async {
    final res = await _sendWithAuth(
      (u) => _http.get(u).timeout(const Duration(seconds: 10)),
      '/workspaces/_registry/app_update',
    );
    if (res.statusCode == 200 && res.body.isNotEmpty && res.body != 'null') {
      final raw = jsonDecode(res.body);
      if (raw is Map) return Map<String, dynamic>.from(raw);
    }
    return const {};
  }

  Future<void> publishAppUpdateConfig({
    required String latestVersion,
    required String minRequiredVersion,
    required String downloadUrl,
    required String releaseNotes,
    bool forceUpdate = false,
  }) async {
    await _sendWithAuth(
      (u) => _http
          .put(
            u,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'latest_version': latestVersion.trim(),
              'min_required_version': minRequiredVersion.trim(),
              'download_url': downloadUrl.trim(),
              'release_notes': releaseNotes.trim(),
              'force_update': forceUpdate,
              'updated_at': DateTime.now().millisecondsSinceEpoch,
            }),
          )
          .timeout(const Duration(seconds: 10)),
      '/workspaces/_registry/app_update',
    );
  }

  Future<Map<String, dynamic>> fetchMaintenanceMode() async {
    final res = await _sendWithAuth(
      (u) => _http.get(u).timeout(const Duration(seconds: 10)),
      '/workspaces/_registry/maintenance_mode',
    );
    if (res.statusCode == 200 && res.body.isNotEmpty && res.body != 'null') {
      final raw = jsonDecode(res.body);
      if (raw is Map) return Map<String, dynamic>.from(raw);
    }
    return const {};
  }

  Future<void> setMaintenanceMode({
    required bool enabled,
    required String message,
    String estimatedReturn = '',
  }) async {
    await _sendWithAuth(
      (u) => _http
          .put(
            u,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'enabled': enabled,
              'message': message.trim(),
              'estimated_return': estimatedReturn.trim(),
              'updated_at': DateTime.now().millisecondsSinceEpoch,
            }),
          )
          .timeout(const Duration(seconds: 10)),
      '/workspaces/_registry/maintenance_mode',
    );
  }
}

class HttpException implements Exception {
  final String message;
  HttpException(this.message);
  @override
  String toString() => message;
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
