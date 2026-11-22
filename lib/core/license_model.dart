// 🔑 نموذج الترخيص وبيانات المشترك ومنظومة التحكم السحابي (2026-09-24).
//
// يمثل كائن الترخيص في قاعدة البيانات السحابية (Firebase / Backend).
// يدعم مركز التحكم السحابي:
//  • الحقول الإلزامية: clientName, storeName, phone, deviceId, licenseKey, expiryDate, status
//  • التنبيهات المباشرة ورموز FCM: fcmToken
//  • الإدارة عن بعد: isFrozen, minAppVersion, maintenanceMode, maintenanceMessage
//  • مفاتيح الميزات: featureFlags (cloud_sync, cloud_backup, multi_branch, multi_user, advanced_invoicing)
//  • سقوف الاستخدام: maxDevices, maxTrialInvoices
//  • مراقبة السحابة والنسخ: lastBackupAt, backupSizeBytes, lastSeenAt, installedVersion
library;

import 'dart:math';

/// حالة الترخيص السحابي.
enum LicenseStatus {
  active('active', 'فعّال'),
  trial('trial', 'تجريبي'),
  expired('expired', 'منتهي'),
  suspended('suspended', 'معلّق');

  final String code;
  final String label;
  const LicenseStatus(this.code, this.label);

  static LicenseStatus fromString(String? val) {
    final v = (val ?? '').trim().toLowerCase();
    if (v == 'active') return LicenseStatus.active;
    if (v == 'expired') return LicenseStatus.expired;
    if (v == 'suspended') return LicenseStatus.suspended;
    return LicenseStatus.trial;
  }
}

/// توليد كود ترخيص قياسي منظم من معرف الجهاز أو البصمة.
/// صيغة الكود: NX-XXXX-XXXX-XXXX
String generateLicenseKey(String seed) {
  if (seed.trim().isEmpty) return 'NX-KEY-0000-0001';
  final clean = seed.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  String core = clean;
  if (core.startsWith('DEVICE')) {
    core = core.substring(6);
  } else if (core.startsWith('WS')) {
    core = core.substring(2);
  }
  if (core.isEmpty) core = clean;

  if (core.length >= 12) {
    return 'NX-${core.substring(0, 4)}-${core.substring(4, 8)}-${core.substring(8, 12)}';
  } else if (core.length >= 8) {
    return 'NX-${core.substring(0, 4)}-${core.substring(4, 8)}';
  } else if (core.length >= 4) {
    return 'NX-${core.substring(0, 4)}-0001';
  }
  return 'NX-${core.padRight(4, '0')}-0001';
}

/// توليد كود شحن / قسيمة تفعيل (Voucher Key).
/// نمط الكود: VCH-XXXX-XXXX-XXXX
String generateVoucherCode([String prefix = 'VCH']) {
  const chars = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  final rnd = Random.secure();
  String chunk(int len) =>
      List.generate(len, (_) => chars[rnd.nextInt(chars.length)]).join();
  return '$prefix-${chunk(4)}-${chunk(4)}-${chunk(4)}';
}

/// تحويل آمن للأرقام والأختام الزمنية.
int _asInt(Object? v, [int dflt = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? dflt;
  return dflt;
}

double _asDouble(Object? v, [double dflt = 0.0]) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim()) ?? dflt;
  return dflt;
}

String _asStr(Object? v) => v == null ? '' : '$v'.trim();

bool _asBool(Object? v, [bool dflt = false]) {
  if (v is bool) return v;
  if (v is num) return v == 1;
  if (v is String) {
    final s = v.trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'yes';
  }
  return dflt;
}

/// كائن الترخيص الكامل في قاعدة البيانات السحابية والمحلية.
class LicenseModel {
  final String clientName;
  final String storeName;
  final String phone;
  final String deviceId;
  final String licenseKey;
  final int expiryDate; // Timestamp / Long ms
  final String status;

  // حقول إضافية للمساحة والتوافق
  final String workspaceId;
  final String planType;
  final int maxDevices;
  final int activatedAtMs;

  // الحقول السحابية المتقدمة لمركز التحكم (Cloud Control Center)
  final String fcmToken;
  final bool isFrozen;
  final String minAppVersion;
  final bool maintenanceMode;
  final String maintenanceMessage;
  final Map<String, bool> featureFlags;
  final int maxTrialInvoices;
  final int lastBackupAt;
  final int backupSizeBytes;
  final int lastSeenAt;
  final String installedVersion;

