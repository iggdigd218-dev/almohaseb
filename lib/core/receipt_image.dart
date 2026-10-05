import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'theme.dart';
import 'package:path_provider/path_provider.dart';

import 'accounting.dart';
import 'format.dart';
import 'models.dart';
import 'words.dart';

/// بيانات الإيصال المرسوم كصورة.
class ReceiptData {
  final String title;
  final String number;
  final String accountName;
  final String accountPhone;
  final double amount;
  final CurrencyDef currency;
  final String statement;
  final DateTime date;
  final double? balanceAfter;
  final String orgName;
  final String orgPhone;
  final String logoPath;
  final String footer;
  final List<InvoiceLine> items;

  const ReceiptData({
    required this.title,
    this.number = '',
    required this.accountName,
    this.accountPhone = '',
    required this.amount,
    required this.currency,
    this.statement = '',
    required this.date,
    this.balanceAfter,
    this.orgName = '',
    this.orgPhone = '',
    this.logoPath = '',
    this.footer = '',
    this.items = const [],
    this.isDebit = true,
  });

  /// اتجاه المبلغ: true = عليه (مدين/صرف) يظهر بالأحمر؛ false = له (قبض/دائن) بالأخضر.
  final bool isDebit;

  factory ReceiptData.fromTx({
    required Tx tx,
    required Account? account,
    required CurrencyDef currency,
    double? balanceAfter,
    required Map<String, String> settings,
    List<InvoiceLine> items = const [],
  }) =>
      ReceiptData(
        title: tx.type == OpType.debit && items.isNotEmpty
            ? 'فاتورة مبيع آجل'
            : tx.type.label,
        number: tx.reference,
        accountName: account?.name ?? '—',
        accountPhone: account?.phone ?? '',
        amount: tx.amount,
        currency: currency,
        statement: tx.description,
        date: tx.date,
        balanceAfter: balanceAfter,
        orgName: settings['businessName'] ?? '',
        orgPhone: settings['phone'] ?? '',
        logoPath: settings['logo'] ?? '',
        footer: settings['voucherFooter'] ?? '',
        items: items,
        // المبلغ عليه (مدين/صرف/مصروف) = أحمر؛ له (قبض/دائن/إيراد) = أخضر.
        isDebit: tx.type == OpType.debit ||
            tx.type == OpType.outflow ||
            tx.type == OpType.expense,
      );
}

