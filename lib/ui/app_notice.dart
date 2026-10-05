// نافذة الإشعار الداخلي المنبثقة — تصميم أنيق بألوان التطبيق:
// بطاقة بيضاء بزوايا دائرية كبيرة، أيقونة ⓘ داخل حلقة ملونة أعلى المنتصف،
// نص الرسالة في الوسط، وزر «موافق» ممتلئ بعرض كامل (مستوحى من لقطة
// الشاشة المرجعية التي أرفقها المستخدم).
import 'package:flutter/material.dart';

import '../core/sfx.dart';
import '../core/theme.dart';

/// نوع الإشعار يحدد لون الحلقة والأيقونة.
enum AppNoticeKind { info, success, warning, error }

/// يعرض إشعاراً داخلياً منبثقاً أنيقاً بألوان التطبيق.
Future<void> showAppNotice(
  BuildContext context, {
  required String message,
  String title = '',
  AppNoticeKind kind = AppNoticeKind.info,
  String buttonLabel = 'موافق',
  bool playSound = true,
}) async {
  if (playSound) Sfx.notify();
  final primary = AppColors.primaryOf(context);
  final (ringColor, icon) = switch (kind) {
    AppNoticeKind.success => (Colors.green.shade600, Icons.check_rounded),
    AppNoticeKind.warning => (Colors.amber.shade700, Icons.priority_high_rounded),
    AppNoticeKind.error => (Colors.red.shade600, Icons.close_rounded),
    AppNoticeKind.info => (Colors.amber.shade600, Icons.info_outline_rounded),
  };
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // أيقونة داخل حلقة ملونة (مثل ⓘ في التصميم المرجعي).
            Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: ringColor, width: 5),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 36, color: ringColor),
            ),
            const SizedBox(height: 18),
            if (title.isNotEmpty) ...[
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14.5, height: 1.6),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24)),
                ),
                onPressed: () {
                  Sfx.click();
                  Navigator.of(ctx).pop();
                },
                child: Text(
                  buttonLabel,
                  style: const TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
