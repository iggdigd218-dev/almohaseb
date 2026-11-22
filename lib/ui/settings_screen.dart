import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../core/security.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'accounts_screen.dart';
import 'backup_screen.dart';
import 'currencies_screen.dart';
import 'trial_ui.dart' show SubscriptionDetailsSection;
import 'update_section.dart';

// ═══════════════════════════════════════════════════════════════════
//  الإعدادات — واجهة «دفتر الحسابات» الكاملة فوق مخزن نيكسورا المحاسب
// ═══════════════════════════════════════════════════════════════════

/// مفتاح إعداد عام — قراءة سريعة من مخزن الإعدادات.
String stVal(Map<String, String> st, String key, [String def = '']) =>
    (st[key] ?? def).trim();

/// صف إيموجي كما في التصميم: أيقونة يسار + نص.
Widget emojiTile(String emoji, String title, {String? sub, VoidCallback? onTap,
    Widget? trailing, bool enabled = true}) {
  return ListTile(
    enabled: enabled,
    onTap: onTap,
    leading: Text(emoji, style: const TextStyle(fontSize: 22)),
    title: Text(title,
        style: TextStyle(
            fontSize: 15.5,
            fontWeight: FontWeight.w600,
            color: enabled ? AppColors.text : AppColors.text3)),
    subtitle: sub == null
        ? null
        : Text(sub,
            style: TextStyle(fontSize: 12.5, color: AppColors.text3)),
    trailing: trailing ??
        (onTap == null
            ? null
            : const Icon(Icons.chevron_left, color: AppColors.text3)),
  );
}

/// مفتاح تبديل وردي كما في التصميم.
Widget pinkSwitch(bool v, ValueChanged<bool> onChanged) => Switch(
      value: v,
      onChanged: onChanged,
      activeColor: Colors.white,
      activeTrackColor: AppColors.pinkDark,
      inactiveThumbColor: AppColors.toggleOff,
      inactiveTrackColor: AppColors.toggleOffTrack,
    );

/// صف بمفتاح تبديل (العنوان + اختياري سطر فرعي).
Widget switchTile(String emoji, String title, bool v, ValueChanged<bool> on,
    {String? sub}) {
  return emojiTile(emoji, title, sub: sub, trailing: pinkSwitch(v, on));
}

/// شريط علوي موحّد للصفحات الفرعية: سهم رجوع يسار + عنوان.
AppBar subBar(BuildContext context, String title, {List<Widget>? actions}) =>
    AppBar(
      backgroundColor: AppColors.primary,
      foregroundColor: Colors.white,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(title,
          style: const TextStyle(
              fontSize: 19, fontWeight: FontWeight.w700, color: Colors.white)),
      actions: actions,
    );

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final st = ref.watch(settingsProvider).value ?? const <String, String>{};
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: subBar(context, 'الإعدادات', actions: [
        TextButton(
          onPressed: () => _templateDialog(st),
          child: const Text('تغيير القالب',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          emojiTile('📇', 'البيانات الشخصية',
              onTap: () => _open(_PersonalDataScreen(st: st))),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('🖨️', 'خيارات الطابعة',
              onTap: () => _open(_PrinterOptionsScreen(st: st))),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('🔒', 'خيارات الأمان',
              onTap: () => _open(_SecurityOptionsScreen(st: st))),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('📋', 'التصنيفات',
              onTap: () => _open(const AccountsScreen())),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('💰', 'العملات',
              onTap: () => _open(const CurrenciesScreen())),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('🗄️', 'خيارات حفظ البيانات',
              onTap: () => _open(_DataSaveOptionsScreen(st: st))),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('💻', 'إستعراض البيانات من الكمبيوتر',
              onTap: () => _open(const _ComputerViewScreen())),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('📧', 'خيارات الإشعارات',
              onTap: () => _open(_NotificationsOptionsScreen(st: st))),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('🔧', 'خيارات أخرى',
              onTap: () => _open(_OtherOptionsScreen(st: st))),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('💵', 'شراء النسخة الكاملة', onTap: () {
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => const SingleChildScrollView(
                  child: SubscriptionDetailsSection()),
            );
          }),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 12),
          // تحديثات التطبيق — من نظام نيكسورا للتحديث.
          const UpdateSection(),
        ],
      ),
    );
  }

  void _open(Widget w) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => w));

  Future<void> _templateDialog(Map<String, String> st) async {
    final cur = stVal(st, 'tpl.style', '1');
    await showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('تغيير القالب',
            style: TextStyle(fontWeight: FontWeight.w700)),
        children: [
          for (final o in [
            ('1', 'قالب ١'),
            ('2', 'قالب ٢'),
            ('en', 'English'),
          ])
            RadioListTile<String>(
              value: o.$1,
              groupValue: cur,
              activeColor: AppColors.pink,
              title: Text(o.$2),
              onChanged: (v) async {
                await ref.read(repoProvider).setSetting('tpl.style', v!);
                if (ctx.mounted) Navigator.pop(ctx);
                setState(() {});
              },
            ),
        ],
      ),
    );
  }
}

