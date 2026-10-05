// مستند فاتورة البيع الحرارية (80مم) — وحدة مستقلة قابلة للاختبار.
//
// كانت تبنيتها داخل `pos_screen._printThermalInvoice` بـ `pw.Document()` **بلا
// أي خط**، فكانت كل فواتير البيع تخرج مربعات «▯»: الخط الافتراضي Helvetica لا
// يحمل حرفاً عربياً واحداً. نُقلت إلى هنا لسببين:
//   1. تطبيق خدمة الخطوط العربية (PdfFonts) واتجاه RTL على كل فاتورة.
//   2. إتاحة بناء المستند للاختبار الآلي (بند «اختبار إنشاء المعاينة»).
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'format.dart';
import 'models.dart';
import 'pdf_fonts.dart';
import '../data/sync/subscription_guard.dart' show kWatermarkText;

/// نتيجة بناء الفاتورة: المستند (للفحص) والبايتات (للطباعة/المشاركة).
class ThermalInvoiceDoc {
  const ThermalInvoiceDoc(this.document, this.bytes);

  final pw.Document document;

  /// بايتات PDF جاهزة للطباعة أو الحفظ أو المشاركة.
  final Uint8List bytes;
}

/// يبني فاتورة حرارية 80مم بخط عربي مدمج واتجاه من اليمين إلى اليسار.
///
/// * [orgName] اسم المتجر — يظهر بالخط العريض في رأس الفاتورة.
/// * [lines] سطور الأصنام (الاسم والكمية وسعر الوحدة والإجمالي).
/// * [stamp] يضيف سطر الختم الصغير أسفل التذييل للحساب المقيد.
Future<ThermalInvoiceDoc> buildThermalInvoiceDocument({
  required Tx tx,
  required Account? account,
  required List<InvoiceLine> lines,
  required String orgName,
  required String orgPhone,
  required String footer,
  bool stamp = false,
}) async {
  // (بند 2) تحميل الخط العربي قبل إنشاء المستند — مرة واحدة ومخبّأة.
  final fonts = await PdfFonts.load();

  final doc = pw.Document(
    // (بند 3) تعيين الخط في ثيم المستند: يورّثه لكل النصوص تلقائياً.
    theme: fonts.theme,
  );

  doc.addPage(
    pw.Page(
      pageTheme: pw.PageTheme(
        pageFormat: const PdfPageFormat(
          80 * PdfPageFormat.mm,
          double.infinity,
          marginAll: 4 * PdfPageFormat.mm,
        ),
        // (بند 4) اتجاه RTL على مستوى الصفحة: يضبط ترتيب الأحرف والأرقام
        // واتجاه الأعمدة في كل سطر، وليس فقط محاذاة النص.
        textDirection: pw.TextDirection.rtl,
        theme: fonts.theme,
      ),
      build: (pw.Context context) {
        // Directionality داخل الصفحة أيضاً: يحمي الأجزاء المضمّنة (مثل
        // الجداول) التي قد تتجاهل ثيم الصفحة في إصدارات الحزمة.
        return PdfFonts.rtl(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text(
                orgName,
                style: pw.TextStyle(
                  fontSize: 16,
                  font: fonts.bold,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              if (orgPhone.isNotEmpty)
                pw.Text(
                  'هاتف: $orgPhone',
                  style: const pw.TextStyle(fontSize: 10),
                ),
              pw.Divider(thickness: 1),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'فاتورة مبيعات',
                    style: pw.TextStyle(
                      font: fonts.bold,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text('#${tx.reference}'),
                ],
              ),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('التاريخ: ${Fmt.date(tx.date)}'),
                  pw.Text('الوقت: ${tx.date.hour}:${tx.date.minute}'),
                ],
              ),
              if (account != null)
                pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text('العميل: ${account.name}'),
                ),
              pw.Divider(thickness: 1),
              for (final item in lines) ...[
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Expanded(
                      child: pw.Text(
                        item.name,
                        style: const pw.TextStyle(fontSize: 10),
                      ),
                    ),
                    pw.Text(
                      '${item.quantity} × ${Fmt.money(item.unitPrice)} = ${Fmt.money(item.total)}',
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ],
              pw.Divider(thickness: 1),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'الإجمالي المطلوب:',
                    style: pw.TextStyle(
                      font: fonts.bold,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.Text(
                    '${Fmt.money(tx.amount)} ${tx.currency}',
                    style: pw.TextStyle(
                      font: fonts.bold,
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                footer,
                style: const pw.TextStyle(fontSize: 9),
                textAlign: pw.TextAlign.center,
              ),
              // الحراري 80مم يضيق عن ختم مائل مقروء — نكتفي بسطر ختم صغير
              // أسفل التذييل.
              if (stamp) ...[
                pw.SizedBox(height: 4),
                pw.Text(
                  kWatermarkText,
                  style: const pw.TextStyle(
                    fontSize: 7,
                    color: PdfColors.grey600,
                  ),
                  textAlign: pw.TextAlign.center,
                ),
              ],
            ],
          ),
        );
      },
    ),
  );

  return ThermalInvoiceDoc(doc, await doc.save());
}

/// بايتات PDF لفاتورة حرارية جاهزة للطباعة/المشاركة.
Future<Uint8List> buildThermalInvoicePdf({
  required Tx tx,
  required Account? account,
  required List<InvoiceLine> lines,
  required String orgName,
  required String orgPhone,
  required String footer,
  bool stamp = false,
}) async =>
    (await buildThermalInvoiceDocument(
      tx: tx,
      account: account,
      lines: lines,
      orgName: orgName,
      orgPhone: orgPhone,
      footer: footer,
      stamp: stamp,
    ))
        .bytes;
