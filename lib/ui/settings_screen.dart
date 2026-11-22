import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../core.dart';
import '../main.dart';
import '../update.dart';
import 'widgets.dart';

/// شاشة الإعدادات
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'الإعدادات'),
      body: ListView(
        children: [
          EmojiTile(emoji: '📇', title: 'البيانات الشخصية', onTap: () => _go(context, const PersonalScreen())),
          EmojiTile(emoji: '🖨️', title: 'خيارات الطابعة', onTap: () => _go(context, const PrinterScreen())),
          EmojiTile(emoji: '🔒', title: 'خيارات الأمان', onTap: () => _go(context, const SecurityScreen())),
          EmojiTile(emoji: '📋', title: 'التصنيفات', onTap: () => _go(context, const CategoriesScreen())),
          EmojiTile(emoji: '💰', title: 'العملات', onTap: () => _go(context, const CurrenciesScreen())),
          EmojiTile(emoji: '🗄️', title: 'خيارات حفظ البيانات', onTap: () => _go(context, const BackupOptionsScreen())),
          EmojiTile(emoji: '💻', title: 'إستعراض البيانات من الكمبيوتر', onTap: () => _go(context, const ComputerScreen())),
          EmojiTile(emoji: '📧', title: 'خيارات الإشعارات', onTap: () => _go(context, const NotificationsScreen())),
          EmojiTile(emoji: '🔧', title: 'خيارات أخرى', onTap: () => _go(context, const OtherOptionsScreen())),
          const Divider(height: 1, color: AppColors.line),
          // (2026-11-22) صف التحديثات: النسخة الأصلية لم تكن تملك أي آلية
          // تحديث، فأي إصلاح يبقى خارج أجهزة المستخدمين إلى الأبد.
          const UpdateTile(),
          EmojiTile(emoji: '💵', title: 'شراء النسخة الكاملة', onTap: () => _go(context, const PurchaseScreen())),
        ],
      ),
    );
  }

  void _go(BuildContext context, Widget screen) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }
}

/// ============ البيانات الشخصية ============
class PersonalScreen extends StatefulWidget {
  const PersonalScreen({super.key});

  @override
  State<PersonalScreen> createState() => _PersonalScreenState();
}

class _PersonalScreenState extends State<PersonalScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'البيانات الشخصية'),
      body: ListView(
        children: [
          const SizedBox(height: 18),
          Center(
            child: GestureDetector(
              onTap: _changeLogo,
              child: Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.card,
                  border: Border.all(color: AppColors.primary, width: 2),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 5)],
                ),
                child: Prefs.logoPath.isNotEmpty
                    ? ClipOval(
                        child: Image.file(File(Prefs.logoPath), fit: BoxFit.cover, width: 74, height: 74))
                    : const Center(child: Text('📒\$', style: TextStyle(fontSize: 24, color: AppColors.primary))),
              ),
            ),
          ),
          const SizedBox(height: 16),
          EmojiTile(
            emoji: '👤',
            title: 'الاسم',
            subtitle: Prefs.name.isEmpty ? 'الاسم' : Prefs.name,
            onTap: () => _edit('name', 'الاسم'),
          ),
          EmojiTile(
            emoji: '🏠',
            title: 'العنوان',
            subtitle: Prefs.address.isEmpty ? 'العنوان' : Prefs.address,
            onTap: () => _edit('address', 'العنوان'),
          ),
          EmojiTile(
            emoji: '📞',
            title: 'رقم الهاتف',
            subtitle: Prefs.phone.isEmpty ? 'رقم الهاتف' : Prefs.phone,
            onTap: () => _edit('phone', 'رقم الهاتف'),
          ),
          EmojiTile(
            emoji: '🖼️',
            title: 'تغيير الشعار',
            subtitle: 'تغيير الشعار الخاص بك',
            onTap: _changeLogo,
          ),
          EmojiTile(
            emoji: '👤',
            title: 'Name',
            subtitle: Prefs.nameEn.isEmpty ? 'Name' : Prefs.nameEn,
            onTap: () => _edit('nameEn', 'Name'),
          ),
          EmojiTile(
            emoji: '🏠',
            title: 'Address',
            subtitle: Prefs.addressEn.isEmpty ? 'Address' : Prefs.addressEn,
            onTap: () => _edit('addressEn', 'Address'),
          ),
          EmojiTile(
            emoji: '📇',
            title: 'نموذج المصادقة على الحساب',
            onTap: () => _edit('approvalForm', 'نموذج المصادقة على الحساب',
                hint: 'نص يُطبع أسفل كشف الحساب'),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(String key, String title, {String? hint}) async {
    final v = await textDialog(context, title, initial: Prefs.s(key), hint: hint);
    if (v != null) {
      await Prefs.setS(key, v);
      setState(() {});
    }
  }

  Future<void> _changeLogo() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80);
      if (x != null) {
        final docs = await getApplicationDocumentsDirectory();
        final dest = p.join(docs.path, 'logo.png');
        await File(x.path).copy(dest);
        await Prefs.setS('logoPath', dest);
        setState(() {});
      }
    } catch (_) {}
  }
}