// ═══════════ 1) البيانات الشخصية ═══════════
class _PersonalDataScreen extends ConsumerStatefulWidget {
  const _PersonalDataScreen({required this.st});
  final Map<String, String> st;

  @override
  ConsumerState<_PersonalDataScreen> createState() =>
      _PersonalDataScreenState();
}

class _PersonalDataScreenState extends ConsumerState<_PersonalDataScreen> {
  late final TextEditingController _name =
      TextEditingController(text: stVal(widget.st, 'org.name'));
  late final TextEditingController _address =
      TextEditingController(text: stVal(widget.st, 'address'));
  late final TextEditingController _phone =
      TextEditingController(text: stVal(widget.st, 'phone'));
  late final TextEditingController _enName =
      TextEditingController(text: stVal(widget.st, 'en.name'));
  late final TextEditingController _enAddress =
      TextEditingController(text: stVal(widget.st, 'en.address'));

  @override
  Widget build(BuildContext context) {
    final icon = stVal(widget.st, 'org.icon.b64');
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: subBar(context, 'البيانات الشخصية'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: GestureDetector(
              onTap: _pickLogo,
              child: CircleAvatar(
                radius: 52,
                backgroundColor: AppColors.primarySoft,
                backgroundImage: icon.isEmpty
                    ? null
                    : MemoryImage(base64Decode(icon.split(',').last)),
                child: icon.isEmpty
                    ? const Text('📒',
                        style: TextStyle(
                            fontSize: 40, color: AppColors.primary))
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 20),
          _field(_name, 'الاسم'),
          _field(_address, 'العنوان'),
          _field(_phone, 'رقم الهاتف'),
          const SizedBox(height: 8),
          emojiTile('🖼️', 'تغيير الشعار',
              sub: 'تغيير الشعار الخاص بك', onTap: _pickLogo),
          const Divider(height: 1, color: AppColors.border),
          _field(_enName, 'Name'),
          _field(_enAddress, 'Address'),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('🧾', 'نموذج المصادقة على الحساب', onTap: () {
            showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('نموذج المصادقة على الحساب'),
                content: const Text(
                    'يُطبع نموذج المصادقة أسفل كشف الحساب عند تفعيله من خيارات الطابعة.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('حسناً')),
                ],
              ),
            );
          }),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary2,
                minimumSize: const Size.fromHeight(48)),
            onPressed: _save,
            child: const Text('حفظ',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: TextField(
          controller: c,
          decoration: InputDecoration(
            labelText: label,
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(
                borderRadius: AppRadius.fieldAll,
                borderSide: const BorderSide(color: AppColors.border)),
            enabledBorder: OutlineInputBorder(
                borderRadius: AppRadius.fieldAll,
                borderSide: const BorderSide(color: AppColors.border)),
          ),
        ),
      );

