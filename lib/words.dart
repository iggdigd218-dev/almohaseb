/// تحويل المبلغ إلى كلمات عربية — «إظهار المبلغ كتابة عند الإضافة»
String amountInWords(double amount, String currencyKey) {
  final unit = {
        'local': 'ريال',
        'dollar': 'دولار',
        'saudi': 'ريال سعودي',
      }[currencyKey] ??
      'ريال';
  final abs = amount.abs();
  final whole = abs.floor();
  final frac = ((abs - whole) * 100).round();
  var s = _intWords(whole);
  if (frac > 0) {
    s = '$s و ${_intWords(frac)}';
  }
  return '$s $unit فقط لا غير';
}

String _intWords(int n) {
  if (n == 0) return 'صفر';
  final ones = [
    '', 'واحد', 'اثنان', 'ثلاثة', 'أربعة', 'خمسة', 'ستة', 'سبعة', 'ثمانية', 'تسعة',
    'عشرة', 'أحد عشر', 'اثنا عشر', 'ثلاثة عشر', 'أربعة عشر', 'خمسة عشر',
    'ستة عشر', 'سبعة عشر', 'ثمانية عشر', 'تسعة عشر'
  ];
  final tens = [
    '', '', 'عشرون', 'ثلاثون', 'أربعون', 'خمسون', 'ستون', 'سبعون', 'ثمانون', 'تسعون'
  ];
  const hundreds = [
    '', 'مائة', 'مائتان', 'ثلاثمائة', 'أربعمائة', 'خمسمائة',
    'ستمائة', 'سبعمائة', 'ثمانمائة', 'تسعمائة'
  ];
  final parts = <String>[];

  final billions = n ~/ 1000000000;
  n %= 1000000000;
  final millions = n ~/ 1000000;
  n %= 1000000;
  final thousands = n ~/ 1000;
  n %= 1000;

  if (billions > 0) {
    parts.add(billions == 1
        ? 'مليار'
        : billions == 2
            ? 'ملياران'
            : '${_intWords(billions)} مليارات');
  }
  if (millions > 0) {
    parts.add(millions == 1
        ? 'مليون'
        : millions == 2
            ? 'مليونان'
            : '${_intWords(millions)} ملايين');
  }
  if (thousands > 0) {
    parts.add(thousands == 1
        ? 'ألف'
        : thousands == 2
            ? 'ألفان'
            : '${_intWords(thousands)} آلاف');
  }

  final h = n ~/ 100;
  final rest = n % 100;
  if (h > 0) parts.add(hundreds[h]);
  if (rest > 0) {
    if (rest < 20) {
      parts.add(ones[rest]);
    } else {
      final o = rest % 10;
      final t = rest ~/ 10;
      parts.add(o > 0 ? '${ones[o]} و ${tens[t]}' : tens[t]);
    }
  }
  return parts.join(' و ');
}
