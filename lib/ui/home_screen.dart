import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core.dart';
import 'account_screen.dart';
import 'reports_screens.dart';
import 'settings_screen.dart';
import 'widgets.dart';

/// الشاشة الرئيسية — قائمة الحسابات + شريط الملخص السفلي
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _type = 'general';
  List<Account> _accounts = [];
  Map<String, double> _totals = {'debit': 0, 'credit': 0};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await Db.accounts(type: _type);
    final t = await Db.typeTotals(_type);
    if (!mounted) return;
    setState(() {
      _accounts = list;
      _totals = t;
    });
  }

  Future<void> _openAccount([Account? a]) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => AccountScreen(initialAccount: a?.name ?? '')),
    );
    _reload();
  }

  void _typeDialog() {
    final cur = Prefs.activeCurrencyLabel;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        contentPadding: const EdgeInsets.symmetric(vertical: 6),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final e in kTypeLabels.entries)
              InkWell(
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _type = e.key);
                  _reload();
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                  decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: AppColors.line, width: e.key == 'suppliers' ? 0 : 0.7))),
                  child: Text('${e.value}($cur)',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 16, color: AppColors.ink)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _rowMenu(Account a) async {
    final bal = await Db.balanceOf(a.id);
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (Prefs.whatsappStatement)
              ListTile(
                leading: const WhatsAppIcon(size: 24),
                title: const Text('إرسال كشف الحساب عبر واتساب', style: TextStyle(fontSize: 15)),
                onTap: () {
                  Navigator.pop(ctx);
                  _sendWhatsapp(a, bal);
                },
              ),
            ListTile(
              leading: const Icon(Icons.swap_horiz, color: AppColors.sub),
              title: const Text('تحويل مبلغ إلى حساب آخر', style: TextStyle(fontSize: 15)),
              onTap: () {
                Navigator.pop(ctx);
                _transferDialog(from: a.name);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit, color: AppColors.sub),
              title: const Text('تعديل اسم الحساب', style: TextStyle(fontSize: 15)),
              onTap: () async {
                Navigator.pop(ctx);
                final v = await textDialog(context, 'اسم الحساب', initial: a.name);
                if (v != null && v.trim().isNotEmpty) {
                  await Db.saveAccount(Account(
                      id: a.id, name: v.trim(), type: a.type, categoryId: a.categoryId, note: a.note));
                  _reload();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppColors.red),
              title: const Text('حذف الحساب وجميع العمليات', style: TextStyle(fontSize: 15)),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    content: Text('حذف «${a.name}» وجميع عملياته؟', style: const TextStyle(fontSize: 15)),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
                      TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('حذف', style: TextStyle(color: AppColors.red))),
                    ],
                  ),
                );
                if (ok == true) {
                  await Db.deleteAccount(a.id);
                  _reload();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendWhatsapp(Account a, double bal) async {
    final text = 'كشف حساب: ${a.name}\n'
        'الرصيد: ${fmtNum(bal.abs())} ${bal >= 0 ? Prefs.debitWord2 : Prefs.creditWord2}\n'
        'التاريخ: ${isoToDisplay(todayISO())}';
    final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _transferDialog({String from = ''}) async {
    final fromCtrl = TextEditingController(text: from);
    final toCtrl = TextEditingController();
    final amtCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تحويل بين الحسابين', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: fromCtrl, decoration: const InputDecoration(labelText: 'من حساب')),
            TextField(controller: toCtrl, decoration: const InputDecoration(labelText: 'إلى حساب')),
            TextField(controller: amtCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          TextButton(
            onPressed: () async {
              final amt = double.tryParse(amtCtrl.text.trim().replaceAll(',', '')) ?? 0;
              if (amt > 0 && fromCtrl.text.trim().isNotEmpty && toCtrl.text.trim().isNotEmpty) {
                final f = await Db.ensureAccount(fromCtrl.text.trim());
                final t = await Db.ensureAccount(toCtrl.text.trim());
                await Db.saveTx(
                    Tx(accountId: f.id, kind: 2, amount: amt, details: 'تحويل إلى ${t.name}', date: todayISO(), time: nowHM()));
                await Db.saveTx(
                    Tx(accountId: t.id, kind: 1, amount: amt, details: 'تحويل من ${f.name}', date: todayISO(), time: nowHM()));
              }
              if (ctx.mounted) Navigator.pop(ctx);
              _reload();
            },
            child: const Text('تحويل', style: TextStyle(color: AppColors.primary)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const SideDrawer(),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: GestureDetector(
          onTap: _typeDialog,
          child: Text(kTypeLabels[_type] ?? 'عام'),
        ),
        actions: [
          if (Prefs.showTransferIcon)
            IconButton(
              icon: const Icon(Icons.swap_horiz, size: 22),
              onPressed: () => _transferDialog(),
            ),
          IconButton(
            icon: const Icon(Icons.search, size: 21),
            onPressed: () async {
              final q = await textDialog(context, 'بحث عن حساب', hint: 'اسم الحساب');
              if (q != null && q.trim().isNotEmpty) {
                final a = await Db.accountByName(q.trim());
                if (a != null) {
                  _openAccount(a);
                } else {
                  _openAccount();
                }
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.notifications_none, size: 22),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const RemindersScreen())),
          ),
          IconButton(
            icon: const Icon(Icons.filter_list, size: 22),
            onPressed: _typeDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                children: [
                  for (final a in _accounts) _accountRow(a),
                ],
              ),
            ),
          ),
          // ===== شريط الملخص السفلي =====
          Container(
            height: 56,
            color: AppColors.deep,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _circleBtn(
                  icon: Icons.help_outline,
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      content: Text(
                        'الرقم الأول: مجموع ما ${Prefs.debitWord2} (عليهم).\n'
                        'لــه: مجموع ما ${Prefs.creditWord2} (لهم).\n'
                        'الحالة النهائية والعملة في السطر الثاني.',
                        style: const TextStyle(fontSize: 14.5),
                      ),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('حسناً', style: TextStyle(color: AppColors.primary))),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${fmtNum(_totals['debit']!)} = لــه: ${fmtNum(_totals['credit']!)} = ${_totals['debit']! >= _totals['credit']! ? Prefs.debitWord2 : Prefs.creditWord2}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12.5, color: Color(0xFFAEB8D6)),
                      ),
                      Text(
                        Prefs.activeCurrencyLabel,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: Color(0xFFAEB8D6)),
                      ),
                    ],
                  ),
                ),
                _circleBtn(
                  icon: Icons.add,
                  onTap: () => _openAccount(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleBtn({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF8FA0C8), width: 1.6),
        ),
        child: Icon(icon, color: const Color(0xFF8FA0C8), size: 21),
      ),
    );
  }

  Widget _accountRow(Account a) {
    return FutureBuilder<Map<String, dynamic>>(
      future: () async {
        return {
          'bal': await Db.balanceOf(a.id),
          'count': await Db.txCount(a.id),
        };
      }(),
      builder: (ctx, snap) {
        final bal = (snap.data?['bal'] as double?) ?? 0.0;
        final count = (snap.data?['count'] as int?) ?? 0;
        final isDebit = bal >= 0;
        return GestureDetector(
          onTap: () => _openAccount(a),
          onLongPress: () => _rowMenu(a),
          child: Container(
            height: 52,
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Prefs.darkMode ? const Color(0xFF1E1E1E) : Colors.white,
              border: Border.all(color: Prefs.darkMode ? Colors.white12 : AppColors.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 12,
                  child: Center(
                    child: Icon(
                      isDebit ? Icons.arrow_drop_down : Icons.arrow_drop_up,
                      color: isDebit ? AppColors.red : AppColors.green,
                      size: 30,
                    ),
                  ),
                ),
                Expanded(
                  flex: 11,
                  child: Center(
                    child: Text(fmtNum(bal.abs()),
                        style: const TextStyle(fontSize: 15, color: AppColors.sub)),
                  ),
                ),
                Expanded(
                  flex: 12,
                  child: Center(
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: const BoxDecoration(color: AppColors.badge, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: Text('$count',
                          style: const TextStyle(fontSize: 11.5, color: Color(0xFF16324F))),
                    ),
                  ),
                ),
                Expanded(
                  flex: 17,
                  child: Center(
                    child: Text(a.name,
                        style: const TextStyle(fontSize: 15.5, color: AppColors.navy, fontWeight: FontWeight.w500)),
                  ),
                ),
                Expanded(
                  flex: 19,
                  child: Center(
                    child: GestureDetector(
                      onTap: () => _openAccount(a),
                      child: const Icon(Icons.add, color: AppColors.navy, size: 30),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// القائمة الجانبية
class SideDrawer extends StatelessWidget {
  const SideDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _item(context, '➕', 'إضافة مبلغ',
                iconColor: AppColors.green,
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const AccountScreen()));
                }),
            _item(context, '🗓️', 'تقرير-إجمالي المبالغ',
                onTap: () => _go(context, const TotalsReportScreen())),
            _item(context, '🗓️', 'تقرير-تفاصيل كل المبالغ',
                onTap: () => _go(context, const DetailsReportScreen())),
            _item(context, '🗓️', 'تقرير-إجمالي المبالغ شهرياً',
                onTap: () => _go(context, const MonthlyReportScreen())),
            _item(context, '🗓️', 'تقرير-إجمالي التصنيفات',
                onTap: () => _go(context, const CategoriesReportScreen())),
            _item(context, '🗓️', 'تقرير-حركة الحسابات',
                onTap: () => _go(context, const MovementReportScreen())),
            _item(context, '💲', 'التذكر التلقائي',
                onTap: () => _go(context, const RemindersScreen())),
            _item(context, '⬆️', 'حفظ نسخة إحتياطية',
                onTap: () => _go(context, const BackupScreen())),
            _item(context, '⬇️', 'إسترجاع قاعدة البيانات',
                onTap: () => _go(context, const RestoreScreen())),
            _item(context, '', 'مجلد درايف',
                customIcon: const DriveIcon(size: 22),
                onTap: () => _go(context, const DriveScreen())),
            _item(context, '🔧', 'إعدادات',
                onTap: () => _go(context, const SettingsScreen())),
            _item(context, '📞', 'للاتصال والدعم',
                onTap: () => _go(context, const SupportScreen())),
            _item(context, '❓', 'حول البرنامج',
                onTap: () => _go(context, const AboutScreen())),
            _item(context, '📤', 'مشاركة البرنامج', onTap: () async {
              Navigator.pop(context);
              await shareApp();
            }),
            _item(context, '❌', 'خروج', onTap: () async {
              Navigator.pop(context);
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  content: const Text('هل تريد الخروج من البرنامج؟', style: TextStyle(fontSize: 15)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
                    TextButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('خروج', style: TextStyle(color: AppColors.red))),
                  ],
                ),
              );
              if (ok == true) {
                // ignore: use_build_context_synchronously
                Navigator.of(context).maybePop();
              }
            }),
          ],
        ),
      ),
    );
  }

  void _go(BuildContext context, Widget screen) {
    Navigator.pop(context);
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  Widget _item(BuildContext context, String emoji, String label,
      {VoidCallback? onTap, Color? iconColor, Widget? customIcon}) {
    return Container(
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.line, width: 0.7))),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading: customIcon ??
            Text(emoji,
                style: TextStyle(
                    fontSize: 18,
                    color: emoji == '➕' ? AppColors.green : iconColor)),
        title: Text(label, style: const TextStyle(fontSize: 15, color: AppColors.ink)),
        onTap: onTap,
      ),
    );
  }
}