  Future<void> _pickLogo() async {
    final x = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 85);
    if (x == null) return;
    final b64 = base64Encode(await File(x.path).readAsBytes());
    await ref.read(repoProvider).setSetting('org.icon.b64', b64);
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final r = ref.read(repoProvider);
    await r.setSetting('org.name', _name.text.trim());
    await r.setSetting('address', _address.text.trim());
    await r.setSetting('phone', _phone.text.trim());
    await r.setSetting('en.name', _enName.text.trim());
    await r.setSetting('en.address', _enAddress.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('تم الحفظ ✅')));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    _enName.dispose();
    _enAddress.dispose();
    super.dispose();
  }
}

// ═══════════ 2) خيارات الطابعة ═══════════
class _PrinterOptionsScreen extends ConsumerStatefulWidget {
  const _PrinterOptionsScreen({required this.st});
  final Map<String, String> st;

  @override
  ConsumerState<_PrinterOptionsScreen> createState() =>
      _PrinterOptionsScreenState();
}

class _PrinterOptionsScreenState
    extends ConsumerState<_PrinterOptionsScreen> {
  bool _k(String key, [String def = '1']) =>
      stVal(widget.st, key, def) != '0';
  late final TextEditingController _note =
      TextEditingController(text: stVal(widget.st, 'print.note'));
  late final TextEditingController _m1 =
      TextEditingController(text: stVal(widget.st, 'print.termDebit', 'مدين'));
  late final TextEditingController _m2 =
      TextEditingController(text: stVal(widget.st, 'print.termDebit2', 'عليه'));
  late final TextEditingController _c1 =
      TextEditingController(text: stVal(widget.st, 'print.termCredit', 'دائن'));
  late final TextEditingController _c2 =
      TextEditingController(text: stVal(widget.st, 'print.termCredit2', 'له'));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: subBar(context, 'خيارات الطابعة'),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          switchTile('📇', 'إظهار البيانات', _k('print.showPersonal'), (v) =>
              _set('print.showPersonal', v),
              sub: 'طباعة البيانات الشخصية'),
          const Divider(height: 1, color: AppColors.border),
          switchTile('📅', 'إظهار التاريخ', _k('print.showDate'), (v) =>
              _set('print.showDate', v),
              sub: 'إظهار التاريخ أسفل الطباعة'),
          const Divider(height: 1, color: AppColors.border),
          switchTile('⬆️', 'طباعة البيانات تصاعديا', _k('print.asc'), (v) =>
              _set('print.asc', v),
              sub: 'من التاريخ الأقدم للأحدث'),
          const Divider(height: 1, color: AppColors.border),
          switchTile('💰', 'طباعة الكشف بجمع المبالغ',
              _k('print.sumAmounts', '0'), (v) => _set('print.sumAmounts', v)),
          const Divider(height: 1, color: AppColors.border),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _note,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: '🗓️ إضافة ملاحظة أسفل الكشف',
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                    borderRadius: AppRadius.fieldAll,
                    borderSide: const BorderSide(color: AppColors.border)),
              ),
              onChanged: (v) => _set('print.note', v, silent: true),
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          _pairRow('🔽', _m1, _m2, 'print.termDebit', 'print.termDebit2'),
          const Divider(height: 1, color: AppColors.border),
          _pairRow('🔼', _c1, _c2, 'print.termCredit', 'print.termCredit2'),
        ],
      ),
    );
  }

  Widget _pairRow(String emoji, TextEditingController a,
          TextEditingController b, String ka, String kb) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: a,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 10)),
                onChanged: (v) => _set(ka, v, silent: true),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text('/'),
            ),
            Expanded(
              child: TextField(
                controller: b,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 10)),
                onChanged: (v) => _set(kb, v, silent: true),
              ),
            ),
          ],
        ),
      );

  Future<void> _set(String k, dynamic v, {bool silent = false}) async {
    final s = v is bool ? (v ? '1' : '0') : '$v';
    await ref.read(repoProvider).setSetting(k, s);
    if (!silent && mounted) setState(() {});
  }

  @override
  void dispose() {
    _note.dispose();
    _m1.dispose();
    _m2.dispose();
    _c1.dispose();
    _c2.dispose();
    super.dispose();
  }
}

// ═══════════ 3) خيارات الأمان ═══════════
class _SecurityOptionsScreen extends ConsumerStatefulWidget {
  const _SecurityOptionsScreen({required this.st});
  final Map<String, String> st;