  const LicenseModel({
    required this.clientName,
    required this.storeName,
    required this.phone,
    required this.deviceId,
    required this.licenseKey,
    required this.expiryDate,
    required this.status,
    this.workspaceId = '',
    this.planType = 'individual',
    this.maxDevices = 1,
    this.activatedAtMs = 0,
    this.fcmToken = '',
    this.isFrozen = false,
    this.minAppVersion = '',
    this.maintenanceMode = false,
    this.maintenanceMessage = '',
    this.featureFlags = const {},
    this.maxTrialInvoices = 0,
    this.lastBackupAt = 0,
    this.backupSizeBytes = 0,
    this.lastSeenAt = 0,
    this.installedVersion = '',
  });

  /// تحويل الكائن إلى خريطة JSON تُكتب في Firebase RTDB.
  Map<String, dynamic> toJson() => {
        // الحقول الإجبارية المطلوبة (camelCase)
        'clientName': clientName,
        'storeName': storeName,
        'phone': phone,
        'deviceId': deviceId,
        'licenseKey': licenseKey,
        'expiryDate': expiryDate,
        'status': status,

        // أسماء التوافق الرجعي مع العقد السابقة في RTDB
        'client_name': clientName,
        'store_name': storeName,
        'device_id': deviceId,
        'license_key': licenseKey,
        'expires_at': expiryDate,
        'workspace_id': workspaceId,
        'plan_type': planType,
        'max_devices': maxDevices,
        'activated_at': activatedAtMs,
        'is_active': status == 'active' && !isFrozen,

        // حقول التحكم والإدارة عن بعد
        'fcm_token': fcmToken,
        'is_frozen': isFrozen,
        'min_version': minAppVersion,
        'maintenance_mode': maintenanceMode,
        'maintenance_message': maintenanceMessage,
        'feature_flags': featureFlags,
        'max_trial_invoices': maxTrialInvoices,
        'last_backup_at': lastBackupAt,
        'backup_size_bytes': backupSizeBytes,
        'last_seen_at': lastSeenAt,
        'installed_version': installedVersion,
      };

  factory LicenseModel.fromJson(Map<dynamic, dynamic> map,
      {String workspaceId = ''}) {
    final devId = _asStr(map['deviceId'] ??
        map['device_id'] ??
        map['deviceRef'] ??
        map['device_ref']);
    final ws =
        _asStr(map['workspaceId'] ?? map['workspace_id'] ?? workspaceId);
    final key = _asStr(map['licenseKey'] ?? map['license_key'] ?? map['key']);
    final exp = _asInt(map['expiryDate'] ??
        map['expiry_date'] ??
        map['expires_at']);

    final rawFlags = map['feature_flags'] ?? map['features'];
    final Map<String, bool> flags = {};
    if (rawFlags is Map) {
      for (final e in rawFlags.entries) {
        flags[e.key.toString()] = _asBool(e.value, true);
      }
    }

    final rawFrozen = map['is_frozen'] ?? map['isFrozen'];
    final frozen = _asBool(rawFrozen, false) ||
        _asStr(map['status']).toLowerCase() == 'suspended';

    return LicenseModel(
      clientName: _asStr(map['clientName'] ??
          map['client_name'] ??
          map['userName'] ??
          map['user_name'] ??
          map['owner_name']),
      storeName: _asStr(map['storeName'] ??
          map['store_name'] ??
          map['businessName'] ??
          map['business_name']),
      phone: _asStr(map['phone'] ?? map['whatsapp'] ?? map['phoneNumber']),
      deviceId: devId,
      licenseKey: key.isNotEmpty
          ? key
          : generateLicenseKey(devId.isNotEmpty ? devId : ws),
      expiryDate: exp,
      status: frozen
          ? 'suspended'
          : (_asStr(map['status'] ?? 'trial').isEmpty
              ? 'trial'
              : _asStr(map['status'])),
      workspaceId: ws,
      planType: _asStr(map['plan_type'] ?? map['planType'] ?? 'individual'),
      maxDevices: _asInt(map['max_devices'] ?? map['maxDevices'], 1),
      activatedAtMs: _asInt(map['activated_at'] ?? map['activatedAt']),
      fcmToken: _asStr(map['fcm_token'] ?? map['fcmToken']),
      isFrozen: frozen,
      minAppVersion: _asStr(map['min_version'] ?? map['minAppVersion']),
      maintenanceMode:
          _asBool(map['maintenance_mode'] ?? map['maintenanceMode']),
      maintenanceMessage:
          _asStr(map['maintenance_message'] ?? map['maintenanceMessage']),
      featureFlags: flags,
      maxTrialInvoices:
          _asInt(map['max_trial_invoices'] ?? map['maxTrialInvoices']),
      lastBackupAt: _asInt(map['last_backup_at'] ?? map['lastBackupAt']),
      backupSizeBytes:
          _asInt(map['backup_size_bytes'] ?? map['backupSizeBytes']),
      lastSeenAt: _asInt(map['last_seen_at'] ?? map['lastSeenAt']),
      installedVersion:
          _asStr(map['installed_version'] ?? map['installedVersion']),
    );
  }

