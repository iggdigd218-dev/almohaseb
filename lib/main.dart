import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core.dart';
import 'ui/home_screen.dart';
import 'ui/security_gate.dart';
import 'ui/reports_screens.dart';
import 'update.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Prefs.init();
  await Db.open();
  // (2026-11-22) حفظ تلقائي يومي صامت: كان مفتاح «حفظ البيانات يوميا»
  // يُحفظ في التفضيلات بلا أي أثر. الآن يُنفَّذ عند أول فتح في اليوم.
  unawaited(autoBackupIfDue());
  runApp(const LedgerApp());
}

/// (إصلاح 2026-11-22) ناقل تغييرات التفضيلات.
///
/// كان الوضع الليلي (وكل تفضيل يمسّ الثيم) يُقرأ مرة واحدة عند الإقلاع،
/// والمفتاح في الإعدادات يستدعي setState على شاشة الإعدادات وحدها — فلا
/// يرى التطبيق التغيير إطلاقاً حتى يُغلق ويُفتح من جديد. الآن كل تغيير
/// يبثّ إشعاراً فيُعاد بناء الجذر والثيم فوراً.
final ValueNotifier<int> prefsRevision = ValueNotifier<int>(0);

/// يُنادى بعد حفظ أي تفضيل يمسّ المظهر.
void notifyPrefsChanged() => prefsRevision.value++;

/// جسر يمنح الفحص الصامت سياقاً صالحاً بعد بناء الشاشة الأولى.
class _UpdateProbe extends StatefulWidget {
  final Widget child;
  const _UpdateProbe({required this.child});
  @override
  State<_UpdateProbe> createState() => _UpdateProbeState();
}

class _UpdateProbeState extends State<_UpdateProbe> {
  @override
  void initState() {
    super.initState();
    // بعد إطار كامل: لا نُبطئ فتح التطبيق ولا نزاحم بناء الواجهة.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(checkForUpdateOnStart(context));
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class LedgerApp extends StatelessWidget {
  const LedgerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: prefsRevision,
      builder: (context, _, __) => _buildApp(),
    );
  }

  Widget _buildApp() {
    final dark = Prefs.darkMode;
    return MaterialApp(
      title: 'المحاسب',
      debugShowCheckedModeBanner: false,
      builder: (ctx, child) => Directionality(
        textDirection: TextDirection.ltr,
        child: child!,
      ),
      theme: _theme(dark),
      home: const _UpdateProbe(
        child: SecurityGate(child: HomeScreen()),
      ),
    );
  }

  ThemeData _theme(bool dark) {
    final base = ThemeData(
      useMaterial3: false,
      fontFamily: 'AppNaskh',
      brightness: dark ? Brightness.dark : Brightness.light,
    );
    return base.copyWith(
      scaffoldBackgroundColor: dark ? const Color(0xFF121212) : Colors.white,
      primaryColor: AppColors.primary,
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.primary,
        secondary: AppColors.pink,
        surface: dark ? const Color(0xFF1E1E1E) : Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        toolbarHeight: 44,
        titleTextStyle: const TextStyle(
          fontFamily: 'AppNaskh',
          color: Colors.white,
          fontSize: 19,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: const IconThemeData(color: Colors.white, size: 22),
      ),
      toggleButtonsTheme: base.toggleButtonsTheme,
      dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 0.7, space: 0.7),
      textTheme: base.textTheme.apply(
        bodyColor: dark ? Colors.white : AppColors.ink,
        displayColor: dark ? Colors.white : AppColors.ink,
      ),
    );
  }
}