  @override
  ConsumerState<_SecurityOptionsScreen> createState() =>
      _SecurityOptionsScreenState();
}

class _SecurityOptionsScreenState
    extends ConsumerState<_SecurityOptionsScreen> {
  bool _req = false;

  @override
  void initState() {
    super.initState();
    _req = stVal(widget.st, 'password.required') == '1';
  }

  @override
  Widget build(BuildContext context) {
    final hasPw = stVal(widget.st, 'password.hash').isNotEmpty;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: subBar(context, 'خيارات الأمان'),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          switchTile('🔑', 'تفعيل كلمة السر', _req, (v) async {
            if (v && !hasPw) {
              await _setPassword();
              return;
            }
            await ref
                .read(repoProvider)
                .setSetting('password.required', v ? '1' : '0');
            setState(() => _req = v);
          }, sub: 'طلب كلمة السر عند الدخول'),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('🤚', 'كلمة السر',
              sub: hasPw ? '******' : 'غير محددة',
              onTap: _setPassword),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 8),
          switchTile('🫆', 'فتح التطبيق بالبصمة',
              stVal(widget.st, 'biometric') == '1', (v) =>
                  _set('biometric', v ? '1' : '0')),
          const Divider(height: 1, color: AppColors.border),
          switchTile('⏸️', 'القفل عند العودة للتطبيق',
              stVal(widget.st, 'autoLock') == '1', (v) =>
                  _set('autoLock', v ? '1' : '0'),
              sub: 'يُطلب التحقق بعد كل تصغير'),
        ],
      ),
    );
  }

  Future<void> _set(String k, String v) async {
    await ref.read(repoProvider).setSetting(k, v);
    if (mounted) setState(() {});
  }

  Future<void> _setPassword() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعيين كلمة السر'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'كلمة السر الجديدة'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ')),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    final r = ref.read(repoProvider);
    await r.setSetting('password.hash', Security.hash(ctrl.text.trim()));
    await r.setSetting('password.required', '1');
    if (mounted) setState(() => _req = true);
  }
}

// ═══════════ 6) خيارات حفظ البيانات ═══════════
class _DataSaveOptionsScreen extends ConsumerStatefulWidget {
  const _DataSaveOptionsScreen({required this.st});
  final Map<String, String> st;

  @override
  ConsumerState<_DataSaveOptionsScreen> createState() =>
      _DataSaveOptionsScreenState();
}

