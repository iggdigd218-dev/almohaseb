import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core.dart';
import 'widgets.dart';

Future<void> shareApp() async {
  await Share.share('دفتر الحسابات — سجل الديون والحسابات\n'
      'تطبيق متكامل لإدارة الحسابات والديون مع التقارير والنسخ الاحتياطي.');
}

String _balText(double bal) =>
    '${fmtNum(bal.abs())} ${bal >= 0 ? Prefs.debitWord2 : Prefs.creditWord2}';

/// تقرير-إجمالي المبالغ (يومي/شهري/سنوي حسب الإعداد)
class TotalsReportScreen extends StatelessWidget {
  const TotalsReportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final freq = Prefs.totalsReportFreq;
    return Scaffold(
      appBar: simpleBar(context, 'تقرير-إجمالي المبالغ'),
      body: FutureBuilder<List<Tx>>(
        future: Db.allTxs(),
        builder: (ctx, snap) {
          final txs = snap.data ?? [];
          final groups = <String, List<Tx>>{};
          for (final t in txs) {
            String key;
            if (freq == 'شهري') {
              key = t.date.substring(0, 7);
            } else if (freq == 'سنوي') {
              key = t.date.substring(0, 4);
            } else {
              key = t.date;
            }
            groups.putIfAbsent(key, () => []).add(t);
          }
          final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));
          double gD = 0, gC = 0;
          for (final t in txs) {
            if (t.kind == 1) {
              gD += t.amount;
            } else {
              gC += t.amount;
            }
          }
          return ListView(
            children: [
              for (final k in keys)
                Builder(builder: (_) {
                  final list = groups[k]!;
                  final d = list.where((t) => t.kind == 1).fold(0.0, (a, b) => a + b.amount);
                  final c = list.where((t) => t.kind == 2).fold(0.0, (a, b) => a + b.amount);
                  return EmojiTile(
                    emoji: '📅',
                    title: freq == 'يومي'
                        ? isoToDisplay(k)
                        : freq == 'شهري'
                            ? monthLabel('$k-01')
                            : k,
                    subtitle:
                        '${Prefs.debitWord1}: ${fmtNum(d)}   |   ${Prefs.creditWord1}: ${fmtNum(c)}',
                  );
                }),
              Container(
                color: const Color(0xFFF5F5F5),
                padding: const EdgeInsets.all(14),
                child: Text(
                  'الإجمالي العام:  ${Prefs.debitWord1}: ${fmtNum(gD)}  =  ${Prefs.creditWord1}: ${fmtNum(gC)}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// تقرير-تفاصيل كل المبالغ
class DetailsReportScreen extends StatelessWidget {
  const DetailsReportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'تقرير-تفاصيل كل المبالغ'),
      body: FutureBuilder<List<Tx>>(
        future: Db.allTxs(),
        builder: (ctx, snap) {
          final txs = snap.data ?? [];
          return ListView(
            children: [
              for (final t in txs)
                EmojiTile(
                  emoji: t.kind == 1 ? '▼' : '▲',
                  emojiSize: 15,
                  title: '${fmtNum(t.amount)} — ${t.details.isEmpty ? 'بدون تفاصيل' : t.details}',
                  subtitle: '${isoToDisplay(t.date)} ${t.time}',
                  trailing: Text(t.kind == 1 ? Prefs.debitWord2 : Prefs.creditWord2,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: t.kind == 1 ? AppColors.red : AppColors.green)),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// تقرير-إجمالي المبالغ شهرياً
class MonthlyReportScreen extends StatelessWidget {
  const MonthlyReportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'تقرير-إجمالي المبالغ شهرياً'),
      body: FutureBuilder<List<Tx>>(
        future: Db.allTxs(),
        builder: (ctx, snap) {
          final txs = snap.data ?? [];
          final groups = <String, List<Tx>>{};
          for (final t in txs) {
            groups.putIfAbsent(t.date.substring(0, 7), () => []).add(t);
          }
          final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));
          return ListView(
            children: [
              for (final k in keys)
                Builder(builder: (_) {
                  final list = groups[k]!;
                  final d = list.where((t) => t.kind == 1).fold(0.0, (a, b) => a + b.amount);
                  final c = list.where((t) => t.kind == 2).fold(0.0, (a, b) => a + b.amount);
                  return EmojiTile(
                    emoji: '🗓️',
                    title: monthLabel('$k-01'),
                    subtitle:
                        '${Prefs.debitWord1}: ${fmtNum(d)}   |   ${Prefs.creditWord1}: ${fmtNum(c)}   |   العمليات: ${list.length}',
                  );
                }),
            ],
          );
        },
      ),
    );
  }
}

/// تقرير-إجمالي التصنيفات
class CategoriesReportScreen extends StatelessWidget {
  const CategoriesReportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'تقرير-إجمالي التصنيفات'),
      body: FutureBuilder<List<dynamic>>(
        future: () async {
          final cats = await Db.categories();
          final accs = await Db.accounts();
          final txs = await Db.allTxs();
          return [cats, accs, txs];
        }(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const SizedBox();
          final cats = snap.data![0] as List<Category>;
          final accs = snap.data![1] as List<Account>;
          final txs = snap.data![2] as List<Tx>;
          final byCat = <int, double>{};
          for (final t in txs) {
            final acc = accs.where((a) => a.id == t.accountId).toList();
            final cid = acc.isEmpty ? 0 : acc.first.categoryId;
            final v = t.kind == 1 ? t.amount : -t.amount;
            byCat[cid] = (byCat[cid] ?? 0) + v;
          }
          final rows = <Widget>[];
          for (final c in cats) {
            rows.add(EmojiTile(
              emoji: '📋',
              title: c.name,
              subtitle: _balText(byCat[c.id] ?? 0),
            ));
          }
          if (byCat.containsKey(0)) {
            rows.add(const EmojiTile(emoji: '📋', title: 'بدون تصنيف', subtitle: ''));
            rows.last = EmojiTile(emoji: '📋', title: 'بدون تصنيف', subtitle: _balText(byCat[0]!));
          }
          return ListView(children: rows);
        },
      ),
    );
  }
}

/// تقرير-حركة الحسابات
class MovementReportScreen extends StatelessWidget {
  const MovementReportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'تقرير-حركة الحسابات'),
      body: FutureBuilder<List<Account>>(
        future: Db.accounts(),
        builder: (ctx, snap) {
          final accs = snap.data ?? [];
          return ListView(
            children: [
              for (final a in accs)
                FutureBuilder<Map<String, dynamic>>(
                  future: () async {
                    final txs = await Db.txsOf(a.id);
                    final d = txs.where((t) => t.kind == 1).fold(0.0, (x, y) => x + y.amount);
                    final c = txs.where((t) => t.kind == 2).fold(0.0, (x, y) => x + y.amount);
                    return {'d': d, 'c': c, 'n': txs.length, 'bal': d - c};
                  }(),
                  builder: (c2, s2) {
                    final m = s2.data ?? {'d': 0.0, 'c': 0.0, 'n': 0, 'bal': 0.0};
                    return EmojiTile(
                      emoji: '📊',
                      title: a.name,
                      subtitle:
                          'العمليات: ${m['n']}   |   ${Prefs.debitWord1}: ${fmtNum(m['d'] as double)}   |   ${Prefs.creditWord1}: ${fmtNum(m['c'] as double)}   |   الرصيد: ${_balText(m['bal'] as double)}',
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

/// التذكر التلقائي
class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'التذكر التلقائي', showTemplate: false, actions: [
        IconButton(
          icon: const Icon(Icons.add, size: 23),
          onPressed: _add,
        ),
      ]),
      body: FutureBuilder<List<Reminder>>(
        future: Db.reminders(),
        builder: (ctx, snap) {
          final list = snap.data ?? [];
          return ListView(
            children: [
              for (final r in list)
                EmojiTile(
                  emoji: '💲',
                  title: '${r.accountName} — ${fmtNum(r.amount)}',
                  subtitle: '${isoToDisplay(r.date)} ${r.note.isEmpty ? '' : '— ${r.note}'}',
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: AppColors.faint, size: 20),
                    onPressed: () async {
                      await Db.deleteReminder(r.id);
                      setState(() {});
                    },
                  ),
                ),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(
                      child: Text('لا توجد تذكيرات — اضغط + لإضافة تذكير',
                          style: TextStyle(color: AppColors.faint, fontSize: 14))),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _add() async {
    final nameCtrl = TextEditingController();
    final amtCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    String date = todayISO();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تذكير جديد', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'الحساب')),
            TextField(controller: amtCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ')),
            TextField(controller: noteCtrl, decoration: const InputDecoration(labelText: 'ملاحظة')),
            TextButton(
              onPressed: () async {
                final d = await showDatePicker(
                    context: ctx,
                    initialDate: DateTime.now(),
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100));
                if (d != null) {
                  date = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                }
              },
              child: Text('التاريخ: ${isoToDisplay(date)}',
                  style: const TextStyle(color: AppColors.primary)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          TextButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isNotEmpty) {
                await Db.saveReminder(Reminder(
                  accountName: nameCtrl.text.trim(),
                  amount: double.tryParse(amtCtrl.text.trim()) ?? 0,
                  date: date,
                  note: noteCtrl.text.trim(),
                ));
              }
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('حفظ', style: TextStyle(color: AppColors.primary)),
          ),
        ],
      ),
    );
  }
}

/// مجلد حفظ النسخ — دليل العمل
Future<Directory> backupRoot() async {
  Directory base;
  try {
    base = Directory('/storage/emulated/0/Documents/Market_Customers');
    if (!await base.exists()) await base.create(recursive: true);
  } catch (_) {
    final docs = await getApplicationDocumentsDirectory();
    base = Directory(p.join(docs.path, 'Market_Customers'));
    if (!await base.exists()) await base.create(recursive: true);
  }
  return base;
}

/// حفظ نسخة إحتياطية
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  String _status = '';

  Future<void> _backup() async {
    setState(() => _status = 'جارٍ الحفظ...');
    try {
      final root = await backupRoot();
      final stamp = DateTime.now()
          .toString()
          .replaceAll(RegExp(r'[-: .]'), '')
          .substring(0, 14);
      final dir = Directory(p.join(root.path, stamp));
      await dir.create(recursive: true);
      final dbFile = File(Db.dbPath);
      if (await dbFile.exists()) {
        await dbFile.copy(p.join(dir.path, 'ledger.db'));
      }
      final data = {
        'accounts': (await Db.accounts()).map((a) => a.toMap()).toList(),
        'txs': (await Db.allTxs()).map((t) => t.toMap()).toList(),
        'categories': (await Db.categories()).map((c) => c.toMap()).toList(),
      };
      await File(p.join(dir.path, 'backup.json')).writeAsString(jsonEncode(data));
      Prefs.setS('backupFolder', dir.path);
      setState(() => _status = 'تم الحفظ في:\n${dir.path}');
    } catch (e) {
      setState(() => _status = 'تعذر الحفظ: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'حفظ نسخة إحتياطية', showTemplate: false),
      body: ListView(
        children: [
          const SizedBox(height: 30),
          const Center(child: Text('⬆️', style: TextStyle(fontSize: 46))),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 13)),
              onPressed: _backup,
              child: const Text('حفظ نسخة إحتياطية الآن', style: TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 20),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 30),
              child: Text(_status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13.5, color: AppColors.sub)),
            ),
          const SizedBox(height: 20),
          EmojiTile(
              emoji: '📁',
              title: 'مجلد حفظ البيانات',
              subtitle: Prefs.backupFolder.isEmpty ? '(يُحدد تلقائياً)' : Prefs.backupFolder),
        ],
      ),
    );
  }
}

/// إسترجاع قاعدة البيانات
class RestoreScreen extends StatelessWidget {
  const RestoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'إسترجاع قاعدة البيانات', showTemplate: false),
      body: ListView(
        children: [
          const SizedBox(height: 30),
          const Center(child: Text('⬇️', style: TextStyle(fontSize: 46))),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 13)),
              onPressed: () async {
                final res = await FilePicker.platform.pickFiles(type: FileType.any);
                if (res == null || res.files.isEmpty) return;
                final path = res.files.single.path;
                if (path == null) return;
                try {
                  final f = File(path);
                  if (path.endsWith('.json')) {
                    final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
                    final db = await Db.open();
                    await db.delete('txs');
                    await db.delete('accounts');
                    await db.delete('categories');
                    for (final a in (data['accounts'] as List)) {
                      await Db.saveAccount(Account.fromMap(Map<String, dynamic>.from(a)));
                    }
                    for (final t in (data['txs'] as List)) {
                      await Db.saveTx(Tx.fromMap(Map<String, dynamic>.from(t)));
                    }
                    for (final c in (data['categories'] as List)) {
                      await Db.saveCategory(Category.fromMap(Map<String, dynamic>.from(c)));
                    }
                  } else if (path.endsWith('.db')) {
                    await f.copy(Db.dbPath);
                  }
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('تم إسترجاع البيانات بنجاح', style: TextStyle(fontSize: 13))));
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('تعذر الإسترجاع: $e', style: const TextStyle(fontSize: 13))));
                  }
                }
              },
              child: const Text('إختيار ملف النسخة الإحتياطية', style: TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'إختار ملف backup.json أو ledger.db من مجلد النسخ الإحتياطية.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.sub),
            ),
          ),
        ],
      ),
    );
  }
}

