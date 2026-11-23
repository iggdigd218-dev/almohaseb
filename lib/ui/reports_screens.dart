import 'dart:convert';
import 'dart:io';
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

/// (2026-11-22) إنشاء نسخة احتياطية كاملة — منطق واحد يستخدمه الزر
/// اليدوي والحفظ التلقائي اليومي، فلا يتفرّع السلوك بين مسارين.
Future<String> createBackup({bool silent = false}) async {
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
  await File(p.join(dir.path, 'backup.json'))
      .writeAsString(jsonEncode(data));
  await Prefs.setS('backupFolder', dir.path);
  await Prefs.setS('lastAutoBackup', todayISO());
  if (!silent) {
    await _pruneOldBackups(root, keep: 5);
  }
  return dir.path;
}

/// يحتفظ بآخر [keep] نسخ ويحذف الأقدم — يمنع تضخّم التخزين.
Future<void> _pruneOldBackups(Directory root, {int keep = 5}) async {
  try {
    final dirs = <Directory>[];
    await for (final e in root.list()) {
      if (e is Directory) dirs.add(e);
    }
    dirs.sort((a, b) => b.path.compareTo(a.path)); // الأسماء زمنية
    for (var i = keep; i < dirs.length; i++) {
      try {
        await dirs[i].delete(recursive: true);
      } catch (_) {}
    }
  } catch (_) {}
}