/// ============ خيارات الطابعة ============
class PrinterScreen extends StatefulWidget {
  const PrinterScreen({super.key});

  @override
  State<PrinterScreen> createState() => _PrinterScreenState();
}

class _PrinterScreenState extends State<PrinterScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'خيارات الطابعة'),
      body: ListView(
        children: [
          EmojiTile(
            emoji: '📇',
            title: 'إظهار البيانات',
            subtitle: 'طباعة البيانات الشخصية',
            trailing: pinkSwitch(value: Prefs.printShowData, onChanged: (v) => _set('printShowData', v)),
          ),
          EmojiTile(
            emoji: '📅',
            title: 'إظهار التاريخ',
            subtitle: 'إظهار التاريخ أسفل الطباعة',
            trailing: pinkSwitch(value: Prefs.printShowDate, onChanged: (v) => _set('printShowDate', v)),
          ),
          EmojiTile(
            emoji: '🔤',
            title: 'طباعة البيانات تصاعديا',
            subtitle: 'من التاريخ الأقدم للأحدث',
            trailing: pinkSwitch(value: Prefs.printAscending, onChanged: (v) => _set('printAscending', v)),
          ),
          EmojiTile(
            emoji: '💰',
            title: 'طباعة الكشف بجمع المبالغ',
            trailing: pinkSwitch(value: Prefs.printSum, onChanged: (v) => _set('printSum', v)),
          ),
          EmojiTile(
            emoji: '🗓️',
            title: 'إضافة ملاحظة أسفل الكشف',
            subtitle: Prefs.printNote.isEmpty ? null : Prefs.printNote,
            onTap: () async {
              final v = await textDialog(context, 'ملاحظة أسفل الكشف', initial: Prefs.printNote);
              if (v != null) {
                await Prefs.setS('printNote', v);
                setState(() {});
              }
            },
          ),
          EmojiTile(
            emoji: '▼',
            emojiSize: 15,
            title: Prefs.debitWord1,
            subtitle: Prefs.debitWord2,
            trailing: const Icon(Icons.arrow_drop_down, color: AppColors.red, size: 26),
            onTap: () => _editPair('debitWord1', 'debitWord2', 'كلمة المدين'),
          ),
          EmojiTile(
            emoji: '▲',
            emojiSize: 15,
            title: Prefs.creditWord1,
            subtitle: Prefs.creditWord2,
            trailing: const Icon(Icons.arrow_drop_up, color: AppColors.green, size: 26),
            onTap: () => _editPair('creditWord1', 'creditWord2', 'كلمة الدائن'),
          ),
        ],
      ),
    );
  }

  Future<void> _editPair(String k1, String k2, String title) async {
    final w1 = await textDialog(context, title, initial: Prefs.s(k1, 'مدين'));
    if (w1 != null && w1.trim().isNotEmpty) await Prefs.setS(k1, w1.trim());
    final w2 = await textDialog(context, '$title (الثانية)', initial: Prefs.s(k2, 'عليه'));
    if (w2 != null && w2.trim().isNotEmpty) await Prefs.setS(k2, w2.trim());
    setState(() {});
  }

  void _set(String k, bool v) {
    Prefs.setB(k, v);
    // إخطار جذر التطبيق: تفضيلات المظهر (الوضع الليلي وجمع المبالغ
    // وترتيب الأسماء) تُطبَّق فوراً بدل انتظار إعادة التشغيل.
    notifyPrefsChanged();
    setState(() {});
  }
}

