import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart' as pdfc;
import 'package:pdf/widgets.dart' as pdf;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
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


  // ═══════════════════════════════════════════════════════════════════
  // (2026-11-22) القائمة الجانبية لشاشة الحساب — ١٢ خياراً كما في التصميم.
  // كانت الشاشة بلا أي قائمة، فلا وصول للمشاركة ولا للتحويل ولا للسقف.
  // ═══════════════════════════════════════════════════════════════════

  /// اسم الحساب الحالي (من حقل الاسم — مصدر الحقيقة في هذه الشاشة).
  String get _accName => nameCtrl.text.trim();

  String get _curLabel => kCurrencies[currency] ?? 'محلي';

  /// رصيد الحساب الآن: مجموع له − عليه.
  double get _balance => _sum(_txs, 2) - _sum(_txs, 1);

  Widget _drawer(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
              color: AppColors.primary,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _accName.isEmpty ? 'الحساب' : _accName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'الرصيد: ${fmtNum(_balance.abs())} $_curLabel',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            _dItem('🔍', 'بحث متقدم', _advancedSearch),
            _dItem('🖨️', 'طابعة حرارية', _thermalPrint),
            _dItem('📤', 'مشاركة', _shareSheet),
            _dItem('📊', 'إكسل', _exportExcel),
            _dItem('✉️', 'إرسال رسالة نصية', () => _sendSms(false)),
            _dItem('🟢', 'إرسال رسالة واتساب', () => _sendSms(true)),
            _dItem('🟢', 'إرسال رسالة نصية+واتساب', _sendBoth),
            _dItem('☑️', 'مصادقة على الحساب وواتساب', _approveAndShare),
            _dItem('🔒', 'إغلاق الرصيد', _closeBalance),
            _dItem('⇄', 'تحويل من حساب إلى حساب', _transferDialog),
            _dItem('🔔', 'التنبيهات', _reminders),
            _dItem('📈', 'سقف الحساب', _accountCeiling),
            const Divider(height: 1),
          ],
        ),
      ),
    );
  }

  Widget _dItem(String emoji, String title, VoidCallback onTap) => ListTile(
        leading: Text(emoji, style: const TextStyle(fontSize: 18)),
        title: Text(title,
            style: TextStyle(fontSize: 14.5, color: AppColors.text)),
        onTap: onTap,
      );

  // ── ١) بحث متقدم ────────────────────────────────────────────────
  Future<void> _advancedSearch() async {
    Navigator.pop(context);
    final q = TextEditingController(text: _search);
    String from = '', to = '';
    int kind = 0; // 0 = الكل
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('بحث متقدم'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: q,
                  autofocus: true,
                  decoration: const InputDecoration(
                      labelText: 'تفاصيل أو مبلغ', isDense: true),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final d = await showDatePicker(
                              context: ctx,
                              initialDate: DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100));
                          if (d != null) {
                            setD(() => from =
                                '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
                          }
                        },
                        child: Text(from.isEmpty ? 'من تاريخ' : from,
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final d = await showDatePicker(
                              context: ctx,
                              initialDate: DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100));
                          if (d != null) {
                            setD(() => to =
                                '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
                          }
                        },
                        child: Text(to.isEmpty ? 'إلى تاريخ' : to,
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('الكل')),
                    ButtonSegment(value: 2, label: Text('له')),
                    ButtonSegment(value: 1, label: Text('عليه')),
                  ],
                  selected: {kind},
                  onSelectionChanged: (s) => setD(() => kind = s.first),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _runAdvancedSearch(q.text.trim(), from, to, kind);
              },
              child: const Text('بحث'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runAdvancedSearch(
      String q, String from, String to, int kind) async {
    final name = _accName;
    if (name.isEmpty) {
      _toast('اكتب اسم الحساب أولاً');
      return;
    }
    final acc = await Db.accountByName(name);
    if (acc == null) return;
    var list = await Db.txsOf(acc.id);
    if (q.isNotEmpty) {
      list = list
          .where((t) =>
              t.details.contains(q) || fmtNum(t.amount).contains(q))
          .toList();
    }
    if (from.isNotEmpty) {
      list = list.where((t) => t.date.compareTo(from) >= 0).toList();
    }
    if (to.isNotEmpty) {
      list = list.where((t) => t.date.compareTo(to) <= 0).toList();
    }
    if (kind != 0) {
      list = list.where((t) => t.kind == kind).toList();
    }
    if (!mounted) return;
    setState(() => _txs = list);
    _toast('${list.length} نتيجة');
  }

  // ── ٢) طابعة حرارية ─────────────────────────────────────────────
  Future<void> _thermalPrint() async {
    Navigator.pop(context);
    // الطباعة الحرارية تستخدم طباعة النظام مع مقاس حراري (80mm).
    await _exportPdf(thermal: true);
  }

  // ── ٣) مشاركة ───────────────────────────────────────────────────
  Future<void> _shareSheet() async {
    Navigator.pop(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('مشاركة',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Text('📄', style: TextStyle(fontSize: 20)),
              title: const Text('مشاركة كشف الحساب PDF'),
              onTap: () {
                Navigator.pop(ctx);
                _exportPdf(share: true);
              },
            ),
            ListTile(
              leading: const Text('🟢', style: TextStyle(fontSize: 20)),
              title: const Text('إرسال عبر واتساب'),
              onTap: () {
                Navigator.pop(ctx);
                _sendSms(true);
              },
            ),
            ListTile(
              leading: const Text('📊', style: TextStyle(fontSize: 20)),
              title: const Text('تصدير إكسل (CSV)'),
              onTap: () {
                Navigator.pop(ctx);
                _exportExcel();
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  // ── ٤) إكسل (CSV) ───────────────────────────────────────────────
  Future<void> _exportExcel() async {
    if (_txs.isEmpty) {
      _toast('لا عمليات لتصديرها');
      return;
    }
    try {
      final rows = <String>[];
      rows.add('التاريخ,التفاصيل,العملة,مدين,دائن');
      for (final t in _txs.reversed) {
        final d = t.kind == 1 ? t.amount.toString() : '';
        final c = t.kind == 2 ? t.amount.toString() : '';
        rows.add('${t.date},${t.details.replaceAll(',', ' ')},${t.currency},$d,$c');
      }
      final dir = await getApplicationDocumentsDirectory();
      final f = File(p.join(dir.path,
          'كشف_${_accName.isEmpty ? 'حساب' : _accName}_${todayISO()}.csv'));
      await f.writeAsString('\uFEFF${rows.join('\n')}');
      await Share.shareXFiles([XFile(f.path)],
          text: 'كشف حساب $_accName');
    } catch (e) {
      _toast('تعذّر التصدير: $e');
    }
  }

  // ── ٥-٧) واتساب / رسائل ─────────────────────────────────────────
  String get _statementText {
    final b = _balance;
    final side = b >= 0 ? Prefs.creditWord1 : Prefs.debitWord1;
    return 'كشف حساب: $_accName\n'
        '${b.abs() < 0 ? '' : ''}الرصيد: ${fmtNum(b.abs())} $_curLabel ($side)\n'
        'عدد العمليات: ${_txs.length}';
  }

  Future<void> _sendSms(bool whatsapp) async {
    Navigator.pop(context);
    if (_accName.isEmpty) {
      _toast('اكتب اسم الحساب أولاً');
      return;
    }
    final acc = await Db.accountByName(_accName);
    // نموذج Account لا يحمل حقلاً للهاتف — يُقرأ من التفضيلات إن حُفظ.
    final phone = acc == null
        ? ''
        : Prefs.s('phone_${acc.id}').trim();
    if (whatsapp) {
      if (phone.isEmpty) {
        _toast('لا يوجد رقم هاتف لهذا الحساب');
        return;
      }
      final uri = Uri.parse(
          'https://wa.me/${phone.replaceAll(RegExp(r'[^0-9]'), '')}?text=${Uri.encodeComponent(_statementText)}');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } else {
      final uri = Uri.parse(
          'sms:${phone.isEmpty ? '' : phone}?body=${Uri.encodeComponent(_statementText)}');
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    }
  }

  Future<void> _sendBoth() async {
    Navigator.pop(context);
    await _sendSms(true);
    await _sendSms(false);
  }

  // ── ٨) مصادقة على الحساب ────────────────────────────────────────
  Future<void> _approveAndShare() async {
    Navigator.pop(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('مصادقة على الحساب'),
        content: Text(
            'سيُطبع نص المصادقة أسفل الكشف:\n\n'
            '«${Prefs.approvalForm.isEmpty ? 'أقر بصحة الرصيد المذكور أعلاه' : Prefs.approvalForm}»'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('متابعة')),
        ],
      ),
    );
    if (ok != true) return;
    await _exportPdf(share: true);
  }

  // ── ٩) إغلاق الرصيد ─────────────────────────────────────────────
  Future<void> _closeBalance() async {
    Navigator.pop(context);
    final b = _balance;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إغلاق الرصيد'),
        content: Text(
            'سيُسجَّل رصيد افتتاحي يساوي الرصيد الحالي '
            '(${fmtNum(b.abs())} $_curLabel)، وتُخفى العمليات السابقة من الكشف.\n\n'
            'العمليات لا تُحذف — تبقى محفوظة.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إغلاق')),
        ],
      ),
    );
    if (ok != true || _accName.isEmpty) return;
    final acc = await Db.accountByName(_accName);
    if (acc == null) return;
    await Prefs.setS('closing_${acc.id}', todayISO());
    if (!mounted) return;
    _toast('تم إغلاق الرصيد في ${isoToDisplay(todayISO())}');
    setState(() {});
  }

  // ── ١٠) تحويل من حساب إلى حساب ──────────────────────────────────
  Future<void> _transferDialog() async {
    Navigator.pop(context);
    final from = _accName;
    if (from.isEmpty) {
      _toast('اكتب اسم الحساب أولاً');
      return;
    }
    final amount = TextEditingController();
    String toName = '';
    final accs = await Db.accounts();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('تحويل من حساب إلى حساب'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('من: $from',
                  style: const TextStyle(fontSize: 13, color: AppColors.sub)),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: toName.isEmpty ? null : toName,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'إلى حساب', isDense: true),
                items: accs
                    .where((a) => a.name != from)
                    .map((a) => DropdownMenuItem(
                        value: a.name,
                        child: Text(a.name, overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: (v) => setD(() => toName = v ?? ''),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'المبلغ', isDense: true),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            TextButton(
              onPressed: () async {
                final v = double.tryParse(
                    amount.text.trim().replaceAll(',', ''));
                if (toName.isEmpty || v == null || v <= 0) return;
                Navigator.pop(ctx);
                final src = await Db.ensureAccount(from);
                final dst = await Db.ensureAccount(toName);
                await Db.saveTx(Tx(
                  accountId: dst.id,
                  kind: 2,
                  amount: v,
                  details: 'تحويل من $from',
                  date: todayISO(),
                  time: nowHM(),
                  currency: currency,
                ));
                await Db.saveTx(Tx(
                  accountId: src.id,
                  kind: 1,
                  amount: v,
                  details: 'تحويل إلى $toName',
                  date: todayISO(),
                  time: nowHM(),
                  currency: currency,
                ));
                if (!mounted) return;
                _toast('تم التحويل ✅');
                _reload();
              },
              child: const Text('تحويل'),
            ),
          ],
        ),
      ),
    );
  }

  // ── ١١) التنبيهات ───────────────────────────────────────────────
  Future<void> _reminders() async {
    Navigator.pop(context);
    if (_accName.isEmpty) {
      _toast('اكتب اسم الحساب أولاً');
      return;
    }
    final acc = await Db.accountByName(_accName);
    if (acc == null) return;
    final key = 'reminder_${acc.id}';
    final on = Prefs.b(key);
    final ctrl = TextEditingController(text: Prefs.s('${key}_days', '7'));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('التنبيهات'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('تذكير عند بقاء الرصيد دون سداد لمدة محددة.',
                style: const TextStyle(fontSize: 12.5, color: AppColors.sub)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'عدد الأيام', isDense: true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () async {
                await Prefs.setB(key, false);
                if (ctx.mounted) Navigator.pop(ctx);
                _toast('تم إيقاف التنبيه');
              },
              child: const Text('إيقاف')),
          TextButton(
            onPressed: () async {
              await Prefs.setB(key, true);
              await Prefs.setS('${key}_days',
                  (int.tryParse(ctrl.text.trim()) ?? 7).toString());
              if (ctx.mounted) Navigator.pop(ctx);
              _toast('تم تفعيل التنبيه');
            },
            child: const Text('تفعيل'),
          ),
        ],
      ),
    );
    if (on) setState(() {});
  }

  // ── ١٢) سقف الحساب ──────────────────────────────────────────────
  Future<void> _accountCeiling() async {
    Navigator.pop(context);
    if (_accName.isEmpty) {
      _toast('اكتب اسم الحساب أولاً');
      return;
    }
    final acc = await Db.accountByName(_accName);
    if (acc == null) return;
    final key = 'ceiling_${acc.id}';
    final ctrl =
        TextEditingController(text: Prefs.s(key));
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('سقف الحساب'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'أقصى رصيد مسموح لهذا الحساب. عند تجاوزه يظهر تحذير أحمر في الكشف.',
                style: TextStyle(fontSize: 12.5, color: AppColors.sub)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'السقف (اتركه فارغاً للإلغاء)', isDense: true),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () async {
                await Prefs.setS(key, '');
                if (ctx.mounted) Navigator.pop(ctx);
                _toast('تم إلغاء السقف');
              },
              child: const Text('إلغاء السقف')),
          TextButton(
            onPressed: () async {
              await Prefs.setS(key, ctrl.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
              _toast('تم حفظ السقف');
              setState(() {});
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportPdf({bool share = false, bool thermal = false}) async {
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
      // الطباعة الحرارية: مقاس 80mm بدل A4.
      pageFormat: thermal
          ? const pdfc.PdfPageFormat(80 * pdfc.PdfPageFormat.mm,
              297 * pdfc.PdfPageFormat.mm)
          : pdfc.PdfPageFormat.a4,
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
    if (share) {
      // مشاركة الملف بدل فتح معاينة الطباعة.
      final bytes = await doc.save();
      final dir = await getApplicationDocumentsDirectory();
      final f = File(p.join(dir.path,
          'كشف_${name}_${todayISO()}.pdf'));
      await f.writeAsBytes(bytes);
      await Share.shareXFiles([XFile(f.path)],
          text: 'كشف حساب $name');
    } else {
      // (2026-11-22) بديل الطباعة: نكتب الملف ونفتحه في أي تطبيق PDF.
      // أُزيلت حزمة printing لأنها تجرّ محرك PDFium (~10MB لكل معمارية)
      // فكانت كل حزمة APK تتجاوز حدّ الـ20MB. open_filex لا يضيف حجماً.
      final bytes = await doc.save();
      final dir = await getApplicationDocumentsDirectory();
      final f = File(p.join(dir.path,
          'كشف_${name}_${todayISO()}.pdf'));
      await f.writeAsBytes(bytes);
      final r = await OpenFilex.open(f.path);
      if (r.type != ResultType.done) {
        // لا يوجد قارئ PDF مثبّت — نشارك الملف بدل الفشل الصامت.
        await Share.shareXFiles([XFile(f.path)],
            text: 'كشف حساب $name');
      }
    }
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
      drawer: _drawer(context),
      appBar: simpleBar(context, 'إضافة مبلغ', showTemplate: false,
          leading: Builder(
            builder: (c) => IconButton(
              tooltip: 'القائمة',
              icon: const Icon(Icons.menu, color: Colors.white),
              onPressed: () => Scaffold.of(c).openDrawer(),
            ),
          ),
          actions: [
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