/// (2026-11-22) حفظ تلقائي يومي: إن كان المفتاح مفعّلاً ولم تُحفظ نسخة
/// اليوم، تُنشأ نسخة صامتة عند فتح التطبيق. كان المفتاح يُحفظ بلا أثر.
Future<void> autoBackupIfDue() async {
  if (!Prefs.dailyBackup) return;
  try {
    final last = Prefs.s('lastAutoBackup');
    if (last == todayISO()) return; // حُفظت اليوم
    await createBackup(silent: true);
    await _pruneOldBackups(await backupRoot(), keep: 5);
  } catch (_) {
    // الحفظ التلقائي لا يجب أن يُعطّل الإقلاع أبداً.
  }
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
      final path = await createBackup();
      if (!mounted) return;
      setState(() => _status = 'تم الحفظ في:\n$path');
    } catch (e) {
      if (mounted) setState(() => _status = 'تعذر الحفظ: $e');
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
/// (2026-11-22) قائمة النسخ المحفوظة — تُعرض **داخل التطبيق**.
///
/// سابقاً كان الاسترجاع يفتح منتقي ملفات النظام ثم يطلب من المستخدم
/// الوصول إلى درايف يدوياً. الآن النسخ تُقرأ من مجلد النسخ المحلي وتظهر
/// في قائمة داخل التطبيق، ويُسترجع أي منها بضغطة واحدة. التصدير الخارجي
/// (مشاركة) يبقى خياراً ثانوياً في أسفل الشاشة.
class _BackupEntry {
  final String path; // مسار مجلد النسخة
  final DateTime when;
  final int accounts;
  final int txs;
  final int bytes;
  const _BackupEntry({
    required this.path,
    required this.when,
    required this.accounts,
    required this.txs,
    required this.bytes,
  });

  String get label {
    final d = when;
    final two = (int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}-${two(d.month)}-${d.year}   ${two(d.hour)}:${two(d.minute)}';
  }

  String get summary => '$accounts حساب · $txs عملية · ${_kb(bytes)} ك.ب';

  static String _kb(int b) => (b / 1024).toStringAsFixed(b > 1024 * 100 ? 0 : 1);
}

class RestoreScreen extends StatefulWidget {
  const RestoreScreen({super.key});

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen> {
  List<_BackupEntry> _items = [];
  bool _loading = true;
  String _note = '';

  @override
  void initState() {
    super.initState();
    _scan();
  }

  /// يمسح مجلد النسخ ويعرض كل نسخة قابلة للاسترجاع — بلا أي منتقي ملفات.
  Future<void> _scan() async {
    setState(() => _loading = true);
    final list = <_BackupEntry>[];
    try {
      final root = await backupRoot();
      if (await root.exists()) {
        await for (final e in root.list()) {
          if (e is! Directory) continue;
          final json = File(p.join(e.path, 'backup.json'));
          if (!await json.exists()) continue;
          var accs = 0, txs = 0;
          try {
            final m = jsonDecode(await json.readAsString()) as Map;
            accs = (m['accounts'] as List?)?.length ?? 0;
            txs = (m['txs'] as List?)?.length ?? 0;
          } catch (_) {}
          int bytes = 0;
          final dbFile = File(p.join(e.path, 'ledger.db'));
          if (await dbFile.exists()) bytes += await dbFile.length();
          bytes += await json.length();
          list.add(_BackupEntry(
            path: e.path,
            when: e.statSync().modified,
            accounts: accs,
            txs: txs,
            bytes: bytes,
          ));
        }
      }
      list.sort((a, b) => b.when.compareTo(a.when));
    } catch (e) {
      _note = 'تعذّر قراءة مجلد النسخ: $e';
    }
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  /// استرجاع نسخة محددة: يقرأ JSON ويستبدل البيانات الحالية.
  Future<void> _restore(_BackupEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('استرجاع نسخة'),
        content: Text(
            'سيتم استبدال كل البيانات الحالية ببيانات نسخة:\n${e.label}\n(${e.summary})\n\n'
            'لا يمكن التراجع. هل تريد المتابعة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء', style: TextStyle(color: AppColors.sub))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('استرجاع',
                  style: TextStyle(color: AppColors.red))),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _note = 'جارٍ الاسترجاع...');
    try {
      final json = File(p.join(e.path, 'backup.json'));
      if (!await json.exists()) throw 'ملف النسخة مفقود';
      final data = jsonDecode(await json.readAsString()) as Map<String, dynamic>;
      final db = await Db.open();
      await db.transaction((t) async {
        await t.delete('txs');
        await t.delete('accounts');
        await t.delete('categories');
        for (final a in (data['accounts'] as List? ?? [])) {
          await t.insert('accounts', Map<String, dynamic>.from(a as Map));
        }
        for (final c in (data['categories'] as List? ?? [])) {
          await t.insert('categories', Map<String, dynamic>.from(c as Map));
        }
        for (final t2 in (data['txs'] as List? ?? [])) {
          await t.insert('txs', Map<String, dynamic>.from(t2 as Map));
        }
      });
      if (!mounted) return;
      setState(() => _note = 'تم الاسترجاع بنجاح ✅');
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم استرجاع النسخة بنجاح ✅')));
    } catch (err) {
      if (mounted) setState(() => _note = 'تعذّر الاسترجاع: $err');
    }
  }

  /// تصدير نسخة للخارج (اختياري): مشاركة ملف النسخة عبر أي تطبيق.
  Future<void> _export(_BackupEntry e) async {
    final json = File(p.join(e.path, 'backup.json'));
    if (!await json.exists()) return;
    await Share.shareXFiles([XFile(json.path)],
        text: 'نسخة ${e.label}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'إسترجاع قاعدة البيانات', showTemplate: false,
          actions: [
            IconButton(
              tooltip: 'تحديث القائمة',
              icon: const Icon(Icons.refresh, color: Colors.white),
              onPressed: _scan,
            ),
          ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (_note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(_note,
                        style: TextStyle(
                            fontSize: 12.5, color: AppColors.textSub)),
                  ),
                if (_items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 60, horizontal: 30),
                    child: Column(
                      children: [
                        Text('📂', style: TextStyle(fontSize: 46)),
                        SizedBox(height: 14),
                        Text('لا توجد نسخ محفوظة',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppColors.navy)),
                        SizedBox(height: 6),
                        Text('اذهب إلى «حفظ نسخة إحتياطية» لتُنشئ أول نسخة.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12.5, color: AppColors.sub)),
                      ],
                    ),
                  )
                else ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Text('النسخ المحفوظة على هذا الجهاز',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.navy)),
                  ),
                  for (final e in _items)
                    EmojiTile(
                      emoji: '🗂️',
                      title: e.label,
                      subtitle: e.summary,
                      dense: false,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'تصدير',
                            icon: const Icon(Icons.ios_share,
                                size: 19, color: AppColors.primary),
                            onPressed: () => _export(e),
                          ),
                          TextButton(
                            onPressed: () => _restore(e),
                            child: const Text('استرجاع',
                                style: TextStyle(color: AppColors.primary)),
                          ),
                        ],
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 18, 16, 8),
                    child: Text(
                        'الاسترجاع يستبدل كل البيانات الحالية. صدّر نسخة احتياطية قبل المتابعة إن كنت غير متأكد.',
                        style: TextStyle(fontSize: 11.5, color: AppColors.faint)),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