  LicenseStatus get licenseStatus => LicenseStatus.fromString(status);

  bool get isExpired =>
      expiryDate > 0 &&
      expiryDate < DateTime.now().millisecondsSinceEpoch &&
      expiryDate < DateTime(2090).millisecondsSinceEpoch;

  bool get isLifetime =>
      expiryDate >= DateTime(2090).millisecondsSinceEpoch ||
      planType == 'lifetime';

  /// هل ميزة معينة مفعلة في مفاتيح الميزات؟
  bool isFeatureEnabled(String featureKey, [bool defaultValue = true]) {
    if (featureFlags.containsKey(featureKey)) {
      return featureFlags[featureKey] ?? defaultValue;
    }
    return defaultValue;
  }
}

/// قسيمة / كود شحن وتفعيل مسبق الدفع (Voucher Key).
class VoucherModel {
  final String code;
  final int durationDays;
  final bool isLifetime;
  final int createdAt;
  final bool isUsed;
  final String usedByWs;
  final String usedByDevice;
  final int usedAt;

  const VoucherModel({
    required this.code,
    required this.durationDays,
    this.isLifetime = false,
    required this.createdAt,
    this.isUsed = false,
    this.usedByWs = '',
    this.usedByDevice = '',
    this.usedAt = 0,
  });

  Map<String, dynamic> toJson() => {
        'code': code,
        'durationDays': durationDays,
        'isLifetime': isLifetime,
        'createdAt': createdAt,
        'isUsed': isUsed,
        'usedByWs': usedByWs,
        'usedByDevice': usedByDevice,
        'usedAt': usedAt,
      };

  factory VoucherModel.fromJson(Map<dynamic, dynamic> map, [String code = '']) {
    return VoucherModel(
      code: _asStr(map['code'] ?? code),
      durationDays: _asInt(map['durationDays'] ?? map['duration_days'], 30),
      isLifetime: _asBool(map['isLifetime'] ?? map['is_lifetime'], false),
      createdAt: _asInt(map['createdAt'] ?? map['created_at']),
      isUsed: _asBool(map['isUsed'] ?? map['is_used'], false),
      usedByWs: _asStr(map['usedByWs'] ?? map['used_by_ws']),
      usedByDevice: _asStr(map['usedByDevice'] ?? map['used_by_device']),
      usedAt: _asInt(map['usedAt'] ?? map['used_at']),
    );
  }

  String get durationLabel {
    if (isLifetime) return 'تفعيل دائم (مدى الحياة)';
    if (durationDays == 30) return 'شهر واحد (30 يوماً)';
    if (durationDays == 90) return '3 أشهر (90 يوماً)';
    if (durationDays == 365) return 'سنة كاملة (365 يوماً)';
    return '$durationDays يوماً';
  }
}

/// سجل مدفوعات وتحصيل ترخيص (Billing Record).
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
    required this.clientName,
    required this.storeName,
    required this.amount,
    required this.currency,
    required this.paymentMethod,
    required this.durationDays,
    this.isLifetime = false,
    this.notes = '',
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'workspaceId': workspaceId,
        'clientName': clientName,
        'storeName': storeName,
        'amount': amount,
        'currency': currency,
        'paymentMethod': paymentMethod,
        'durationDays': durationDays,
        'isLifetime': isLifetime,
        'notes': notes,
        'timestamp': timestamp,
      };

  factory BillingRecord.fromJson(Map<dynamic, dynamic> map, [String id = '']) {
    return BillingRecord(
      id: _asStr(map['id'] ?? id),
      workspaceId: _asStr(map['workspaceId'] ?? map['workspace_id']),
      clientName: _asStr(map['clientName'] ?? map['client_name']),
      storeName: _asStr(map['storeName'] ?? map['store_name']),
      amount: _asDouble(map['amount']),
      currency: _asStr(map['currency'] ?? 'YER'),
      paymentMethod: _asStr(map['paymentMethod'] ?? map['payment_method'] ?? 'cash'),
      durationDays: _asInt(map['durationDays'] ?? map['duration_days']),
      isLifetime: _asBool(map['isLifetime'] ?? map['is_lifetime']),
      notes: _asStr(map['notes']),
      timestamp: _asInt(map['timestamp'] ?? map['created_at']),
    );
  }
}

