// خدمة الخطوط العربية لمستندات PDF — المصدر الوحيد لتحميل خطوط الطباعة.
//
// المشكلة التي يعالجها هذا الملف:
//   الخط الافتراضي في حزمة `pdf` هو Helvetica، ولا يحمل **أي حرف عربي**.
//   فكل نص عربي يُرسم به يخرج مربعات «▯» أو إشارات «×» في المعاينة والطباعة.
//   يكفي تعيين الخط على `pw.Document`/`pw.PageTheme` مرة واحدة ليُدمَج ملف
//   الخط داخل PDF ويُقرأ على أي جهاز — بلا خطوط مثبتة ولا إنترنت.
//
// قبل هذا الملف كان التحميل مكرراً في voucher_doc وreports، **وغائباً تماماً**
// عن فاتورة نقطة البيع (أكثر ما يطبعه المستخدم)، فكانت كل فواتير البيع تخرج
// مربعات. الآن: نقطة تحميل واحدة، تخزين مؤقت، ورسالة خطأ صريحة بدل PDF صامت
// بلا حروف عربية.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pdf/widgets.dart' as pw;

/// مسار الخط العربي العادي المدمج (Cairo — رخصة OFL-1.1).
const String kPdfFontRegularAsset = 'assets/fonts/Cairo-Regular.ttf';

/// مسار الخط العربي العريض المدمج (Cairo Bold).
const String kPdfFontBoldAsset = 'assets/fonts/Cairo-Bold.ttf';

/// حزمة خطوط جاهزة للاستخدام في بناء أي مستند PDF.
class PdfArabicFonts {
  const PdfArabicFonts({required this.base, required this.bold});

  /// خط النصوص العادية.
  final pw.Font base;

  /// خط العناوين والأرقام البارزة.
  final pw.Font bold;

  /// ثيم المستند: الخط الأساس والعريض معاً.
  ///
  /// تمريره إلى `pw.Document(theme: …)` أو `pw.PageTheme(theme: …)` يكفي
  /// لتوريث الخط العربي إلى كل نصوص الصفحة بلا تكرار `font:` في كل `pw.Text`.
  pw.ThemeData get theme => pw.ThemeData.withFont(base: base, bold: bold);
}

/// محمّل الخطوط العربية مع تخزين مؤقت للعملية.
///
/// ملفات TTF تُقرأ مرة واحدة فقط (≈330KB للخطين) وتُعاد في كل طباعة تالية،
/// فلا انتظار ولا هدر ذاكرة عند طباعة دفعة فواتير متتالية.
class PdfFonts {
  PdfFonts._();

  static PdfArabicFonts? _cache;

  /// يحمّل خطي الطباعة (أو يعيدهما من الذاكرة).
  ///
  /// يرمي [FlutterError] **صراحةً** إذا تعذّر التحميل: PDF بلا خط عربي ليس
  /// «تدهوراً مقبولاً» بل مستند غير مقروء، فيُفضّل أن يفشل مبكراً بسبب واضح
  /// على أن يُطبع للمستخدم صفقة مربعات.
  static Future<PdfArabicFonts> load() async {
    final cached = _cache;
    if (cached != null) return cached;

    pw.Font base;
    pw.Font bold;
    try {
      final regularData = await rootBundle.load(kPdfFontRegularAsset);
      final boldData = await rootBundle.load(kPdfFontBoldAsset);
      base = pw.Font.ttf(regularData);
      bold = pw.Font.ttf(boldData);
    } catch (e) {
      throw FlutterError(
        'تعذّر تحميل الخط العربي للطباعة:\n'
        '  • $kPdfFontRegularAsset\n'
        '  • $kPdfFontBoldAsset\n'
        'السبب: $e\n'
        'بدون هذا الخط تظهر الحروف العربية في ملف PDF على شكل مربعات «▯».\n'
        'تأكد من وجود الملفين ومن إعلان المجلد تحت flutter: assets: في pubspec.yaml.',
      );
    }

    return _cache = PdfArabicFonts(base: base, bold: bold);
  }

  /// ثيم RTL جاهز للإسناد المباشر (خطوط عربية + اتجاه من اليمين لليسار).
  ///
  /// `textDirection: rtl` ضروري وليس تحسيناً شكلياً: بدونه تُقلب العناوين
  /// المركّبة (مثل «الإجمالي: 12,000») وترتيب الأعمدة في الجداول.
  static Future<pw.ThemeData> theme() async => (await load()).theme;

  /// يغلّف أي محتوى باتجاه من اليمين إلى اليسار.
  static pw.Widget rtl({required pw.Widget child}) => pw.Directionality(
        textDirection: pw.TextDirection.rtl,
        child: child,
      );

  /// تفريغ الذاكرة المؤقتة (للاختبارات فقط).
  static void resetCacheForTest() => _cache = null;
}
