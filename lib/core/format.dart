import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'accounting.dart';

/// تنسيق الأرقام والتواريخ.
class Fmt {
  static final _int = NumberFormat('#,##0', 'en');
  static final _two = NumberFormat('#,##0.00', 'en');
  static final _date = DateFormat('yyyy/MM/dd', 'en');
  static final _dateTime = DateFormat('yyyy/MM/dd  hh:mm a', 'en');
  static final _clock = DateFormat('hh:mm a', 'en');
  static final _month = DateFormat('MMMM yyyy', 'ar');
  static final _day = DateFormat('EEEE d MMMM', 'ar');

  /// مبلغ بعدد المنازل العشرية المناسب للعملة.
  static String money(double v, [int decimals = 0]) =>
      decimals > 0 ? _two.format(v) : _int.format(v);

  static String moneyFor(double v, CurrencyDef c) => money(v, c.decimal);

  // ══════ (سلامة الحساب المالي) تقريب ومقارنة بتسامح ══════

  /// تسامح المقارنة بين مبلغين: يمنع قبولاً أو رفضاً خاطئاً ناتجاً عن
  /// أخطاء الفاصلة العائمة (0.1 + 0.2 = 0.30000000000000004).
  static const double moneyEpsilon = 0.0001;

  /// تقريب مبلغ إلى منازل عملته — يُطبَّق على كل ناتج حسابي **مجموع**
  /// (أرصدة تراكمية، مجاميع تقارير) قبل عرضه أو مقارنته، فيمنع أرصدة
  /// مثل 9.99999999999998 بدل 10.00.
  /// القيم غير المنتهية (NaN/Infinity) تُردّ إلى صفر بدل أن تتفشى في
  /// كل الحسابات اللاحقة.
  static double roundMoney(double v, [int decimals = 2]) {
    if (!v.isFinite) return 0;
    final d = decimals < 0
        ? 0
        : (decimals > 6 ? 6 : decimals);
    return double.parse(v.toStringAsFixed(d));
  }

  /// هل المبلغان متساويان حسابيّاً (بتسامح)؟
  static bool sameMoney(double a, double b) => (a - b).abs() <= moneyEpsilon;

  /// هل `a` أكبر من `b` بفارق يُعتدّ به (بتسامح)؟
  static bool moneyGt(double a, double b) => (a - b) > moneyEpsilon;

  /// هل `a` أصغر من `b` بفارق يُعتدّ به (بتسامح)؟
  static bool moneyLt(double a, double b) => (b - a) > moneyEpsilon;

  /// مبلغ مع رمز العملة.
  static String withSymbol(double v, CurrencyDef c) =>
      '${money(v, c.decimal)} ${c.symbol}';

  static String date(DateTime d) => _date.format(d);
  static String dateTime(DateTime d) => _dateTime.format(d);

  /// (دفعة 58 — متطلب 10) وقت التنفيذ فقط HH:MM — يظهر بجانب التاريخ
  /// في بطاقات العمليات.
  static String clock(DateTime d) => _clock.format(d);
  static String month(DateTime d) => _month.format(d);
  static String day(DateTime d) => _day.format(d);

  /// تحويل الأرقام العربية إلى إنجليزية ثم التحليل.
  ///
  /// يعيد null للمدخل غير الصالح بدل أن يرمي، فالحقول تعتمد عليه.
  static double? parseAmount(String s) {
    if (s.trim().isEmpty) return null;
    const ar = '٠١٢٣٤٥٦٧٨٩';
    const fa = '۰۱۲۳۴۵۶۷۸۹';
    final b = StringBuffer();
    bool seenDot = false;
    for (final ch in s.trim().split('')) {
      final ai = ar.indexOf(ch);
      final fi = fa.indexOf(ch);
      if (ai >= 0) {
        b.write(ai);
      } else if (fi >= 0) {
        b.write(fi);
      } else if (ch == '٫') {
        // الفاصلة العربية (فاصل عشري) → نقطة.
        if (seenDot) return null;
        b.write('.');
        seenDot = true;
      } else if (ch == ',' || ch == '٬') {
        // فاصل الآلاف الأوروبي: يُحذف.
        continue;
      } else if (ch == '.') {
        if (seenDot) return null;
        b.write('.');
        seenDot = true;
      } else {
        b.write(ch);
      }
    }
    final v = double.tryParse(b.toString());
    if (v == null || v.isNaN || v.isInfinite) return null;
    return v;
  }

  /// أرقام الهاتف: تُترك الأرقام فقط مع علامة + البادئة.

