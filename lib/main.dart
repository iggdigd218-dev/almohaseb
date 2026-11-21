import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core.dart';
import 'ui/home_screen.dart';
import 'ui/security_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Prefs.init();
  await Db.open();
  runApp(const LedgerApp());
}

class LedgerApp extends StatelessWidget {
  const LedgerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Prefs.darkMode;
    return MaterialApp(
      title: 'دفتر الحسابات',
      debugShowCheckedModeBanner: false,
      builder: (ctx, child) => Directionality(
        textDirection: TextDirection.ltr,
        child: child!,
      ),
      theme: _theme(dark),
      home: const SecurityGate(child: HomeScreen()),
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
