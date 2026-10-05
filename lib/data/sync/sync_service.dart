// خدمة الاستعلام عن حالة المزامنة (تُستخدم في UI لعرض المؤشر).
import '../repository.dart';
import 'operation.dart';
import 'sync_engine.dart';
import 'sync_queue.dart';
import '../../core/cloud_config.dart';

enum SyncState {
  synced, // 🟢 لا توجد عمليات معلقة
  syncing, // 🟡 توجد عملية في حالة syncing
  pending, // 🟠 توجد عمليات في الانتظار
  failed, // 🔴 توجد عمليات فشلت بعد عدة محاولات
  offline, // ⚪ غير مُهيّأ للعمل
}

class SyncStatusInfo {
  final SyncState state;
  final int pending;
  final int failed;
  final String? lastSyncAt;
  final String? cloudUrl;
  final bool cloudConfigured;
  final String? error;

  const SyncStatusInfo({
    required this.state,
    required this.pending,
    required this.failed,
    this.lastSyncAt,
    this.cloudUrl,
    required this.cloudConfigured,
    this.error,
  });
}

class SyncService {
  final Repo repo;
  final SyncEngine engine;
  SyncService({required this.repo, required this.engine});

  Future<SyncStatusInfo> status() async {
    final db = await repo.database;
    final q = SyncQueueOps(db);
    final pending = await q.countPending();
    final failed = await q.countFailed();
    final s = await db.rawQuery(
      "SELECT COUNT(*) c FROM sync_queue WHERE status = ?",
      [SyncStatus.syncing.name],
    );
    final syncing = (s.first['c'] as int?) ?? 0;
    final st = await repo.settings();
    // (دفعة 58) القناة الوحيدة سحابية — لا lastLanSync/lanSyncEnabled.
    final lastSync = st['lastCloudSync'];
    final cloudUrl = effectiveBackendUrl(st['cloudBackendUrl']);
    final cloudConfigured =
        cloudUrl.isNotEmpty && kCloudAutoSyncAlways;
    final mode = await repo.workspaceMode();
    final anyChannel = cloudConfigured;

    SyncState state;
    if (mode == 'standalone') {
      // في الوضع المستقل لا مزامنة — نعرض كل شيء كأنه متزامن حتى لو بقيت
      // سجلات قديمة في sync_queue من جلسة سابقة.
      state = SyncState.synced;
    } else if (failed > 0 && anyChannel) {
      state = SyncState.failed;
    } else if (syncing > 0 && anyChannel) {
      state = SyncState.syncing;
    } else if (pending > 0 && anyChannel) {
      state = SyncState.pending;
    } else if (!anyChannel) {
      // المجموعة موجودة لكن لا توجد قناة مزامنة فعّالة.
      state = SyncState.offline;
    } else {
      state = SyncState.synced;
    }

    return SyncStatusInfo(
      state: state,
      pending: state == SyncState.pending || state == SyncState.syncing
          ? pending
          : 0,
      failed: state == SyncState.failed ? failed : 0,
      lastSyncAt: (lastSync?.isNotEmpty == true) ? lastSync : null,
      cloudUrl: cloudConfigured ? cloudUrl : null,
      cloudConfigured: cloudConfigured,
    );
  }
}