class _DataSaveOptionsScreenState
    extends ConsumerState<_DataSaveOptionsScreen> {
  bool _k(String k, [String def = '1']) => stVal(widget.st, k, def) != '0';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: subBar(context, 'خيارات حفظ البيانات'),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          switchTile('⏰', 'حفظ البيانات يوميا', _k('autosave.on'), (v) =>
              _set('autosave.on', v ? '1' : '0'),
              sub: 'حفظ البيانات ثلاث مرات واحدة باليوم (بشرط تغير البيانات)'),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('📁', 'مجلد حفظ البيانات',
              sub:
                  '/storage/emulated/0/Documents/Market_Customers/<timestamp>/',
              onTap: null),
          const Divider(height: 1, color: AppColors.border),
          switchTile('📷', 'إضافة الصور', _k('save.photos', '0'), (v) =>
              _set('save.photos', v ? '1' : '0')),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('🕐', 'وقت حفظ البيانات',
              sub: '٠٠:٠٠', onTap: () async {
            final t = await showTimePicker(
                context: context,
                initialTime: const TimeOfDay(hour: 0, minute: 0));
            if (t != null) {
              await _set('save.time',
                  '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                  silent: true);
            }
          }),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('💾', 'تغيير الحساب',
              sub: 'الحساب المستخدم للمزامنة السحابية', onTap: () {
            showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('تغيير حساب الدرايف'),
                content: const Text(
                    'يتم تغيير حساب Google Drive من إعدادات المزامنة في لوحة التحكم.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('حسناً')),
                ],
              ),
            );
          }),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('☁️', 'مجلد الدرايف',
              sub: stVal(widget.st, 'cloud.googleId').isNotEmpty
                  ? 'متصل — ${stVal(widget.st, 'cloud.folderName', 'دفتر الحسابات')}'
                  : 'غير متصل — اضغط للربط',
              onTap: _driveFolder),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('📁', 'اسم المجلد في مجلد درايف',
              sub: stVal(widget.st, 'cloud.folderName', 'دفتر الحسابات'),
              onTap: () => _renameDriveFolder(),
              enabled: stVal(widget.st, 'cloud.googleId').isNotEmpty),
          const Divider(height: 1, color: AppColors.border),
          switchTile('🔔', 'إظهار الإشعارات عند إضافة مبلغ',
              _k('notify.onAdd'), (v) => _set('notify.onAdd', v ? '1' : '0')),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 10),
          emojiTile('🗄️', 'النسخ الاحتياطي والاسترجاع', onTap: () =>
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const BackupScreen()))),
        ],
      ),
    );
  }

  /// صف «مجلد الدرايف»: يعرض حالة الربط ويفتح حوار الاتصال.
  Future<void> _driveFolder() async {
    final connected = stVal(widget.st, 'cloud.googleId').isNotEmpty;
    if (!connected) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('ربط مجلد الدرايف'),
          content: const Text(
              'سيتم إنشاء مجلد باسم التطبيق داخل حسابك في Google Drive وحفظ '
              'النسخ الاحتياطية فيه.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('ربط الآن')),
          ],
        ),
      );
      if (ok != true) return;
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('مجلد الدرايف')),
                    body: const BackupScreen(),
                  )));
      if (mounted) setState(() {});
      return;
    }
    await _renameDriveFolder();
  }

  /// تعديل اسم مجلد الدرايف.
  Future<void> _renameDriveFolder() async {
    final ctl = TextEditingController(
        text: stVal(widget.st, 'cloud.folderName', 'دفتر الحسابات'));
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('اسم المجلد في مجلد درايف'),
        content: TextField(
            controller: ctl,
            decoration: const InputDecoration(hintText: 'دفتر الحسابات')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('حفظ')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await _set('cloud.folderName', name);
    }
  }

  Future<void> _set(String k, String v, {bool silent = false}) async {
    await ref.read(repoProvider).setSetting(k, v);
    if (!silent && mounted) setState(() {});
  }
}

// ═══════════ 7) إستعراض البيانات من الكمبيوتر ═══════════
class _ComputerViewScreen extends ConsumerStatefulWidget {
  const _ComputerViewScreen();

  @override
  ConsumerState<_ComputerViewScreen> createState() =>
      _ComputerViewScreenState();
}

