import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/sync/cloud_control_service.dart';
import 'app_notice.dart';
import 'widgets.dart';
import 'widgets/golden_bell_icon.dart';

/// معالج فتح السجل المرتبط بإشعار: (نوع الكيان، معرّفه) → هل فُتحت وجهة؟
typedef NotificationEntityOpener = Future<bool> Function(
    String entityType, String entityId);

/// يفتح مركز الإشعارات الداخلية كصحيفة سفلية.
/// [onOpenEntity] يستدعى عند الضغط على إشعار مرتبط بسجل — يتكفل بالانتقال
/// إلى الشاشة المناسبة (تُغلق الصحيفة قبل الاستدعاء).
Future<void> openNotifications(
  BuildContext context,
  WidgetRef ref, {
  NotificationEntityOpener? onOpenEntity,
}) async {
  final repo = ref.read(repoProvider);
  await repo.markAllNotificationsSeen();
  try {
    final settings = await repo.settings();
    final backendUrl = (settings['backend_url'] ?? '').toString();
    final wsId = repo.requireWorkspaceId;
    await CloudControlService.instance.markAllAlertsRead(backendUrl, wsId);
  } catch (_) {
    await CloudControlService.instance.markAllAlertsRead();
  }
  bump(ref);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // (2026-09-22) الصحيفة لا تغطي شريط التنقل السفلي: تُحجز مسافة
    // بارتفاع الشريط فيبقى الظاهر والأسفل ظاهرين معاً أثناء العرض.
    useRootNavigator: true,
    barrierColor: Colors.black26,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final reserve = MediaQuery.paddingOf(ctx).bottom + 66;
      return Padding(
        padding: EdgeInsets.only(bottom: reserve),
        child: _NotificationsSheet(onOpenEntity: onOpenEntity),
      );
    },
  ).whenComplete(() {
    // ══ (2026-09-22) استعادة التفاعل فور الإغلاق ══
    // بلا هذا التسلسل تبقى حلقة التركيز/الإيماءات محجوزة لصالح الصحيفة
    // فتتجمد أيقونات الشريط السفلي حتى أول لمسة تالية. نُلغي التركيز،
    // ونُزيل أي تراكب متبقٍ، ثم نُعيد بناء الواجهة في إطار تالٍ.
    try {
      FocusManager.instance.primaryFocus?.unfocus();
    } catch (_) {}
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          FocusManager.instance.primaryFocus?.unfocus();
        } catch (_) {}
      });
    } catch (_) {}
  });
  // تحديث العدّاد والحالة بعد الإغلاق (الشريط السفلي يبقى قابلاً للنقر).
  try {
    bump(ref);
  } catch (_) {}
}

class _NotificationsSheet extends ConsumerWidget {
  final NotificationEntityOpener? onOpenEntity;
  const _NotificationsSheet({this.onOpenEntity});

