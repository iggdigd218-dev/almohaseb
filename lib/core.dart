import 'dart:ui' show Color;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

// ============================================================
//  دفتر الحسابات — النواة: قاعدة البيانات والإعدادات والتنسيقات
// ============================================================

class Tx {
  final int id;
  final int accountId;
  final int kind; // 1 = عليه (مدين) ، 2 = له (دائن)
  final double amount;
  final String details;
  final String date; // yyyy-MM-dd
  final String time; // HH:mm
  final String photo;
  final String currency; // local / dollar / saudi

  Tx({
    this.id = 0,
    required this.accountId,
    required this.kind,
    required this.amount,
    this.details = '',
    required this.date,
    this.time = '',
    this.photo = '',
    this.currency = 'local',
  });

  factory Tx.fromMap(Map<String, dynamic> m) => Tx(
        id: m['id'] as int,
        accountId: m['account_id'] as int,
        kind: m['kind'] as int,
        amount: (m['amount'] as num).toDouble(),
        details: (m['details'] ?? '') as String,
        date: (m['date'] ?? '') as String,
        time: (m['time'] ?? '') as String,
        photo: (m['photo'] ?? '') as String,
        currency: (m['currency'] ?? 'local') as String,
      );

  Map<String, dynamic> toMap() => {
        if (id != 0) 'id': id,
        'account_id': accountId,
        'kind': kind,
        'amount': amount,
        'details': details,
        'date': date,
        'time': time,
        'photo': photo,
        'currency': currency,
      };
}

class Account {
  final int id;
  final String name;
  final String type; // general / customers / suppliers
  final int categoryId;
  final String note;

  Account({
    this.id = 0,
    required this.name,
    this.type = 'general',
    this.categoryId = 0,
    this.note = '',
  });

  factory Account.fromMap(Map<String, dynamic> m) => Account(
        id: m['id'] as int,
        name: (m['name'] ?? '') as String,
        type: (m['type'] ?? 'general') as String,
        categoryId: (m['category_id'] ?? 0) as int,
        note: (m['note'] ?? '') as String,
      );

  Map<String, dynamic> toMap() => {
        if (id != 0) 'id': id,
        'name': name,
        'type': type,
        'category_id': categoryId,
        'note': note,
      };

  String get typeLabel => switch (type) {
        'customers' => 'عملاء',
        'suppliers' => 'موردين',
        _ => 'عام',
      };
}

class Category {
  final int id;
  final String name;
  Category({this.id = 0, required this.name});
  factory Category.fromMap(Map<String, dynamic> m) =>
      Category(id: m['id'] as int, name: (m['name'] ?? '') as String);
  Map<String, dynamic> toMap() => {
        if (id != 0) 'id': id,
        'name': name,
      };
}

class Reminder {
  final int id;
  final String accountName;
  final double amount;
  final String date;
  final String note;
  final int done;
  Reminder({
    this.id = 0,
    required this.accountName,
    required this.amount,
    required this.date,
    this.note = '',
    this.done = 0,
  });
  factory Reminder.fromMap(Map<String, dynamic> m) => Reminder(
        id: m['id'] as int,
        accountName: (m['account_name'] ?? '') as String,
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        date: (m['date'] ?? '') as String,
        note: (m['note'] ?? '') as String,
        done: (m['done'] ?? 0) as int,
      );
  Map<String, dynamic> toMap() => {
        if (id != 0) 'id': id,
        'account_name': accountName,
        'amount': amount,
        'date': date,
        'note': note,
        'done': done,
      };
}

