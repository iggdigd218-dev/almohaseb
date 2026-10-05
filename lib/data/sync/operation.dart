// نموذج عملية المزامنة (Operation Log Entry).
// كل عملية إنشاء/تعديل/حذف/استعادة تُسجل في هذا الكائن أولاً محليًا،
// ثم تُرفع إلى السحابة أو الأجهزة الأخرى عبر SyncEngine.
import 'dart:convert';

/// أنواع العمليات المدعومة.
enum OpKind { create, update, delete_, restore, settings }

/// الكيانات التي يمكن تتبعها.
enum EntityKind {
  account,
  tx,
  item,
  itemCategory,
  stockMove,
  voucher,
  user,
  currency,
  setting,
  category, // تصنيفات الحسابات (جدول categories)
  conversation, // محادثات الدردشة
  message, // رسائل الدردشة (دردشة المجموعة بين الأجهزة)
  unknown, // نوع من إصدار أحدث — يُتجاهل بأمان ولا يُكتب في أي جدول
  userPermission, // (3.70) صفوف الصلاحيات المحلية user_permissions
  section; // (2026-09-22) أقسام المتجر (sections)

  /// ══ (2026-09-22) أمان الإصدارات المختلطة ══
  /// كان أي نوع غير معروف يسقط على `tx` فيُدرج صف القسم/الكيان الجديد في
  /// جدول transactions (بيانات تالفة). صار يعود `unknown`، والتطبيق
  /// يتجاهله صراحةً (apply_remote) فلا يُكتب شيء في جدول خاطئ.
  static EntityKind from(String s) => EntityKind.values.firstWhere(
        (e) => e.name == s,
        orElse: () => EntityKind.unknown,
      );
}

/// حالات المزامنة لصف في sync_queue.
enum SyncStatus { pending, syncing, synced, failed }

extension SyncStatusName on SyncStatus {
  String get s => name;
  static SyncStatus from(String s) => SyncStatus.values.firstWhere(
        (e) => e.name == s,
        orElse: () => SyncStatus.pending,
      );
}

/// اتجاه/هدف المزامنة (سحابة أو جهاز محدد).
class SyncTarget {
  static const cloud = 'cloud';
  static String device(String deviceId) => 'device:$deviceId';
  static bool isDevice(String t) => t.startsWith('device:');
  static String deviceIdOf(String t) => t.replaceFirst('device:', '');
}

/// عملية مزامنة واحدة (سجل غير قابل للتعديل بعد الإنشاء).
class SyncOperation {
  /// UUID عالمي فريد. أساس Idempotency: نفس الـ id لا يُطبّق مرتين.
  final String id;
  final String deviceId;
  final String workspaceId;
  final int? userId; // users.id المحلي (اختياري في وضع non-login).
  final EntityKind entityType;
  final String entityId; // المعرّف المحلي للكيان (int أو نص).
  final OpKind opType;
  final int version; // نسخة الكيان بعد تطبيق هذه العملية.
  final String parentOpId; // لعملية restore: عملية delete الأصلية.
  final Map<String, Object?> payload; // Snapshot كامل للكيان بعد العملية.
  final String deviceTime; // ISO 8601 وقت الجهاز.
  final String? serverTime; // وقت السيرفر عند الـ sync (يملأه الـ transport).
  final String timestamp; // وقت إنشاء السجل محليًا.

  const SyncOperation({
    required this.id,
    required this.deviceId,
    required this.workspaceId,
    required this.userId,
    required this.entityType,
    required this.entityId,
    required this.opType,
    required this.version,
    required this.parentOpId,
    required this.payload,
    required this.deviceTime,
    required this.timestamp,
    this.serverTime,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'device_id': deviceId,
        'workspace_id': workspaceId,
        'user_id': userId,
        'entity_type': entityType.name,
        'entity_id': entityId,
        'op_type': opType.name,
        'version': version,
        'parent_op_id': parentOpId,
        'payload': jsonEncode(payload),
        'device_time': deviceTime,
        'server_time': serverTime,
        'timestamp': timestamp,
        'synced': 0,
      };

  static SyncOperation fromMap(Map<String, Object?> m) => SyncOperation(
        id: m['id'] as String,
        deviceId: (m['device_id'] as String?) ?? '',
        workspaceId: (m['workspace_id'] as String?) ?? 'default',
        userId: m['user_id'] as int?,
        entityType: EntityKind.from((m['entity_type'] as String?) ?? 'tx'),
        entityId: (m['entity_id'] as String?) ?? '',
        opType: _opFrom((m['op_type'] as String?) ?? 'create'),
        version: (m['version'] as int?) ?? 1,
        parentOpId: (m['parent_op_id'] as String?) ?? '',
        payload: _decodeJson(m['payload']),
        deviceTime: (m['device_time'] as String?) ?? '',
        serverTime: m['server_time'] as String?,
        timestamp: (m['timestamp'] as String?) ?? '',
      );

  String toJson() => jsonEncode(toMap());
  static SyncOperation fromJson(String s) =>
      fromMap(jsonDecode(s) as Map<String, Object?>);

  @override
  bool operator ==(Object other) => other is SyncOperation && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

OpKind _opFrom(String s) {
  switch (s) {
    case 'create':
      return OpKind.create;
    case 'update':
      return OpKind.update;
    case 'delete_':
    case 'delete':
      return OpKind.delete_;
    case 'restore':
      return OpKind.restore;
    case 'settings':
      return OpKind.settings;
  }
  return OpKind.create;
}

Map<String, Object?> _decodeJson(Object? v) {
  if (v == null) return {};
  if (v is String) {
    try {
      final d = jsonDecode(v);
      return d is Map<String, Object?> ? d : {'_raw': d};
    } catch (_) {
      return {};
    }
  }
  if (v is Map) return Map<String, Object?>.from(v);
  return {};
}
