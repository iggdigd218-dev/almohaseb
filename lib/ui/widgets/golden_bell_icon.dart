import 'dart:math' as math;
import 'package:flutter/material.dart';

/// أيقونة جرس ذهبي عصري برّاق (تصميم 2026-11-03): قبة انسيابية بحافة
/// مشرقة معتدلة، مقبض علوي صغير، ولسان متدلٍّ — بتدرجات الذهب المصقول
/// ولمعة معدنية حادة تحاكي جرس الإشعارات الحديث.
class GoldenBellIcon extends StatelessWidget {
  final double size;
  final bool showSparkle;

  const GoldenBellIcon({super.key, this.size = 24.0, this.showSparkle = true});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GoldenBellPainter(showSparkle: showSparkle),
        size: Size(size, size),
      ),
    );
  }
}

class _GoldenBellPainter extends CustomPainter {
  final bool showSparkle;

  _GoldenBellPainter({this.showSparkle = true});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w * 0.5;

    // 0. ظل ناعم ودافئ أسفل الجرس (Ambient Drop Shadow)
    final shadowPaint = Paint()
      ..color = const Color(0x3D552800)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2);
    canvas.drawPath(
      Path()
        ..addOval(Rect.fromCenter(
          center: Offset(cx, h * 0.90),
          width: w * 0.66,
          height: h * 0.18,
        )),
      shadowPaint,
    );

    // 1. المقبض العلوي الصغير (Modern Top Knob) — يُرسم أولًا
    //    فيغطي جسم القبة نقطة اتصاله.
    final knobCenter = Offset(cx, h * 0.135);
    final knobR = w * 0.082;
    final knobRect = Rect.fromCircle(center: knobCenter, radius: knobR);
    final knobShader = const RadialGradient(
      center: Alignment(-0.35, -0.45),
      radius: 0.95,
      colors: [
        Color(0xFFFFFDE7),
        Color(0xFFFDE047),
        Color(0xFFD97706),
        Color(0xFF92400E),
      ],
      stops: [0.0, 0.4, 0.75, 1.0],
    ).createShader(knobRect);
    canvas.drawCircle(
      knobCenter,
      knobR,
      Paint()
        ..shader = knobShader
        ..style = PaintingStyle.fill,
    );

    // 2. لسان الجرس المتدلي (Clapper) — يُرسم قبل الجسم فيظهر جزؤه
    //    السفلي فقط تحت حافة الفم، كجرس حقيقي معلّق.
    final clapperCenter = Offset(cx, h * 0.845);
    final clapperR = w * 0.105;
    final clapperRect =
        Rect.fromCircle(center: clapperCenter, radius: clapperR);
    final clapperShader = const RadialGradient(
      center: Alignment(-0.35, -0.4),
      radius: 0.9,
      colors: [
        Color(0xFFFFFDE7),
        Color(0xFFFBBF24),
        Color(0xFFD97706),
        Color(0xFF78350F),
      ],
      stops: [0.0, 0.35, 0.72, 1.0],
    ).createShader(clapperRect);
    canvas.drawCircle(
      clapperCenter,
      clapperR,
      Paint()
        ..shader = clapperShader
        ..style = PaintingStyle.fill,
    );

    // 3. تجويف فم الجرس (Hollow Interior) — ظل داخلي عميق يمنح عمقًا.
    final mouthRect = Rect.fromCenter(
      center: Offset(cx, h * 0.755),
      width: w * 0.62,
      height: h * 0.13,
    );
    final mouthShader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF2A1202),
        Color(0xFF542407),
        Color(0xFF78350F),
      ],
      stops: [0.0, 0.55, 1.0],
    ).createShader(mouthRect);
    canvas.drawOval(
      mouthRect,
      Paint()
        ..shader = mouthShader
        ..style = PaintingStyle.fill,
    );

    // 4. جسم الجرس العصري (Sleek Modern Dome) — قبة انسيابية تتمدد
    //    بانحناء واحد متصل حتى حافة مشرقة معتدلة (لا توسّع قديم).
    final bellPath = Path();
    // الكتف الأيسر العلوي
    bellPath.moveTo(w * 0.385, h * 0.215);
    // القبة المنحنية
    bellPath.quadraticBezierTo(cx, h * 0.150, w * 0.615, h * 0.215);
    // الجانب الأيمن: نزول انسيابي متصل (خصر ناعم بلا كسرات)
    bellPath.cubicTo(
      w * 0.642, h * 0.375,
      w * 0.648, h * 0.520,
      w * 0.672, h * 0.620,
    );
    // انفتاح الحافة اليمنى بانحناء قصير حديث
    bellPath.cubicTo(
      w * 0.696, h * 0.712,
      w * 0.780, h * 0.742,
      w * 0.812, h * 0.768,
    );
    // دوران الحافة السفلية اليمنى (Rounded Lip)
    bellPath.quadraticBezierTo(w * 0.838, h * 0.800, w * 0.782, h * 0.818);
    // قوس الفم السفلي
    bellPath.cubicTo(
      w * 0.600, h * 0.858,
      w * 0.400, h * 0.858,
      w * 0.218, h * 0.818,
    );
    // دوران الحافة السفلية اليسرى
    bellPath.quadraticBezierTo(w * 0.162, h * 0.800, w * 0.188, h * 0.768);
    // الجانب الأيسر: صعود انسيابي معكوس
    bellPath.cubicTo(
      w * 0.220, h * 0.742,
      w * 0.304, h * 0.712,
      w * 0.328, h * 0.620,
    );
    bellPath.cubicTo(
      w * 0.352, h * 0.520,
      w * 0.358, h * 0.375,
      w * 0.385, h * 0.215,
    );
    bellPath.close();

    // تدرج ذهب مصقول متعدد الطبقات (Polished 24k Gold)
    final bodyRect = Rect.fromLTWH(w * 0.13, h * 0.14, w * 0.74, h * 0.74);
    final goldShader = const LinearGradient(
      begin: Alignment(-0.85, -0.45),
      end: Alignment(0.9, 0.75),
      colors: [
        Color(0xFF92400E), // ظل برونزي عند الحافة
        Color(0xFFD97706), // ذهب كهرماني
        Color(0xFFFBBF24), // ذهب مشرق
        Color(0xFFFFFBEB), // شريط اللمعان الفائق (Specular Hotspot)
        Color(0xFFF59E0B), // ذهب دافئ
        Color(0xFFD97706), // تدرج الظل
        Color(0xFFFEF08A), // انعكاس حافة مقابلة
        Color(0xFF78350F), // ظل حافة خارجية
      ],
      stops: [0.0, 0.13, 0.27, 0.38, 0.56, 0.74, 0.88, 1.0],
    ).createShader(bodyRect);

    canvas.drawPath(
      bellPath,
      Paint()
        ..shader = goldShader
        ..style = PaintingStyle.fill,
    );

    // 5. حافة الفم البارزة (Embossed Lip) — شريط ذهبي فاتح يفصل
    //    الجسم عن التجويف ويمنح الجرس صلابته.
    final lipPath = Path();
    lipPath.moveTo(w * 0.188, h * 0.768);
    lipPath.quadraticBezierTo(w * 0.162, h * 0.800, w * 0.218, h * 0.818);
    lipPath.cubicTo(
      w * 0.400, h * 0.858,
      w * 0.600, h * 0.858,
      w * 0.782, h * 0.818,
    );
    lipPath.quadraticBezierTo(w * 0.838, h * 0.800, w * 0.812, h * 0.768);
    lipPath.cubicTo(
      w * 0.640, h * 0.828,
      w * 0.360, h * 0.828,
      w * 0.188, h * 0.768,
    );
    lipPath.close();

    final lipShader = const LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        Color(0xFFB45309),
        Color(0xFFFDE047),
        Color(0xFFFFFBEB),
        Color(0xFFF59E0B),
        Color(0xFF78350F),
      ],
      stops: [0.0, 0.3, 0.5, 0.75, 1.0],
    ).createShader(lipPath.getBounds());
    canvas.drawPath(
      lipPath,
      Paint()
        ..shader = lipShader
        ..style = PaintingStyle.fill,
    );

    // 6. خط اللمعان الانسيابي (Glossy Reflection Streak) — انحناء
    //    واحد يوازي الجانب الأيسر كأنعكاس ضوء على معدن مصقول.
    final glintPath = Path();
    glintPath.moveTo(w * 0.400, h * 0.26);
    glintPath.cubicTo(
      w * 0.382, h * 0.40,
      w * 0.388, h * 0.52,
      w * 0.360, h * 0.62,
    );
    canvas.drawPath(
      glintPath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.58)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.1, w * 0.045)
        ..strokeCap = StrokeCap.round,
    );

    // 7. بريق نجمي (Specular Sparkle Star) — لمعة حادة أعلى القبة.
    if (showSparkle) {
      final sparkleX = w * 0.415;
      final sparkleY = h * 0.315;
      final starR = w * 0.095;

      final starPath = Path();
      starPath.moveTo(sparkleX, sparkleY - starR);
      starPath.quadraticBezierTo(
          sparkleX, sparkleY, sparkleX + starR, sparkleY);
      starPath.quadraticBezierTo(
          sparkleX, sparkleY, sparkleX, sparkleY + starR);
      starPath.quadraticBezierTo(
          sparkleX, sparkleY, sparkleX - starR, sparkleY);
      starPath.quadraticBezierTo(
          sparkleX, sparkleY, sparkleX, sparkleY - starR);
      starPath.close();

      canvas.drawPath(
        starPath,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.94)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        Offset(sparkleX, sparkleY),
        w * 0.032,
        Paint()..color = const Color(0xFFFFFFFD),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GoldenBellPainter oldDelegate) =>
      oldDelegate.showSparkle != showSparkle;
}
