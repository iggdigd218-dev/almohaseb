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
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/pdf_fonts.dart';
import 'package:nexora_app/core/thermal_invoice_doc.dart';

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

  Tx sampleTx() => Tx(
        id: 1,
        accountId: 7,
        type: OpType.revenue,
        amount: 12500,
        currency: 'YER',
        date: DateTime(2026, 9, 24, 10, 30),
        reference: '1024',
        description: 'فاتورة مبيعات',
        createdAt: DateTime(2026, 9, 24),
        updatedAt: DateTime(2026, 9, 24),
      );

  Account sampleAccount() => Account(
        id: 7,
        name: 'عبدالله محمد حسين',
        kind: AccountKind.customer,
        currency: 'YER',
        createdAt: DateTime(2026, 9, 24),
        updatedAt: DateTime(2026, 9, 24),
      );

  List<InvoiceLine> sampleLines() => const <InvoiceLine>[
        InvoiceLine(
          name: 'زيت نباتي 1 لتر',
          unit: 'لتر',
          quantity: 3,
          unitPrice: 1500,
        ),
        InvoiceLine(
          name: 'أرز بسمتي 5 كجم',
          unit: 'كجم',
          quantity: 2,
          unitPrice: 4000,
        ),
      ];

  // ============ 1) الأصول ============
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

  // ============ 4) مستند فاتورة نقطة البيع ============
  test('ARF-05 فاتورة نقطة البيع: خط عربي مدمج ولا خط لاتيني افتراضي',
      () async {
    PdfFonts.resetCacheForTest();
    final doc = await buildThermalInvoiceDocument(
      tx: sampleTx(),
      account: sampleAccount(),
      lines: sampleLines(),
      orgName: 'متجر النخبة للتجارة',
      orgPhone: '777123456',
      footer: 'شكراً لزيارتكم!',
    );

    // الخط الذي تحمّله الخدمة هو نفسه المدمج في المستند — نتحقق من هويته
    // العربية من ملف TTF نفسه (Cairo) قبل فحص أثره داخل البايتات.
    final parser = TtfParser(await rootBundle.load(kPdfFontRegularAsset));
    expect(parser.fontName, contains('Cairo'),
        reason: 'الخط الأساس ليس عربياً: ${parser.fontName}');
    expect(parser.unicode, isTrue,
        reason: 'الخط بلا خريطة يونيكود ⇒ لا يمكن ترميز العربية');

    // لا خط افتراضي من عائلة Helvetica/Courier/Times في أي مكان بالمستند:
    // وجوده يعني نصاً عربياً بلا خط (بالضبط سبب المربعات).
    final raw = latin1.decode(doc.bytes, allowInvalid: true);
    for (final latinFont in <String>[
      'Helvetica',
      'Courier',
      'Times',
      'ZapfDingbats'
    ]) {
      expect(raw, isNot(contains('/$latinFont')),
          reason: 'يستخدم الخط اللاتيني $latinFont ⇒ حروف عربية مفقودة');
    }
    expect(raw, contains('Cairo'), reason: 'الخط العربي غير مذكور في الملف');
    expect(raw, contains('Identity-H'),
        reason: 'الخط ليس بترميز Identity-H (نص يونيكود ثنائي البايت)');
    expect(raw, contains('FontFile2'), reason: 'ملف الخط غير مضمّن في PDF');
    // الخط مُضمَّن كمجموعة فرعية مضغوطة (FontFile2) فالملف يبقى صغيراً؛
    // ملف بلا خط مدمج يقلّ عن 3KB عادةً.
    expect(doc.bytes.length, greaterThan(8 * 1024),
        reason: 'الملف صغير جداً: الخط المدمج غائب على الأرجح');
  });

  // ============ 5) المعاينة تحفظ النص العربي كما هو ============
  test('ARF-06 بايتات الفاتورة قابلة للحفظ وتبدأ بتوقيع PDF صالح', () async {
    final bytes = await buildThermalInvoicePdf(
      tx: sampleTx(),
      account: sampleAccount(),
      lines: sampleLines(),
      orgName: 'متجر النخبة',
      orgPhone: '777123456',
      footer: 'شكراً لزيارتكم!',
      stamp: true,
    );
    expect(bytes.lengthInBytes, greaterThan(8 * 1024));
    expect(latin1.decode(bytes.take(5).toList()), startsWith('%PDF-'));
    expect(latin1.decode(bytes, allowInvalid: true), contains('%%EOF'));
  });

  // ============ 6) حارس مصدر: لا رجوع إلى مستند بلا خط ============
  test('ARF-07 كل مستندات PDF تستخدم خدمة الخطوط واتجاه RTL', () {
    final files = <String>[
      'lib/ui/pos_screen.dart',
      'lib/ui/voucher_doc.dart',
      'lib/ui/reports_screen.dart',
    ];
    for (final path in files) {
      final src = File(path).readAsStringSync();
      // نقطة البيع تبني الفاتورة عبر thermal_invoice_doc (الذي يستخدم
      // الخدمة مباشرة)؛ السند والتقارير يستدعيانها مباشرة.
      final usesFontService =
          src.contains('PdfFonts') || src.contains('buildThermalInvoicePdf');
      expect(usesFontService, isTrue,
          reason: '$path لا يستخدم خدمة الخطوط العربية');

      // RTL قد يكون في الشاشة نفسها أو في وحدة المستند التي تستدعيها.
      final sources = <String>[src];
      if (src.contains('buildThermalInvoicePdf')) {
        sources
            .add(File('lib/core/thermal_invoice_doc.dart').readAsStringSync());
      }
      expect(sources.any((s) => s.contains('pw.TextDirection.rtl')), isTrue,
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
