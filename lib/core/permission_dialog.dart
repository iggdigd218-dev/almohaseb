// نافذة طلب صلاحيات مصممة بألوان التطبيق بدل نافذة النظام البسيطة.
// تُعرض قبل طلب الإذن الفعلي لشرح سبب الحاجة إليه بشكل واضح وودّي.
import 'package:flutter/material.dart';

import '../core/sfx.dart';
import '../core/theme.dart';

class PermissionRationale {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String message;
  final String grantLabel;
  final String denyLabel;

  const PermissionRationale({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.message,
    this.grantLabel = 'السماح',
    this.denyLabel = 'ليس الآن',
  });

  // طلبات الصلاحيات الشائعة.
  static const contacts = PermissionRationale(
    icon: Icons.contacts_rounded,
    iconColor: Color(0xFF4CAF50),
    title: 'السماح بالوصول إلى جهات الاتصال',
    message:
        'نحتاج إلى الوصول إلى جهات اتصال هاتفك لتسهيل اختيار الاسم ورقم الجوال عند '
        'إضافة حساب عميل أو مورّد جديد بضغطة واحدة بدل كتابتها يدوياً.\n\n'
        'لن يتم رفع أي من أسمائك أو أرقامك إلى أي خادم — كل شيء يبقى في جهازك.',
  );

  static const camera = PermissionRationale(
    icon: Icons.photo_camera_rounded,
    iconColor: Color(0xFF2196F3),
    title: 'السماح باستخدام الكاميرا',
    message:
        'نحتاج إلى الكاميرا لمسح الباركود وإضافة صور للفواتير أو للمؤسسة.\n\n'
        'لا يتم تشغيل الكاميرا إلا عندما تضغط أنت على زر المسح أو زر الكاميرا.',
  );

  static const notifications = PermissionRationale(
    icon: Icons.notifications_active_rounded,
    iconColor: Color(0xFFFF9800),
    title: 'تفعيل الإشعارات',
    message:
        'لإشعارك عند وصول نسخ احتياطية، انتهاء مخزون، أو فشل مزامنة الأجهزة، '
        'نحتاج إذن عرض الإشعارات.\n\nيمكنك إلغاء الإذن من إعدادات الهاتف في أي وقت.',
  );

  static const storage = PermissionRationale(
    icon: Icons.sd_storage_rounded,
    iconColor: Color(0xFF9C27B0),
    title: 'الوصول إلى التخزين',
    message: 'نحتاج التخزين لحفظ النسخ الاحتياطية (ملف .sijil) وقراءتها عند '
        'الاستعادة أو مشاركتها.',
  );
}

/// يعرض نافذة ملونة مخصصة لشرح سبب طلب الإذن قبل استدعاء الطلب الفعلي.
/// يُعيد true إن وافق المستخدم على المتابعة لطلب الإذن.
Future<bool> showPermissionRationale(
  BuildContext context,
  PermissionRationale rationale,
) async {
  Sfx.warning(); // اهتزاز تنبيهي خفيف عند ظهور النافذة.
  final result = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'permission',
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    transitionBuilder: (ctx, anim, secAnim, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
      return ScaleTransition(
        scale: Tween<double>(begin: .85, end: 1).animate(curved),
        alignment: Alignment.center,
        child: FadeTransition(
          opacity: curved,
          child: _PermissionDialog(rationale: rationale),
        ),
      );
    },
  );
  return result == true;
}

class _PermissionDialog extends StatelessWidget {
  final PermissionRationale rationale;
  const _PermissionDialog({required this.rationale});

  @override
  Widget build(BuildContext context) {
    final primary = AppColors.primaryOf(context);
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(24),
          elevation: 12,
          shadowColor: Colors.black45,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // أيقونة كبيرة داخل دائرة ملونة.
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        rationale.iconColor.withValues(alpha: .25),
                        rationale.iconColor.withValues(alpha: .08),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: rationale.iconColor.withValues(alpha: .45),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    rationale.icon,
                    size: 46,
                    color: rationale.iconColor,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  rationale.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  rationale.message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13.5,
                    height: 1.7,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: rationale.iconColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 2,
                    ),
                    onPressed: () {
                      Sfx.pop();
                      Navigator.pop(context, true);
                    },
                    child: Text(
                      rationale.grantLabel,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    Sfx.click();
                    Navigator.pop(context, false);
                  },
                  child: Text(
                    rationale.denyLabel,
                    style: TextStyle(
                      color: primary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
