import 'package:flutter/foundation.dart';

/// قناة تنقّل خفيفة بين شاشات القشرة (2026-09-24).
///
/// تسمح لشاشة داخلية — نقطة البيع مثلاً — بطلب الانتقال إلى شاشة أخرى
/// دون استيراد `home_shell.dart` (الذي يستوردها بدوره ⇒ دورة استيراد).
///
/// الاستخدام من أي شاشة:
/// ```dart
/// ShellNav.go(ShellNav.home); // العودة إلى الرئيسية
/// ```
class ShellNav {
  const ShellNav._();

  /// الهدف المطلوب — تُنشئ القشرة تغييره إلى الشاشة المناسبة.
  static final ValueNotifier<String> request = ValueNotifier<String>('');

  /// الشاشة الرئيسية (لوحة المعلومات).
  static const String home = 'home';

  /// المخزون.
  static const String inventory = 'inventory';

  static void go(String target) {
    if (target.isEmpty) return;
    // إعادة إطلاق نفس الهدف: إفراغ القيمة أولاً حتى يُلتقط التغيير.
    request.value = '';
    request.value = target;
  }
}
