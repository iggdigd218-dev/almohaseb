import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/sync/error_localization_mapper.dart';
import '../widgets.dart' show showSnack;

/// نافذة تشخيص أخطاء المزامنة وقاعدة البيانات باللغة العربية (Diagnostic Error Dialog).
class SyncDiagnosticErrorDialog extends StatelessWidget {
  final LocalizedSyncError error;

  const SyncDiagnosticErrorDialog({super.key, required this.error});

  /// عرض النافذة المنبثقة
  static Future<void> show(BuildContext context, LocalizedSyncError error) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => SyncDiagnosticErrorDialog(error: error),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                color: Colors.amber,
                size: 28,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                error.arabicTitle,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 17,
                ),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 520,
            maxHeight: 460,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── الجزء الأساسي (للمستخدم العادي) ──
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF2D1818)
                        : const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(14),
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
                        Icons.info_outline_rounded,
                        color: Color(0xFFEF4444),
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          error.arabicExplanation,
                          style: TextStyle(
                            color: isDark
                                ? const Color(0xFFFCA5A5)
                                : const Color(0xFF991B1B),
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                            height: 1.55,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // ── الجزء التقني المتقدم (للمطور والدعم الفني) ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'التفاصيل التقنية (للمطور والدعم الفني):',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: isDark ? Colors.white70 : Colors.black87,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      'قابل للنسخ',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // صندوق نصي متباين قابل للتمرير
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF0F172A)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: SelectableText(
                    [
                      '• Raw Exception:\n${error.rawException}',
                      if (error.sqlQuery != null &&
                          error.sqlQuery!.trim().isNotEmpty)
                        '\n• SQL Query:\n${error.sqlQuery}',
                      if (error.sqlArgs != null && error.sqlArgs!.isNotEmpty)
                        '\n• Args:\n${error.sqlArgs}',
                    ].join('\n'),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      color: isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF475569),
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: error.fullTechnicalReport));
              showSnack(context, 'تم نسخ تقرير تفاصيل الخطأ بنجاح 📋');
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('نسخ تفاصيل الخطأ'),
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('حسناً، فهمت'),
          ),
        ],
      ),
    );
  }
}
