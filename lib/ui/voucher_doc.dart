import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/pdf_fonts.dart';
import '../core/words.dart';
import '../data/sync/subscription_guard.dart' show kWatermarkText;

/// بيانات المؤسسة المطبوعة على السند — تأتي من الإعدادات.
class OrgInfo {
  final String name;
  final String nameEn;
  final String address;
  final String phone;
  final String email;
  final String managerName;
  final String logoPath;
  final String footer;

  const OrgInfo({
    this.name = 'مؤسسة',
    this.nameEn = '',
    this.address = '',
    this.phone = '',
    this.email = '',
    this.managerName = '',
    this.logoPath = '',
    this.footer = 'هذا السند آلي ولا يحتاج إلى ختم أو توقيع.',
  });

  factory OrgInfo.fromSettings(Map<String, String> s) => OrgInfo(
        name: s['businessName']?.trim().isNotEmpty == true
            ? s['businessName']!
            : 'مؤسسة',
        nameEn: s['businessNameEn'] ?? '',
        address: s['address'] ?? '',
        phone: [
          s['phone'],
          s['whatsapp'],
        ].where((e) => e != null && e.trim().isNotEmpty).join(' — '),
        email: s['email'] ?? '',
        managerName: s['managerName'] ?? '',
        logoPath: s['logo'] ?? '',
        footer: s['voucherFooter']?.trim().isNotEmpty == true
            ? s['voucherFooter']!
            : 'هذا السند آلي ولا يحتاج إلى ختم أو توقيع.',
      );
}

