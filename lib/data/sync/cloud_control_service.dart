// 🌐 خدمة مركز التحكم السحابي والتنبيهات وإدارة الأجهزة (Cloud Control Service).
//
// تدير:
//  1) حفظ وقراءة رمز FCM والتنبيهات المباشرة (In-App & Broadcast Alerts).
//  2) الإدارة عن بعد: زر التعليق الفوري (Kill Switch)، التحديث الإجباري، وضع الصيانة.
//  3) تتبع نشاط الأجهزة (Connected Devices) وتلقي أمر النسخ الفوري.
//  4) شحن وتفعيل التراخيص ذاتياً عبر أكواد القسائم (Voucher Keys).
//  5) الدعم الفني المباشر مع الإدارة (Text & Emojis Only).
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_version.dart';
import '../../core/cloud_config.dart';
import '../../core/license_model.dart';
import '../repository.dart';
import 'device_id.dart';
import 'subscription_guard.dart';

class CloudControlService {
  CloudControlService._();
  static final CloudControlService instance = CloudControlService._();

  final ValueNotifier<bool> isFrozenNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> forceUpdateNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> maintenanceActiveNotifier =
      ValueNotifier<bool>(false);
  final ValueNotifier<String> maintenanceMessageNotifier =
      ValueNotifier<String>('');
  final ValueNotifier<List<CloudAlert>> cloudAlertsNotifier =
      ValueNotifier<List<CloudAlert>>([]);
  final ValueNotifier<int> unreadAlertCountNotifier = ValueNotifier<int>(0);

  static const String _kReadAlertIdsPref = 'read_cloud_alert_ids';
  Set<String>? _cachedReadAlertIds;

  Future<Set<String>> _loadReadAlertIds() async {
    if (_cachedReadAlertIds != null) return _cachedReadAlertIds!;
    try {
      final sp = await SharedPreferences.getInstance();
      final list = sp.getStringList(_kReadAlertIdsPref) ?? const [];
      _cachedReadAlertIds = list.toSet();
    } catch (_) {
      _cachedReadAlertIds ??= <String>{};
    }
    return _cachedReadAlertIds!;
  }

  /// معالج عند وصول تنبيه سحابي جديد في الوقت الفعلي
  void Function(CloudAlert alert)? onNewAlertReceived;

  bool _initializedAlertScan = false;
  final Set<String> _notifiedAlertIds = <String>{};

  Timer? _heartbeatTimer;
  bool _isChecking = false;

