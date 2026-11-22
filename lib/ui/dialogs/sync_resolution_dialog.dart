import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/sfx.dart';
import '../../data/providers.dart';
import '../../data/sync/error_localization_mapper.dart';
import '../../data/sync/sync_diagnostics.dart';
import '../widgets.dart' show confirmDialog, showSnack;

/// نافذة معالجة تنبيهات وعمليات المزامنة بالتفصيل (Sync Resolution Dialog / Sheet).
///
/// تتيح للمستخدم:
///  1) رؤية العمليات أو العملية التي لم تتزامن بالتفصيل مع سبب التعثر المترجم للعربية.
///  2) خيار حذف العمليات المتعارضة لفك التعليق فوراً.
///  3) خيار مسح البيانات المحلية واستيراد نسخة السحابة كما هي.
///  4) زر إعادة المحاولة والمزامنة فوراً.
class SyncResolutionDialog extends ConsumerStatefulWidget {
  const SyncResolutionDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const SyncResolutionDialog(),
    );
  }

  @override
  ConsumerState<SyncResolutionDialog> createState() =>
      _SyncResolutionDialogState();
}

class _SyncResolutionDialogState extends ConsumerState<SyncResolutionDialog> {
  bool _loading = true;
  bool _actionInProgress = false;
  List<Map<String, Object?>> _unsyncedOps = [];

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    setState(() => _loading = true);
    try {
      final repo = ref.read(repoProvider);
      final ops = await repo.getUnsyncedOperationsWithDetails();
      if (mounted) {
        setState(() {
          _unsyncedOps = ops;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _entityLabel(String? kind) {
    switch (kind) {
      case 'account':
        return 'حساب';
      case 'tx':
      case 'transaction':
        return 'حركة مالية / فاتورة';
      case 'item':
        return 'صنف مخزني';
      case 'section':
        return 'قسم';
      case 'category':
      case 'item_category':
        return 'فئة أصناف';
      case 'voucher':
        return 'سند مالي';
      case 'currency':
        return 'عملة';
      case 'user':
        return 'مستخدم / صلاحية';
      default:
        return kind?.isNotEmpty == true ? kind! : 'عملية مالية';
    }
  }

  String _opLabel(String? op) {
    switch (op) {
      case 'create':
        return 'إضافة (+)';
      case 'update':
        return 'تعديل (✎)';
      case 'delete_':
        return 'حذف (×)';
      default:
        return 'تحديث';
    }
  }

  Color _opColor(String? op) {
    switch (op) {
      case 'create':
        return Colors.green.shade700;
      case 'update':
        return Colors.blue.shade700;
      case 'delete_':
        return Colors.red.shade700;
      default:
        return Colors.blueGrey;
    }
  }

  /// حذف العمليات المتعارضة
  Future<void> _handleDeleteConflicting() async {
    final ok = await confirmDialog(
      context,
      title: 'حذف العمليات المتعارضة',
      message:
          'سيتم إلغاء العمليات العالقة في طابور المزامنة المحلي لفك التعارض، '
          'والسماح باستئناف المزامنة بشكل طبيعي.\n\nهل تريد المتابعة؟',
      confirmText: 'حذف وفك التعارض',
      danger: true,
    );
    if (ok != true || !mounted) return;

    setState(() => _actionInProgress = true);
    Sfx.click();
    try {
      final repo = ref.read(repoProvider);
      final engine = ref.read(syncEngineProvider);
      final count = await repo.cancelConflictingOperations();
      await engine.reconcileAndSyncNow();
      if (mounted) {
        showSnack(
          context,
          '✅ تم فك التعارض وإلغاء $count عملية عالقة بنجاح واستئناف المزامنة.',
        );
        bump(ref);
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, 'تعذّر فك التعارض: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  /// حذف البيانات المحلية واستيراد نسخة السحابة كما هي
  Future<void> _handleWipeAndImportCloud() async {
    final ok = await confirmDialog(
      context,
      title: 'استيراد نسخة السحابة كلياً',
      message:
          '⚠️ تحذير مهم:\n'
          'سيتم مسح البيانات المحلية غير المتزامنة وتنزيل أحدث نسخة مطابقة تماماً '
          'للسحابة لتوحيد كافة السجلات مع بقية الأجهزة.\n\n'
          'هل تريد بالتأكيد استبدال البيانات بنسخة السحابة؟',
      confirmText: 'استبدال بنسخة السحابة',
      danger: true,
    );
    if (ok != true || !mounted) return;

    setState(() => _actionInProgress = true);
    Sfx.click();
    try {
      final repo = ref.read(repoProvider);
      final engine = ref.read(syncEngineProvider);
      await repo.wipeLocalAndImportCloudSnapshot(engine: engine);
      if (mounted) {
        showSnack(context, '☁️ تم استيراد نسخة السحابة وتوحيد البيانات بنجاح.');
        bump(ref);
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, 'تعذّر استيراد نسخة السحابة: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  /// إعادة المحاولة والمزامنة فوراً
  Future<void> _handleRetryNow() async {
    setState(() => _actionInProgress = true);
    Sfx.click();
    try {
      final engine = ref.read(syncEngineProvider);
      await engine.reconcileAndSyncNow();
      await _loadDetails();
      if (mounted) {
        showSnack(context, '🔄 جرت محاولة المزامنة والتوفيق مع السحابة.');
        bump(ref);
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, 'تعذّرت المزامنة: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _actionInProgress = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final diag = SyncDiagnostics.instance.snapshot;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // مقبض السحب العلوي
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 44,
                height: 4.5,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),

            // شريط العنوان
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.amber,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'معالجة تنبيهات وعمليات المزامنة',
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'عرض تفاصيل العمليات غير المتزامنة والخيارات المتاحة للحل',
                          style: TextStyle(fontSize: 11.5, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // محتوى العمليات والأسباب
            Flexible(
              child: _loading
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(40),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // تفاصيل العمليات العالقة
                        if (_unsyncedOps.isNotEmpty) ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'العمليات غير المتزامنة (${_unsyncedOps.length})',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                'مرتبة حسب الأولوية',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          for (final op in _unsyncedOps) ...[
                            _OperationCard(
                              op: op,
                              entityLabel:
                                  _entityLabel(op['entity_type'] as String?),
                              opLabel: _opLabel(op['op_type'] as String?),
                              opColor: _opColor(op['op_type'] as String?),
                            ),
                            const SizedBox(height: 10),
                          ],
                        ] else ...[
                          // لا توجد عمليات عالقة
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.green.withValues(alpha: 0.25),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.check_circle_outline,
                                  color: Colors.green,
                                  size: 26,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'طابور المزامنة نظيف',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                          color: Colors.green,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        diag.catalogMismatch
                                            ? 'توجد فروق بين الأجهزة — يمكنك استيراد نسخة السحابة كلياً لتوحيد البيانات.'
                                            : 'جميع العمليات المحلية مسلّمة ومحدثة.',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        // خطأ الاتصال العام إن وُجد
                        if (diag.lastLocalizedError != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF2D1818)
                                  : const Color(0xFFFEF2F2),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF7F1D1D)
                                    : const Color(0xFFFECACA),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.info_outline,
                                  color: Color(0xFFEF4444),
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    diag.lastLocalizedError!.arabicExplanation,
                                    style: TextStyle(
                                      color: isDark
                                          ? const Color(0xFFFCA5A5)
                                          : const Color(0xFF991B1B),
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
            ),

            // شريط الإجراءات والحلول (حذف العمليات المتعارضة / استيراد نسخة السحابة)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).dividerColor.withValues(alpha: 0.15),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_actionInProgress)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 10),
                            Text('جارٍ المعالجة وتطبيق الحل...',
                                style: TextStyle(fontSize: 12.5)),
                          ],
                        ),
                      ),
                    )
                  else ...[
                    // زر حذف العمليات المتعارضة
                    FilledButton.tonalIcon(
                      onPressed: _handleDeleteConflicting,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: const Text('حذف العمليات المتعارضة وفك التعليق'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: Colors.amber.withValues(alpha: 0.18),
                        foregroundColor: Colors.amber.shade900,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // زر استيراد نسخة السحابة كما هي ومسح البيانات المحلية
                    OutlinedButton.icon(
                      onPressed: _handleWipeAndImportCloud,
                      icon: const Icon(Icons.cloud_download_outlined, size: 18),
                      label: const Text(
                          'مسح البيانات المحلية واستيراد نسخة السحابة كلياً'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        foregroundColor: Colors.blue.shade700,
                        side: BorderSide(color: Colors.blue.shade300),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // زر إعادة المحاولة والمزامنة فوراً
                    FilledButton.icon(
                      onPressed: _handleRetryNow,
                      icon: const Icon(Icons.sync, size: 18),
                      label: const Text('إعادة المحاولة والمزامنة فوراً'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OperationCard extends StatelessWidget {
  final Map<String, Object?> op;
  final String entityLabel;
  final String opLabel;
  final Color opColor;

  const _OperationCard({
    required this.op,
    required this.entityLabel,
    required this.opLabel,
    required this.opColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final lastError = (op['last_error'] as String?)?.trim() ?? '';
    final attempts = (op['attempts'] as int?) ?? 0;
    final status = (op['status'] as String?) ?? 'pending';
    final dateIso = (op['op_created_at'] ?? op['queued_at']) as String?;
    final date = dateIso != null ? DateTime.tryParse(dateIso) : null;

    final String reasonText;
    if (lastError.isNotEmpty) {
      reasonText = ErrorLocalizationMapper.map(lastError).arabicExplanation;
    } else if (attempts > 0) {
      reasonText =
          'تعذّر الإرسال بعد $attempts محاولات بسبب ضعف الاتصال بالسحابة أو انقطاع الشبكة.';
    } else {
      reasonText =
          'العملية في قائمة الانتظار للمزامنة اللحظية مع السحابة.';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: status == 'failed'
              ? Colors.red.withValues(alpha: 0.3)
              : Colors.amber.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: opColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  opLabel,
                  style: TextStyle(
                    color: opColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entityLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              if (date != null)
                Text(
                  Fmt.dateTime(date),
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                status == 'failed'
                    ? Icons.error_outline
                    : Icons.hourglass_top_outlined,
                size: 16,
                color: status == 'failed' ? Colors.red : Colors.amber.shade800,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  reasonText,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white70 : Colors.black87,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          if (attempts > 0) ...[
            const SizedBox(height: 6),
            Text(
              'عدد محاولات الإرسال: $attempts',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ],
        ],
      ),
    );
  }
}