  /// وقت نسبي بالعربية — نقل حرفي لـ `relTime` في نسخة الويب.
  static String relative(DateTime d) {
    final diff = DateTime.now().difference(d);
    final s = diff.inSeconds;
    if (s < 60) return 'الآن';
    if (s < 3600) return 'قبل ${diff.inMinutes} دقيقة';
    if (s < 86400) return 'قبل ${diff.inHours} ساعة';
    if (s < 2592000) return 'قبل ${diff.inDays} يوم';
    return date(d);
  }

  static String phoneDigits(String s) {
    final d = s.replaceAll(RegExp(r'[^\d+]'), '');
    return d.startsWith('+') ? '+${d.substring(1).replaceAll('+', '')}' : d;
  }

  // ==================== البحث العربي الذكي ====================

  static final _diacritics = RegExp('[\u064B-\u0652\u0670\u0640]');

  /// تطبيع عربي للبحث: إزالة التشكيل والتطويل، توحيد الهمزات
  /// (أ/إ/آ/ٱ → ا)، (ة → ه)، (ى/ئ → ي)، (ؤ → و)، وأرقام عربية → إنجليزية.
  static String normArabic(String s) {
    var t = s.toLowerCase().replaceAll(_diacritics, '');
    const map = {
      'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا',
      'ة': 'ه',
      'ى': 'ي', 'ئ': 'ي',
      'ؤ': 'و',
    };
    map.forEach((k, v) => t = t.replaceAll(k, v));
    const ar = '٠١٢٣٤٥٦٧٨٩';
    const fa = '۰۱۲۳۴۵۶۷۸۹';
    for (var i = 0; i < 10; i++) {
      t = t.replaceAll(ar[i], '$i').replaceAll(fa[i], '$i');
    }
    return t.trim();
  }

  /// هل الاستعلام رقمي بحت؟ (بعد تحويل الأرقام العربية) — يوجه البحث
  /// نحو SKU / الهاتف / المبالغ بدل الأسماء.
  static bool isNumericQuery(String s) {
    final n = normArabic(s).replaceAll(RegExp(r'[\s,+\-.]'), '');
    return n.isNotEmpty && RegExp(r'^\d+$').hasMatch(n);
  }

  /// مطابقة ذكية: تطبيع عربي للطرفين ثم احتواء.
  static bool smartContains(String haystack, String query) {
    final q = normArabic(query);
    if (q.isEmpty) return true;
    return normArabic(haystack).contains(q);
  }

  /// رقم دولي لواتساب: يمني بلا صفر بادئ ← 967…
  static String waNumber(String s) {
    const ar = '٠١٢٣٤٥٦٧٨٩';
    var clean = s;
    for (var i = 0; i < ar.length; i++) {
      clean = clean.replaceAll(ar[i], '$i');
    }
    var d = clean.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('00')) d = d.substring(2);
    if (d.startsWith('967')) return d;
    if (d.startsWith('0')) d = d.replaceFirst(RegExp(r'^0+'), '');
    if (d.length == 9) return '967$d';
    return d;
  }
}

/// فواصل آلاف حيّة أثناء الكتابة في حقول المبالغ: 1000000 → 1,000,000
/// يحافظ على موضع المؤشر ويقبل الأرقام العربية (تُحوَّل للإنجليزية فوراً).
class ThousandsFormatter extends TextInputFormatter {
  const ThousandsFormatter();

  static final _grouper = NumberFormat('#,##0', 'en');

  /// إزالة الفواصل قبل التحليل — قيمة الحقل النقية.
  static String strip(String s) => s.replaceAll(',', '');

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    var text = newValue.text;
    // أرقام عربية/فارسية → إنجليزية.
    const ar = '٠١٢٣٤٥٦٧٨٩';
    const fa = '۰۱۲۳۴۵۶۷۸۹';
    for (var i = 0; i < 10; i++) {
      text = text.replaceAll(ar[i], '$i').replaceAll(fa[i], '$i');
    }
    text = text.replaceAll('٫', '.').replaceAll('٬', '');
    // تجاهل أي محارف غير رقمية عدا النقطة العشرية الأولى.
    final raw = strip(text);
    if (raw.isEmpty) return newValue.copyWith(text: '');
    if (!RegExp(r'^\d*\.?\d*$').hasMatch(raw)) return oldValue;
    final dot = raw.indexOf('.');
    final intPart = dot < 0 ? raw : raw.substring(0, dot);
    final decPart = dot < 0 ? '' : raw.substring(dot);
    final groupedInt =
        intPart.isEmpty ? '' : _grouper.format(int.parse(intPart));
    final out = '$groupedInt$decPart';
    return TextEditingValue(
      text: out,
      selection: TextSelection.collapsed(offset: out.length),
    );
  }
}