/// يرسم الإيصال كصورة PNG ويحفظه في مجلد مؤقت، ثم يعيد مساره.
///
/// نرسم عبر `PictureRecorder` مباشرة بدل التقاط عنصر من الشجرة، فالصورة
/// تُولَّد حتى لو لم تُعرض أي واجهة — وهذا شرط الإرسال التلقائي.
Future<String> buildReceiptImage(ReceiptData d) async {
  const w = 1000.0;
  const pad = 48.0;

  // تخطيط مستوحى من سندات «تدوين الحسابات» و«نكسورا»:
  // ترويسة خضراء (اسم المنشأة/الهاتف/الشعار) ← شريط «سند عملية» مع الرقم
  // ← بيانات الحساب ← كبسولة المبلغ الكبيرة (عليه بالأحمر/له بالأخضر)
  // ← جدول الأصناف (صنف/كمية/سعر/إجمالي) مع الإجمالي ← التفاصيل والتاريخ
  // ← «الرصيد بعد العملية» ← تذييل الشكر.
  const headerH = 150.0;
  const bandH = 66.0;
  const rowH = 58.0;
  const amountH = 128.0;
  final infoRows = 1 + // اسم الحساب
      (d.accountPhone.isNotEmpty ? 1 : 0) +
      1; // التاريخ والوقت (يُرسم لاحقاً في قسم التفاصيل)
  final detailRows = (d.statement.isNotEmpty ? 1 : 0) + 1;
  final itemsBlock =
      d.items.isEmpty ? 0.0 : (54.0 + d.items.length * 52.0 + 56.0 + 24.0);
  final balanceBlock = d.balanceAfter != null ? 96.0 : 0.0;
  final height = headerH +
      bandH +
      (infoRows - 1) * rowH + // صفوف بيانات الحساب (بدون صف التاريخ)
      24 +
      amountH +
      24 +
      itemsBlock +
      detailRows * rowH +
      16 +
      balanceBlock +
      110 + // تذييل الشكر
      40;

  ui.Image? logo;
  if (d.logoPath.trim().isNotEmpty) {
    try {
      final file = File(d.logoPath);
      if (await file.exists()) {
        final codec = await ui.instantiateImageCodec(await file.readAsBytes());
        logo = (await codec.getNextFrame()).image;
      }
    } catch (_) {
      // شعار غير صالح لا يمنع إنشاء السند؛ نتابع من دون صورة.
    }
  }

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, height));

  const ink = Color(0xFF1F2A37); // نص أساسي داكن
  const muted = Color(0xFF6B7280); // عناوين رمادية
  const line = Color(0xFFE5E7EB); // خطوط فاصلة
  const green = Color(0xFF15803D); // أخضر «له»/الترويسة
  const red = Color(0xFFDC2626); // أحمر «عليه»

  canvas.drawRect(Rect.fromLTWH(0, 0, w, height), Paint()..color = Colors.white);

  // ===== 1) الترويسة الخضراء: اسم المنشأة + الهاتف + الشعار يميناً =====
  canvas.drawRect(
      const Rect.fromLTWH(0, 0, w, headerH), Paint()..color = green);
  if (logo != null) {
    final logoBox = RRect.fromRectAndRadius(
      const Rect.fromLTWH(w - pad - 96, (headerH - 96) / 2, 96, 96),
      const Radius.circular(14),
    );
    canvas.drawRRect(logoBox, Paint()..color = Colors.white);
    canvas.drawImageRect(
      logo,
      Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
      logoBox.outerRect.deflate(6),
      Paint()..filterQuality = ui.FilterQuality.high,
    );
  }
  final orgX = logo != null ? w - pad - 116 : w - pad;
  _text(canvas, d.orgName.isEmpty ? 'سجل الحسابات' : d.orgName, orgX, 26, 36,
      Colors.white, bold: true, alignEnd: true, maxWidth: w * .7);
  if (d.orgPhone.isNotEmpty) {
    _text(canvas, d.orgPhone, orgX, 78, 24, Colors.white70,
        alignEnd: true);
  }

  var y = headerH;

  // ===== 2) شريط «سند عملية» + الرقم المرجعي يساراً =====
  canvas.drawRect(
      Rect.fromLTWH(0, y, w, bandH), Paint()..color = const Color(0xFFF3F4F6));
  _text(canvas, d.title, w - pad, y + 16, 28, ink,
      bold: true, alignEnd: true);
  if (d.number.isNotEmpty) {
    _text(canvas, d.number, pad, y + 20, 24, muted, alignStart: true);
  }
  y += bandH + 18;

  void divider() {
    canvas.drawRect(
        Rect.fromLTWH(pad, y, w - pad * 2, 2), Paint()..color = line);
    y += 16;
  }

  // صف بيانات: عنوان يميناً وقيمة في الوسط/يسار (مثل «تدوين الحسابات»).
  void infoRow(String label, String value, {Color? valueColor, bool big = false}) {
    _text(canvas, label, w - pad, y, 24, muted, alignEnd: true);
    _text(canvas, value, pad, y - (big ? 4 : 0), big ? 28 : 25,
        valueColor ?? ink,
        bold: true, alignStart: true, maxWidth: w * .6);
    y += rowH;
  }

  // ===== 3) بيانات الحساب =====
  infoRow('اسم الحساب', d.accountName);
  if (d.accountPhone.isNotEmpty) infoRow('رقم الهاتف', d.accountPhone);
  divider();

  // ===== 4) كبسولة المبلغ الكبيرة: «عليه» أحمر / «له» أخضر =====
  final amtColor = d.isDebit ? red : green;
  final amtBg = d.isDebit ? const Color(0xFFFDECEC) : const Color(0xFFEAF7EF);
  final amountBox = RRect.fromRectAndRadius(
    Rect.fromLTWH(pad, y, w - pad * 2, amountH),
    const Radius.circular(22),
  );
  canvas.drawRRect(amountBox, Paint()..color = amtBg);
  _text(canvas, d.isDebit ? 'عليه' : 'له', w - pad - 28, y + 42, 30, amtColor,
      bold: true, alignEnd: true);
  _text(
    canvas,
    '${Fmt.money(d.amount, d.currency.decimal)} ${d.currency.symbol}',
    pad + (w - pad * 2) / 2 - 40,
    y + 26,
    54,
    amtColor,
    bold: true,
    center: true,
  );
  _text(
    canvas,
    'فقط ${numberToWords(d.amount)} ${d.currency.name} لا غير',
    w / 2,
    y + amountH - 36,
    18,
    muted,
    center: true,
    maxWidth: w - pad * 3,
  );
  y += amountH + 24;

  // ===== 5) جدول الأصناف (صنف/كمية/سعر/إجمالي) مثل سند نكسورا =====
  if (d.items.isNotEmpty) {
    const tPad = pad;
    const tw = w - tPad * 2;
    // أعمدة من اليمين: الصنف 40٪، الكمية 15٪، السعر 22.5٪، الإجمالي 22.5٪.
    const cName = w - tPad; // حافة يمنى
    const cQty = w - tPad - tw * 0.40 - tw * 0.075;
    const cPrice = tPad + tw * 0.225 + tw * 0.1125;
    const cTotal = tPad + tw * 0.1125;
    // رأس الجدول.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(tPad, y, tw, 46), const Radius.circular(10)),
      Paint()..color = const Color(0xFFF3F4F6),
    );
    _text(canvas, 'الصنف', cName - 14, y + 8, 22, muted, alignEnd: true);
    _text(canvas, 'الكمية', cQty, y + 8, 22, muted, center: true);
    _text(canvas, 'السعر', cPrice, y + 8, 22, muted, center: true);
    _text(canvas, 'الإجمالي', cTotal, y + 8, 22, muted, center: true);
    y += 54;
    for (final it in d.items) {
      _text(canvas, it.name, cName - 14, y, 23, ink,
          bold: true, alignEnd: true, maxWidth: tw * 0.38);
      _text(canvas, _quantity(it.quantity), cQty, y, 23, ink, center: true);
      _text(canvas, Fmt.money(it.unitPrice, d.currency.decimal), cPrice, y, 23,
          ink, center: true);
      _text(canvas, Fmt.money(it.total, d.currency.decimal), cTotal, y, 23,
          ink, bold: true, center: true);
      y += 52;
    }
    // صف الإجمالي.
    final itemsTotal =
        d.items.fold<double>(0, (sum, line) => sum + line.total);
    canvas.drawRect(
        Rect.fromLTWH(tPad, y, tw, 2), Paint()..color = line);
    y += 12;
    _text(canvas, 'الإجمالي', w - tPad - 14, y, 24, ink,
        bold: true, alignEnd: true);
    _text(canvas,
        '${Fmt.money(itemsTotal, d.currency.decimal)} ${d.currency.symbol}',
        tPad + 14, y, 26, ink, bold: true, alignStart: true);
    y += 56;
    divider();
  }

  // ===== 6) التفاصيل + التاريخ والوقت =====
  if (d.statement.isNotEmpty) infoRow('التفاصيل', d.statement);
  infoRow('التاريخ والوقت', Fmt.dateTime(d.date));
  y += 4;

  // ===== 7) الرصيد بعد العملية (شريط رمادي فاتح بقيمة ملونة) =====
  if (d.balanceAfter != null) {
    final b = d.balanceAfter!;
    final label = b > 0 ? '(عليه)' : (b < 0 ? '(له)' : '');
    final balColor = b > 0 ? red : (b < 0 ? green : ink);
    final balBox = RRect.fromRectAndRadius(
      Rect.fromLTWH(pad, y, w - pad * 2, 76),
      const Radius.circular(16),
    );
    canvas.drawRRect(balBox, Paint()..color = const Color(0xFFF3F4F6));
    _text(canvas, 'الرصيد بعد العملية', w - pad - 22, y + 22, 25, ink,
        bold: true, alignEnd: true);
    _text(
      canvas,
      '${Fmt.money(b.abs(), d.currency.decimal)} ${d.currency.symbol} $label',
      pad + 22,
      y + 20,
      27,
      balColor,
      bold: true,
      alignStart: true,
    );
    y += 96;
  }

  // ===== 8) تذييل الشكر =====
  canvas.drawRect(
      Rect.fromLTWH(pad, y, w - pad * 2, 2), Paint()..color = line);
  y += 20;
  _text(
    canvas,
    'شكراً لتعاملكم معنا — نتمنى لكم أطيب الأوقات',
    w / 2,
    y,
    23,
    green,
    bold: true,
    center: true,
  );
  y += 40;
  _text(
    canvas,
    d.footer.isEmpty ? 'هذا السند آلي ولا يحتاج إلى ختم أو توقيع.' : d.footer,
    w / 2,
    y,
    18,
    muted,
    center: true,
    maxWidth: w - pad * 2,
  );

  final picture = recorder.endRecording();
  final img = await picture.toImage(w.toInt(), height.toInt());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  final data = bytes!.buffer.asUint8List();

  final dir = await getTemporaryDirectory();
  final shared = Directory('${dir.path}/receipts')..createSync(recursive: true);
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final file = File('${shared.path}/receipt-$stamp.png');
  await file.writeAsBytes(data, flush: true);
  return file.path;
}