class AppColors {
  static const primary = Color(0xFF3F51B5); // أزرق الأشرطة
  static const deep = Color(0xFF335AB8); // الأزرق السفلي والأزرار
  static const pink = Color(0xFFFF4081); // الوردي (التحديد)
  static const toggleOn = Color(0xFFFA3F7F);
  static const toggleTrack = Color(0xFFFFCEDE);
  static const toggleOff = Color(0xFFBDBDBD);
  static const toggleOffTrack = Color(0xFFECECEC);
  static const ink = Color(0xFF212121);
  static const sub = Color(0xFF757575);
  static const faint = Color(0xFF9E9E9E);
  static const line = Color(0xFFE6E6E6);
  static const navy = Color(0xFF1A237E);
  static const badge = Color(0xFF9BB8DC);
  static const red = Color(0xFFE8352B);
  static const green = Color(0xFF3CCC3C);
  static const pdfRed = Color(0xFFE94C3A);
  static const waGreen = Color(0xFF25D366);
  static const waBizGreen = Color(0xFF075E54);
  static const driveBlue = Color(0xFF4285F4);
  static const driveGreen = Color(0xFF0F9D58);
  static const driveYellow = Color(0xFFF4B400);
}

const kCurrencies = <String, String>{
  'local': 'محلي',
  'dollar': 'دولار',
  'saudi': 'سعودي',
};

const kCurrencyUnits = <String, String>{
  'local': 'ريال يمني',
  'dollar': 'دولار أمريكي',
  'saudi': 'ريال سعودي',
};

const kTypeLabels = <String, String>{
  'general': 'عام',
  'customers': 'عملاء',
  'suppliers': 'موردين',
};

String fmtNum(double v) {
  final neg = v < 0;
  var s = v.abs().toStringAsFixed(v.abs() == v.abs().roundToDouble() ? 0 : 2);
  final parts = s.split('.');
  final buf = StringBuffer();
  final digits = parts[0];
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  s = parts.length > 1 ? '${buf}.${parts[1]}' : buf.toString();
  return neg ? '-$s' : s;
}

String todayISO() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

String nowHM() {
  final n = DateTime.now();
  return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
}

/// yyyy-MM-dd  ->  dd-MM-yyyy
String isoToDisplay(String iso) {
  final parts = iso.split('-');
  if (parts.length != 3) return iso;
  return '${parts[2]}-${parts[1]}-${parts[0]}';
}

String displayToIso(String disp) {
  final parts = disp.split('-');
  if (parts.length != 3) return todayISO();
  return '${parts[2]}-${parts[1]}-${parts[0]}';
}

String monthLabel(String iso) {
  const names = [
    '', 'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
    'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'
  ];
  final parts = iso.split('-');
  if (parts.length < 2) return iso;
  final m = int.tryParse(parts[1]) ?? 1;
  return '${names[m]} ${parts[0]}';
}

/// أرقام عربية هندية للعرض في مواضع محددة (مثل وقت الحفظ)
String toArabicDigits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  return s.replaceAllMapped(RegExp(r'\d'), (m) => ar[int.parse(m[0]!)]);
}

// ------------------------------------------------------------
//  إعدادات التطبيق (SharedPreferences)
// ------------------------------------------------------------
class Prefs {
  static late SharedPreferences _p;
  static Future<void> init() async => _p = await SharedPreferences.getInstance();

  static bool b(String k, [bool d = false]) => _p.getBool(k) ?? d;
  static String s(String k, [String d = '']) => _p.getString(k) ?? d;
  static Future<void> setB(String k, bool v) => _p.setBool(k, v);
  static Future<void> setS(String k, String v) => _p.setString(k, v);

  // البيانات الشخصية
  static String get name => s('name');
  static String get address => s('address');
  static String get phone => s('phone');
  static String get nameEn => s('nameEn');
  static String get addressEn => s('addressEn');
  static String get logoPath => s('logoPath');
  static String get approvalForm => s('approvalForm');

  // القالب
  static String get template => s('template', '1');

  // الطابعة
  static bool get printShowData => b('printShowData', true);
  static bool get printShowDate => b('printShowDate', true);
  static bool get printAscending => b('printAscending', true);
  static bool get printSum => b('printSum', false);
  static String get printNote => s('printNote');
  static String get debitWord1 => s('debitWord1', 'مدين');
  static String get debitWord2 => s('debitWord2', 'عليه');
  static String get creditWord1 => s('creditWord1', 'دائن');
  static String get creditWord2 => s('creditWord2', 'له');

  // الأمان
  static bool get lockEnabled => b('lockEnabled');
  static String get password => s('password');

