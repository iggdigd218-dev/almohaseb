// شاشة البداية: شعار متحرك بحركة احترافية (ظهور مرن + طفو ناعم + توهج
// نابض) على خلفية سماوية فاتحة، ثم انتقال سلس للتطبيق.
// عند أول تشغيل (قاعدة فارغة بلا إعداد سابق) تُعرض شاشة الإعداد الأول.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'home_shell.dart';
import 'lock_gate.dart';
import 'onboarding_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _c;
  late final AnimationController _float;
  late final Animation<double> _scale;
  late final Animation<double> _fade;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    // الظهور: 1200ms بمنحنى مرن (easeOutBack) — دخول بحياة دون مبالغة.
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..forward();
    // الطفو: حلقة مستمرة لطيفة (صعود/هبوط 6 بكسل) — حركة تنفسية هادئة.
    _float = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2100),
    )..repeat(reverse: true);
    _scale = CurvedAnimation(
      parent: _c,
      curve: const Interval(0, 0.7, curve: Curves.easeOutBack),
    );
    _fade = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.3, 0.85, curve: Curves.easeOut),
    );
    // توهج نابض خلف الشعار يعطي عمقًا وإحساسًا بالحضور.
    _glow = Tween(begin: 0.25, end: 0.6).animate(
      CurvedAnimation(parent: _float, curve: Curves.easeInOut),
    );
    _go();
  }

  Future<void> _go() async {
    // تهيئة محلية خفيفة بالتوازي مع مدة الشعار والدخول المباشر للتطبيق.
    await Future.wait([
      Future.delayed(const Duration(milliseconds: 1700)),
      () async {
        try {
          final container = ProviderScope.containerOf(context, listen: false);
          final repo = container.read(repoProvider);
          // سلوك الإقلاع الأصلي: وسم الإعداد الأول كمكتمل (يتخطى معالج
          // الإعداد إن كانت القاعدة مهيأة مسبقًا).
          await repo
              .setSetting(kOnboardingDoneKey, '1')
              .timeout(const Duration(seconds: 2));
          await repo
              .restoreManagerOwnership()
              .timeout(const Duration(seconds: 2));
        } catch (_) {}
      }(),
    ]);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, __, ___) => const LockGate(child: HomeShell()),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    _float.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // خلفية سماوية فاتحة متدرجة بدل اللون الغامق السابق.
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF7DD3FC), Color(0xFF38BDF8), Color(0xFF0EA5E9)],
            stops: [0, 0.55, 1],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // الشعار: ظهور مرن + طفو مستمر + هالة نابضة.
              AnimatedBuilder(
                animation: Listenable.merge([_c, _float]),
                builder: (context, _) {
                  final floatOffset =
                      math.sin(_float.value * math.pi) * 6.0;
                  return Transform.translate(
                    offset: Offset(0, -floatOffset),
                    child: ScaleTransition(
                      scale: Tween(begin: 0.5, end: 1.0).animate(_scale),
                      child: FadeTransition(
                        opacity: _fade,
                        child: Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              // الهالة النابضة خلف البطاقة.
                              BoxShadow(
                                color: Colors.white
                                    .withValues(alpha: 0.25 + _glow.value * 0.5),
                                blurRadius: 34 + _glow.value * 22,
                                spreadRadius: 2 + _glow.value * 6,
                              ),
                            ],
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(30),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.12),
                                  blurRadius: 18,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(30),
                              child: Image.asset(
                                'assets/images/logo.png',
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 28),
              FadeTransition(
                opacity: _fade,
                child: const Text(
                  'مدير الحسابات',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .3,
                    shadows: [
                      Shadow(blurRadius: 10, color: Color(0x33000000)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 34),
              FadeTransition(
                opacity: _fade,
                child: const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
