import 'package:flutter/material.dart';

/// خط واجهة التطبيق.
///
/// **Noto Naskh Arabic** (خط النسخ العربي الفاخر) متطابق كلياً مع نسخة الويب
/// المعتمدة في شاشة المعاينة. الخط مضمّن محلياً في `assets/fonts/NotoNaskhArabic-*.ttf`
/// ويعمل دون اتصال بالكامل وبأعلى دقة قراءة.
String? get uiFontFamily => 'Noto Naskh Arabic';

/// ألوان نكسورا — متطابقة تماماً مع تصميم نسخة الويب الأنيقة والعصرية.
class AppColors {
  // ===== الوضع الفاتح (نسخة الويب الحديثة) =====
  static const bg = Color(0xFFF8FAFC); // Slate-50 — خلفية نقية وناعمة
  static const bg2 = Color(0xFFF1F5F9); // Slate-100
  static const surface = Color(0xFFFFFFFF); // أبيض ناصع للكروت
  static const surface2 = Color(0xFFF8FAFC); // أوف وايت للبطاقات الداخلية
  static const text = Color(0xFF0F172A); // Slate-900 — نصوص داكنة حادة ومريحة
  static const text2 = Color(0xFF475569); // Slate-600
  static const text3 = Color(0xFF94A3B8); // Slate-400
  static const border = Color(0xFFE2E8F0); // Slate-200

  static const primary = Color(0xFF0284C7); // Sky-600 — أزرق سماوي عصري
  static const primary2 = Color(0xFF0EA5E9); // Sky-500
  static const primarySoft = Color(0xFFE0F2FE); // Sky-100
  static const accent = Color(0xFFF59E0B); // Amber-500
  static const accentSoft = Color(0xFFFEF3C7); // Amber-100
  static const danger = Color(0xFFEF4444); // Red-500
  static const dangerSoft = Color(0xFFFEE2E2); // Red-100
  static const green = Color(0xFF10B981); // Emerald-500 — أخضر زمردي إيجابي
  static const greenSoft = Color(0xFFD1FAE5); // Emerald-100
  static const info = Color(0xFF0EA5E9); // Sky-500
  static const infoSoft = Color(0xFFE0F2FE); // Sky-100
  static const violet = Color(0xFF8B5CF6); // Violet-500
  static const violetSoft = Color(0xFFEDE9FE); // Violet-100

  // ===== الوضع الداكن =====
  static const dBg = Color(0xFF0F172A); // Slate-900
  static const dBg2 = Color(0xFF1E293B); // Slate-800
  static const dSurface = Color(0xFF1E293B); // Slate-800
  static const dSurface2 = Color(0xFF334155); // Slate-700
  static const dText = Color(0xFFF8FAFC); // Slate-50
  static const dText2 = Color(0xFFCBD5E1); // Slate-300
  static const dText3 = Color(0xFF94A3B8); // Slate-400
  static const dBorder = Color(0xFF334155); // Slate-700

  static const dPrimary = Color(0xFF38BDF8); // Sky-400
  static const dPrimary2 = Color(0xFF7DD3FC); // Sky-300
  static const dPrimarySoft = Color(0xFF0C4A6E); // Sky-900
  static const dAccent = Color(0xFFFBBF24); // Amber-400
  static const dAccentSoft = Color(0xFF451A03);
  static const dDanger = Color(0xFFF87171); // Red-400
  static const dDangerSoft = Color(0xFF450A0A);
  static const dGreen = Color(0xFF34D399); // Emerald-400
  static const dGreenSoft = Color(0xFF064E3B);
  static const dInfo = Color(0xFF38BDF8);
  static const dInfoSoft = Color(0xFF0C4A6E);
  static const dViolet = Color(0xFFA78BFA);
  static const dVioletSoft = Color(0xFF2E1065);

  /// اللون حسب الوضع الحالي — يُستخدم في الواجهات بدل الثوابت المباشرة.
  static Color of(BuildContext c, Color light, Color dark) =>
      Theme.of(c).brightness == Brightness.dark ? dark : light;

  static Color bgOf(BuildContext c) => of(c, bg, dBg);
  static Color bg2Of(BuildContext c) => of(c, bg2, dBg2);
  static Color surfaceOf(BuildContext c) => of(c, surface, dSurface);
  static Color surface2Of(BuildContext c) => of(c, surface2, dSurface2);
  static Color textOf(BuildContext c) => of(c, text, dText);
  static Color text2Of(BuildContext c) => of(c, text2, dText2);
  static Color text3Of(BuildContext c) => of(c, text3, dText3);
  static Color borderOf(BuildContext c) => of(c, border, dBorder);
  static Color primaryOf(BuildContext c) => of(c, primary, dPrimary);
  static Color accentOf(BuildContext c) => of(c, accent, dAccent);
  static Color dangerOf(BuildContext c) => of(c, danger, dDanger);
  static Color greenOf(BuildContext c) => of(c, green, dGreen);
  static Color infoOf(BuildContext c) => of(c, info, dInfo);
  static Color violetOf(BuildContext c) => of(c, violet, dViolet);

