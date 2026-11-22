import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/media_paths.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../core/receipt_image.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'calculator.dart';
import 'tx_share.dart';
import 'widgets.dart';

/// يفتح نموذج العملية المالية (إضافة / تعديل / تكرار).
Future<Object?> openTxForm(
  BuildContext context,
  WidgetRef ref, {
  Tx? existing,
  int? presetAccountId,
  bool isCopy = false,
  OpType? presetType,
}) async {
  final res = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(ctx).height * 0.85,
      ),
      child: TxForm(
        existing: existing,
        presetAccountId: presetAccountId,
        isCopy: isCopy,
        presetType: presetType,
      ),
    ),
  );
  if (res is Tx && context.mounted) {
    await showTxSuccessSheet(context, ref, tx: res);
  }
  return res;
}

class TxForm extends ConsumerStatefulWidget {
  final Tx? existing;
  final int? presetAccountId;
  final bool isCopy;
  final OpType? presetType;
  const TxForm({
    super.key,
    this.existing,
    this.presetAccountId,
    this.isCopy = false,
    this.presetType,
  });

  @override
  ConsumerState<TxForm> createState() => _TxFormState();
}

class _TxFormState extends ConsumerState<TxForm> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _rate = TextEditingController(text: '1');
  final _desc = TextEditingController();
  final _ref = TextEditingController();
  final _notes = TextEditingController();

  OpType _type = OpType.debit;
  bool _showMoreTypes = false;
  int? _accountId;
  int? _toId;
  String _currency = 'YER';
  String _sign = '+';
  String _status = 'done';
  DateTime _date = DateTime.now();

  List<Account> _accounts = [];
  List<CurrencyDef> _currencies = [];

  /// العملة الأساسية = الأولى في قائمة العملات (سعرها 1 دوماً).
  String get _baseCurrencyCode =>
      _currencies.isNotEmpty ? _currencies.first.code : 'YER';
  bool _loading = true;
  bool _saving = false;
  bool _saveSlow = false;

  /// توليد صورة الإيصال وإرسالها للعميل فور الحفظ (البنود ٣ و ٤ و ١٢ و ١٤).
  String _image = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(repoProvider);
      final accs = await repo.accounts(includeArchived: true);
      final curs = await repo.currencies();
      final t = widget.existing;

      _accounts = accs;
      _currencies = curs;

      if (t != null) {
        _type = t.type;
        // تعديل عملية بنوع متقدم (تحويل/مصروف/…) — نفتح الخيارات مباشرة.
        if (t.type != OpType.debit && t.type != OpType.credit) {
          _showMoreTypes = true;
        }
        _accountId = t.type == OpType.transfer ? t.fromId : t.accountId;
        _toId = t.toId;
        _currency = t.currency;
        _sign = t.sign.isEmpty ? '+' : t.sign;
        _status = t.status;
        _image = MediaPaths.toAbsolute(t.image);
        _date = t.date;
        _amount.text = Fmt.money(t.amount, 2).replaceAll(',', '');
        _rate.text = '${t.rate}';
        _desc.text = t.description;
        _ref.text = widget.isCopy ? '' : t.reference;
        _notes.text = t.notes;
      } else {
        if (widget.presetType != null) {
          _type = widget.presetType!;
        } else {
          final s = await repo.settings();
          final mapped = {
            'inflow': OpType.inflow,
            'outflow': OpType.outflow,
            'debit': OpType.debit,
            'credit': OpType.credit,
            'revenue': OpType.revenue,
            'expense': OpType.expense,
          };
          final def = s['defaultOp'];
          if (def != null && mapped.containsKey(def)) _type = mapped[def]!;
          final defNotes = s['defaultVoucherNotes']?.trim();
          if (defNotes != null && defNotes.isNotEmpty) {
            _notes.text = defNotes;
          }
        }
        _accountId =
            widget.presetAccountId ?? (accs.isNotEmpty ? accs.first.id : null);
      }

      final acc = accs.where((a) => a.id == _accountId).firstOrNull;
      if (t == null && acc != null) _currency = acc.currency;
    } catch (e) {
      if (mounted) {
        Sfx.error();
        showSnack(
          context,
          'تعذّر تحميل البيانات: $e',
          error: true,
          silent: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _rate.dispose();
    _desc.dispose();
    _ref.dispose();
    _notes.dispose();
    super.dispose();
  }

  Account? get _account =>
      _accounts.where((a) => a.id == _accountId).firstOrNull;

  bool get _isTransfer => _type == OpType.transfer;

  /// نص الأثر المتوقّع — نفس تلميح نسخة الويب.

  Future<void> _save() async {
    // Acquire the lock synchronously, before unfocus/validation awaits.
    if (_saving || !mounted) return;
    setState(() {
      _saving = true;
      _saveSlow = false;
    });
    Timer? slowWarning;
    int? savedId;
    try {
      FocusScope.of(context).unfocus();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
      final form = _formKey.currentState;
      if (form == null || !form.validate()) {
        Sfx.reject();
        return;
      }
      form.save();
      if (_accountId == null) throw StateError('اختر الحساب');
      if (_isTransfer && (_toId == null || _toId == _accountId)) {
        throw StateError('اختر حساب الوجهة (مختلفًا عن المصدر)');
      }
      final amount = Fmt.parseAmount(_amount.text);
      if (amount == null || amount <= 0) {
        throw StateError('أدخل مبلغًا صحيحًا أكبر من صفر');
      }
      final rate = Fmt.parseAmount(_rate.text);
      if (_isTransfer && (rate == null || rate <= 0)) {
        throw StateError('أدخل سعر صرف صحيحًا أكبر من صفر');
      }
      final repo = ref.read(repoProvider);
      final now = DateTime.now();
      final old = widget.existing;
      final keepId = old != null && !widget.isCopy ? old.id : null;
      final me = ref.read(currentUserProvider).valueOrNull;
      final tx = Tx(
        id: keepId,
        accountId: _isTransfer ? null : _accountId,
        accountKind: _account?.kind ?? AccountKind.general,
        type: _type,
        amount: amount,
        currency: _currency,
        sign: _type == OpType.settle ? _sign : '',
        fromId: _isTransfer ? _accountId : null,
        toId: _isTransfer ? _toId : null,
        rate: rate ?? 1,
        description: _desc.text.trim(),
        reference: _ref.text.trim(),
        notes: _notes.text.trim(),
        image: _image,
        status: _status,
        date: _date,
        createdByUserId: old?.createdByUserId ?? me?.id,
        cashierName: old?.cashierName ?? me?.name ?? '',
        createdAt: keepId != null ? old!.createdAt : now,
        updatedAt: now,
      );
      if (keepId == null) {
        List<Tx> duplicates = const [];
        try {
          duplicates =
              await repo.findDuplicates(tx).timeout(const Duration(seconds: 3));
        } catch (_) {
          // Advisory only; the in-flight lock is independent of this lookup.
        }
        if (!mounted) return;
        if (duplicates.isNotEmpty) {
          final proceed = await confirmDialog(context,
              title: '⚠️ عملية مكررة محتملة',
              message:
                  'توجد ${duplicates.length} عملية مماثلة. هل تريد المتابعة؟',
              confirmText: 'متابعة');
          if (proceed != true || !mounted) return;
        }
      }
      // A timeout does NOT cancel an SQLite write. Report a slow/unknown state
      // without permitting a retry until the original write has resolved.
      slowWarning = Timer(const Duration(seconds: 10), () {
        if (mounted) setState(() => _saveSlow = true);
      });
      savedId = await repo.saveTx(tx);
      slowWarning.cancel();
      if (mounted) bump(ref);

      var saved = tx.copyWith(id: savedId);
      try {
        saved = await repo
                .transactionById(savedId)
                .timeout(const Duration(seconds: 2)) ??
            saved;
      } catch (_) {
        // The save is committed; failure of a follow-up read is not a save failure.
      }
      if (!mounted) return;
      bump(ref);
      showSnack(
        context,
        keepId != null
            ? 'تم تعديل العملية وتحديث الرصيد ✅'
            : 'تم حفظ العملية وتحديث الرصيد ✅',
        silent: true,
      );
      Navigator.pop(context, saved);
      // إنشاء عملية جديدة: اهتزاز طويل (1.5 ث) + صوت مميز؛ التعديل: نجاح عادي.
      if (widget.existing == null || widget.isCopy) {
        Sfx.opCreated();
      } else {
        Sfx.success();
      }
    } catch (e) {
      if (!mounted) return;
      Sfx.error();
      if (savedId != null) {
        bump(ref);
        showSnack(context, 'تم الحفظ محليًا، لكن تعذّر إكمال خطوة لاحقة: $e',
            error: true);
        Navigator.pop(context, true);
      } else {
        showSnack(
            context, e is StateError ? e.message : 'تعذّر حفظ العملية: $e',
            error: true, silent: true);
      }
    } finally {
      slowWarning?.cancel();
      if (mounted) {
        setState(() {
          _saving = false;
          _saveSlow = false;
        });
      }
    }
  }

  /// دائرتا نوع العملية أسفل يمين النافذة — عليه (أخضر ▲) أو له
  /// (أحمر ▼)، وزر «متقدم» صغير يسارًا للتحويل/المصروف/التسوية.
  Widget _typeCircles() {
    final isOwe = _type == OpType.debit;
    final isLahu = _type == OpType.credit;
    final isOther = !isOwe && !isLahu;
    // دائرتا «عليه/له» أسفل يمين النافذة (بداية RTL)، وزر «متقدم»
    // في الطرف المقابل — بحشوات مضغوطة كي يستوعب الصف عرض 320.
    return Row(
      children: [
        _TypeCircle(
          label: 'عليه',
          icon: Icons.arrow_upward_rounded,
          color: const Color(0xFF059669),
          selected: isOwe,
          onTap: () => setState(() => _type = OpType.debit),
        ),
        const SizedBox(width: 10),
        _TypeCircle(
          label: 'له',
          icon: Icons.arrow_downward_rounded,
          color: const Color(0xFFDC2626),
          selected: isLahu,
          onTap: () => setState(() => _type = OpType.credit),
        ),
        if (isOther)
          Expanded(
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 10),
              child: Text(
                'النوع: ${_type.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text2Of(context),
                ),
              ),
            ),
          )
        else
          const Spacer(),
        TextButton.icon(
          onPressed: () =>
              setState(() => _showMoreTypes = !_showMoreTypes),
          icon: Icon(
            _showMoreTypes ? Icons.expand_less : Icons.expand_more,
            size: 15,
          ),
          label: const Text(
            'متقدم',
            style: TextStyle(fontSize: 11),
          ),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
        ),
      ],
    );
  }

  /// معاينة صغيرة للصورة المرفقة قابلة للحذف.
  Widget _imagePreview() {
    final hasImage = _image.isNotEmpty && File(_image).existsSync();
    if (!hasImage) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(_image),
              width: 52,
              height: 52,
              fit: BoxFit.cover,
            ),
          ),
          PositionedDirectional(
            top: -6,
            end: -6,
            child: GestureDetector(
              onTap: () => setState(() => _image = ''),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                  color: Color(0xFFDC2626),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close,
                    size: 12, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 260,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_accounts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const EmptyState(
              icon: Icons.person_off_outlined,
              title: 'لا توجد حسابات',
              message: 'أضف حسابًا أولًا قبل تسجيل أي عملية.',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('حسنًا'),
            ),
          ],
        ),
      );
    }
    final title = widget.isCopy
        ? '🔁 تكرار عملية'
        : (widget.existing != null ? '✏️ تعديل عملية' : '＋ عملية جديدة');
    return PopScope(
      canPop: !_saving,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderOf(context),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            // ترويسة ملوّنة بنفس طابع التصميم المرجعي.
            Container(
              margin: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [Color(0xFF1E3A5F), AppColors.primary],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const Icon(Icons.edit_note_rounded,
                      color: Colors.white, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // (تصحيح 2026-11-03) اسم الحساب يتصدر النافذة.
                        Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                            fontSize: 11.5,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          _account?.name ?? 'اختر الحساب',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            fontFamily: 'AppNaskh',
                          ),
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    onTap:
                        _saving ? null : () => Navigator.pop(context),
                    borderRadius: BorderRadius.circular(20),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.close, color: Colors.white, size: 22),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: Form(
                key: _formKey,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _accountPickers(),
                      const SizedBox(height: 14),
                      _amountRow(),
                      const SizedBox(height: 6),
                      AmountWords(controller: _amount),
                      const SizedBox(height: 12),
                      // التفاصيل وبجانبها أيقونة صغيرة للصورة: معرض أو
                      // كاميرا فورية — كما في النموذج المرجعي.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _desc,
                              decoration: const InputDecoration(
                                labelText: 'التفاصيل',
                                prefixIcon: Icon(Icons.notes_outlined),
                                hintText: 'وصف مختصر (اختياري)',
                              ),
                              textInputAction: TextInputAction.done,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _AttachPhotoButtons(
                            onGallery: _pickImage,
                            onCamera: _captureImage,
                          ),
                        ],
                      ),
                      if (_image.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _imagePreview(),
                      ],
                      const SizedBox(height: 12),
                      // التاريخ ظاهر مباشرة — لا قائمة منطوية.
                      _datePicker(),
                      if (_type == OpType.settle) ...[
                        const SizedBox(height: 12),
                        _signPicker(),
                      ],
                      if (_showMoreTypes) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: OpType.values
                              .where((t) =>
                                  t != OpType.debit &&
                                  t != OpType.credit)
                              .map((t) {
                            final sel = t == _type;
                            return ChoiceChip(
                              selected: sel,
                              onSelected: (_) =>
                                  setState(() => _type = t),
                              avatar: Text(t.icon,
                                  style: const TextStyle(fontSize: 13)),
                              label: Text(t.label),
                              labelStyle: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 11.5,
                                color: sel
                                    ? AppColors.primaryOf(context)
                                    : AppColors.text2Of(context),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                      const SizedBox(height: 4),
                      // دائرتا نوع العملية أسفل يمين النافذة.
                      _typeCircles(),

                      if (_saveSlow)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: Text(
                              'الحفظ أبطأ من المعتاد. ننتظر نتيجة قاعدة البيانات؛ لا تُكرر العملية.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.orange)),
                        ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.save_outlined, size: 22),
                          label: Text(
                            _saving ? 'جارٍ الحفظ...' : 'حفظ العملية',
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed:
                            _saving ? null : () => Navigator.pop(context),
                        child: const Text('إلغاء'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }


  Future<void> _pickImage() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
    );
    if (x == null) return;
    final saved = await saveImageBytes(await x.readAsBytes(), prefix: 'tx');
    if (mounted) setState(() => _image = saved);
  }

  Future<void> _captureImage() async {
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 82,
      );
      if (x == null) return;
      final saved = await saveImageBytes(await x.readAsBytes(), prefix: 'tx');
      if (mounted) setState(() => _image = saved);
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر فتح الكاميرا', error: true);
    }
  }


  Widget _accountPickers() {
    return Column(
      children: [
        DropdownButtonFormField<int>(
          initialValue: _accountId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: _isTransfer ? 'من حساب' : 'الحساب',
            prefixIcon: const Icon(Icons.account_balance_wallet_outlined),
          ),
          items: _accounts
              .map(
                (a) => DropdownMenuItem(
                  value: a.id,
                  child: Text(
                    '${a.kind.icon}  ${a.name}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: (v) {
            setState(() {
              _accountId = v;
              if (_toId == v) _toId = null;
              final acc = _account;
              if (acc != null && widget.existing == null) {
                _currency = acc.currency;
              }
            });
          },
          validator: (v) => v == null ? 'اختر الحساب' : null,
        ),
        if (_isTransfer) ...[
          const SizedBox(height: 14),
          DropdownButtonFormField<int>(
            key: ValueKey('to_$_accountId'),
            initialValue: _toId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'إلى حساب',
              prefixIcon: Icon(Icons.arrow_forward),
            ),
            items: _accounts
                .where((a) => a.id != _accountId)
                .map(
                  (a) => DropdownMenuItem(
                    value: a.id,
                    child: Text(
                      '${a.kind.icon}  ${a.name}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => _toId = v),
            validator: (v) => v == null ? 'اختر حساب الوجهة' : null,
          ),
        ],
      ],
    );
  }

  Widget _amountRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: TextFormField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            // فواصل آلاف حية أثناء الكتابة: 1000000 → 1,000,000.
            inputFormatters: const [ThousandsFormatter()],
            decoration: InputDecoration(
              labelText: 'المبلغ *',
              hintText: '0.00',
              prefixIcon: const Icon(Icons.payments_outlined),
              suffixIcon: IconButton(
                tooltip: 'آلة حاسبة',
                icon: const Icon(Icons.calculate_outlined),
                onPressed: () async {
                  final v = await openCalculator(
                    context,
                    initial: _amount.text,
                  );
                  if (v == null) return;
                  setState(() {
                    _amount.text =
                        v == v.roundToDouble() ? '${v.toInt()}' : '$v';
                  });
                },
              ),
            ),
            validator: (v) {
              final n = Fmt.parseAmount(v ?? '');
              if (n == null || n <= 0) return 'مبلغ غير صالح';
              return null;
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<String>(
            initialValue: _currencies.any((c) => c.code == _currency)
                ? _currency
                : (_currencies.isNotEmpty ? _currencies.first.code : null),
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'العملة'),
            items: _currencies
                .map(
                  (c) => DropdownMenuItem(
                    value: c.code,
                    child: Text(
                      '${c.symbol}  ${c.code}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) async {
              setState(() => _currency = v ?? _currency);
              // اختيار عملة غير أساسية يقترح سعرها المعتمد (إعداد
              // rate_<code>) كنقطة بداية قابلة للتجاوز لهذه العملية فقط.
              if (!_isTransfer && _currency != _baseCurrencyCode) {
                try {
                  final st = await ref.read(repoProvider).settings();
                  final r = st['rate_$_currency'];
                  if (r != null && mounted) {
                    setState(() => _rate.text = r);
                  }
                } catch (_) {}
              }
            },
          ),
        ),
        // سعر الصرف: للتحويلات دائماً، ولأي عملية بعملة غير أساسية —
        // تجاوز محلي على مستوى العملية لا يمس إعدادات العملات العالمية.
        if (_isTransfer || _currency != _baseCurrencyCode) ...[
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: TextFormField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'سعر الصرف',
                helperText: 'لهذه العملية فقط',
                helperMaxLines: 1,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _signPicker() {
    return RadioGroup<String>(
      groupValue: _sign,
      onChanged: (v) {
        if (v != null) setState(() => _sign = v);
      },
      child: const Row(
        children: [
          Expanded(
            child: RadioListTile<String>(
              value: '+',
              title: Text(
                'بالزيادة (+)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
          Expanded(
            child: RadioListTile<String>(
              value: '-',
              title: Text(
                'بالنقصان (−)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _datePicker() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final d = await showDatePicker(
          context: context,
          initialDate: _date,
          firstDate: DateTime(2015),
          lastDate: DateTime(2100),
          locale: const Locale('ar'),
        );
        if (d != null) setState(() => _date = d);
      },
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'التاريخ',
          prefixIcon: Icon(Icons.event_outlined),
        ),
        child: Text(
          Fmt.date(_date),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// دائرة اختيار صغيرة لنوع العملية — تمتلئ بلونها عند التحديد.
class _TypeCircle extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _TypeCircle({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(40),
          border: Border.all(
            color: selected ? color : AppColors.borderOf(context),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? color : Colors.transparent,
                border: Border.all(
                  color: selected ? color : AppColors.borderOf(context),
                  width: 1.4,
                ),
              ),
              child: selected
                  ? Icon(icon, size: 12, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? color : AppColors.text2Of(context),
                fontFamily: 'AppNaskh',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// عمود أيقونتين صغيرتين بجانب حقل التفاصيل: معرض الصور أو كاميرا
/// فورية لإرفاق صورة بالعملية.
class _AttachPhotoButtons extends StatelessWidget {
  final VoidCallback onGallery;
  final VoidCallback onCamera;

  const _AttachPhotoButtons({
    required this.onGallery,
    required this.onCamera,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onGallery,
          child: Tooltip(
            message: 'صورة من المعرض',
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.surface2Of(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.borderOf(context)),
              ),
              child: Icon(
                Icons.photo_library_outlined,
                size: 18,
                color: AppColors.primaryOf(context),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: onCamera,
          child: Tooltip(
            message: 'التقاط صورة فورية',
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.surface2Of(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.borderOf(context)),
              ),
              child: Icon(
                Icons.photo_camera_outlined,
                size: 18,
                color: AppColors.primaryOf(context),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
