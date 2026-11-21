import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart' as pdfc;
import 'package:pdf/widgets.dart' as pdf;
import 'package:printing/printing.dart';
import '../core.dart';
import '../words.dart' as words;
import 'calculator.dart';
import 'widgets.dart';

/// شاشة «إضافة مبلغ» — إدخال العمليات وكشف الحساب
class AccountScreen extends StatefulWidget {
  final String initialAccount;
  const AccountScreen({super.key, this.initialAccount = ''});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final amountCtrl = TextEditingController();
  final nameCtrl = TextEditingController();
  final detailsCtrl = TextEditingController();
  String date = todayISO();
  String currency = Prefs.activeCurrency;
  List<Tx> _txs = [];
  String _pendingPhoto = '';
  String _search = '';


  @override
  void initState() {
    super.initState();
    nameCtrl.text = widget.initialAccount;
    _reload();
  }

  Future<void> _reload() async {
    final name = nameCtrl.text.trim();
    List<Tx> list = [];
    if (name.isNotEmpty) {
      final acc = await Db.accountByName(name);
      if (acc != null) list = await Db.txsOf(acc.id);
    }
    if (_search.isNotEmpty) {
      list = list
          .where((t) =>
              t.details.contains(_search) ||
              fmtNum(t.amount).contains(_search) ||
              isoToDisplay(t.date).contains(_search))
          .toList();
    }
    setState(() => _txs = list);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final init = DateTime.tryParse(date) ?? now;
    final d = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => date = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _add(int kind) async {
    final amount = double.tryParse(amountCtrl.text.trim().replaceAll(',', '')) ?? 0;
    final name = nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast('اكتب اسم الحساب أولاً');
      return;
    }
    if (amount <= 0) {
      _toast('اكتب المبلغ أولاً');
      return;
    }
    if (Prefs.amountInWords) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(
            words.amountInWords(amount, currency),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء', style: TextStyle(color: AppColors.sub))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('موافق', style: TextStyle(color: AppColors.primary))),
          ],
        ),
      );
      if (ok != true) return;
    }
    final acc = await Db.ensureAccount(name);
    await Db.saveTx(Tx(
      accountId: acc.id,
      kind: kind,
      amount: amount,
      details: detailsCtrl.text.trim(),
      date: date,
      time: nowHM(),
      photo: _pendingPhoto,
      currency: currency,
    ));
    if (Prefs.notifOnAdd) {
      // الإشعار عند إضافة مبلغ — يُعرض فوراً كتنبيه داخلي خفيف
    }
    amountCtrl.clear();
    detailsCtrl.clear();
    _pendingPhoto = '';
    _reload();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 13)),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _pickPhoto() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70);
      if (x != null) {
        setState(() => _pendingPhoto = x.path);
        _toast('تم إرفاق الصورة بالعملية القادمة');
      }
    } catch (_) {
      _toast('تعذر فتح الصور على هذا الجهاز');
    }
  }

  Future<void> _editTx(Tx t) async {
    final amtCtrl = TextEditingController(text: fmtNum(t.amount));
    final detCtrl = TextEditingController(text: t.details);
    int kind = t.kind;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: amtCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'المبلغ')),
              TextField(
                  controller: detCtrl,
                  decoration: const InputDecoration(labelText: 'التفاصيل')),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: RadioListTile<int>(
                      dense: true,
                      activeColor: AppColors.pink,
                      title: const Text('له'),
                      value: 2,
                      groupValue: kind,
                      onChanged: (v) => setSt(() => kind = v!),
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<int>(
                      dense: true,
                      activeColor: AppColors.pink,
                      title: const Text('عليه'),
                      value: 1,
                      groupValue: kind,
                      onChanged: (v) => setSt(() => kind = v!),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Db.deleteTx(t.id);
                if (ctx.mounted) Navigator.pop(ctx);
                _reload();
              },
              child: const Text('حذف', style: TextStyle(color: AppColors.red)),
            ),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء', style: TextStyle(color: AppColors.sub))),
            TextButton(
              onPressed: () async {
                await Db.saveTx(Tx(
                  id: t.id,
                  accountId: t.accountId,
                  kind: kind,
                  amount: double.tryParse(amtCtrl.text.trim().replaceAll(',', '')) ?? t.amount,
                  details: detCtrl.text.trim(),
                  date: t.date,
                  time: t.time,
                  photo: t.photo,
                  currency: t.currency,
                ));
                if (ctx.mounted) Navigator.pop(ctx);
                _reload();
              },
              child: const Text('حفظ', style: TextStyle(color: AppColors.primary)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportPdf() async {
    final name = nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast('لا يوجد حساب لطباعته');
      return;
    }
    final acc = await Db.accountByName(name);
    if (acc == null) return;
    final txs = await Db.txsOf(acc.id);
    final doc = pdf.Document();
    final ascending = Prefs.printAscending;
    final list = [...txs]
      ..sort((a, b) => ascending
          ? '${a.date} ${a.time}'.compareTo('${b.date} ${b.time}')
          : '${b.date} ${b.time}'.compareTo('${a.date} ${a.time}'));
    final bal = await Db.balanceOf(acc.id);
    final showData = Prefs.printShowData;
    final template = Prefs.template;
    final naskhFont = await _loadNaskh();

    doc.addPage(pdf.MultiPage(
      pageFormat: pdfc.PdfPageFormat.a4,
      textDirection: template == '3' ? pdf.TextDirection.ltr : pdf.TextDirection.rtl,
      theme: () {
        try {
          if (template != '3' && naskhFont != null) {
            return pdf.ThemeData.withFont(base: pdf.Font.ttf(naskhFont));
          }
        } catch (_) {}
        return pdf.ThemeData.withFont(base: pdf.Font.helvetica());
      }(),
      build: (ctx) => [
        if (showData)
          pdf.Header(
            level: 0,
            child: pdf.Column(
              crossAxisAlignment: pdf.CrossAxisAlignment.center,
              children: [
                pdf.Text(template == '3' ? Prefs.nameEn : Prefs.name,
                    style: pdf.TextStyle(
                        fontSize: 18, fontWeight: pdf.FontWeight.bold)),
                if ((template == '3' ? Prefs.addressEn : Prefs.address).isNotEmpty)
                  pdf.Text(template == '3' ? Prefs.addressEn : Prefs.address),
                if (Prefs.phone.isNotEmpty && template != '3')
                  pdf.Text(Prefs.phone),
              ],
            ),
          ),
        pdf.Center(
            child: pdf.Text('كشف حساب: $name',
                style: pdf.TextStyle(
                    fontSize: 15, fontWeight: pdf.FontWeight.bold))),
        pdf.SizedBox(height: 8),
        pdf.TableHelper.fromTextArray(
          headers: [
            template == '3' ? 'Balance' : 'الرصيد',
            template == '3' ? 'Type' : 'النوع',
            template == '3' ? 'Amount' : 'المبلغ',
            template == '3' ? 'Details' : 'التفاصيل',
            template == '3' ? 'Date' : 'التاريخ',
          ],
          data: [
            for (final t in list)
              [
                fmtNum(_running(list, t)),
                t.kind == 1 ? Prefs.debitWord2 : Prefs.creditWord2,
                fmtNum(t.amount),
                t.details,
                isoToDisplay(t.date),
              ],
          ],
        ),
        pdf.SizedBox(height: 8),
        pdf.Row(mainAxisAlignment: pdf.MainAxisAlignment.spaceAround, children: [
          pdf.Text('${Prefs.creditWord1}: ${fmtNum(_sum(list, 2))}'),
          pdf.Text('${Prefs.debitWord1}: ${fmtNum(_sum(list, 1))}'),
          pdf.Text(
              '${template == '3' ? 'Net' : 'الرصيد'}: ${fmtNum(bal.abs())} ${bal >= 0 ? Prefs.debitWord2 : Prefs.creditWord2}'),
        ]),
        if (Prefs.printNote.isNotEmpty)
          pdf.Padding(
              padding: const pdf.EdgeInsets.only(top: 14),
              child: pdf.Text(Prefs.printNote)),
        if (Prefs.printShowDate)
          pdf.Align(
              alignment: pdf.Alignment.centerLeft,
              child: pdf.Padding(
                  padding: const pdf.EdgeInsets.only(top: 18),
                  child: pdf.Text(
                      '${template == '3' ? 'Date' : 'التاريخ'}: ${isoToDisplay(todayISO())}'))),
        if (Prefs.approvalForm.isNotEmpty)
          pdf.Padding(
              padding: const pdf.EdgeInsets.only(top: 22),
              child: pdf.Text(Prefs.approvalForm)),
      ],
    ));
    await Printing.layoutPdf(onLayout: (_) => doc.save());
  }

  Future<ByteData?> _loadNaskh() async {
    try {
      return await rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf');
    } catch (_) {
      return null;
    }
  }

  double _running(List<Tx> sortedAsc, Tx t) {
    double s = 0;
    for (final x in sortedAsc) {
      s += x.kind == 1 ? x.amount : -x.amount;
      if (x.id == t.id) break;
    }
    return s;
  }

  double _sum(List<Tx> list, int kind) =>
      list.where((t) => t.kind == kind).fold(0.0, (a, b) => a + b.amount);

  @override
  Widget build(BuildContext context) {
    final dark = Prefs.darkMode;
    return Scaffold(
      appBar: simpleBar(context, 'إضافة مبلغ', showTemplate: false, actions: [
        IconButton(
          icon: const Icon(Icons.search, size: 21),
          onPressed: () async {
            final q = await textDialog(context, 'بحث في العمليات', hint: 'تفاصيل أو مبلغ أو تاريخ');
            if (q != null) {
              _search = q.trim();
              _reload();
            }
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: GestureDetector(
            onTap: _exportPdf,
            child: Container(
              width: 27,
              height: 27,
              decoration: const BoxDecoration(color: AppColors.pdfRed, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const Icon(Icons.picture_as_pdf, color: Colors.white, size: 17),
            ),
          ),
        ),
      ]),
      body: Column(
        children: [
          // ===== صف الحقول: 🧮 | المبلغ | ⊗ | اسم الحساب =====
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () async {
                    final v = await showCalculator(context);
                    if (v != null) setState(() => amountCtrl.text = fmtNum(v));
                  },
                  child: const Text('🧮', style: TextStyle(fontSize: 21)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    autofocus: true,
                    style: const TextStyle(fontSize: 16),
                    decoration: const InputDecoration(
                      labelText: 'المبلغ',
                      labelStyle: TextStyle(fontSize: 15, color: AppColors.sub),
                      floatingLabelStyle: TextStyle(fontSize: 13, color: AppColors.sub),
                      enabledBorder: UnderlineInputBorder(),
                      focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: AppColors.pink, width: 1.6)),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.cancel, color: AppColors.faint, size: 22),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  onPressed: () {
                    amountCtrl.clear();
                    detailsCtrl.clear();
                    _pendingPhoto = '';
                  },
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: _pickAccount,
                    child: Container(
                      padding: const EdgeInsets.only(bottom: 7),
                      decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: dark ? Colors.white24 : AppColors.sub, width: 0.8))),
                      child: Text(
                        nameCtrl.text.isEmpty ? 'الحساب' : nameCtrl.text,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 15,
                            color: nameCtrl.text.isEmpty ? AppColors.faint : AppColors.ink),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ===== التاريخ + الكاميرا + التفاصيل =====
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 0),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _pickDate,
                  child: Text(isoToDisplay(date),
                      style: const TextStyle(fontSize: 14.5, color: AppColors.sub)),
                ),
                const SizedBox(width: 14),
                GestureDetector(
                  onTap: _pickPhoto,
                  child: const Text('📷', style: TextStyle(fontSize: 19)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: detailsCtrl,
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 15),
                    decoration: const InputDecoration(
                      labelText: 'التفاصيل',
                      labelStyle: TextStyle(fontSize: 15, color: AppColors.sub),
                      floatingLabelStyle: TextStyle(fontSize: 13, color: AppColors.sub),
                      enabledBorder: UnderlineInputBorder(),
                      focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: AppColors.pink, width: 1.6)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ===== العملات =====
          if (Prefs.showCurrencies)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final e in kCurrencies.entries) ...[
                    Radio<String>(
                      value: e.key,
                      groupValue: currency,
                      activeColor: AppColors.pink,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) => setState(() => currency = v!),
                    ),
                    Text(e.value, style: const TextStyle(fontSize: 14.5)),
                    const SizedBox(width: 10),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 12),
          // ===== الأزرار: له ▲ | عليه ▼ =====
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(child: _kindButton(kind: 2, label: 'له', icon: Icons.arrow_drop_up, color: AppColors.green)),
                const SizedBox(width: 12),
                Expanded(child: _kindButton(kind: 1, label: 'عليه', icon: Icons.arrow_drop_down, color: AppColors.red)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // ===== قائمة العمليات =====
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              children: [
                for (final t in _txs) _txRow(t),
                if (_txs.isNotEmpty && Prefs.totalsBelowAccount)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'إجمالي العمليات: ${_txs.length}  =  ${Prefs.debitWord1}: ${fmtNum(_sum(_txs, 1))}  =  ${Prefs.creditWord1}: ${fmtNum(_sum(_txs, 2))}',
                      style: const TextStyle(fontSize: 12.5, color: AppColors.sub),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kindButton({required int kind, required String label, required IconData icon, required Color color}) {
    return SizedBox(
      height: 44,
      child: Material(
        color: AppColors.deep,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _add(kind),
          child: Row(
            children: [
              const SizedBox(width: 12),
              Icon(icon, color: color, size: 26),
              Expanded(
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 38),
            ],
          ),
        ),
      ),
    );
  }

  Widget _txRow(Tx t) {
    final bal = _running(List.of(_txs.reversed), t);
    return GestureDetector(
      onTap: () => _editTx(t),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: Prefs.darkMode ? Colors.white12 : AppColors.line),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 7,
              child: Center(
                child: Text(fmtNum(bal.abs()),
                    style: const TextStyle(fontSize: 13.5, color: AppColors.faint)),
              ),
            ),
            Expanded(
              flex: 10,
              child: Center(
                child: Icon(
                  t.kind == 1 ? Icons.arrow_drop_down : Icons.arrow_drop_up,
                  color: t.kind == 1 ? AppColors.red : AppColors.green,
                  size: 28,
                ),
              ),
            ),
            Expanded(
              flex: 14,
              child: Center(
                child: Text(t.details,
                    style: const TextStyle(fontSize: 13.5, color: AppColors.ink)),
              ),
            ),
            Expanded(
              flex: 16,
              child: Center(
                child: Text(fmtNum(t.amount),
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: AppColors.ink)),
              ),
            ),
            Expanded(
              flex: 18,
              child: Column(
                children: [
                  Text(isoToDisplay(t.date),
                      style: const TextStyle(fontSize: 12.5, color: AppColors.sub)),
                  if (Prefs.showTxTime)
                    Text(t.time,
                        style: const TextStyle(fontSize: 11, color: AppColors.faint)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAccount() async {
    final list = await Db.accounts();
    final names = [for (final a in list) a.name];
    final ctrl = TextEditingController(text: nameCtrl.text);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('اختر الحساب', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                textAlign: TextAlign.right,
                decoration: const InputDecoration(hintText: 'اكتب اسم حساب جديد'),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final n in names)
                      ListTile(
                        dense: true,
                        title: Text(n, textAlign: TextAlign.right, style: const TextStyle(fontSize: 14.5)),
                        onTap: () {
                          Navigator.pop(ctx);
                          setState(() => nameCtrl.text = n);
                          _reload();
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                setState(() => nameCtrl.text = ctrl.text.trim());
                _reload();
              },
              child: const Text('موافق', style: TextStyle(color: AppColors.primary))),
        ],
      ),
    );
  }
}