  static Color primarySoftOf(BuildContext c) =>
      of(c, primarySoft, dPrimarySoft);
  static Color accentSoftOf(BuildContext c) => of(c, accentSoft, dAccentSoft);
  static Color dangerSoftOf(BuildContext c) => of(c, dangerSoft, dDangerSoft);
  static Color greenSoftOf(BuildContext c) => of(c, greenSoft, dGreenSoft);
  static Color infoSoftOf(BuildContext c) => of(c, infoSoft, dInfoSoft);
  static Color violetSoftOf(BuildContext c) => of(c, violetSoft, dVioletSoft);

  // أسماء متوافقة مع الشيفرة القائمة
  static const teal = primary;
  static const tealLight = primary2;
  static const red = danger;
  static const amber = accent;
}

/// أنصاف أقطار الزوايا الموحّدة للتطبيق (16px للبطاقات والحقول).
class AppRadius {
  static const double small = 10;
  static const double card = 16;
  static const double field = 16;
  static const double button = 16;
  static const double sheet = 24;
  static const double pill = 999;

  static BorderRadius get cardAll => BorderRadius.circular(card);
  static BorderRadius get fieldAll => BorderRadius.circular(field);
  static BorderRadius get buttonAll => BorderRadius.circular(button);
  static BorderRadius get sheetTop =>
      const BorderRadius.vertical(top: Radius.circular(sheet));
}

/// تدرجات الباستيل الهادئة لكروت الأقسام والفئات.
class AppTone {
  final String key;
  final String label;
  final Color background;
  final Color foreground;

  const AppTone(this.key, this.label, this.background, this.foreground);

  static const blue = AppTone('blue', 'أزرق ناعم', Color(0xFFE8F0FF), Color(0xFF0D6EFD));
  static const orange = AppTone('orange', 'برتقالي', Color(0xFFFFF1E3), Color(0xFFEA8C1C));
  static const violet = AppTone('violet', 'موف', Color(0xFFF2EAFD), Color(0xFF7C3AED));
  static const green = AppTone('green', 'أخضر', Color(0xFFE7F7EE), Color(0xFF16A34A));
  static const pink = AppTone('pink', 'وردي', Color(0xFFFDE9F1), Color(0xFFDB2777));
  static const teal = AppTone('teal', 'فيروزي', Color(0xFFE3F7F5), Color(0xFF0E9488));
  static const red = AppTone('red', 'أحمر', Color(0xFFFDE8E8), Color(0xFFDC2626));
  static const sand = AppTone('sand', 'بيج', Color(0xFFF7EFE1), Color(0xFFB4741A));

  static const List<AppTone> all = [blue, orange, violet, green, pink, teal, sand, red];

  static AppTone byKey(String? key) {
    for (final t in all) {
      if (t.key == key) return t;
    }
    return blue;
  }

  /// يحوّل نص لون HEX (#RRGGBB) إلى نغمة مخصّصة بخلفية باستيل مشتقة.
  static AppTone fromHex(String? hex) {
    final h = (hex ?? '').trim().replaceAll('#', '');
    if (h.length != 6) return byKey(null);
    final v = int.tryParse(h, radix: 16);
    if (v == null) return byKey(null);
    final base = Color(0xFF000000 | v);
    return AppTone('custom', 'مخصص', _pastelize(base), base);
  }

  /// يخفف اللون إلى خلفية باستيل هادئة تحافظ على هوية اللون.
  static Color _pastelize(Color c) {
    final r = (c.r * 255).round();
    final g = (c.g * 255).round();
    final b = (c.b * 255).round();
    return Color.fromARGB(
      255,
      r + ((255 - r) * 0.86).round(),
      g + ((255 - g) * 0.86).round(),
      b + ((255 - b) * 0.86).round(),
    );
  }
}

/// ظلال نكسورا — ظلال ناعمة خفيفة جداً بدل الحدود السميكة.
class AppShadows {
  /// ظل بطاقة بالكاد يُرى — البديل الحديث للحدود السميكة.
  static List<BoxShadow> card(ColorScheme scheme) => [
        BoxShadow(
          color: scheme.primary.withValues(alpha: .05),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: .04),
          blurRadius: 6,
          offset: const Offset(0, 1),
        ),
      ];

  static List<BoxShadow> soft(bool dark) => [
        BoxShadow(
          color: dark
              ? Colors.black.withValues(alpha: .35)
              : const Color(0xFF0F1E32).withValues(alpha: .08),
          blurRadius: 18,
          offset: const Offset(0, 4),
        ),
      ];

  static List<BoxShadow> large(bool dark) => [
        BoxShadow(
          color: dark
              ? Colors.black.withValues(alpha: .5)
              : const Color(0xFF0F1E32).withValues(alpha: .16),
          blurRadius: 40,
          offset: const Offset(0, 14),
        ),
      ];
}