  /// بدء المراقبة الدورية لمركز التحكم (نبض كل 30 ثانية).
  void startPeriodicHeartbeat(Repo repo) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      checkControlCenter(repo);
    });
    // فحص أولي فوري
    checkControlCenter(repo);
  }

  void stop() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// فحص شامل لمركز التحكم السحابي وتحديث حالة الأجهزة والتنبيهات.
  Future<void> checkControlCenter(Repo repo) async {
    if (_isChecking) return;
    _isChecking = true;
    try {
      final st = await repo.settings();
      final backendUrl =
          effectiveBackendUrl((st['cloudBackendUrl'] ?? '').toString());
      if (backendUrl.isEmpty) return;

      final wsId = await SubscriptionGuard.workspaceIdFor(repo);
      final devId = await ensureDeviceId(repo);
      final base = backendUrl.replaceAll(RegExp(r'/+$'), '');

      // 1) فحص حالة التجميد والتعليق (Kill Switch)
      final subUrl = '$base/workspaces/${Uri.encodeComponent(wsId)}/subscription.json';
      final subMap = await _getJson(subUrl);
      if (subMap != null) {
        final frozen = subMap['is_frozen'] == true ||
            '${subMap['status']}'.trim().toLowerCase() == 'suspended';
        isFrozenNotifier.value = frozen;

        // التحقق من فك ارتباط الجهاز (Unlink Device) للمدير فقط
        final isOwner = await repo.isWorkspaceOwner();
        final boundDevId = '${subMap['deviceId'] ?? subMap['device_id'] ?? ''}'.trim();
        if (isOwner && boundDevId.isEmpty && subMap['status'] == 'active') {
          // تم فك ارتباط الجهاز من لوحة المدير بنجاح — إعادة ربط الجهاز الحالي تلقائياً
          await _patchJson(subUrl, {
            'deviceId': devId,
            'device_id': devId,
          });
        }
      }

      // 2) فحص سياسة التحديث الإجباري (Force Update)
      var verPolicy = await _getJson('$base/system/version_policy.json');
      verPolicy ??= await _getJson('$base/system/force_update.json');
      if (verPolicy != null) {
        final minBuild = _asInt(verPolicy['min_build'] ??
            verPolicy['min_version'] ??
            verPolicy['minBuild']);
        if (minBuild > 0 && kAppBuild < minBuild) {
          forceUpdateNotifier.value = true;
        } else {
          forceUpdateNotifier.value = false;
        }
      }

      // 3) فحص وضع الصيانة السحابي (Maintenance Mode)
      var maint = await _getJson('$base/system/maintenance.json');
      maint ??= await _getJson('$base/system/maintenance_mode.json');
      if (maint != null &&
          (maint['is_active'] == true || maint['isActive'] == true)) {
        maintenanceActiveNotifier.value = true;
        maintenanceMessageNotifier.value =
            '${maint['message'] ?? 'الخوادم قيد الصيانة المؤقتة لتحديث الخدمات'}';
      } else {
        maintenanceActiveNotifier.value = false;
        maintenanceMessageNotifier.value = '';
      }

      // 4) تسجيل نبض الجهاز والنشاط ورمز الإشعارات وبيانات المنشأة (Heartbeat & Metadata)
      final devName =
          (st['sync.deviceName'] ?? st['account.name'] ?? 'جهاز').trim();
      final storeName = (st['businessName'] ?? '').trim();
      final clientName = (st['managerName'] ??
              st['account.name'] ??
              st['sync.deviceName'] ??
              '')
          .trim();
      final phone = (st['phone'] ?? st['whatsapp'] ?? '').trim();
      final devUrl =
          '$base/workspaces/${Uri.encodeComponent(wsId)}/devices/${Uri.encodeComponent(devId)}.json';
      final platformName = kIsWeb
          ? 'web'
          : Platform.isAndroid
              ? 'Android'
              : Platform.isWindows
                  ? 'Windows'
                  : Platform.operatingSystem;

      final fcmToken = 'fcm_${devId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}';

      final devPayload = <String, dynamic>{
        'deviceId': devId,
        'device_id': devId,
        'deviceName': devName,
        'device_name': devName,
        'model': platformName,
        'platform': platformName,
        'lastSeenAt': {'.sv': 'timestamp'},
        'last_seen_at': {'.sv': 'timestamp'},
        'installed_version': '$kAppVersion+$kAppBuild',
        'fcm_token': fcmToken,
      };
      if (storeName.isNotEmpty) {
        devPayload['storeName'] = storeName;
        devPayload['store_name'] = storeName;
      }
      if (clientName.isNotEmpty) {
        devPayload['clientName'] = clientName;
        devPayload['client_name'] = clientName;
      }
      if (phone.isNotEmpty) {
        devPayload['phone'] = phone;
      }
      await _patchJson(devUrl, devPayload);

      // حفظ رمز الإشعارات وبيانات المنشأة مع عقدة الاشتراك (للمدير فقط)
      if (await repo.isWorkspaceOwner()) {
        final fcmWsUrl =
            '$base/workspaces/${Uri.encodeComponent(wsId)}/subscription.json';
        final subPatch = <String, dynamic>{
          'fcm_token': fcmToken,
          'last_seen_at': {'.sv': 'timestamp'},
          'lastSeenAt': {'.sv': 'timestamp'},
          'installed_version': '$kAppVersion+$kAppBuild',
          'device_id': devId,
          'deviceId': devId,
          'device_name': devName,
          'deviceName': devName,
        };
        if (storeName.isNotEmpty) {
          subPatch['store_name'] = storeName;
          subPatch['storeName'] = storeName;
        }
        if (clientName.isNotEmpty) {
          subPatch['client_name'] = clientName;
          subPatch['clientName'] = clientName;
        }
        if (phone.isNotEmpty) {
          subPatch['phone'] = phone;
          subPatch['phone_number'] = phone;
        }
        await _patchJson(fcmWsUrl, subPatch);
      }

      // 5) فحص أمر النسخ الاحتياطي الفوري عن بعد (Remote Instant Backup)
      final ctlUrl =
          '$base/workspaces/${Uri.encodeComponent(wsId)}/control.json';
      final ctlMap = await _getJson(ctlUrl);
      if (ctlMap != null && ctlMap['request_backup'] == true) {
        // تنفيذ النسخ فوراً
        try {
          final backupRes = await repo.exportForLocalBackup(withImages: false);
          final bSize = jsonEncode(backupRes).length;
          await _patchJson(
              '$base/workspaces/${Uri.encodeComponent(wsId)}/monitoring/backup.json',
              {
                'last_backup_at': {'.sv': 'timestamp'},
                'backup_size_bytes': bSize,
                'status': 'success',
              });
          await _patchJson(ctlUrl, {'request_backup': false});
        } catch (_) {}
      }

      // 6) جلب التنبيهات السحابية الحية (In-App Cloud Alerts)
      await _fetchCloudAlerts(base, wsId);
    } catch (_) {
      // نبض خلفي هادئ
    } finally {
      _isChecking = false;
    }
  }

  static const int kMaxRetentionMs = 6 * 3600 * 1000; // 6 ساعات كحد أقصى

  Future<int> _ensureFirstUseMs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      var firstUse = sp.getInt('app_first_use_ms');
      if (firstUse == null) {
        firstUse = DateTime.now().millisecondsSinceEpoch;
        await sp.setInt('app_first_use_ms', firstUse);
      }
      return firstUse;
    } catch (_) {
      return DateTime.now().millisecondsSinceEpoch;
    }
  }

  /// جلب الإشعارات الخاصة بالمنشأة والإشعارات العامة
  Future<void> _fetchCloudAlerts(String base, String wsId) async {
    final alerts = <CloudAlert>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    final firstUseMs = await _ensureFirstUseMs();
    final cutoff6h = now - kMaxRetentionMs;
    // العتبة الصارمة: إما مرور 6 ساعات أو وقت بدء استخدام المستخدم الجديد (أيهما أحدث)
    final effectiveMinTimeMs = firstUseMs > cutoff6h ? firstUseMs : cutoff6h;

    // إشعارات المنشأة
    final wsNotifUrl =
        '$base/workspaces/${Uri.encodeComponent(wsId)}/notifications.json';
    final wsNotifs = await _getJson(wsNotifUrl);
    if (wsNotifs is Map) {
      for (final e in wsNotifs.entries) {
        if (e.value is Map) {
          final alert = CloudAlert.fromJson(e.value as Map, e.key.toString());
          if (alert.createdAt >= effectiveMinTimeMs) {
            alerts.add(alert);
          }
        }
      }
    }
    // إشعارات البث العام — فحص كلا المسارين system/broadcast_notifications و system/broadcast_alerts
    final bcastUrl1 = '$base/system/broadcast_notifications.json';
    final bcastNotifs1 = await _getJson(bcastUrl1);
    if (bcastNotifs1 is Map) {
      for (final e in bcastNotifs1.entries) {
        if (e.value is Map) {
          final alert = CloudAlert.fromJson(e.value as Map, e.key.toString());
          if (alert.createdAt >= effectiveMinTimeMs) {
            alerts.add(alert);
          }
        }
      }
    }
    final bcastUrl2 = '$base/system/broadcast_alerts.json';
    final bcastNotifs2 = await _getJson(bcastUrl2);
    if (bcastNotifs2 is Map) {
      for (final e in bcastNotifs2.entries) {
        if (e.value is Map) {
          final id = e.key.toString();
          if (!alerts.any((a) => a.id == id)) {
            final alert = CloudAlert.fromJson(e.value as Map, id);
            if (alert.createdAt >= effectiveMinTimeMs) {
              alerts.add(alert);
            }
          }
        }
      }
    }

    final readIds = await _loadReadAlertIds();
    final resolvedAlerts = <CloudAlert>[];
    for (final a in alerts) {
      if (a.createdAt < effectiveMinTimeMs) continue;
      final isAlreadyRead = a.isRead || readIds.contains(a.id);
      if (isAlreadyRead != a.isRead) {
        resolvedAlerts.add(CloudAlert(
          id: a.id,
          title: a.title,
          body: a.body,
          isModal: a.isModal,
          createdAt: a.createdAt,
          isRead: isAlreadyRead,
          targetWs: a.targetWs,
        ));
      } else {
        resolvedAlerts.add(a);
      }
    }

    resolvedAlerts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    cloudAlertsNotifier.value = resolvedAlerts;
    final unreadList = resolvedAlerts.where((a) => !a.isRead).toList();
    unreadAlertCountNotifier.value = unreadList.length;

    if (!_initializedAlertScan) {
      _initializedAlertScan = true;
      for (final a in unreadList) {
        // عند فتح التطبيق، إذا وُجد تنبيه حديث خلال آخر 15 دقيقة لم يُقرأ، نطلقه فوراً
        // بشرط ألا يكون قديماً قبل وقت بدء استخدام المستخدم
        if (a.createdAt > (now - 15 * 60 * 1000) && a.createdAt >= firstUseMs) {
          _notifiedAlertIds.add(a.id);
          onNewAlertReceived?.call(a);
        } else {
          _notifiedAlertIds.add(a.id);
        }
      }
    } else {
      // في الفحوصات الدورية اللاحقة: أي تنبيه لم يُشعر به الجهاز
      for (final a in unreadList) {
        if (!_notifiedAlertIds.contains(a.id)) {
          _notifiedAlertIds.add(a.id);
          onNewAlertReceived?.call(a);
        }
      }
    }
  }

  /// تعليم كافة التنبيهات السحابية كمقروءة وحفظها محلياً في SharedPreferences لمنع عودتها
  Future<void> markAllAlertsRead([String? backendUrl, String? wsId]) async {
    final readIds = await _loadReadAlertIds();
    final currentAlerts = cloudAlertsNotifier.value;
    for (final a in currentAlerts) {
      readIds.add(a.id);
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_kReadAlertIdsPref, readIds.toList());
    } catch (_) {}

    final updated = currentAlerts.map((a) {
      if (!a.isRead) {
        return CloudAlert(
          id: a.id,
          title: a.title,
          body: a.body,
          isModal: a.isModal,
          createdAt: a.createdAt,
          isRead: true,
          targetWs: a.targetWs,
        );
      }
      return a;
    }).toList();
    cloudAlertsNotifier.value = updated;
    unreadAlertCountNotifier.value = 0;

    if (backendUrl != null &&
        wsId != null &&
        backendUrl.trim().isNotEmpty &&
        wsId.trim().isNotEmpty) {
      for (final a in currentAlerts) {
        if (a.targetWs.isNotEmpty) {
          markAlertAsRead(backendUrl, wsId, a.id);
        }
      }
    }
  }

  /// تعليم إشعار كمقروء وحفظه محلياً في SharedPreferences وسحابياً
  Future<void> markAlertAsRead(
      String backendUrl, String wsId, String notifId) async {
    try {
      final readIds = await _loadReadAlertIds();
      readIds.add(notifId);
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_kReadAlertIdsPref, readIds.toList());
    } catch (_) {}

    final updated = cloudAlertsNotifier.value.map((a) {
      if (a.id == notifId) {
        return CloudAlert(
          id: a.id,
          title: a.title,
          body: a.body,
          isModal: a.isModal,
          createdAt: a.createdAt,
          isRead: true,
          targetWs: a.targetWs,
        );
      }
      return a;
    }).toList();
    cloudAlertsNotifier.value = updated;
    unreadAlertCountNotifier.value = updated.where((a) => !a.isRead).length;

    try {
      final base = backendUrl.replaceAll(RegExp(r'/+$'), '');
      final notifUrl =
          '$base/workspaces/${Uri.encodeComponent(wsId)}/notifications/${Uri.encodeComponent(notifId)}.json';
      await _patchJson(notifUrl, {'isRead': true, 'is_read': true});
    } catch (_) {}
  }

  /// شحن وتفعيل كود الترخيص الذاتي (Voucher Key).
  /// يمدد الاشتراك فورياً ويحدّث حالة الكود في السيرفر إلى "مستخدم".
  Future<VoucherModel> redeemVoucherKey(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    required String rawVoucherCode,
  }) async {
    final code = rawVoucherCode.trim().toUpperCase();
    if (code.isEmpty) {
      throw ArgumentError('يرجى إدخال كود الشحن');
    }

    final base = backendUrl.replaceAll(RegExp(r'/+$'), '');
    final vchUrl = '$base/vouchers/${Uri.encodeComponent(code)}.json';
    final vchData = await _getJson(vchUrl);
    if (vchData == null) {
      throw StateError('كود الشحن المدخل غير صحيح أو غير موجود بالسيرفر');
    }

    final isUsed = vchData['isUsed'] == true || vchData['is_used'] == true;
    if (isUsed) {
      throw StateError('كود الشحن هذا تم استخدامه مسبقاً وغير صالح للتفعيل');
    }

    final durationDays = _asInt(vchData['durationDays'] ?? vchData['duration_days'], 30);
    final isLifetime =
        vchData['isLifetime'] == true || vchData['is_lifetime'] == true;
    final devId = await ensureDeviceId(repo);
    final nowMs = await SubscriptionGuard.serverNowMs(backendUrl);

    // قراءة الاشتراك الحالي لحساب المدة التراكمية
    final subUrl =
        '$base/workspaces/${Uri.encodeComponent(workspaceId)}/subscription.json';
    final currentSub = await _getJson(subUrl) ?? {};
    final currentExp = _asInt(currentSub['expires_at'] ?? currentSub['expiryDate']);

    int newExpMs;
    if (isLifetime) {
      newExpMs = DateTime(2099, 1, 1).millisecondsSinceEpoch;
    } else {
      final baseExp = (currentExp > nowMs) ? currentExp : nowMs;
      newExpMs = baseExp + (durationDays * 86400000);
    }

    // 1) تعليم الكود كمستخدم في السحابة
    await _patchJson(vchUrl, {
      'isUsed': true,
      'is_used': true,
      'usedByWs': workspaceId,
      'used_by_ws': workspaceId,
      'usedByDevice': devId,
      'used_by_device': devId,
      'usedAt': {'.sv': 'timestamp'},
      'used_at': {'.sv': 'timestamp'},
    });

    // 2) تمديد عقدة الاشتراك السحابية وتفعيل الحساب
    await _patchJson(subUrl, {
      'status': 'active',
      'is_active': true,
      'is_frozen': false,
      'expires_at': newExpMs,
      'expiryDate': newExpMs,
      'last_voucher_used': code,
      'plan_type': isLifetime ? 'lifetime' : (currentSub['plan_type'] ?? 'individual'),
    });

    // 3) تصفير الكاش وإعادة فحص الاشتراك فورياً
    SubscriptionGuard.debugReset();
    await SubscriptionGuard.check(repo,
        backendUrl: backendUrl, workspaceId: workspaceId, force: true);

    return VoucherModel(
      code: code,
      durationDays: durationDays,
      isLifetime: isLifetime,
      createdAt: _asInt(vchData['createdAt']),
      isUsed: true,
      usedByWs: workspaceId,
      usedByDevice: devId,
      usedAt: nowMs,
    );
  }

  /// إرسال رسالة دعم فني جديدة من العميل للإدارة (Text & Emojis Only).
  Future<void> sendSupportMessage(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    required String text,
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty) return;

    final base = backendUrl.replaceAll(RegExp(r'/+$'), '');
    final st = await repo.settings();
    final clientName = (st['managerName'] ??
            st['account.name'] ??
            st['sync.deviceName'] ??
            'مسؤول المنشأة')
        .toString()
        .trim();
    final storeName = (st['businessName'] ?? 'منشأة').toString().trim();
    final phone = (st['phone'] ?? st['whatsapp'] ?? '').toString().trim();
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgId = 'msg_${now}_${(cleanText.hashCode.abs() % 10000)}';

    final msgUrl =
        '$base/support_chats/${Uri.encodeComponent(workspaceId)}/messages/${Uri.encodeComponent(msgId)}.json';
    final metaUrl =
        '$base/support_chats/${Uri.encodeComponent(workspaceId)}/meta.json';
    final rootChatUrl =
        '$base/support_chats/${Uri.encodeComponent(workspaceId)}.json';

    final msgPayload = {
      'id': msgId,
      'workspaceId': workspaceId,
      'workspace_id': workspaceId,
      'storeName': storeName,
      'store_name': storeName,
      'clientName': clientName,
      'client_name': clientName,
      'phone': phone,
      'sender': 'client',
      'senderName': clientName,
      'sender_name': clientName,
      'text': cleanText,
      'timestamp': {'.sv': 'timestamp'},
      'created_at': now,
      'createdAt': now,
      'isRead': false,
      'is_read': false,
    };

    await _putJson(msgUrl, msgPayload);

    final chatMeta = {
      'workspaceId': workspaceId,
      'workspace_id': workspaceId,
      'storeName': storeName,
      'store_name': storeName,
      'clientName': clientName,
      'client_name': clientName,
      'phone': phone,
      'lastMessage': cleanText,
      'last_message': cleanText,
      'lastSender': 'client',
      'last_sender': 'client',
      'updatedAt': {'.sv': 'timestamp'},
      'updated_at': now,
      'unreadByAdmin': true,
      'unread_by_admin': true,
      'unreadByClient': false,
      'unread_by_client': false,
    };

    await _patchJson(metaUrl, chatMeta);
    await _patchJson(rootChatUrl, chatMeta);
  }

  /// استرجاع رسائل الدعم الفني
  Future<List<SupportMessage>> fetchSupportMessages(
    String backendUrl,
    String workspaceId,
  ) async {
    final base = backendUrl.replaceAll(RegExp(r'/+$'), '');
    final url =
        '$base/support_chats/${Uri.encodeComponent(workspaceId)}/messages.json';
    final data = await _getJson(url);
    if (data is! Map) return [];

    final list = <SupportMessage>[];
    for (final e in data.entries) {
      if (e.value is Map) {
        list.add(SupportMessage.fromJson(e.value as Map, e.key.toString()));
      }
    }
    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return list;
  }

  // --- دوال مساعدة للاتصال عبر REST ---

  static Future<dynamic> _getJson(String url) async {
    try {
      final res =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final t = res.body.trim();
      if (t.isEmpty || t == 'null') return null;
      return jsonDecode(t);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _patchJson(String url, Map<String, dynamic> body) async {
    try {
      await http
          .patch(Uri.parse(url),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  static Future<void> _putJson(String url, Object body) async {
    try {
      await http
          .put(Uri.parse(url),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  static int _asInt(Object? v, [int dflt = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? dflt;
    return dflt;
  }
}