class _ComputerViewScreenState extends ConsumerState<_ComputerViewScreen> {
  HttpServer? _server;
  String _url = '';
  String _err = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: subBar(context, 'إستعراض البيانات من الكمبيوتر'),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'شغّل الخادم ثم افتح الرابط أدناه من متصفح الكمبيوتر على نفس شبكة الواي فاي.',
                style: TextStyle(fontSize: 15, color: AppColors.text2)),
            const SizedBox(height: 20),
            if (_url.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: AppRadius.cardAll),
                child: SelectableText(_url,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary)),
              ),
            if (_err.isNotEmpty)
              Text(_err, style: const TextStyle(color: AppColors.danger)),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor:
                      _server == null ? AppColors.primary2 : AppColors.danger,
                  minimumSize: const Size.fromHeight(50)),
              onPressed: _server == null ? _start : _stop,
              icon: Icon(_server == null ? Icons.play_arrow : Icons.stop,
                  color: Colors.white),
              label: Text(_server == null ? 'تشغيل الخادم' : 'إيقاف الخادم',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _start() async {
    try {
      final server =
          await HttpServer.bind(InternetAddress.anyIPv4, 8787);
      final repo = ref.read(repoProvider);
      server.listen((req) async {
        final accounts = await repo.accounts();
        final buf = StringBuffer(
            '<!doctype html><html dir="rtl"><head><meta charset="utf-8"><title>المحاسب</title>'
            '<style>body{font-family:sans-serif;background:#f5f6f8;padding:24px}'
            'table{width:100%;border-collapse:collapse;background:#fff}'
            'th,td{padding:10px;border:1px solid #e6e6e6;text-align:right}'
            'th{background:#3F51B5;color:#fff}</style></head><body>'
            '<h2>المحاسب — بيانات الحسابات</h2><table><tr><th>الاسم</th><th>الرصيد</th><th>النوع</th></tr>');
        for (final a in accounts) {
          buf.write(
              '<tr><td>${a.name}</td><td>${a.openingBalance.toStringAsFixed(0)}</td><td>${a.kind.name}</td></tr>');
        }
        buf.write('</table></body></html>');
        req.response.headers.contentType = ContentType.html;
        req.response.write(buf.toString());
        await req.response.close();
      });
      final ips = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      String ipStr = '127.0.0.1';
      outer:
      for (final ni in ips) {
        for (final raw in ni.addresses) {
          // يتوافق مع اختلاف نوع addresses بين إصدارات Dart
          // (InternetAddress في الأقدم و InterfaceAddress في الأحدث).
          final dynamic d = raw;
          final InternetAddress addr =
              d is InternetAddress ? d : d.address as InternetAddress;
          if (!addr.isLoopback) {
            ipStr = addr.address;
            break outer;
          }
        }
      }
      setState(() {
        _server = server;
        _url = 'http://$ipStr:8787';
        _err = '';
      });
    } catch (e) {
      setState(() => _err = 'تعذّر تشغيل الخادم: $e');
    }
  }

  Future<void> _stop() async {
    await _server?.close(force: true);
    setState(() {
      _server = null;
      _url = '';
    });
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }
}

// ═══════════ 8) خيارات الإشعارات ═══════════
class _NotificationsOptionsScreen extends ConsumerStatefulWidget {
  const _NotificationsOptionsScreen({required this.st});
  final Map<String, String> st;

  @override
  ConsumerState<_NotificationsOptionsScreen> createState() =>
      _NotificationsOptionsScreenState();
}

class _NotificationsOptionsScreenState
    extends ConsumerState<_NotificationsOptionsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: subBar(context, 'خيارات الإشعارات'),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          switchTile('⏰', 'إيقاف التذكير بالتنبيهات',
              stVal(widget.st, 'reminders.muted') == '1',
              (v) => _set('reminders.muted', v ? '1' : '0')),
          const Divider(height: 1, color: AppColors.border),
          switchTile('🔔', 'إظهار الإشعارات عند إضافة مبلغ',
              stVal(widget.st, 'notify.onAdd', '1') != '0',
              (v) => _set('notify.onAdd', v ? '1' : '0')),
        ],
      ),
    );
  }

  Future<void> _set(String k, String v) async {
    await ref.read(repoProvider).setSetting(k, v);
    if (mounted) setState(() {});
  }
}

// ═══════════ 9) خيارات أخرى ═══════════
class _OtherOptionsScreen extends ConsumerStatefulWidget {
  const _OtherOptionsScreen({required this.st});
  final Map<String, String> st;

  @override
  ConsumerState<_OtherOptionsScreen> createState() =>
      _OtherOptionsScreenState();
}

class _OtherOptionsScreenState extends ConsumerState<_OtherOptionsScreen> {
  bool _k(String k, [String def = '0']) => stVal(widget.st, k, def) == '1';

