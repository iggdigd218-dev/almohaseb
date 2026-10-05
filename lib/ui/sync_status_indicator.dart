// ويدجت مؤشر حالة المزامنة في شريط الحالة.
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../data/sync/sync_service.dart';

class SyncStatusBadge extends StatelessWidget {
  final SyncStatusInfo info;
  final VoidCallback? onTap;
  const SyncStatusBadge({super.key, required this.info, this.onTap});

  @override
  Widget build(BuildContext context) {
    // لا عدادات عمليات خام في الواجهة — المزامنة صامتة وتُعاد تلقائياً؛
    // نعرض حالة عالية المستوى فقط (متزامن / تجري المزامنة / غير فعّال).
    final (icon, color, label) = switch (info.state) {
      SyncState.synced => (Icons.cloud_done, Colors.green, 'متزامن'),
      SyncState.syncing ||
      SyncState.pending ||
      SyncState.failed =>
        (Icons.sync, Colors.amber, 'تجري المزامنة في الخلفية'),
      SyncState.offline => (Icons.cloud_off, Colors.grey, 'غير فعّال'),
    };
    // (دفعة 58 — متطلب 9) وقت آخر مزامنة سحابية ناجحة يظهر في التلميح
    // بجانب حالة الاتصال — يراه العضو حياً على جهازه.
    final lastDt =
        info.lastSyncAt == null ? null : DateTime.tryParse(info.lastSyncAt!);
    final tooltip = lastDt == null
        ? label
        : '$label · آخر مزامنة: ${Fmt.relative(lastDt)}';
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }
}