class AppTheme {
  static ThemeData light() => _build(false);
  static ThemeData dark() => _build(true);

  static ThemeData _build(bool dark) {
    final primary = dark ? AppColors.dPrimary : AppColors.primary;
    final bg = dark ? AppColors.dBg : AppColors.bg;
    final surface = dark ? AppColors.dSurface : AppColors.surface;
    final border = dark ? AppColors.dBorder : AppColors.border;
    final text = dark ? AppColors.dText : AppColors.text;
    final text2 = dark ? AppColors.dText2 : AppColors.text2;
    final danger = dark ? AppColors.dDanger : AppColors.danger;

    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: dark ? Brightness.dark : Brightness.light,
    ).copyWith(
      primary: primary,
      surface: surface,
      error: danger,
      outline: border,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: dark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      fontFamily: uiFontFamily,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: .5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: uiFontFamily,
          fontSize: 19,
          fontWeight: FontWeight.w700,
          color: text,
        ),
      ),
      textTheme: (dark ? ThemeData.dark() : ThemeData.light())
          .textTheme
          .apply(
            fontFamily: uiFontFamily,
            bodyColor: text,
            displayColor: text,
          )
          .copyWith(
            titleLarge: TextStyle(
              fontFamily: uiFontFamily,
              fontWeight: FontWeight.w700,
              color: text,
              fontSize: 18,
            ),
            titleMedium: TextStyle(
              fontFamily: uiFontFamily,
              fontWeight: FontWeight.w700,
              color: text,
              fontSize: 15.5,
            ),
            bodyLarge: TextStyle(
              fontFamily: uiFontFamily,
              color: text,
              fontSize: 16,
            ),
            bodyMedium: TextStyle(
              fontFamily: uiFontFamily,
              color: text,
              fontSize: 14.5,
            ),
            bodySmall: TextStyle(
              fontFamily: uiFontFamily,
              color: text2,
              fontSize: 12.5,
            ),
            labelLarge: TextStyle(
              fontFamily: uiFontFamily,
              fontWeight: FontWeight.w700,
              fontSize: 14.5,
            ),
          ),
      primaryTextTheme: (dark ? ThemeData.dark() : ThemeData.light())
          .primaryTextTheme
          .apply(fontFamily: uiFontFamily),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        // (2026-09-24) هوية حديثة: بلا حدود سميكة — ظل ناعم خفيف جداً
        // وزاوية موحّدة 16px على كل المنصات.
        elevation: 1,
        shadowColor: const Color(0xFF0D6EFD).withValues(alpha: .10),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide.none,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? AppColors.dSurface2 : AppColors.surface2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: BorderSide(color: primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: BorderSide(color: danger),
        ),
        labelStyle: TextStyle(color: text2),
        hintStyle: TextStyle(
          color: dark ? AppColors.dText3 : AppColors.text3,
          fontSize: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: dark ? const Color(0xFF06231F) : Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          textStyle: TextStyle(
            fontFamily: uiFontFamily,
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          textStyle: TextStyle(
            fontFamily: uiFontFamily,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: TextStyle(
            fontFamily: uiFontFamily,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: dark ? const Color(0xFF06231F) : Colors.white,
        elevation: 2,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: dark ? AppColors.dSurface2 : AppColors.surface2,
        selectedColor: dark ? AppColors.dPrimarySoft : AppColors.primarySoft,
        side: BorderSide(color: border),
        labelStyle: TextStyle(
          fontFamily: uiFontFamily,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
      ),
      // (2026-09-24) قاعدة الفواصل النظيفة الصارمة: خط فاصل واحد ناعم خفيف 1px بلا ازدواجية.
      dividerTheme: DividerThemeData(
        color: border.withValues(alpha: 0.5),
        thickness: 1,
        space: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        // (2026-09-24) التبويب النشط بكبسولة لونية هادئة (Stadium).
        indicatorColor: dark ? AppColors.dPrimarySoft : AppColors.primarySoft,
        indicatorShape: const StadiumBorder(),
        height: 68,
        elevation: 8,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
            fontFamily: uiFontFamily,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: text2,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? primary : text2,
            size: 23,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sheet),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: text2,
        textColor: text,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
      ),
    );
  }
}
