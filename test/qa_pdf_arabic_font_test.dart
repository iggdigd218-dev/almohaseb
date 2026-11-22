// QA — ترميز الخط العربي في ملفات PDF (2026-09-24).
//
// الخلل: الخط الافتراضي في حزمة `pdf` هو Helvetica ولا يحمل أي حرف عربي،
// فكل نص عربي يُرسم به يخرج مربعات «▯» أو إشارات «×». وكان مستند فاتورة
// نقطة البيع يُنشأ بـ `pw.Document()` **بلا ثيم ولا خط** إطلاقاً.
//
// العقد بعد الإصلاح:
//  • مصدر واحد لتحميل الخطوط العربية: PdfFonts (مع تخزين مؤقت).
//  • كل مستند PDF: ثيم بالخط العربي + اتجاه RTL.
//  • لا حرف عربي بلا رسم (glyph) في الخط المدمج = لا مربعات.
//  • لا خط لاتيني افتراضي (Helvetica/Courier/Times) في أي مستند.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:nexora_app/core/pdf_fonts.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Fmt.date يستخدم DateFormat المحلي — بلا هذه التهيئة يرمي
    // LocaleDataException أثناء بناء المستند.
    await initializeDateFormatting('ar');
  });

  // نصوص فاتورة حقيقية: اسم متجر، عميل، صنف، إجمالي، تذييل، أرقام وترقيم.
  const invoiceTexts = <String>[
    'متجر النخبة للتجارة',
    'فاتورة مبيعات',
    'العميل: عبدالله محمد حسين',
    'زيت نباتي 1 لتر',
    'الإجمالي المطلوب: 12,500 ريال يمني',
    'شكراً لزيارتكم!',
    'التاريخ: 24/09/2026',
  ];

  test('ARF-01 الملفان معلنان في pubspec وموجودان على القرص', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('assets/fonts/'),
        reason: 'بدون إعلان المجلد لا يجد rootBundle أي ملف خط');

    for (final path in <String>[kPdfFontRegularAsset, kPdfFontBoldAsset]) {
      final f = File(path);
      expect(f.existsSync(), isTrue, reason: 'ملف الخط مفقود: $path');
      // خط TTF سليم ≥ 10KB (الملفات التالفة/الفارغة تُسكت الخط بلا إنذار).
      expect(f.lengthSync(), greaterThan(10 * 1024), reason: 'حجم $path');
      final head = f.openSync().readSync(4);
      expect(head[0], 0x00, reason: '$path ليس TTF صالحاً');
    }
  });

  // ============ 2) خدمة الخطوط ============
  test('ARF-02 PdfFonts تحمّل الخطين وتخزّنهما مؤقتاً', () async {
    PdfFonts.resetCacheForTest();
    final first = await PdfFonts.load();
    final second = await PdfFonts.load();
    expect(identical(first, second), isTrue,
        reason: 'التخزين المؤقت يمنع إعادة قراءة 330KB عند كل طباعة');
    expect(first.base, isNot(same(first.bold)), reason: 'الخطان مختلفان');

    final theme = await PdfFonts.theme();
    expect(theme, isNotNull);
  });

  test('ARF-03 PdfFonts.rtl يغلّف المحتوى باتجاه RTL', () async {
    final widget = PdfFonts.rtl(child: pw.Text('مرحباً'));
    expect(widget, isA<pw.Directionality>());
    expect((widget as pw.Directionality).textDirection,
        pw.TextDirection.rtl);
  });

  // ============ 3) لا حروف مفقودة (جوهر «لا مربعات») ============
  test('ARF-04 كل حرف في نصوص الفاتورة له رسم (glyph) في الخط العربي',
      () async {
    for (final asset in <String>[kPdfFontRegularAsset, kPdfFontBoldAsset]) {
      final parser = TtfParser(await rootBundle.load(asset));
      final missing = <String>[];

      for (final text in invoiceTexts) {
        for (final unit in text.codeUnits) {
          final glyph = parser.charToGlyphIndexMap[unit];
          // غياب الحرف عن خريطة cmap = .notdef = مربع «▯» في الملف.
          if (glyph == null || glyph == 0) {
            missing.add(
                '${String.fromCharCode(unit)} (U+${unit.toRadixString(16).toUpperCase()})');
          }
        }
      }
      // الأرقام العربية وأهم علامات الترقيم المستعملة في الفواتير.
      for (final unit in '٠١٢٣٤٥٦٧٨٩٪:×/-.,'.codeUnits) {
        if (parser.charToGlyphIndexMap[unit] == null) {
          missing.add(String.fromCharCode(unit));
        }
      }

      expect(missing, isEmpty,
          reason: 'حروف بلا رسم في $asset ⇒ ستظهر مربعات: '
              '${missing.toSet().join(' ')}');
    }
  });



  // ============ 6) حارس مصدر: لا رجوع إلى مستند بلا خط ============
  test('ARF-07 كل مستندات PDF تستخدم خدمة الخطوط واتجاه RTL', () {
    final files = <String>[
      'lib/ui/voucher_doc.dart',
      'lib/ui/reports_screen.dart',
    ];
    for (final path in files) {
      final src = File(path).readAsStringSync();
      // السند والتقارير يستدعيان خدمة الخطوط مباشرة.
      final usesFontService = src.contains('PdfFonts');
      expect(usesFontService, isTrue,
          reason: '$path لا يستخدم خدمة الخطوط العربية');

      expect(src.contains('pw.TextDirection.rtl'), isTrue,
          reason: '$path بلا اتجاه RTL');
    }
  });

  test('ARF-08 أي ملف ينشئ مستند PDF يمرّر ثيماً عربياً (حارس ديناميكي)', () {
    final lib = Directory('lib');
    final offenders = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      if (!src.contains('package:pdf/widgets.dart')) continue;

      // تعليقات الشيفرة لا تُحسب: النص `pw.Document()` داخل شرح مسموح.
      final code = src.replaceAll(RegExp(r'//.*'), '');
      if (!code.contains('pw.Document(')) continue; // لا ينشئ مستنداً

      if (code.contains('pw.Document()')) {
        offenders.add('${entity.path}: pw.Document() بلا ثيم');
      } else if (!code.contains('theme:')) {
        offenders.add('${entity.path}: مستند بلا theme');
      }
    }
    expect(offenders, isEmpty,
        reason: 'مستند بلا ثيم = خط Helvetica = حروف عربية مربعة:\n'
            '${offenders.join('\n')}');
  });
}