/// مجلد درايف
class DriveScreen extends StatelessWidget {
  const DriveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'مجلد درايف', showTemplate: false),
      body: ListView(
        children: [
          const SizedBox(height: 24),
          const Center(child: DriveIcon(size: 54)),
          const SizedBox(height: 18),
          EmojiTile(
            emoji: '👤',
            title: 'حساب الدرايف',
            subtitle: Prefs.driveAccount.isEmpty ? 'غير محدد' : Prefs.driveAccount,
            trailing: TextButton(
              onPressed: () async {
                final v = await textDialog(context, 'حساب الدرايف', initial: Prefs.driveAccount, hint: 'البريد الإلكتروني');
                if (v != null) {
                  await Prefs.setS('driveAccount', v.trim());
                  if (context.mounted) (context as Element).markNeedsBuild();
                }
              },
              child: const Text('تغيير', style: TextStyle(color: AppColors.primary)),
            ),
          ),
          EmojiTile(
            emoji: '📁',
            title: 'اسم المجلد في مجلد درايف',
            subtitle: Prefs.driveFolder,
            grayed: Prefs.driveAccount.isEmpty,
            trailing: TextButton(
              onPressed: Prefs.driveAccount.isEmpty
                  ? null
                  : () async {
                      final v = await textDialog(context, 'اسم المجلد', initial: Prefs.driveFolder);
                      if (v != null && v.trim().isNotEmpty) {
                        await Prefs.setS('driveFolder', v.trim());
                        if (context.mounted) (context as Element).markNeedsBuild();
                      }
                    },
              child: const Text('تغيير', style: TextStyle(color: AppColors.primary)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.driveBlue, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
              icon: const Icon(Icons.cloud_upload),
              label: const Text('فتح جوجل درايف', style: TextStyle(fontSize: 15)),
              onPressed: () async {
                final uri = Uri.parse('https://drive.google.com');
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// للاتصال والدعم
class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'للاتصال والدعم', showTemplate: false),
      body: ListView(
        children: [
          const SizedBox(height: 20),
          EmojiTile(
            emoji: '📞',
            title: 'إتصال هاتفي',
            subtitle: Prefs.phone.isEmpty ? 'غير محدد' : Prefs.phone,
            onTap: () async {
              final uri = Uri.parse('tel:${Prefs.phone}');
              if (await canLaunchUrl(uri)) await launchUrl(uri);
            },
          ),
          EmojiTile(
            emoji: '🟢',
            title: 'واتساب الدعم',
            subtitle: 'مراسلة مباشرة',
            onTap: () async {
              final uri = Uri.parse('https://wa.me/${Prefs.phone}');
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
          EmojiTile(
            emoji: '📧',
            title: 'البريد الإلكتروني',
            subtitle: 'الدعم الفني عبر الإيميل',
            onTap: () async {
              final uri = Uri.parse('mailto:support@example.com');
              if (await canLaunchUrl(uri)) await launchUrl(uri);
            },
          ),
        ],
      ),
    );
  }
}

/// حول البرنامج
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'حول البرنامج', showTemplate: false),
      body: ListView(
        children: [
          const SizedBox(height: 34),
          const Center(
            child: Text('📒', style: TextStyle(fontSize: 52)),
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text('دفتر الحسابات',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600, color: AppColors.navy)),
          ),
          const SizedBox(height: 6),
          const Center(
            child: Text('الإصدار 4.0.0',
                style: TextStyle(fontSize: 13, color: AppColors.sub)),
          ),
          const SizedBox(height: 22),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 36),
            child: Text(
              'سجل متكامل لإدارة الحسابات والديون — عمليات، تصنيفات، تقارير، نسخ احتياطية، وكشف حساب جاهز للطباعة والإرسال.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: AppColors.sub, height: 1.7),
            ),
          ),
          const SizedBox(height: 30),
          const Center(
            child: Text('جميع الحقوق محفوظة © 2026',
                style: TextStyle(fontSize: 12, color: AppColors.faint)),
          ),
        ],
      ),
    );
  }
}
