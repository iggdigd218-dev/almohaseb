// 🔑 نموذج الترخيص وبيانات المشترك السحابية — تطبيق المدير (2026-09-24).
//
// يمثل كائن الترخيص في قاعدة البيانات السحابية (Firebase / Backend).
// الحقول الإجبارية:
//  • clientName: اسم العميل / المسؤول
//  • storeName: اسم المنشأة / المحل
//  • phone: رقم الهاتف / الواتساب
//  • deviceId: معرف الجهاز الفريد
//  • licenseKey: كود الترخيص
//  • expiryDate: ختم تاريخ الانتهاء بالمللي ثانية (Timestamp / Long)
//  • status: حالة الترخيص (active | trial | expired)

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

int _asInt(Object? v, [int dflt = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? dflt;
  return dflt;
}

String _asStr(Object? v) => v == null ? '' : '$v'.trim();

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

  /// تحويل الكائن إلى خريطة JSON تُكتب في Firebase RTDB.
  /// يضم التسميات camelCase الإجبارية وأسماء snake_case للتوافق الرجعي.
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
        'is_active': status == 'active',
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
      status: _asStr(map['status'] ?? 'trial').isEmpty
          ? 'trial'
          : _asStr(map['status']),
      workspaceId: ws,
      planType: _asStr(map['plan_type'] ?? map['planType'] ?? 'individual'),
      maxDevices: _asInt(map['max_devices'] ?? map['maxDevices'], 1),
      activatedAtMs: _asInt(map['activated_at'] ?? map['activatedAt']),
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