/// ============ خيارات الأمان ============
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  @override
  Widget build(BuildContext context) {
    final has = Prefs.password.isNotEmpty;
    return Scaffold(
      appBar: simpleBar(context, 'خيارات الأمان'),
      body: ListView(
        children: [
          EmojiTile(
            emoji: '🔑',
            title: 'تفعيل كلمة السر',
            subtitle: 'طلب كلمة السر عند الدخول',
            trailing: pinkSwitch(
              value: Prefs.lockEnabled,
              onChanged: (v) async {
                if (v && Prefs.password.isEmpty) {
                  await _setPassword();
                } else {
                  await Prefs.setB('lockEnabled', v);
                }
                setState(() {});
              },
            ),
          ),
          EmojiTile(
            emoji: '🤚',
            title: 'كلمة السر',
            subtitle: has ? '******' : 'غير محددة',
            onTap: () async {
              await _setPassword();
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Future<void> _setPassword() async {
    final v = await textDialog(context, 'كلمة السر', initial: Prefs.password, password: true);
    if (v != null && v.isNotEmpty) {
      await Prefs.setS('password', v);
      await Prefs.setB('lockEnabled', true);
    }
  }
}

/// ============ التصنيفات ============
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'التصنيفات', showTemplate: false, actions: [
        IconButton(
          icon: const Icon(Icons.add, size: 23),
          onPressed: () async {
            final v = await textDialog(context, 'تصنيف جديد', hint: 'اسم التصنيف');
            if (v != null && v.trim().isNotEmpty) {
              await Db.saveCategory(Category(name: v.trim()));
              setState(() {});
            }
          },
        ),
      ]),
      body: FutureBuilder<List<Category>>(
        future: Db.categories(),
        builder: (ctx, snap) {
          final cats = snap.data ?? [];
          return ListView(
            children: [
              for (final c in cats)
                EmojiTile(
                  emoji: '📋',
                  title: c.name,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, size: 19, color: AppColors.faint),
                        onPressed: () async {
                          final v = await textDialog(context, 'تعديل التصنيف', initial: c.name);
                          if (v != null && v.trim().isNotEmpty) {
                            await Db.saveCategory(Category(id: c.id, name: v.trim()));
                            setState(() {});
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, size: 19, color: AppColors.faint),
                        onPressed: () async {
                          await Db.deleteCategory(c.id);
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                ),
              if (cats.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(
                      child: Text('لا توجد تصنيفات — اضغط + لإضافة تصنيف',
                          style: TextStyle(color: AppColors.faint, fontSize: 14))),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// ============ العملات ============
class CurrenciesScreen extends StatefulWidget {
  const CurrenciesScreen({super.key});

  @override
  State<CurrenciesScreen> createState() => _CurrenciesScreenState();
}

class _CurrenciesScreenState extends State<CurrenciesScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'العملات'),
      body: ListView(
        children: [
          for (final e in kCurrencies.entries)
            RadioListTile<String>(
              activeColor: AppColors.pink,
              title: Text('${e.value}  —  ${kCurrencyUnits[e.key]}',
                  style: const TextStyle(fontSize: 15)),
              value: e.key,
              groupValue: Prefs.activeCurrency,
              onChanged: (v) async {
                await Prefs.setS('activeCurrency', v!);
                setState(() {});
              },
            ),
        ],
      ),
    );
  }
}

/// ============ خيارات حفظ البيانات ============
class BackupOptionsScreen extends StatefulWidget {
  const BackupOptionsScreen({super.key});

  @override
  State<BackupOptionsScreen> createState() => _BackupOptionsScreenState();
}

class _BackupOptionsScreenState extends State<BackupOptionsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'خيارات حفظ البيانات'),
      body: ListView(
        children: [
          EmojiTile(
            emoji: '⏰',
            title: 'حفظ البيانات يوميا',
            subtitle: 'حفظ البيانات ثلاث مرات واحدة باليوم (بشرط تغير البيانات)',
            trailing: pinkSwitch(value: Prefs.dailyBackup, onChanged: (v) => _set('dailyBackup', v)),
          ),
          EmojiTile(
            emoji: '📁',
            title: 'مجلد حفظ البيانات',
            subtitle: Prefs.backupFolder.isEmpty
                ? '/storage/emulated/0/Documents/Market_Customers/${DateTime.now().toString().replaceAll(RegExp(r'[-: .]'), '').substring(0, 13)}/'
                : Prefs.backupFolder,
            onTap: () async {
              final v = await textDialog(context, 'مجلد حفظ البيانات', initial: Prefs.backupFolder);
              if (v != null) {
                await Prefs.setS('backupFolder', v);
                setState(() {});
              }
            },
          ),
          EmojiTile(
            emoji: '📷',
            title: 'إضافة الصور',
            trailing: pinkSwitch(value: Prefs.backupPhotos, onChanged: (v) => _set('backupPhotos', v)),
          ),
          EmojiTile(
            emoji: '🕐',
            title: 'وقت حفظ البيانات',
            subtitle: toArabicDigits(Prefs.backupTime),
            onTap: () async {
              final t = await showTimePicker(
                context: context,
                initialTime: TimeOfDay(
                  hour: int.tryParse(Prefs.backupTime.split(':').first) ?? 0,
                  minute: int.tryParse(Prefs.backupTime.split(':').last) ?? 0,
                ),
              );
              if (t != null) {
                await Prefs.setS('backupTime',
                    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
                setState(() {});
              }
            },
          ),
          EmojiTile(
            emoji: '☁️',
            title: 'تغيير الحساب',
            trailing: const DriveIcon(size: 22),
            onTap: () async {
              final v = await textDialog(context, 'حساب الدرايف', initial: Prefs.driveAccount, hint: 'البريد الإلكتروني');
              if (v != null) {
                await Prefs.setS('driveAccount', v.trim());
                setState(() {});
              }
            },
          ),
          EmojiTile(
            emoji: '📁',
            title: 'اسم المجلد في مجلد درايف',
            subtitle: Prefs.driveFolder,
            grayed: Prefs.driveAccount.isEmpty,
            onTap: Prefs.driveAccount.isEmpty
                ? null
                : () async {
                    final v = await textDialog(context, 'اسم المجلد في مجلد درايف', initial: Prefs.driveFolder);
                    if (v != null && v.trim().isNotEmpty) {
                      await Prefs.setS('driveFolder', v.trim());
                      setState(() {});
                    }
                  },
          ),
          EmojiTile(
            emoji: '🔔',
            title: 'إظهار الإشعارات عند إضافة مبلغ',
            trailing: pinkSwitch(value: Prefs.notifOnAdd, onChanged: (v) => _set('notifOnAdd', v)),
          ),
        ],
      ),
    );
  }

  void _set(String k, bool v) {
    Prefs.setB(k, v);
    // إخطار جذر التطبيق: تفضيلات المظهر (الوضع الليلي وجمع المبالغ
    // وترتيب الأسماء) تُطبَّق فوراً بدل انتظار إعادة التشغيل.
    notifyPrefsChanged();
    setState(() {});
  }
}

/// ============ إستعراض البيانات من الكمبيوتر ============
class ComputerScreen extends StatefulWidget {
  const ComputerScreen({super.key});

  @override
  State<ComputerScreen> createState() => _ComputerScreenState();
}

class _ComputerScreenState extends State<ComputerScreen> {
  HttpServer? _server;
  String _url = '';

  Future<void> _toggle() async {
    if (_server != null) {
      await _server!.close(force: true);
      setState(() {
        _server = null;
        _url = '';
      });
      return;
    }
    try {
      final srv = await HttpServer.bind(InternetAddress.anyIPv4, 8765);
      _server = srv;
      srv.listen((req) async {
        final accs = await Db.accounts();
        final buf = StringBuffer(
            '<html dir="rtl"><head><meta charset="utf-8"><title>دفتر الحسابات</title>'
            '<style>body{font-family:sans-serif;padding:20px}table{width:100%;border-collapse:collapse}'
            'td,th{border:1px solid #ccc;padding:8px;text-align:right}</style></head><body>'
            '<h2>دفتر الحسابات — عرض من الكمبيوتر</h2><table>'
            '<tr><th>الحساب</th><th>النوع</th><th>الرصيد</th></tr>');
        for (final a in accs) {
          final bal = await Db.balanceOf(a.id);
          buf.write(
              '<tr><td>${a.name}</td><td>${a.typeLabel}</td><td>${fmtNum(bal.abs())} ${bal >= 0 ? Prefs.debitWord2 : Prefs.creditWord2}</td></tr>');
        }
        buf.write('</table></body></html>');
        req.response.headers.contentType = ContentType.html;
        req.response.write(buf.toString());
        await req.response.close();
      });
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      String ip = '127.0.0.1';
      for (final f in ifs) {
        for (final addr in f.addresses) {
          if (!addr.isLoopback) ip = addr.address;
        }
      }
      setState(() => _url = 'http://$ip:8765');
    } catch (e) {
      setState(() => _url = 'تعذر تشغيل الخادم: $e');
    }
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final running = _server != null;
    return Scaffold(
      appBar: simpleBar(context, 'إستعراض البيانات من الكمبيوتر', showTemplate: false),
      body: ListView(
        children: [
          const SizedBox(height: 26),
          const Center(child: Text('💻', style: TextStyle(fontSize: 46))),
          const SizedBox(height: 14),
          Center(
            child: Text(
              running ? 'الخادم يعمل — افتح الرابط من متصفح الكمبيوتر' : 'اضغط لتشغيل عرض البيانات من الكمبيوتر',
              style: const TextStyle(fontSize: 14, color: AppColors.sub),
            ),
          ),
          const SizedBox(height: 16),
          if (_url.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 30),
              child: SelectableText(_url,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, color: AppColors.primary)),
            ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 50),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: running ? AppColors.red : AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12)),
              onPressed: _toggle,
              child: Text(running ? 'إيقاف الخادم' : 'تشغيل الخادم', style: const TextStyle(fontSize: 15)),
            ),
          ),
        ],
      ),
    );
  }
}

