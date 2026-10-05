import 'dart:math' as math;
import 'package:flutter/material.dart';

/// أيقونة جرس ذهبي حقيقي ثلاثي الأبعاد بتدرجات الذهب الخالص (24k Gold)
/// ولمعات بريق معدنية تحاكي انعكاس الضوء على المعدن المصقول.
class GoldenBellIcon extends StatelessWidget {
  final double size;
  final bool showSparkle;

  const GoldenBellIcon({
    super.key,
    this.size = 24.0,
    this.showSparkle = true,
  });

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

    // 0. ظل ناعم ودافئ للجرس بالكامل (Ambient Drop Shadow)
    final shadowPaint = Paint()
      ..color = const Color(0x40552800)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);

    // مسار ظل تقريبي خلف الجرس
    final shadowPath = Path()
      ..addOval(Rect.fromCenter(
        center: Offset(cx, h * 0.88),
        width: w * 0.72,
        height: h * 0.22,
      ));
    canvas.drawPath(shadowPath, shadowPaint);

    // 1. لسان الجرس المتدلي (Clapper) في الأسفل
    final clapperCenter = Offset(cx, h * 0.85);
    final clapperRadius = w * 0.11;
    final clapperRect =
        Rect.fromCircle(center: clapperCenter, radius: clapperRadius);

    final clapperShader = const RadialGradient(
      center: Alignment(-0.35, -0.4),
      radius: 0.85,
      colors: [
        Color(0xFFFFFDE7), // لمعة لسان الجرس
        Color(0xFFFBBF24), // ذهب صافي
        Color(0xFFD97706), // ذهب برونزي
        Color(0xFF78350F), // ظل سفلي
      ],
      stops: [0.0, 0.35, 0.70, 1.0],
    ).createShader(clapperRect);

    final clapperPaint = Paint()
      ..shader = clapperShader
      ..style = PaintingStyle.fill;

    canvas.drawCircle(clapperCenter, clapperRadius, clapperPaint);

    // 2. تجويف فم الجرس الداخلي (Hollow Interior Dark Shadow)
    final mouthRect = Rect.fromCenter(
      center: Offset(cx, h * 0.77),
      width: w * 0.70,
      height: h * 0.16,
    );
    final mouthShader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF2A1202), // ظلمة جوف الجرس
        Color(0xFF542407),
        Color(0xFF78350F),
      ],
      stops: [0.0, 0.5, 1.0],
    ).createShader(mouthRect);

    final mouthPaint = Paint()
      ..shader = mouthShader
      ..style = PaintingStyle.fill;
    canvas.drawOval(mouthRect, mouthPaint);

    // 3. حلقة التعليق العلوية (Top Crown Ring)
    final ringCenter = Offset(cx, h * 0.17);
    final ringOuterR = w * 0.13;
    final ringStrokeW = w * 0.075;

    final ringRect = Rect.fromCircle(center: ringCenter, radius: ringOuterR);
    final ringShader = const LinearGradient(
      begin: Alignment(-0.8, -0.8),
      end: Alignment(0.8, 0.8),
      colors: [
        Color(0xFFFFFBEB), // بريق ذهبي
        Color(0xFFFDE047),
        Color(0xFFD97706),
        Color(0xFF92400E),
      ],
      stops: [0.0, 0.35, 0.75, 1.0],
    ).createShader(ringRect);

    final ringPaint = Paint()
      ..shader = ringShader
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringStrokeW
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: ringCenter, radius: ringOuterR - ringStrokeW / 2),
      math.pi * 0.9,
      math.pi * 1.2,
      false,
      ringPaint,
    );

    // 4. جسم الجرس الرئيسي (Bell Dome & Flared Skirt)
    final bellPath = Path();
    // القمة المنحنية
    bellPath.moveTo(w * 0.35, h * 0.23);
    bellPath.quadraticBezierTo(cx, h * 0.19, w * 0.65, h * 0.23);

    // الجانب الأيمن: نزول بانحناء ناعم للخصر ثم توسع الحافة السفلية
    bellPath.cubicTo(
      w * 0.66,
      h * 0.38,
      w * 0.69,
      h * 0.52,
      w * 0.73,
      h * 0.61,
    );
    bellPath.cubicTo(
      w * 0.77,
      h * 0.70,
      w * 0.87,
      h * 0.74,
      w * 0.90,
      h * 0.77,
    );

    // الحافة السفلية اليمين متجهة للأسفل قليلاً
    bellPath.quadraticBezierTo(w * 0.90, h * 0.81, w * 0.86, h * 0.82);

    // تقويس الحافة السفلية الدائرية (Lip Rim Arc)
    bellPath.cubicTo(
      w * 0.65,
      h * 0.85,
      w * 0.35,
      h * 0.85,
      w * 0.14,
      h * 0.82,
    );

    // الحافة السفلية اليسار
    bellPath.quadraticBezierTo(w * 0.10, h * 0.81, w * 0.10, h * 0.77);

    // الجانب الأيسر: صعود مع تقعر الخصر
    bellPath.cubicTo(
      w * 0.23,
      h * 0.74,
      w * 0.27,
      h * 0.70,
      w * 0.27,
      h * 0.61,
    );
    bellPath.cubicTo(
      w * 0.31,
      h * 0.52,
      w * 0.34,
      h * 0.38,
      w * 0.35,
      h * 0.23,
    );
    bellPath.close();

    // تدرج لوني معدني واقعي متعدد الدرجات (Multi-Stop 24k Gold Gradient)
    final bodyRect = Rect.fromLTWH(w * 0.08, h * 0.19, w * 0.84, h * 0.66);
    final goldShader = const LinearGradient(
      begin: Alignment(-0.85, -0.4),
      end: Alignment(0.9, 0.7),
      colors: [
        Color(0xFF92400E), // ظل معدني برونزي عند الحافة
        Color(0xFFD97706), // ذهب كهرماني
        Color(0xFFFBBF24), // ذهب مشرق
        Color(0xFFFFFBEB), // شريط اللمعان الفائق (Specular Hotspot)
        Color(0xFFF59E0B), // ذهب كلاسيكي دافئ
        Color(0xFFD97706), // تدرج الظل
        Color(0xFFFEF08A), // انعكاس إضاءة ثانوية عند الحافة المقابلة
        Color(0xFF78350F), // ظل حافة خارجية
      ],
      stops: [
        0.0,
        0.14,
        0.28,
        0.40,
        0.58,
        0.75,
        0.88,
        1.0,
      ],
    ).createShader(bodyRect);

    final bodyPaint = Paint()
      ..shader = goldShader
      ..style = PaintingStyle.fill;

    canvas.drawPath(bellPath, bodyPaint);

    // 5. حافة شفة الجرس البارزة (Embossed Bottom Lip Rim)
    final lipPath = Path();
    lipPath.moveTo(w * 0.10, h * 0.77);
    lipPath.cubicTo(
      w * 0.35,
      h * 0.82,
      w * 0.65,
      h * 0.82,
      w * 0.90,
      h * 0.77,
    );
    lipPath.quadraticBezierTo(w * 0.90, h * 0.81, w * 0.86, h * 0.82);
    lipPath.cubicTo(
      w * 0.65,
      h * 0.85,
      w * 0.35,
      h * 0.85,
      w * 0.14,
      h * 0.82,
    );
    lipPath.quadraticBezierTo(w * 0.10, h * 0.81, w * 0.10, h * 0.77);
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

    final lipPaint = Paint()
      ..shader = lipShader
      ..style = PaintingStyle.fill;
    canvas.drawPath(lipPath, lipPaint);

    // 6. خط لمعان انعكاسي أنيق على انحناء الجانب الأيسر (Glossy Reflection Streak)
    final glintPath = Path();
    glintPath.moveTo(w * 0.36, h * 0.28);
    glintPath.cubicTo(
      w * 0.35,
      h * 0.42,
      w * 0.32,
      h * 0.54,
      w * 0.27,
      h * 0.64,
    );

    final glintPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, w * 0.05)
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(glintPath, glintPaint);

    // 7. بريق نجمي لامع للذهب (Specular Sparkle Star)
    if (showSparkle) {
      final sparkleX = w * 0.37;
      final sparkleY = h * 0.34;
      final starR = w * 0.10;

      final sparklePaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.92)
        ..style = PaintingStyle.fill;

      // نجمة لمعان بأربعة أطراف حادة
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

      canvas.drawPath(starPath, sparklePaint);

      // نقطة بريق مركزية شديدة السطوع
      final corePaint = Paint()
        ..color = const Color(0xFFFFFFFD)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(sparkleX, sparkleY), w * 0.035, corePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GoldenBellPainter oldDelegate) =>
      oldDelegate.showSparkle != showSparkle;
}