/// جهاز متصل بمنشأة (Connected Device).
class ConnectedDevice {
  final String deviceId;
  final String deviceName;
  final String model;
  final String platform;
  final int linkedAt;
  final int lastSeenAt;
  final bool isBlocked;

  const ConnectedDevice({
    required this.deviceId,
    this.deviceName = '',
    this.model = '',
    this.platform = '',
    this.linkedAt = 0,
    this.lastSeenAt = 0,
    this.isBlocked = false,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'model': model,
        'platform': platform,
        'linkedAt': linkedAt,
        'lastSeenAt': lastSeenAt,
        'isBlocked': isBlocked,
      };

  factory ConnectedDevice.fromJson(Map<dynamic, dynamic> map, [String id = '']) {
    return ConnectedDevice(
      deviceId: _asStr(map['deviceId'] ?? map['device_id'] ?? id),
      deviceName: _asStr(map['deviceName'] ?? map['device_name']),
      model: _asStr(map['model']),
      platform: _asStr(map['platform']),
      linkedAt: _asInt(map['linkedAt'] ?? map['linked_at']),
      lastSeenAt: _asInt(map['lastSeenAt'] ?? map['last_seen_at']),
      isBlocked: _asBool(map['isBlocked'] ?? map['is_blocked'], false),
    );
  }
}

/// رسالة دعم فني مباشرة مع الإدارة (Support Message — Text & Emojis Only).
class SupportMessage {
  final String id;
  final String workspaceId;
  final String sender; // 'client' | 'admin'
  final String senderName;
  final String text;
  final int timestamp;
  final bool isRead;

  const SupportMessage({
    required this.id,
    required this.workspaceId,
    required this.sender,
    this.senderName = '',
    required this.text,
    required this.timestamp,
    this.isRead = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'workspaceId': workspaceId,
        'sender': sender,
        'senderName': senderName,
        'text': text,
        'timestamp': timestamp,
        'isRead': isRead,
      };

  factory SupportMessage.fromJson(Map<dynamic, dynamic> map, [String id = '']) {
    return SupportMessage(
      id: _asStr(map['id'] ?? id),
      workspaceId: _asStr(map['workspaceId'] ?? map['workspace_id']),
      sender: _asStr(map['sender'] ?? 'client'),
      senderName: _asStr(map['senderName'] ?? map['sender_name']),
      text: _asStr(map['text'] ?? map['body']),
      timestamp: _asInt(map['timestamp'] ?? map['created_at']),
      isRead: _asBool(map['isRead'] ?? map['is_read'], false),
    );
  }
}

/// تنبيه سحابي مباشر أو عام (Cloud Alert).
class CloudAlert {
  final String id;
  final String title;
  final String body;
  final bool isModal;
  final int createdAt;
  final bool isRead;
  final String targetWs;

  const CloudAlert({
    required this.id,
    required this.title,
    required this.body,
    this.isModal = false,
    required this.createdAt,
    this.isRead = false,
    this.targetWs = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'isModal': isModal,
        'createdAt': createdAt,
        'isRead': isRead,
        'targetWs': targetWs,
      };

  factory CloudAlert.fromJson(Map<dynamic, dynamic> map, [String id = '']) {
    return CloudAlert(
      id: _asStr(map['id'] ?? id),
      title: _asStr(map['title']),
      body: _asStr(map['body']),
      isModal: _asBool(map['isModal'] ?? map['is_modal'], false),
      createdAt: _asInt(map['createdAt'] ?? map['created_at']),
      isRead: _asBool(map['isRead'] ?? map['is_read'], false),
      targetWs: _asStr(map['targetWs'] ?? map['target_ws']),
    );
  }
}