/// ============ خيارات الإشعارات ============
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'خيارات الإشعارات'),
      body: ListView(
        children: [
          EmojiTile(
            emoji: '💲',
            title: 'إشعارات التذكر التلقائي',
            trailing: pinkSwitch(value: Prefs.notifReminders, onChanged: (v) => _set('notifReminders', v)),
          ),
          EmojiTile(
            emoji: '🔔',
            title: 'إشعار يومي بإجمالي الحسابات',
            trailing: pinkSwitch(value: Prefs.notifDaily, onChanged: (v) => _set('notifDaily', v)),
          ),
          EmojiTile(
            emoji: '🔊',
            title: 'صوت الإشعارات',
            trailing: pinkSwitch(value: Prefs.notifSound, onChanged: (v) => _set('notifSound', v)),
          ),
          EmojiTile(
            emoji: '📳',
            title: 'اهتزاز عند الإشعارات',
            trailing: pinkSwitch(value: Prefs.notifVibrate, onChanged: (v) => _set('notifVibrate', v)),
          ),
        ],
      ),
    );
  }

  void _set(String k, bool v) {
    Prefs.setB(k, v);
    // إخطار جذر التطبيق: تفضيلات المظهر (الوضع الليلي وجمع المبالغ
    // وترتيب الأسماء) تُطبَّق فوراً بدل انتظار إعادة التشغيل.
    notifyPrefsChanged();
    setState(() {});
  }
}