  // حفظ البيانات
  static bool get dailyBackup => b('dailyBackup', true);
  static String get backupFolder => s('backupFolder');
  static bool get backupPhotos => b('backupPhotos', false);
  static String get backupTime => s('backupTime', '00:00');
  static String get driveAccount => s('driveAccount');
  static String get driveFolder => s('driveFolder', 'دفتر الحسابات');
  static bool get notifOnAdd => b('notifOnAdd', true);

  // الإشعارات
  static bool get notifReminders => b('notifReminders', true);
  static bool get notifSound => b('notifSound', false);
  static bool get notifVibrate => b('notifVibrate', false);
  static bool get notifDaily => b('notifDaily', false);

  // خيارات أخرى
  static bool get whatsappStatement => b('whatsappStatement', true);
  static bool get whatsappBusiness => b('whatsappBusiness', false);
  static bool get showTransferIcon => b('showTransferIcon', false);
  static bool get showCurrencies => b('showCurrencies', true);
  static String get annualClosing => s('annualClosing');
  static String get totalsReportFreq => s('totalsReportFreq', 'يومي');
  static bool get stopReminderAlerts => b('stopReminderAlerts', false);
  static bool get totalsBelowAccount => b('totalsBelowAccount', true);
  static bool get showTxTime => b('showTxTime', true);
  static bool get amountInWords => b('amountInWords', false);
  static bool get darkMode => b('darkMode', false);
  static bool get sortAlpha => b('sortAlpha', false);

  static String get activeCurrency => s('activeCurrency', 'local');
  static String get activeCurrencyLabel => kCurrencies[activeCurrency] ?? 'محلي';
}

// ------------------------------------------------------------
//  قاعدة البيانات
// ------------------------------------------------------------
class Db {
  static Database? _db;
  static String dbPath = '';

