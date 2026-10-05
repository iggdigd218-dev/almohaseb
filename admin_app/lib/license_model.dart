// 🔑 نماذج بيانات نظام التراخيص المعزول — تطبيق إدارة التراخيص (Nexora License Admin).
//
// يحتوي هذا الملف على كافة النماذج المهيكلة والمعزولة لنظام التراخيص:
//  • LicenseStatus & PlanDuration
//  • LicenseModel (النموذج القياسي للترخيص)
//  • ActivationResult (نتيجة التفعيل أو التجديد)
//  • SubscriberEntry (بطاقة المشترك في لوحة التحكم)
//  • ConnectedDevice (الأجهزة المرتبطة بالترخيص)
//  • BillingRecord (سجل المدفوعات والفوترة)
//  • VoucherModel (أكواد التفعيل والشحن المسبق)
//  • SupportMessage & AdminMetrics

/// حالة الترخيص السحابي.
enum LicenseStatus {
  active('active', 'فعّال'),
  trial('trial', 'تجريبي'),
  expired('expired', 'منتهي');

  final String code;
  final String label;
  const LicenseStatus(this.code, this.label);

  static LicenseStatus fromString(String? val) {
    final v = (val ?? '').trim().toLowerCase();
    if (v == 'active') return LicenseStatus.active;
    if (v == 'expired') return LicenseStatus.expired;
    return LicenseStatus.trial;
  }
}

/// مدد خطط الاشتراك المتاحة للتفعيل أو التمديد.
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

int asInt(Object? v, [int dflt = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? dflt;
  return dflt;
}

int asMs(Object? v) => asInt(v, 0);

String asStr(Object? v) => v == null ? '' : '$v'.trim();

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

/// كائن الترخيص الكامل في قاعدة بيانات التراخيص المعزولة.
class LicenseModel {
  final String clientName;
  final String storeName;
  final String phone;
  final String deviceId;
  final String licenseKey;
  final int expiryDate; // Timestamp / Long ms
  final String status;

  final String workspaceId;
  final String planType;
  final int maxDevices;
  final int activatedAtMs;

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
  });

  Map<String, dynamic> toJson() => {
        'clientName': clientName,
        'storeName': storeName,
        'phone': phone,
        'deviceId': deviceId,
        'licenseKey': licenseKey,
        'expiryDate': expiryDate,
        'status': status,
        'client_name': clientName,
        'store_name': storeName,
        'device_id': deviceId,
        'license_key': licenseKey,
        'expires_at': expiryDate,
        'workspace_id': workspaceId,
        'plan_type': planType,
        'max_devices': maxDevices,
        'activated_at': activatedAtMs,
        'is_active': status == 'active',
      };

  factory LicenseModel.fromJson(
    Map<dynamic, dynamic> map, {
    String workspaceId = '',
  }) {
    final devId = asStr(map['deviceId'] ??
        map['device_id'] ??
        map['deviceRef'] ??
        map['device_ref']);
    final ws = asStr(map['workspaceId'] ?? map['workspace_id'] ?? workspaceId);
    final key = asStr(map['licenseKey'] ?? map['license_key'] ?? map['key']);
    final exp =
        asInt(map['expiryDate'] ?? map['expiry_date'] ?? map['expires_at']);

    return LicenseModel(
      clientName: asStr(map['clientName'] ??
          map['client_name'] ??
          map['userName'] ??
          map['user_name'] ??
          map['owner_name']),
      storeName: asStr(map['storeName'] ??
          map['store_name'] ??
          map['businessName'] ??
          map['business_name']),
      phone: asStr(map['phone'] ?? map['whatsapp'] ?? map['phoneNumber']),
      deviceId: devId,
      licenseKey: key.isNotEmpty
          ? key
          : generateLicenseKey(devId.isNotEmpty ? devId : ws),
      expiryDate: exp,
      status: asStr(map['status'] ?? 'trial').isEmpty
          ? 'trial'
          : asStr(map['status']),
      workspaceId: ws,
      planType: asStr(map['plan_type'] ?? map['planType'] ?? 'individual'),
      maxDevices: asInt(map['max_devices'] ?? map['maxDevices'], 1),
      activatedAtMs: asInt(map['activated_at'] ?? map['activatedAt']),
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
}

/// نتيجة تفعيل أو تجديد ناجحة.
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

/// سجل مشترك للعرض في قائمة المشتركين.
class SubscriberEntry {
  final String workspaceId;
  final String planType;
  final String status;
  final int maxDevices;
  final int expiresAtMs;
  final int activatedAtMs;
  final String deviceRef;
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
      clientName:
          asStr(map['clientName'] ?? map['client_name'] ?? map['userName']),
      storeName:
          asStr(map['storeName'] ?? map['store_name'] ?? map['businessName']),
      phone: asStr(map['phone'] ?? map['phone_number'] ?? map['whatsapp']),
      deviceId: devId,
      licenseKey: key,
      isFrozen: map['is_frozen'] == true || map['frozen'] == true,
      featureFlags: flags,
    );
  }
}

/// جهاز مسجل ضمن ترخيص المنشأة.
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

/// سجل مدفوعات وتحصيل التراخيص.
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

/// كود تفعيل مسبق الدفع (Voucher).
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

/// رسالة دعم فني.
class SupportMessage {
  final String id;
  final String sender;
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

/// مؤشرات لوحة التحكم الإحصائية.
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