/// يبني ملف PDF بمقاس A4 للسند — نفس تخطيط `voucherHTML` في نسخة الويب.
Future<Uint8List> buildVoucherPdf({
  required Voucher v,
  required Account? account,
  required CurrencyDef currency,
  required OrgInfo org,
  bool stamp = false,
}) async {
  // (2026-09-24) تحميل موحّد عبر خدمة الخطوط: مصدر واحد، تخزين مؤقت،
  // ورسالة خطأ صريحة إن تعذّر التحميل بدل PDF صامت بلا حروف عربية.
  final fonts = await PdfFonts.load();
  final regular = fonts.base;
  final bold = fonts.bold;

  pw.MemoryImage? logo;
  if (org.logoPath.trim().isNotEmpty) {
    try {
      final file = File(org.logoPath);
      if (await file.exists()) {
        logo = pw.MemoryImage(await file.readAsBytes());
      }
    } catch (_) {
      // شعار غير صالح لا يمنع إنشاء السند.
    }
  }

  final doc = pw.Document(
    // الثيم على المستند نفسه: يضمن الخط العربي لأي صفحة تُضاف لاحقاً
    // حتى لو لم تُعيّن pageTheme صراحةً.
    theme: fonts.theme,
  );
  const brand = PdfColor.fromInt(0xFF0D6EFD);
  const border = PdfColor.fromInt(0xFFE2E8F2);
  const soft = PdfColor.fromInt(0xFFE8F0FF);
  const muted = PdfColor.fromInt(0xFF5B6B83);
  // لون المبلغ حسب نوع السند: أحمر لمدين/صرف (عليه)، أخضر لقبض/دائن (له).
  final isRed = v.kind == VoucherKind.debit || v.kind == VoucherKind.payment;
  final isGreen = v.kind == VoucherKind.receipt || v.kind == VoucherKind.credit;
  final amtColor = isRed
      ? const PdfColor.fromInt(0xFFC0392B)
      : (isGreen ? const PdfColor.fromInt(0xFF16A34A) : brand);
  final amtBg = isRed
      ? const PdfColor.fromInt(0xFFFDECEA)
      : (isGreen ? const PdfColor.fromInt(0xFFEAF7EF) : soft);

  final words = '${numberToWords(v.amount)} ${currency.name}';

  pw.Widget line(String k, String val) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 5),
        child: pw.Row(
          children: [
            pw.SizedBox(
              width: 110,
              child: pw.Text(
                k,
                style: const pw.TextStyle(fontSize: 10, color: muted),
              ),
            ),
            pw.Expanded(
              child:
                  pw.Text(val, style: pw.TextStyle(fontSize: 11, font: bold)),
            ),
          ],
        ),
      );

  pw.Widget infoCell(String k, String val) => pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: border),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text(k,
                  style: const pw.TextStyle(fontSize: 8.5, color: muted)),
              pw.SizedBox(height: 3),
              pw.Text(val, style: pw.TextStyle(fontSize: 11, font: bold)),
            ],
          ),
        ),
      );

  pw.Widget sig(String label) => pw.Expanded(
        child: pw.Column(
          children: [
            pw.Container(
              height: 1,
              margin: const pw.EdgeInsets.only(bottom: 6),
              color: border,
            ),
            pw.Text(label,
                style: const pw.TextStyle(fontSize: 9, color: muted)),
          ],
        ),
      );

  doc.addPage(
    pw.Page(
      // (دفعة 65-ب) ختم مائي مائل بخلفية الصفحة للحساب المقيد — شفاف
      // فلا يحجب أرقام السند، ويظهر في الطباعة والمشاركة معاً.
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        theme: pw.ThemeData.withFont(base: regular, bold: bold),
        margin: const pw.EdgeInsets.all(32),
        buildBackground: stamp
            ? (ctx) => pw.Watermark.text(
                  kWatermarkText,
                  angle: 0.6,
                  style: pw.TextStyle(
                    font: bold,
                    fontSize: 22,
                    color: const PdfColor(0.06, 0.46, 0.43, 0.12),
                  ),
                )
            : null,
      ),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // ترويسة المؤسسة
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      org.name,
                      style: pw.TextStyle(
                        fontSize: 20,
                        font: bold,
                        color: brand,
                      ),
                    ),
                    if (org.nameEn.isNotEmpty)
                      pw.Text(
                        org.nameEn,
                        style: pw.TextStyle(fontSize: 10, font: bold),
                      ),
                    if (org.address.isNotEmpty)
                      pw.Text(
                        org.address,
                        style: const pw.TextStyle(fontSize: 9, color: muted),
                      ),
                    if (org.phone.isNotEmpty)
                      pw.Text(
                        org.phone,
                        style: const pw.TextStyle(fontSize: 9, color: muted),
                      ),
                    if (org.email.isNotEmpty)
                      pw.Text(
                        org.email,
                        style: const pw.TextStyle(fontSize: 9, color: muted),
                      ),
                  ],
                ),
              ),
              if (logo != null) ...[
                pw.Container(
                  width: 62,
                  height: 62,
                  padding: const pw.EdgeInsets.all(6),
                  decoration: pw.BoxDecoration(
                    color: PdfColors.white,
                    border: pw.Border.all(color: border),
                    borderRadius: pw.BorderRadius.circular(10),
                  ),
                  alignment: pw.Alignment.center,
                  child: pw.Image(logo, fit: pw.BoxFit.contain),
                ),
                pw.SizedBox(width: 8),
              ],
              pw.Container(
                width: 62,
                height: 62,
                decoration: pw.BoxDecoration(
                  color: soft,
                  borderRadius: pw.BorderRadius.circular(10),
                ),
                alignment: pw.Alignment.center,
                child: pw.Text(
                  v.kind.label.split(' ').last,
                  style: pw.TextStyle(font: bold, fontSize: 12, color: brand),
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 14),
          pw.Container(height: 2, color: brand),
          pw.SizedBox(height: 14),

          // شريط المعلومات
          pw.Row(
            children: [
              infoCell('التاريخ', Fmt.date(v.date)),
              pw.SizedBox(width: 8),
              infoCell('رقم السند', v.number),
              pw.SizedBox(width: 8),
              infoCell('نوع السند', v.kind.label),
            ],
          ),
          pw.SizedBox(height: 16),

          // تفاصيل الحساب
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: border),
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Column(
              children: [
                line('اسم الحساب', account?.name ?? '—'),
                if (account != null && account.phone.isNotEmpty)
                  line('رقم الهاتف', account.phone),
                line('رقم الحساب', account?.id?.toString() ?? '—'),
                if (v.statement.isNotEmpty) line('بيان العملية', v.statement),
                line('العملة', '${currency.name} (${currency.symbol})'),
              ],
            ),
          ),
          // صندوق المبلغ
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.symmetric(vertical: 16),
            decoration: pw.BoxDecoration(
              color: amtBg,
              borderRadius: pw.BorderRadius.circular(10),
            ),
            child: pw.Column(
              children: [
                pw.Text(
                  '${Fmt.money(v.amount, currency.decimal)} ${currency.symbol}',
                  style: pw.TextStyle(
                    fontSize: 26,
                    font: bold,
                    color: amtColor,
                  ),
                ),
                pw.SizedBox(height: 6),
                pw.Text(
                  'فقط: $words لا غير',
                  style: pw.TextStyle(fontSize: 11, font: bold),
                ),
              ],
            ),
          ),

          if (v.notes.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: border),
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Text(
                'ملاحظات: ${v.notes}',
                style: const pw.TextStyle(fontSize: 10),
              ),
            ),
          ],

          pw.Spacer(),

          // التواقيع
          pw.Row(
            children: [
              sig('اسم المستلم'),
              pw.SizedBox(width: 18),
              sig('توقيع المستلم'),
              pw.SizedBox(width: 18),
              sig('توقيع المسؤول: ${org.managerName}'),
            ],
          ),
          pw.SizedBox(height: 16),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              color: const PdfColor.fromInt(0xFFF7F9FC),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Text(
              org.footer,
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 9, color: muted),
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'تاريخ الإصدار: ${Fmt.dateTime(v.createdAt)}',
                style: const pw.TextStyle(fontSize: 8, color: muted),
              ),
              pw.Text(
                'الحالة: ${v.statusLabel}',
                style: const pw.TextStyle(fontSize: 8, color: muted),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  return doc.save();
}

/// نص السند لإرساله عبر واتساب — نقل حرفي لـ `voucherText`.
String voucherText({
  required Voucher v,
  required Account? account,
  required CurrencyDef currency,
  required String orgName,
}) {
  final b = StringBuffer()
    ..writeln('📄 ${v.kind.label} رقم ${v.number}')
    ..writeln('التاريخ: ${Fmt.date(v.date)}')
    ..writeln('الحساب: ${account?.name ?? '—'}')
    ..writeln(
      'المبلغ: ${Fmt.money(v.amount, currency.decimal)} ${currency.symbol}',
    )
    ..writeln('البيان: ${v.statement.isEmpty ? '—' : v.statement}');
  if (orgName.isNotEmpty) b.writeln(orgName);
  return b.toString();
}