  @override
  Widget build(BuildContext context) {
    final period = stVal(widget.st, 'report.period', 'يومي');
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: subBar(context, 'خيارات أخرى'),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          switchTile('🟢', 'إرسال كشف الحساب عبر واتساب',
              _k('wa.statement', '1'), (v) => _set('wa.statement', v),
              sub: 'إرسال كشف الحساب عبر واتساب'),
          const Divider(height: 1, color: AppColors.border),
          switchTile('Ⓑ', 'إستخدام واتساب للأعمال', _k('wa.business'),
              (v) => _set('wa.business', v)),
          const Divider(height: 1, color: AppColors.border),
          switchTile('⇄', 'إظهار أيقونة التحويل في الشاشة الرئيسية',
              _k('ui.transferIcon'), (v) => _set('ui.transferIcon', v)),
          const Divider(height: 1, color: AppColors.border),
          switchTile('💵', 'إظهار العملات', _k('ui.currencies', '1') ||
              stVal(widget.st, 'ui.currencies', '1') != '0', (v) =>
              _set('ui.currencies', v),
              sub: 'إظهار العملات في إضافة المبلغ'),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('📅', 'الإغلاق السنوي للحسابات', onTap: _annualClosing),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('📇', 'تقرير إجمالي المبالغ', sub: period, onTap: () async {
            final v = await showDialog<String>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: const Text('تقرير إجمالي المبالغ'),
                children: ['يومي', 'شهري', 'سنوي']
                    .map((o) => SimpleDialogOption(
                          onPressed: () => Navigator.pop(ctx, o),
                          child: Text(o),
                        ))
                    .toList(),
              ),
            );
            if (v != null) await _set('report.period', v);
          }),
          const Divider(height: 1, color: AppColors.border),
          switchTile('⏰', 'إيقاف التذكير بالتنبيهات',
              _k('reminders.muted'), (v) => _set('reminders.muted', v)),
          const Divider(height: 1, color: AppColors.border),
          _plainSwitch('إجمالي العمليات أسفل الحساب', _k('ui.totals', '1'),
              (v) => _set('ui.totals', v)),
          const Divider(height: 1, color: AppColors.border),
          _plainSwitch('إظهار وقت العملية في شاشة الحساب',
              _k('ui.txTime', '1'), (v) => _set('ui.txTime', v)),
          const Divider(height: 1, color: AppColors.border),
          _plainSwitch('إظهار المبلغ كتابة عند الإضافة', _k('ui.amountWords'),
              (v) => _set('ui.amountWords', v)),
          const Divider(height: 1, color: AppColors.border),
          _plainSwitch('الوضع الليلي', _k('ui.dark'), (v) => _set('ui.dark', v)),
          const Divider(height: 1, color: AppColors.border),
          _plainSwitch('ترتيب الأسماء أبجديا', _k('ui.sortAlpha'),
              (v) => _set('ui.sortAlpha', v)),
          const Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 10),
          // إضافات نيكسورا المحافظ عليها
          emojiTile('🎨', 'المظهر والأصوات', onTap: _appearance),
          const Divider(height: 1, color: AppColors.border),
          emojiTile('💱', 'العملة الافتراضية',
              sub: stVal(widget.st, 'defaultCurrency', 'YER'), onTap: _currency),
        ],
      ),
    );
  }

  Widget _plainSwitch(String title, bool v, ValueChanged<bool> on) => SwitchListTile(
        value: v,
        onChanged: on,
        activeColor: Colors.white,
        activeTrackColor: AppColors.pinkDark,
        inactiveThumbColor: AppColors.toggleOff,
        inactiveTrackColor: AppColors.toggleOffTrack,
        title: Text(title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      );

  Future<void> _set(String k, dynamic v) async {
    final s = v is bool ? (v ? '1' : '0') : '$v';
    await ref.read(repoProvider).setSetting(k, s);
    if (mounted) setState(() {});
  }

  Future<void> _annualClosing() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('الإغلاق السنوي للحسابات'),
        content: const Text(
            'سيتم تحويل أرصدة كل الحسابات إلى «رصيد افتتاحي» وتصفير الحركات للسنة الجديدة. هل تريد المتابعة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تنفيذ',
                  style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    // يُنفَّذ عبر مستودع البيانات: ترحيل الأرصدة إلى رصيد افتتاحي.
    await ref.read(repoProvider).setSetting('closing.year', DateTime.now().year.toString());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم الإغلاق السنوي ✅')));
    }
  }

  void _appearance() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('المظهر والأصوات'),
        content: const Text('حجم الخط، الأصوات والاهتزاز — من شاشة المظهر.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('حسناً')),
        ],
      ),
    );
  }

  void _currency() {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const CurrenciesScreen()));
  }
}
