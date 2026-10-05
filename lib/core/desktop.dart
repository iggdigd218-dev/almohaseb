// أدوات سطح المكتب: كشف بيئة ويندوز/الشاشات الكبيرة، حدود الألواح
// المرئية، وتكبير الخط الأساسي ~15% لراحة العين على الشاشات الكبيرة.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'platform_info.dart';

/// عتبة «الشاشة الكبيرة» بالـ dp — فوقها نعتمد هندسة سطح المكتب.
const double kDesktopBreakpoint = 900;

/// هل نعمل على منصة سطح مكتب أصلية (ويندوز/لينكس/ماك)?
bool get isDesktopPlatform {
  if (kIsWeb) return false;
  try {
    return PlatformInfo.isDesktop;
  } catch (_) {
    return false;
  }
}

/// سطح مكتب حقيقي: منصة مكتبية خارج بيئة اختبارات flutter test —
/// حتى لا تغيّر الاختبارات (التي تعمل على لينكس) سلوك الإقلاع.
bool get isRealDesktop {
  if (!isDesktopPlatform) return false;
  try {
    return !Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return true;
  }
}

/// هل نعرض هندسة سطح المكتب الآن؟ القرار بالعرض المتاح (> 900dp):
/// نافذة ويندوز الاعتيادية أوسع من العتبة، ونافذة ضيقة (أو هاتف) تسقط
/// تلقائياً إلى التخطيط المحمول — انتقال سلس عند تغيير حجم النافذة.
bool isDesktopLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width > kDesktopBreakpoint;

/// معامل تكبير الخط على سطح المكتب (~15%).
double desktopFontScale(BuildContext context) =>
    isDesktopLayout(context) ? 1.15 : 1.0;

/// حدود الألواح المرئية على سطح المكتب: إطار واضح + زوايا 12 + ظل خفيف.
BoxDecoration desktopPanelDecoration(BuildContext context) {
  final theme = Theme.of(context);
  return BoxDecoration(
    color: theme.colorScheme.surface,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(
      color: theme.dividerColor.withValues(alpha: 0.18),
      width: 1.2,
    ),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.05),
        blurRadius: 8,
        offset: const Offset(0, 2),
      ),
    ],
  );
}

/// لوح مؤطّر لسطح المكتب — يلفّ أي محتوى بإطار مرئي وزوايا وظل موحّد.
class DesktopPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  const DesktopPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.margin = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) => Container(
        margin: margin,
        padding: padding,
        decoration: desktopPanelDecoration(context),
        child: child,
      );
}

/// غلاف تفاعل مكتبي: حالة hover ناعمة + انتقال دقيق للبطاقات والصفوف.
class HoverLift extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;
  const HoverLift({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius,
  });

  @override
  State<HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<HoverLift> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BorderRadius.circular(12);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: radius,
          color: _hover
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.05)
              : Colors.transparent,
          boxShadow: _hover
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.07),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : const [],
        ),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: radius,
          child: widget.child,
        ),
      ),
    );
  }
}
