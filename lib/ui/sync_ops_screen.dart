// شاشة حالة المزامنة والأجهزة — عرض عالي المستوى فقط (Roster-Only):
// «الأجهزة المتزامنة» مع وقت آخر مزامنة، و«أجهزة قيد الانتظار / غير متصلة».
// لا تعرض أي عمليات خام من طابور المزامنة ولا أزرار حذف/إلغاء — الحذف اليدوي
// من الطابور كان يسبب تبايناً حرجاً في السجلات بين الأجهزة، والمزامنة تعمل
// بصمت في الخلفية بإعادة محاولة لانهائية حتى يستلم كل جهاز كل العمليات.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../data/providers.dart';
import '../data/sync/sync_activity.dart';
import 'widgets.dart';

class SyncOpsScreen extends ConsumerStatefulWidget {
  const SyncOpsScreen({super.key});

  @override
  ConsumerState<SyncOpsScreen> createState() => _SyncOpsScreenState();
}

class _SyncOpsScreenState extends ConsumerState<SyncOpsScreen> {
  Timer? _ticker;
  StreamSubscription<int>? _bus;
  bool _syncing = false;

  /// (دفعة 58 — متطلب 9) وقت آخر مزامنة سحابية ناجحة لهذا الجهاز.
  String _lastCloudSync = '';

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
    _bus = SyncActivityBus.instance.stream.listen((_) => _refresh());
    _loadLastSync();
  }

  Future<void> _loadLastSync() async {
    final st = await ref.read(repoProvider).settings();
    if (mounted) {
      setState(() => _lastCloudSync = st['lastCloudSync'] ?? '');
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _bus?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    ref.invalidate(deviceSyncStatusProvider);
    _loadLastSync();
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    try {
      await ref.read(syncEngineProvider).forceSyncNow();
      await Future.delayed(const Duration(milliseconds: 600));
      _refresh();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String _lastSyncLabel(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    final diff = DateTime.now().difference(d);
    if (diff < const Duration(minutes: 1)) return 'قبل لحظات';
    if (diff < const Duration(hours: 1)) return 'قبل ${diff.inMinutes} دقيقة';
    if (diff < const Duration(hours: 24)) return 'قبل ${diff.inHours} ساعة';
    return Fmt.dateTime(d);
  }

  @override
  Widget build(BuildContext context) {
    final devsAsync = ref.watch(deviceSyncStatusProvider);
    final devs = devsAsync.valueOrNull ?? const <DeviceSyncStatus>[];
    final synced = devs.where((d) => d.fullySynced).toList();
    final waiting = devs.where((d) => !d.fullySynced).toList();
    final allSynced = devs.isNotEmpty && waiting.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('حالة المزامنة والأجهزة'),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _syncNow,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            // بطاقة الحالة العامة — بلا أي عدادات عمليات خام.
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: (allSynced ? Colors.green : Colors.blue)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        allSynced
                            ? Icons.cloud_done
                            : (_syncing ? Icons.sync : Icons.cloud_sync),
                        color: allSynced ? Colors.green : Colors.blue,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            allSynced
                                ? 'كل الأجهزة متزامنة ✅'
                                : 'المزامنة تعمل في الخلفية',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 15),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            allSynced
                                ? 'وصلت كل العمليات إلى جميع أجهزة المجموعة.'
                                : 'تُعاد المحاولة تلقائياً حتى يستلم كل '
                                    'جهاز كل العمليات — لا تدخّل يدوي مطلوب.',
                            style: TextStyle(
                                fontSize: 12.5, color: Colors.grey[700]),
                          ),
                          // (دفعة 58 — متطلب 9) وقت آخر مزامنة سحابية
                          // ناجحة لهذا الجهاز — يظهر حياً ويتحدّث تلقائياً.
                          if (_lastCloudSync.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              '☁️ آخر مزامنة ناجحة: '
                              '${_lastSyncLabel(_lastCloudSync)}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.teal,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _syncing ? null : _syncNow,
                      icon: _syncing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.sync, size: 18),
                      label: const Text('مزامنة الآن'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            if (devs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: EmptyState(
                  icon: Icons.devices_other,
                  title: 'لا توجد أجهزة مرتبطة',
                  message:
                      'اربط أجهزة المجموعة من شاشة إدارة المجموعة لتبدأ '
                      'المزامنة التلقائية الصامتة.',
                ),
              )
            else ...[
              // ---------- الأجهزة المتزامنة ----------
              _SectionHeader(
                icon: Icons.check_circle_outline,
                color: Colors.green,
                title: 'الأجهزة المتزامنة (${synced.length})',
              ),
              const SizedBox(height: 6),
              if (synced.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 10),
                  child: Text(
                    'لا توجد أجهزة مكتملة المزامنة بعد.',
                    style:
                        TextStyle(fontSize: 12.5, color: Colors.grey[600]),
                  ),
                )
              else
                for (final d in synced)
                  _PeerTile(
                    d: d,
                    subtitle: d.lastSyncAt.isEmpty
                        ? 'متزامن بالكامل'
                        : 'آخر مزامنة: ${_lastSyncLabel(d.lastSyncAt)}',
                    trailingIcon: Icons.check_circle,
                    trailingColor: Colors.green,
                    trailingLabel: 'متزامن',
                  ),
              const SizedBox(height: 14),

              // ---------- أجهزة قيد الانتظار / غير متصلة ----------
              _SectionHeader(
                icon: Icons.hourglass_bottom,
                color: Colors.orange,
                title: 'أجهزة قيد الانتظار / غير متصلة (${waiting.length})',
              ),
              const SizedBox(height: 6),
              if (waiting.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 10),
                  child: Text(
                    'لا توجد أجهزة بانتظار المزامنة — كل شيء واصل ✅',
                    style:
                        TextStyle(fontSize: 12.5, color: Colors.grey[600]),
                  ),
                )
              else
                for (final d in waiting)
                  _PeerTile(
                    d: d,
                    subtitle: d.online
                        ? 'متصل — تجري المزامنة الآن'
                        : 'غير متصل — سيستلم تلقائياً فور عودته',
                    trailingIcon:
                        d.online ? Icons.sync : Icons.wifi_off_outlined,
                    trailingColor: d.online ? Colors.blue : Colors.grey,
                    trailingLabel: d.online ? 'يزامن' : 'بالانتظار',
                  ),
              const SizedBox(height: 14),

              // طمأنة: لا فقدان لأي عملية.
              Card(
                color: Colors.teal.withValues(alpha: 0.08),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.shield_outlined,
                          color: Colors.teal, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'المزامنة صامتة وتلقائية بالكامل: كل عملية تبقى '
                          'محفوظة وتُعاد محاولتها بلا توقف عبر الشبكة '
                          'المحلية والسحابة حتى تصل إلى كل الأجهزة — '
                          'لا مجال لفقدان أي عملية.',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  const _SectionHeader({
    required this.icon,
    required this.color,
    required this.title,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Text(title, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
      );
}

/// صف جهاز واحد في قائمة الأقران: لقب الدور (اسم الجهاز) + الحالة.
class _PeerTile extends StatelessWidget {
  final DeviceSyncStatus d;
  final String subtitle;
  final IconData trailingIcon;
  final Color trailingColor;
  final String trailingLabel;
  const _PeerTile({
    required this.d,
    required this.subtitle,
    required this.trailingIcon,
    required this.trailingColor,
    required this.trailingLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: trailingColor.withValues(alpha: 0.12),
                  child: Icon(
                    d.isOwner ? Icons.security : Icons.devices_other,
                    size: 20,
                    color: trailingColor,
                  ),
                ),
                PositionedDirectional(
                  bottom: 0,
                  start: 0,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: d.online ? Colors.green : Colors.grey,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.surface,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.displayName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style:
                        TextStyle(fontSize: 11.5, color: Colors.grey[600]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(trailingIcon, size: 15, color: trailingColor),
                const SizedBox(width: 4),
                Text(
                  trailingLabel,
                  style: TextStyle(
                    fontSize: 11,
                    color: trailingColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
