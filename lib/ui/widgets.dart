import 'package:flutter/material.dart';
import '../core.dart';

/// صف بإيموجي وعنوان وسطر فرعي — نمط شاشات الإعدادات
class EmojiTile extends StatelessWidget {
  final String emoji;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? leadingWidget;
  final VoidCallback? onTap;
  final double emojiSize;
  final bool dense;
  final bool grayed;

  const EmojiTile({
    super.key,
    required this.emoji,
    required this.title,
    this.subtitle,
    this.trailing,
    this.leadingWidget,
    this.onTap,
    this.emojiSize = 21,
    this.dense = true,
    this.grayed = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(minHeight: dense ? 52 : 62),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        child: Row(
          children: [
            if (leadingWidget != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 14),
                child: leadingWidget!,
              )
            else if (emoji.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 14),
                child: Text(emoji, style: TextStyle(fontSize: emojiSize)),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      color: grayed ? AppColors.textFaint : AppColors.text,
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: TextStyle(fontSize: 11.5, color: grayed ? AppColors.faint : AppColors.sub),
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// مفتاح تبديل وردي بنمط التطبيق
Widget pinkSwitch({required bool value, required ValueChanged<bool> onChanged}) {
  return Switch(
    value: value,
    onChanged: onChanged,
    activeColor: AppColors.toggleOn,
    activeTrackColor: AppColors.toggleTrack,
    inactiveThumbColor: AppColors.toggleOff,
    inactiveTrackColor: AppColors.toggleOffTrack,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

/// عنوان قسم رمادي داخل الإعدادات
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.surface2,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Text(text, style: TextStyle(fontSize: 12.5, color: AppColors.textSub)),
    );
  }
}

/// شريط علوي موحد بالسهم والعنوان (السهم على اليسار) + إجراء «تغيير القالب»
AppBar simpleBar(BuildContext context, String title,
    {List<Widget>? actions, bool showTemplate = true}) {
  return AppBar(
    automaticallyImplyLeading: false,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => Navigator.of(context).maybePop(),
    ),
    title: Text(title),
    actions: [
      ...?actions,
      if (showTemplate)
        TextButton(
          onPressed: () => showTemplateDialog(context),
          child: const Text('تغيير القالب',
              style: TextStyle(color: Colors.white, fontSize: 13.5)),
        ),
    ],
  );
}

Future<void> showTemplateDialog(BuildContext context) async {
  final options = {'1': 'القالب الأول', '2': 'القالب الثاني', '3': 'English'};
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: options.entries
            .map((e) => RadioListTile<String>(
                  dense: true,
                  activeColor: AppColors.pink,
                  title: Text(e.value, style: const TextStyle(fontSize: 15)),
                  value: e.key,
                  groupValue: Prefs.template,
                  onChanged: (v) {
                    Prefs.setS('template', v!);
                    Navigator.pop(ctx);
                  },
                ))
            .toList(),
      ),
    ),
  );
}

/// حوار بسيط بخيارات
Future<void> choiceDialog(BuildContext context, String title, List<String> options,
    String current, void Function(String) onPick) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: options
            .map((o) => RadioListTile<String>(
                  dense: true,
                  activeColor: AppColors.pink,
                  title: Text(o, style: const TextStyle(fontSize: 15)),
                  value: o,
                  groupValue: current,
                  onChanged: (v) {
                    Navigator.pop(ctx);
                    onPick(v!);
                  },
                ))
            .toList(),
      ),
    ),
  );
}

/// حوار إدخال نص
Future<String?> textDialog(BuildContext context, String title,
    {String initial = '', String? hint, bool password = false}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: TextField(
        controller: ctrl,
        obscureText: password,
        autofocus: true,
        style: const TextStyle(fontSize: 15),
        decoration: InputDecoration(
          hintText: hint,
          enabledBorder: const UnderlineInputBorder(),
          focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: AppColors.pink)),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء', style: TextStyle(color: AppColors.sub))),
        TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('موافق', style: TextStyle(color: AppColors.primary))),
      ],
    ),
  );
}

/// أيقونة واتساب مرسومة
class WhatsAppIcon extends StatelessWidget {
  final double size;
  final bool business;
  const WhatsAppIcon({super.key, this.size = 26, this.business = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: business ? AppColors.waBizGreen : AppColors.waGreen,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: business
          ? Text('B',
              style: TextStyle(
                  color: Colors.white, fontSize: size * 0.55, fontWeight: FontWeight.w700))
          : Icon(Icons.phone, color: Colors.white, size: size * 0.62),
    );
  }
}

/// أيقونة جوجل درايف مرسومة
class DriveIcon extends StatelessWidget {
  final double size;
  const DriveIcon({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size), painter: _DrivePainter());
  }
}

class _DrivePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final tri1 = Paint()..color = const Color(0xFF0066DA); // أزرق
    final tri2 = Paint()..color = const Color(0xFF00AC47); // أخضر
    final tri3 = Paint()..color = const Color(0xFFEA4335); // أحمر
    final tri4 = Paint()..color = const Color(0xFFFFBA00); // أصفر
    // شكل الدائرة الثلاثي المبسّط
    final p1 = Path()
      ..moveTo(w * 0.5, h * 0.08)
      ..lineTo(w * 0.92, h * 0.8)
      ..lineTo(w * 0.72, h * 0.8)
      ..lineTo(w * 0.5, h * 0.42)
      ..close();
    final p2 = Path()
      ..moveTo(w * 0.08, h * 0.8)
      ..lineTo(w * 0.28, h * 0.8)
      ..lineTo(w * 0.5, h * 0.42)
      ..lineTo(w * 0.3, h * 0.42)
      ..close();
    final p3 = Path()
      ..moveTo(w * 0.28, h * 0.8)
      ..lineTo(w * 0.72, h * 0.8)
      ..lineTo(w * 0.5, h * 0.42)
      ..close();
    final p4 = Path()
      ..moveTo(w * 0.3, h * 0.42)
      ..lineTo(w * 0.5, h * 0.08)
      ..lineTo(w * 0.7, h * 0.42)
      ..close();
    canvas.drawPath(p1, tri1);
    canvas.drawPath(p2, tri4);
    canvas.drawPath(p3, tri2);
    canvas.drawPath(p4, tri3);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
