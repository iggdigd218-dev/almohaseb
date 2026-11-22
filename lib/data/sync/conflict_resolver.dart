// كاشف/حلّال التعارضات الذكي — مبدأ Last-Write-Wins (اعتماد الأحدث وحذف القديم).
// يضمن استمرار المزامنة بدون توقف وحسم أي تفاوت بين الأجهزة تلقائياً وحتمياً.
import 'operation.dart';

class ConflictInfo {
  final String entityType;
  final String entityId;
  final SyncOperation localOp;
  final SyncOperation remoteOp;
  const ConflictInfo({
    required this.entityType,
    required this.entityId,
    required this.localOp,
    required this.remoteOp,
  });
}

class ConflictResolver {
  /// يقرر هل تُطبَّق العملية الواردة على الكيان المحلي.
  /// يُعيد قرارًا: تطبيق / تجاهل — وفق مبدأ الحسم الذكي Last-Write-Wins (اعتماد الأحدث وحذف القديم).
  ConflictDecision decide({
    required SyncOperation incoming,
    required bool exists,
    required int localVersion,
    required SyncOperation? localLatest,
  }) {
    // 1. Idempotency: نفس العملية برقمها مسجلة محلياً -> تجاهل مكرر
    if (localLatest != null && localLatest.id == incoming.id) {
      return ConflictDecision.ignore(reason: 'duplicate-id');
    }

    // 2. الكيان غير موجود محلياً
    if (!exists) {
      if (incoming.opType == OpKind.create) {
        return ConflictDecision.apply();
      }
      if (incoming.opType == OpKind.delete_) {
        // حذف لكيان غير موجود أصلاً -> تجاهل آمن دون توقف
        return ConflictDecision.ignore(reason: 'already-nonexistent');
      }
      // عملية تعديل لكيان غير موجود: إن توفرت بيانات كافية ننشئه محلياً (اعتماد الأحدث)
      if (incoming.payload.isNotEmpty) {
        return ConflictDecision.apply();
      }
      return ConflictDecision.ignore(reason: 'empty-payload-missing');
    }

    // 3. الكيان موجود محلياً: الحسم الذكي وفق أحدث ختم زمني (Last-Write-Wins) ورقم الإصدار
    // إذا كان رقم الإصدار الوارد أكبر: تطبيق فوراً
    if (incoming.version > localVersion) {
      return ConflictDecision.apply();
    }

    final tIn =
        DateTime.tryParse(incoming.timestamp)?.millisecondsSinceEpoch ??
        (DateTime.tryParse(incoming.deviceTime)?.millisecondsSinceEpoch ?? 0);
    final tLocal =
        DateTime.tryParse(localLatest?.timestamp ?? '')?.millisecondsSinceEpoch ??
        (DateTime.tryParse(localLatest?.deviceTime ?? '')?.millisecondsSinceEpoch ?? 0);

    // إذا كانت العملية الواردة أحدث زمنياً (Last-Write-Wins): تطبيق واعتماد الأحدث
    if (tIn > tLocal) {
      return ConflictDecision.apply();
    }

    if (incoming.version == localVersion) {
      if (localLatest != null && localLatest.deviceId == incoming.deviceId) {
        return ConflictDecision.apply();
      }
      if (incoming.deviceId.compareTo(localLatest?.deviceId ?? '') <= 0) {
        return ConflictDecision.apply();
      }
      return ConflictDecision.ignore(reason: 'tiebreak-deterministic');
    }

    return ConflictDecision.ignore(reason: 'older-version-ignored');
  }
}

class ConflictDecision {
  final bool apply;
  final bool conflict;
  final String? reason;
  const ConflictDecision._(this.apply, this.conflict, this.reason);
  factory ConflictDecision.apply() =>
      const ConflictDecision._(true, false, null);
  factory ConflictDecision.ignore({required String reason}) =>
      ConflictDecision._(false, false, reason);
  factory ConflictDecision.conflict({required String reason}) =>
      ConflictDecision._(false, true, reason);
}