String _quantity(double value) =>
    value == value.roundToDouble() ? Fmt.money(value) : Fmt.money(value, 2);

void _text(
  Canvas canvas,
  String text,
  double x,
  double y,
  double size,
  Color color, {
  bool bold = false,
  bool center = false,
  bool alignEnd = false,
  bool alignStart = false,
  double? maxWidth,
}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: size,
        fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
        fontFamily: uiFontFamily,
        height: 1.35,
      ),
    ),
    textDirection: TextDirection.rtl,
    textAlign: center ? TextAlign.center : TextAlign.right,
    maxLines: 3,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth ?? 800);

  final dx = center
      ? x - tp.width / 2
      : (alignEnd ? x - tp.width : (alignStart ? x : x - tp.width / 2));
  tp.paint(canvas, Offset(dx, y));
}

/// يحوّل بايتات صورة إلى ملف دائم داخل مجلد مستندات التطبيق.
/// يُستخدم للصور المختارة ولشعار المؤسسة حتى تبقى المسارات صالحة بعد إعادة التشغيل.
Future<String> saveImageBytes(Uint8List bytes, {String prefix = 'img'}) async {
  final dir = await getApplicationDocumentsDirectory();
  final folder = Directory('${dir.path}/images')..createSync(recursive: true);
  final f = File(
    '${folder.path}/$prefix-${DateTime.now().millisecondsSinceEpoch}.png',
  );
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}