/// ============ النسخ الاحتياطي على جوجل درايف ============
///
/// (2026-11-22) كانت هذه الشاشة **وهمية بالكامل**: حقل «حساب الدرايف» مجرد
/// خانة نص تُحفظ في التفضيلات بلا أي أثر، وزر «فتح جوجل درايف» يفتح المتصفح
/// على drive.google.com ولا يرفع شيئاً. فأوهمت المستخدم بأن بياناته محفوظة
/// سحابياً وهي ليست كذلك — وهذا أخطر من غياب الميزة.
///
/// القرار: تُعرض الآن حالة صادقة + وجهة بديلة تعمل فعلاً (مشاركة الملف
/// إلى درايف عبر تطبيق Drive المثبّت، أو استعراض النسخ المحلي داخل التطبيق).
class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key});

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  bool _busy = false;

  /// يشارك أحدث نسخة احتياطية محلية عبر تطبيق Drive المثبّت على الجهاز.
  /// هذا يعمل بلا أي تسجيل دخول داخل التطبيق: المستخدم يختار الحساب في
  /// نافذة المشاركة التي يعرضها نظام أندرويد نفسه.
  Future<void> _shareLatestToDrive() async {
    setState(() => _busy = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory(dir.path);
      final files = <File>[];
      if (await folder.exists()) {
        await for (final e in folder.list()) {
          if (e is File && e.path.endsWith('.nexora')) files.add(e);
        }
      }
      if (files.isEmpty) {
        // لا نسخة بعد: ننشئ واحدة الآن ثم نشاركها.
        await createBackup(silent: true);
        await for (final e in folder.list()) {
          if (e is File && e.path.endsWith('.nexora')) files.add(e);
        }
      }
      if (files.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('تعذّر إنشاء نسخة احتياطية')));
        }
        return;
      }
      files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      await Share.shareXFiles([XFile(files.first.path)],
          text: 'نسخة احتياطية — المحاسب');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذّر المشاركة: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'النسخ الاحتياطي السحابي', showTemplate: false),
      body: ListView(
        children: [
          const SizedBox(height: 20),
          const Center(child: DriveIcon(size: 54)),
          const SizedBox(height: 16),
          // حالة صادقة بدل الوهم السابق.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.warnBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.warnLine),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('الرفع التلقائي إلى درايف غير مُفعّل',
                      style: TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w700)),
                  SizedBox(height: 6),
                  Text(
                    'التطبيق لا يسجّل دخولاً إلى جوجل ولا يرفع شيئاً تلقائياً. '
                    'ما يلي طريقة تعمل فعلاً: تُشارك النسخة إلى تطبيق Drive '
                    'المثبّت على جهازك، وتختار الحساب في نافذة المشاركة.',
                    style: TextStyle(fontSize: 11.5, height: 1.6),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          EmojiTile(
            emoji: '📤',
            title: 'إرسال أحدث نسخة إلى درايف',
            subtitle: _busy
                ? 'جارٍ التحضير…'
                : 'ينشئ نسخة ويفتح نافذة المشاركة — اختر Drive ثم الحساب',
            onTap: _busy ? null : _shareLatestToDrive,
          ),
          EmojiTile(
            emoji: '🗂️',
            title: 'النسخ المحفوظة على الجهاز',
            subtitle: 'استعراض واسترجاع داخل التطبيق — لا يحتاج إنترنت',
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RestoreScreen())),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Text(
              'الرفع التلقائي إلى درايف يحتاج تسجيل دخول جوجل وموافقة '
              'Drive API — ميزة غير مبنية بعد.',
              style: TextStyle(fontSize: 11, color: AppColors.faint, height: 1.6),
            ),
          ),
          const SizedBox(height: 24),
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