  static Future<Database> open() async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    dbPath = p.join(dir.path, 'ledger.db');
    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE accounts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            type TEXT NOT NULL DEFAULT 'general',
            category_id INTEGER NOT NULL DEFAULT 0,
            note TEXT NOT NULL DEFAULT ''
          )''');
        await db.execute('''
          CREATE TABLE txs(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id INTEGER NOT NULL,
            kind INTEGER NOT NULL,
            amount REAL NOT NULL,
            details TEXT NOT NULL DEFAULT '',
            date TEXT NOT NULL,
            time TEXT NOT NULL DEFAULT '',
            photo TEXT NOT NULL DEFAULT '',
            currency TEXT NOT NULL DEFAULT 'local'
          )''');
        await db.execute('''
          CREATE TABLE categories(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL
          )''');
        await db.execute('''
          CREATE TABLE reminders(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_name TEXT NOT NULL,
            amount REAL NOT NULL DEFAULT 0,
            date TEXT NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            done INTEGER NOT NULL DEFAULT 0
          )''');
      },
    );
    return _db!;
  }

  // ----- الحسابات -----
  static Future<List<Account>> accounts({String? type}) async {
    final db = await open();
    final rows = await db.query('accounts',
        where: type == null ? null : 'type = ?',
        whereArgs: type == null ? null : [type],
        orderBy: Prefs.sortAlpha ? 'name COLLATE NOCASE ASC' : 'id DESC');
    return rows.map(Account.fromMap).toList();
  }

  static Future<Account?> accountByName(String name) async {
    final db = await open();
    final rows = await db.query('accounts', where: 'name = ?', whereArgs: [name], limit: 1);
    return rows.isEmpty ? null : Account.fromMap(rows.first);
  }

  static Future<int> saveAccount(Account a) async {
    final db = await open();
    if (a.id == 0) return db.insert('accounts', a.toMap());
    await db.update('accounts', a.toMap(), where: 'id = ?', whereArgs: [a.id]);
    return a.id;
  }

  static Future<void> deleteAccount(int id) async {
    final db = await open();
    await db.delete('txs', where: 'account_id = ?', whereArgs: [id]);
    await db.delete('accounts', where: 'id = ?', whereArgs: [id]);
  }

  /// يجلب الحساب بالاسم أو ينشئه
  static Future<Account> ensureAccount(String name, {String type = 'general'}) async {
    final exist = await accountByName(name.trim());
    if (exist != null) return exist;
    final id = await saveAccount(Account(name: name.trim(), type: type));
    return Account(id: id, name: name.trim(), type: type);
  }

  // ----- العمليات -----
  static Future<List<Tx>> txsOf(int accountId) async {
    final db = await open();
    final rows = await db.query('txs', where: 'account_id = ?', whereArgs: [accountId], orderBy: 'date DESC, time DESC, id DESC');
    return rows.map(Tx.fromMap).toList();
  }

  static Future<List<Tx>> allTxs() async {
    final db = await open();
    final rows = await db.query('txs', orderBy: 'date DESC, time DESC, id DESC');
    return rows.map(Tx.fromMap).toList();
  }

  static Future<int> saveTx(Tx t) async {
    final db = await open();
    if (t.id == 0) return db.insert('txs', t.toMap());
    await db.update('txs', t.toMap(), where: 'id = ?', whereArgs: [t.id]);
    return t.id;
  }

  static Future<void> deleteTx(int id) async {
    final db = await open();
    await db.delete('txs', where: 'id = ?', whereArgs: [id]);
  }

  /// رصيد الحساب: موجب = عليه ، سالب = له
  static Future<double> balanceOf(int accountId) async {
    final db = await open();
    final rows = await db.rawQuery(
        'SELECT SUM(CASE WHEN kind = 1 THEN amount ELSE -amount END) AS s FROM txs WHERE account_id = ?',
        [accountId]);
    return (rows.first['s'] as num?)?.toDouble() ?? 0;
  }

  static Future<int> txCount(int accountId) async {
    final db = await open();
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM txs WHERE account_id = ?', [accountId]);
    return (rows.first['c'] as int?) ?? 0;
  }

  // ----- التصنيفات -----
  static Future<List<Category>> categories() async {
    final db = await open();
    final rows = await db.query('categories', orderBy: 'id ASC');
    return rows.map(Category.fromMap).toList();
  }

  static Future<int> saveCategory(Category c) async {
    final db = await open();
    if (c.id == 0) return db.insert('categories', c.toMap());
    await db.update('categories', c.toMap(), where: 'id = ?', whereArgs: [c.id]);
    return c.id;
  }

  static Future<void> deleteCategory(int id) async {
    final db = await open();
    await db.delete('categories', where: 'id = ?', whereArgs: [id]);
    await db.update('accounts', {'category_id': 0}, where: 'category_id = ?', whereArgs: [id]);
  }

  // ----- التذكير -----
  static Future<List<Reminder>> reminders() async {
    final db = await open();
    final rows = await db.query('reminders', orderBy: 'date ASC');
    return rows.map(Reminder.fromMap).toList();
  }

  static Future<int> saveReminder(Reminder r) async {
    final db = await open();
    if (r.id == 0) return db.insert('reminders', r.toMap());
    await db.update('reminders', r.toMap(), where: 'id = ?', whereArgs: [r.id]);
    return r.id;
  }

  static Future<void> deleteReminder(int id) async {
    final db = await open();
    await db.delete('reminders', where: 'id = ?', whereArgs: [id]);
  }

  // ----- الإحصاءات -----
  static Future<Map<String, double>> typeTotals(String type) async {
    final db = await open();
    final rows = await db.rawQuery('''
      SELECT SUM(CASE WHEN t.kind = 1 THEN t.amount ELSE 0 END) AS d,
             SUM(CASE WHEN t.kind = 2 THEN t.amount ELSE 0 END) AS c
      FROM txs t JOIN accounts a ON a.id = t.account_id
      WHERE a.type = ?''', [type]);
    return {
      'debit': (rows.first['d'] as num?)?.toDouble() ?? 0,
      'credit': (rows.first['c'] as num?)?.toDouble() ?? 0,
    };
  }
}

/// ملخص رصيد حساب
class BalanceInfo {
  final double balance; // موجب = عليه
  BalanceInfo(this.balance);
  bool get isDebit => balance >= 0;
  double get amount => balance.abs();
}
