
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_contacts/flutter_contacts.dart' hide Account;

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../core/models.dart';
import '../core/permission_dialog.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import 'widgets.dart';
import '../core/platform_info.dart';

/// فتح نموذج إضافة/تعديل حساب.
///
/// (2026-09-24) نموذج منبثق سفلي بانحناء علوي 24px بدل شاشة كاملة —
/// نفس المحتوى (AccountFormScreen) بلا أي تغيير في المنطق أو الحفظ.
Future<bool> openAccountForm(
  BuildContext context,
  WidgetRef ref, {
  Account? existing,
}) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(ctx).height * 0.85,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(ctx),
          borderRadius: AppRadius.sheetTop,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderOf(ctx),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Flexible(
                child: AccountFormScreen(
                  existing: existing,
                  embedded: true,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return r ?? false;
}

class AccountFormScreen extends ConsumerStatefulWidget {
  final Account? existing;

  /// `true` حين يُعرض داخل ورقة سفلية: يلغي الشريط العلوي والخلفية
  /// المستقلّين (الورقة توفّرهما) ويكتفي بالمحتوى.
  final bool embedded;

  const AccountFormScreen({super.key, this.existing, this.embedded = false});

  @override
  ConsumerState<AccountFormScreen> createState() => _State();
}

class _State extends ConsumerState<AccountFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _opening;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _notes;
  late final TextEditingController _category;
  late final TextEditingController _limit;
  late final TextEditingController _tags;

  late AccountKind _kind;
  late String _currency;
  late bool _archived;

  /// قناة إرسال إشعار السند لهذا الحساب.
  late String _notifyChannel;

  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final a = widget.existing;
    _name = TextEditingController(text: a?.name ?? '');
    _opening = TextEditingController(
      text: a == null || a.openingBalance == 0
          ? ''
          : Fmt.money(a.openingBalance, 2),
    );
    _phone = TextEditingController(
      text: a?.whatsapp.isNotEmpty == true ? a!.whatsapp : (a?.phone ?? ''),
    );
    _address = TextEditingController(text: a?.address ?? '');
    _notes = TextEditingController(text: a?.notes ?? '');
    _category = TextEditingController(text: a?.category ?? '');
    _limit = TextEditingController(
      text: a?.creditLimit == null ? '' : Fmt.money(a!.creditLimit!, 2),
    );
    _tags = TextEditingController(text: a?.tags.join('، ') ?? '');
    _kind = a?.kind ?? AccountKind.customer;
    _currency = a?.currency ?? 'YER';
    _archived = a?.archived ?? false;
    _notifyChannel = a?.notifyChannel ?? 'whatsapp';
    _initialSnapshot = _formSnapshot();
  }

  /// بصمة قيم النموذج — لاكتشاف التغييرات غير المحفوظة عند الرجوع.
  late String _initialSnapshot;
  String _formSnapshot() => [
        _name.text,
        _opening.text,
        _phone.text,
        _address.text,
        _notes.text,
        _category.text,
        _limit.text,
        _tags.text,
        _kind.name,
        _currency,
        '$_archived',
        _notifyChannel,
      ].join('\u0001');

  bool get _dirty => _formSnapshot() != _initialSnapshot;

  /// حارس التغييرات: يسأل قبل تجاهل تعديلات لم تُحفظ.
  Future<void> _guardedPop(bool didPop) async {
    if (didPop || _saving) return;
    if (!_dirty) {
      Navigator.of(context).maybePop();
      return;
    }
    final discard = await confirmDialog(
      context,
      title: 'تغييرات غير محفوظة',
      message: 'هل تريد تجاهل التغييرات؟',
      confirmText: 'تجاهل',
      danger: true,
    );
    if (discard && mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _opening,
      _phone,
      _address,
      _notes,
      _category,
      _limit,
      _tags,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final rawOpening = _opening.text.trim();
      final parsedOpening = Fmt.parseAmount(rawOpening) ?? 0;
      final double finalOpening = parsedOpening;
      final limit = Fmt.parseAmount(_limit.text);
      final now = DateTime.now();

      final acc = Account(
        id: widget.existing?.id,
        name: _name.text.trim(),
        kind: _kind,
        openingBalance: finalOpening,
        currency: _currency,
        phone: Fmt.phoneDigits(_phone.text),
        whatsapp: Fmt.phoneDigits(_phone.text),
        address: _address.text.trim(),
        notes: _notes.text.trim(),
        category: widget.existing?.category ?? '',
        creditLimit: limit,
        tags: _tags.text
            .split(RegExp('[,،]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        archived: _archived,
        notifyChannel: _notifyChannel,
        createdAt: widget.existing?.createdAt ?? now,
        updatedAt: now,
      );

      await ref.read(repoProvider).saveAccount(acc);
      if (!mounted) return;
      bump(ref);
      Navigator.pop(context, true);
      showSnack(context, _isEdit ? 'تم تحديث الحساب' : 'تمت إضافة الحساب');
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر الحفظ: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// جلب اسم ورقم العميل من تطبيق جهات الاتصال (منتقي النظام الخارجي).
  Future<void> _pickContact() async {
    if (!PlatformInfo.isMobile) {
      showSnack(context, 'اختيار جهة الاتصال متاح على الهاتف فقط', error: true);
      return;
    }
    try {
      // بعض الأجهزة تشترط إذن جهات الاتصال لقراءة بيانات الجهة المختارة
      // بعد عودتها من المنتقي الخارجي. نطلبه مرة واحدة بنافذة شرح ودّية،
      // فيظهر بعدها ضمن «الأذونات المسموح بها» في إعدادات النظام.
      final granted = await FlutterContacts.requestPermission(readonly: true);
      if (!granted) {
        if (!mounted) return;
        final retry = await showPermissionRationale(
            context, PermissionRationale.contacts);
        if (!retry) return;
        final second = await FlutterContacts.requestPermission(readonly: true);
        if (!second) {
          if (mounted) {
            showSnack(
              context,
              'لم يُمنح إذن جهات الاتصال — فعّله من إعدادات النظام: '
              'التطبيقات ← مدير الحسابات ← الأذونات',
              error: true,
            );
          }
          return;
        }
      }
      if (!mounted) return;
      // يفتح منتقي جهات اتصال النظام ويعيد جهة واحدة (لا يقرأ كل الجهات).
      final contact = await FlutterContacts.openExternalPick();
      if (contact == null) return; // ألغى المستخدم.
      final name = contact.displayName.trim();
      final phone = contact.phones.isNotEmpty
          ? Fmt.phoneDigits(contact.phones.first.number)
          : '';
      setState(() {
        if (name.isNotEmpty && (_name.text.trim().isEmpty || !_isEdit)) {
          _name.text = name;
        }
        if (phone.isNotEmpty) _phone.text = phone;
      });
      Sfx.success();
      if (mounted) showSnack(context, 'تم جلب بيانات العميل من جهات الاتصال');
    } catch (e) {
      if (mounted) {
        showSnack(context, 'تعذّر جلب جهة الاتصال: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;

    return PopScope(
      // منع الرجوع المباشر إذا كانت هناك تغييرات لم تُحفظ.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) => _guardedPop(didPop),
      child: Scaffold(
        backgroundColor:
            widget.embedded ? Colors.transparent : null,
        // داخل الورقة السفلية: ترويسة مدمجة أنحف بدل AppBar كامل.
        appBar: widget.embedded
            ? null
            : AppBar(title: Text(_isEdit ? 'تعديل حساب' : 'حساب جديد')),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              widget.embedded ? 6 : 12,
              16,
              16,
            ),
            children: [
              if (widget.embedded)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    _isEdit ? 'تعديل حساب' : 'حساب جديد',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              // زر جلب بيانات العميل (اسم + رقم) من تطبيق جهات الاتصال.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _name,
                      decoration:
                          const InputDecoration(labelText: 'اسم الحساب *'),
                      textInputAction: TextInputAction.next,
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'الاسم مطلوب' : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: IconButton.filledTonal(
                      tooltip: 'جلب من جهات الاتصال',
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.blue.withValues(alpha: 0.12),
                        foregroundColor: Colors.blue.shade700,
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(Icons.contacts_rounded),
                      onPressed: _pickContact,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Text(
                      'نوع الحساب:',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Wrap(
                        spacing: 5,
                        children: AccountKind.values
                            .map(
                              (k) => ChoiceChip(
                                label: Text(
                                  '${k.icon} ${k.label}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 0,
                                ),
                                selected: _kind == k,
                                showCheckmark: false,
                                onSelected: (_) => setState(() => _kind = k),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: _opening,
                decoration: const InputDecoration(
                  labelText: 'الرصيد الافتتاحي (اختياري)',
                  hintText: '0.00',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                validator: (v) {
                  if ((v ?? '').trim().isEmpty) return null;
                  return Fmt.parseAmount(v!) == null ? 'مبلغ غير صالح' : null;
                },
              ),
              AmountWords(controller: _opening, decimals: 2),
              const SizedBox(height: 13),
              DropdownButtonFormField<String>(
                initialValue:
                    curs.any((c) => c.code == _currency) ? _currency : null,
                decoration: const InputDecoration(labelText: 'العملة'),
                items: curs
                    .map(
                      (c) => DropdownMenuItem(
                        value: c.code,
                        child: Text('${c.name} (${c.symbol})'),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _currency = v ?? 'YER'),
              ),
              const SizedBox(height: 13),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'رقم الجوال',
                  hintText: '7xxxxxxxx',
                  prefixIcon: Icon(Icons.phone_android),
                ),
              ),
              const SizedBox(height: 13),
              TextFormField(
                controller: _address,
                decoration: const InputDecoration(labelText: 'العنوان'),
              ),
              const SizedBox(height: 13),
              TextFormField(
                controller: _limit,
                decoration: const InputDecoration(
                  labelText: 'حد ائتماني (اختياري)',
                  hintText: '0.00',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              AmountWords(controller: _limit, decimals: 2),
              const SizedBox(height: 13),
              TextFormField(
                controller: _tags,
                decoration: const InputDecoration(
                  labelText: 'علامات',
                  hintText: 'افصل بينها بفاصلة',
                ),
              ),
              const SizedBox(height: 13),
              TextFormField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'ملاحظات'),
                maxLines: 3,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check),
                label: Text(_isEdit ? 'حفظ التعديلات' : 'إضافة الحساب'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