/// ============ خيارات أخرى ============
class OtherOptionsScreen extends StatefulWidget {
  const OtherOptionsScreen({super.key});

  @override
  State<OtherOptionsScreen> createState() => _OtherOptionsScreenState();
}

class _OtherOptionsScreenState extends State<OtherOptionsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'خيارات أخرى'),
      body: ListView(
        children: [
          EmojiTile(
            emoji: '',
            leadingWidget: const WhatsAppIcon(size: 26),
            title: 'إرسال كشف الحساب عبر واتساب',
            trailing: pinkSwitch(value: Prefs.whatsappStatement, onChanged: (v) => _set('whatsappStatement', v)),
            dense: false,
          ),
          EmojiTile(
            emoji: '',
            leadingWidget: const WhatsAppIcon(size: 26, business: true),
            title: 'إستخدام واتساب للأعمال',
            trailing: pinkSwitch(value: Prefs.whatsappBusiness, onChanged: (v) => _set('whatsappBusiness', v)),
            dense: false,
          ),
          EmojiTile(
            emoji: '⇄',
            emojiSize: 19,
            title: 'إظهار أيقونة التحويل في الشاشة الرئيسية',
            trailing: pinkSwitch(value: Prefs.showTransferIcon, onChanged: (v) => _set('showTransferIcon', v)),
            dense: false,
          ),
          EmojiTile(
            emoji: '💵',
            title: 'إظهار العملات',
            trailing: pinkSwitch(value: Prefs.showCurrencies, onChanged: (v) => _set('showCurrencies', v)),
            dense: false,
          ),
          EmojiTile(
            emoji: '📅',
            title: 'الإغلاق السنوي للحسابات',
            onTap: _annualClosing,
            dense: false,
          ),
          EmojiTile(
            emoji: '📇',
            title: 'تقرير إجمالي المبالغ',
            subtitle: Prefs.totalsReportFreq,
            onTap: () async {
              await choiceDialog(context, 'تقرير إجمالي المبالغ',
                  ['يومي', 'شهري', 'سنوي'], Prefs.totalsReportFreq, (v) async {
                await Prefs.setS('totalsReportFreq', v);
                setState(() {});
              });
              setState(() {});
            },
            dense: false,
          ),
          EmojiTile(
            emoji: '⏰',
            title: 'إيقاف التذكير بالتنبيهات',
            trailing: pinkSwitch(value: Prefs.stopReminderAlerts, onChanged: (v) => _set('stopReminderAlerts', v)),
            dense: false,
          ),
          EmojiTile(
            emoji: '',
            title: 'إجمالي العمليات أسفل الحساب',
            trailing: pinkSwitch(value: Prefs.totalsBelowAccount, onChanged: (v) => _set('totalsBelowAccount', v)),
            dense: false,
          ),
          EmojiTile(
            emoji: '',
            title: 'إظهار وقت العملية في شاشة الحساب',
            trailing: pinkSwitch(value: Prefs.showTxTime, onChanged: (v) => _set('showTxTime', v)),
            dense: false,
          ),
          EmojiTile(
            emoji: '',
            title: 'إظهار المبلغ كتابة عند الإضافة',
            trailing: pinkSwitch(value: Prefs.amountInWords, onChanged: (v) => _set('amountInWords', v)),
            dense: false,
          ),
          EmojiTile(
            emoji: '',
            title: 'الوضع الليلي',
            trailing: pinkSwitch(value: Prefs.darkMode, onChanged: (v) => _set('darkMode', v)),
            dense: false,
          ),
          EmojiTile(
            emoji: '',
            title: 'ترتيب الأسماء أبجديا',
            trailing: pinkSwitch(value: Prefs.sortAlpha, onChanged: (v) => _set('sortAlpha', v)),
            dense: false,
          ),
        ],
      ),
    );
  }

  Future<void> _annualClosing() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('الإغلاق السنوي للحسابات', style: TextStyle(fontSize: 16)),
        content: const Text(
          'ينقل الإغلاق السنوي أرصدة الحسابات إلى رصيد افتتاحي جديد ويبدأ دفتر حسابات جديد للسنة القادمة.',
          style: TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          TextButton(
            onPressed: () async {
              final accs = await Db.accounts();
              final balances = <int, double>{};
              for (final a in accs) {
                balances[a.id] = await Db.balanceOf(a.id);
              }
              final db = await Db.open();
              await db.delete('txs');
              for (final a in accs) {
                final bal = balances[a.id] ?? 0;
                if (bal != 0) {
                  await Db.saveTx(Tx(
                    accountId: a.id,
                    kind: bal >= 0 ? 1 : 2,
                    amount: bal.abs(),
                    details: 'رصيد افتتاحي — إغلاق سنوي',
                    date: todayISO(),
                    time: nowHM(),
                  ));
                }
              }
              await Prefs.setS('annualClosing', todayISO());
              if (ctx.mounted) Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('تنفيذ الإغلاق', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
  }

  void _set(String k, bool v) {
    Prefs.setB(k, v);
    // إخطار جذر التطبيق: تفضيلات المظهر (الوضع الليلي وجمع المبالغ
    // وترتيب الأسماء) تُطبَّق فوراً بدل انتظار إعادة التشغيل.
    notifyPrefsChanged();
    setState(() {});
  }
}

/// ============ شراء النسخة الكاملة ============
class PurchaseScreen extends StatelessWidget {
  const PurchaseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: simpleBar(context, 'شراء النسخة الكاملة', showTemplate: false),
      body: ListView(
        children: [
          const SizedBox(height: 30),
          const Center(child: Text('💵', style: TextStyle(fontSize: 52))),
          const SizedBox(height: 14),
          const Center(
            child: Text('النسخة الكاملة',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.navy)),
          ),
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 36),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('✓  حسابات وعمليات غير محدودة', style: TextStyle(fontSize: 15, height: 2.2)),
                Text('✓  تقارير كاملة وتفصيلية', style: TextStyle(fontSize: 15, height: 2.2)),
                Text('✓  نسخ احتياطي تلقائي وسحابي', style: TextStyle(fontSize: 15, height: 2.2)),
                Text('✓  كشف حساب PDF وواتساب', style: TextStyle(fontSize: 15, height: 2.2)),
                Text('✓  بدون إعلانات', style: TextStyle(fontSize: 15, height: 2.2)),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 50),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    content: const Text('سيتم تفعيل النسخة الكاملة بعد إتمام عملية الشراء.',
                        style: TextStyle(fontSize: 14.5)),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('حسناً', style: TextStyle(color: AppColors.primary))),
                    ],
                  ),
                );
              },
              child: const Text('شراء الآن', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}