  /// نقرة على إشعار: إن كان مرتبطاً بسجل نغلق الصحيفة وننتقل إليه،
  /// وإلا نعرض نافذة توضيحية بمحتوى الإشعار كاملاً.
  Future<void> _onTap(
    BuildContext context,
    Map<String, Object?> n,
    String kind,
  ) async {
    final entityType = (n['entity_type'] ?? '') as String;
    final entityId = (n['entity_id'] ?? '') as String;
    if (entityType.isNotEmpty && onOpenEntity != null) {
      Navigator.pop(context); // أغلق الصحيفة أولاً ثم انتقل.
      final opened = await onOpenEntity!(entityType, entityId);
      if (opened) return;
      // نوع بلا وجهة معروفة: لا شيء آخر يمكن فعله هنا (الصحيفة أُغلقت).
      return;
    }
    // إشعار عام بلا سجل محدد: نافذة توضيحية بالتفاصيل.
    final noticeKind = switch (kind) {
      'error' => AppNoticeKind.error,
      'warning' => AppNoticeKind.warning,
      'success' => AppNoticeKind.success,
      _ => AppNoticeKind.info,
    };
    final created = DateTime.tryParse((n['created_at'] ?? '') as String);
    final body = (n['body'] ?? '') as String;
    final when = created == null ? '' : '\n\n🕓 ${Fmt.dateTime(created)}';
    await showAppNotice(
      context,
      title: (n['title'] ?? '') as String,
      message: '$body$when'.trim().isEmpty
          ? 'إشعار عام — لا يوجد سجل مرتبط به.'
          : '$body$when',
      kind: noticeKind,
      playSound: false,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(notificationsProvider);
    return PopScope<Object?>(
      // ══ (2026-09-22) زر الرجوع للنظام وإيماءة الرجوع ══
      // canPop=true يضمن أن مسار الصحيفة هو من يستلم الرجوع فوراً بدل
      // أن يبتلعه PopScope(canPop:false) الخاص بالشل (والذي يحمي
      // الشاشة الرئيسية من الخروج العشوائي) فيبدو الزر متجمّداً.
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // مسار استثنائي: أغلق الصحيفة صراحةً وأعد التركيز للواجهة.
        try {
          Navigator.of(context).maybePop();
        } catch (_) {}
        try {
          FocusManager.instance.primaryFocus?.unfocus();
        } catch (_) {}
      },
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceOf(context),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.borderOf(context),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 14, 18, 8),
                  child: Row(
                    children: [
                      GoldenBellIcon(size: 24),
                      SizedBox(width: 8),
                      Text(
                        'الإشعارات',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: async.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => EmptyState(
                      icon: Icons.error_outline,
                      title: 'تعذّر تحميل الإشعارات',
                      message: '$e',
                    ),
                    data: (list) {
                      final cloudAlerts = CloudControlService
                          .instance.cloudAlertsNotifier.value;
                      if (list.isEmpty && cloudAlerts.isEmpty) {
                        return ListView(
                          controller: scrollController,
                          children: const [
                            SizedBox(height: 60),
                            EmptyState(
                              icon: Icons.notifications_off_outlined,
                              title: 'لا توجد إشعارات',
                              message:
                                  'ستظهر هنا تنبيهات المخزون والنسخ والمزامنة وإشعارات الإدارة',
                            ),
                          ],
                        );
                      }
                      final totalCount = cloudAlerts.length + list.length;
                      return ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 12),
                        itemCount: totalCount,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          if (i < cloudAlerts.length) {
                            final ca = cloudAlerts[i];
                            return ListTile(
                              leading: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF7C3AED)
                                      .withValues(alpha: .14),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.cloud_outlined,
                                    color: Color(0xFF7C3AED)),
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      ca.title,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 14.5),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF7C3AED),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      'إشعار إداري',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(ca.body,
                                    style: const TextStyle(fontSize: 13)),
                              ),
                              onTap: () {
                                showAppNotice(
                                  context,
                                  title: ca.title,
                                  message: ca.body,
                                  kind: AppNoticeKind.info,
                                  playSound: false,
                                );
                              },
                            );
                          }
                          final n = list[i - cloudAlerts.length];
                          final kind = (n['kind'] ?? 'info') as String;
                          final (icon, color) = switch (kind) {
                            'error' => (Icons.error_outline, AppColors.danger),
                            'warning' => (
                                Icons.warning_amber_rounded,
                                AppColors.amber
                              ),
                            'success' => (
                                Icons.check_circle_outline,
                                AppColors.green
                              ),
                            _ => (Icons.info_outline, AppColors.info),
                          };
                          final body = (n['body'] ?? '') as String;
                          final linked =
                              ((n['entity_type'] ?? '') as String).isNotEmpty;
                          return ListTile(
                            onTap: () => _onTap(context, n, kind),
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(icon, color: color),
                            ),
                            title: Text(
                              (n['title'] ?? '') as String,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 14.5),
                            ),
                            subtitle: body.isEmpty
                                ? null
                                : Text(body,
                                    style: const TextStyle(fontSize: 13)),
                            // سهم يدل على أن الإشعار يقود لسجل محدد.
                            trailing: linked
                                ? Icon(Icons.chevron_left,
                                    size: 20, color: AppColors.text3Of(context))
                                : null,
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
