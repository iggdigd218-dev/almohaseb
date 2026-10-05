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
import 'pos_screen.dart';
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
}) =>
    showModalBottomSheet<Object>(
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
  List<InvoiceLine> _invoiceLines = [];
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
      final invoiceLines = t?.id == null
          ? const <InvoiceLine>[]
          : await repo.transactionItems(t!.id!);

      _accounts = accs;
      _currencies = curs;

      if (t != null) {
        _type = t.type;
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
        _invoiceLines = invoiceLines;
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

  /// تفاصيل فاتورة المبيعات (الأصناف) تظهر فقط لعمليات البيع (قبض أو عليه).
  bool get _hasInvoiceDetails =>
      _type == OpType.debit || _type == OpType.inflow;

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
      final saleLines =
          _hasInvoiceDetails ? _invoiceLines : const <InvoiceLine>[];
      // A timeout does NOT cancel an SQLite write. Report a slow/unknown state
      // without permitting a retry until the original write has resolved.
      slowWarning = Timer(const Duration(seconds: 10), () {
        if (mounted) setState(() => _saveSlow = true);
      });
      savedId = await repo.saveTx(tx, items: saleLines);
      slowWarning.cancel();
      if (mounted) bump(ref);

      // Existing stock workflow is separate from the financial transaction.
      // Its atomicity is tracked explicitly as an outstanding QA issue.
      var stockFailed = false;
      if ((_type == OpType.inflow || _type == OpType.debit) &&
          saleLines.isNotEmpty) {
        for (final line in saleLines) {
          if (line.itemId == null) continue;
          try {
            await repo
                .addStockMove(StockMove(
                  itemId: line.itemId!,
                  quantity: line.quantity,
                  kind: StockKind.sale,
                  date: now,
                  createdAt: now,
                  notes: 'مبيع عملية #$savedId',
                ))
                .timeout(const Duration(seconds: 3));
          } catch (_) {
            stockFailed = true;
          }
        }
      }
      var saved = tx.copyWith(id: savedId);
      try {
        saved = await repo
                .transactionById(savedId)
                .timeout(const Duration(seconds: 2)) ??
            saved;
      } catch (_) {
        // The save is committed; failure of a follow-up read is not a save failure.
      }
      var share = TxShareOutcome.skipped;
      if (!_isTransfer && _account != null && mounted) {
        try {
          share = await TxShare.sendNow(context, ref,
                  tx: saved, account: _account!, silentIfNoPhone: true)
              .timeout(const Duration(seconds: 15));
        } catch (_) {
          share = TxShareOutcome.failed;
        }
      }
      if (!mounted) return;
      bump(ref);
      final message = StringBuffer(keepId != null
          ? 'تم تعديل العملية وتحديث الرصيد ✅'
          : 'تم حفظ العملية وتحديث الرصيد ✅');
      if (share == TxShareOutcome.opened) {
        message.write(' — تم فتح تطبيق المشاركة');
      }
      if (share == TxShareOutcome.failed) {
        message.write(' — تعذّر فتح المشاركة؛ الحفظ المحلي ناجح');
      }
      if (stockFailed) {
        message.write(' — تعذّر تحديث بعض المخزون، راجعه قبل المتابعة');
      }
      showSnack(context, message.toString(),
          error: stockFailed || share == TxShareOutcome.failed, silent: true);
      Navigator.pop(context, true);
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

  bool _advancedOpen = false;

  Widget _typeChips() => _typeGrid();

  Widget _invoiceShortcut() {
    return Card(
      color: AppColors.primarySoftOf(context),
      child: ListTile(
        leading: const Icon(Icons.point_of_sale, size: 22),
        title: const Text(
          'فتح شاشة المبيعات لإضافة الفاتورة',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: const Text(
          'تنتقل إلى نقطة البيع لتسجيل الفاتورة كاملة مع العملاء والأصناف',
        ),
        trailing: const Icon(Icons.chevron_left),
        onTap: _saving
            ? null
            : () {
                Sfx.click();
                // افتح شاشة المبيعات مباشرة مهما كانت الجهة التي فتحت النموذج.
                // الاعتماد سابقاً على إشارة 'open_pos' كان يعمل فقط من زر
                // «تسجيل عملية» في شاشة العمليات، ويبدو «بلا استجابة» من
                // بقية الشاشات (تفاصيل الحساب، التعديل، التكرار...).
                final nav = Navigator.of(context);
                nav.pop();
                nav.push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('🛒 المبيعات')),
                      body: const PosScreen(),
                    ),
                  ),
                );
              },
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
                      color: Colors.white, size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
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
                      _typeChips(),
                      const SizedBox(height: 14),
                      _accountPickers(),
                      const SizedBox(height: 14),
                      _amountRow(),
                      const SizedBox(height: 6),
                      AmountWords(controller: _amount),
                      if (_hasInvoiceDetails) ...[
                        const SizedBox(height: 8),
                        _invoiceShortcut(),
                      ],
                      if (_type == OpType.settle) ...[
                        const SizedBox(height: 14),
                        _signPicker(),
                      ],
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _desc,
                        decoration: const InputDecoration(
                          labelText: 'البيان / الوصف',
                          prefixIcon: Icon(Icons.notes_outlined),
                          hintText: 'وصف مختصر (اختياري)',
                        ),
                        textInputAction: TextInputAction.done,
                      ),
                      Theme(
                        data: Theme.of(context)
                            .copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: EdgeInsets.zero,
                          title: Text(
                            _advancedOpen
                                ? 'إخفاء التفاصيل الإضافية'
                                : 'التفاصيل الإضافية',
                          ),
                          leading: const Icon(Icons.tune),
                          onExpansionChanged: (v) =>
                              setState(() => _advancedOpen = v),
                          children: [
                            const SizedBox(height: 6),
                            _datePicker(),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _ref,
                              decoration: const InputDecoration(
                                labelText: 'رقم مرجعي',
                                prefixIcon: Icon(Icons.tag),
                              ),
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _notes,
                              decoration: const InputDecoration(
                                labelText: 'ملاحظات',
                                prefixIcon: Icon(Icons.sticky_note_2_outlined),
                              ),
                              maxLines: 2,
                            ),
                            const SizedBox(height: 10),
                            _smallImagePicker(),
                          ],
                        ),
                      ),
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

  /// إرفاق صورة اختياري — أيقونة صغيرة بجانب بيانات العملية (تُولَّد صورة
  /// الإيصال تلقائياً عند الحفظ، وهذا لإرفاق صورة خارجية فقط).
  Widget _smallImagePicker() {
    final hasImage = _image.isNotEmpty && File(_image).existsSync();
    return Row(
      children: [
        Icon(Icons.attach_file, size: 16, color: AppColors.text3Of(context)),
        const SizedBox(width: 6),
        Text(
          'إرفاق صورة (اختياري):',
          style: TextStyle(fontSize: 12.5, color: AppColors.text2Of(context)),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'من المعرض',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            Icons.photo_library_outlined,
            size: 20,
            color: AppColors.primaryOf(context),
          ),
          onPressed: _pickImage,
        ),
        IconButton(
          tooltip: 'التقاط من الكاميرا',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            Icons.photo_camera_outlined,
            size: 20,
            color: AppColors.primaryOf(context),
          ),
          onPressed: _captureImage,
        ),
        if (hasImage) ...[
          const SizedBox(width: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.file(
              File(_image),
              width: 34,
              height: 34,
              fit: BoxFit.cover,
            ),
          ),
          IconButton(
            tooltip: 'إزالة الصورة',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.close,
              size: 18,
              color: AppColors.dangerOf(context),
            ),
            onPressed: () => setState(() => _image = ''),
          ),
        ],
      ],
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

  Widget _typeGrid() {
    final isAlayh = _type == OpType.debit || _type == OpType.outflow;
    final isLahu = _type == OpType.credit || _type == OpType.inflow;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('طبيعة العملية على الحساب'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () => setState(() => _type = OpType.debit),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 11,
                    horizontal: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isAlayh
                        ? Colors.red.withValues(alpha: 0.12)
                        : AppColors.surface2Of(context),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isAlayh ? Colors.red : AppColors.borderOf(context),
                      width: isAlayh ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('🔴', style: TextStyle(fontSize: 18)),
                          const SizedBox(width: 6),
                          Text(
                            'عليه',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: isAlayh
                                  ? Colors.red.shade800
                                  : AppColors.textOf(context),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '(مستحق لنا / مدين / بيع)',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: isAlayh
                              ? Colors.red.shade700
                              : AppColors.text2Of(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                onTap: () => setState(() => _type = OpType.credit),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 11,
                    horizontal: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isLahu
                        ? Colors.green.withValues(alpha: 0.12)
                        : AppColors.surface2Of(context),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color:
                          isLahu ? Colors.green : AppColors.borderOf(context),
                      width: isLahu ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('🟢', style: TextStyle(fontSize: 18)),
                          const SizedBox(width: 6),
                          Text(
                            'له',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: isLahu
                                  ? Colors.green.shade800
                                  : AppColors.textOf(context),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '(مستحق له / دائن / دفعة)',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: isLahu
                              ? Colors.green.shade700
                              : AppColors.text2Of(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _showMoreTypes = !_showMoreTypes),
            icon: Icon(
              _showMoreTypes ? Icons.expand_less : Icons.expand_more,
              size: 16,
            ),
            label: const Text(
              'خيارات متقدمة (تحويل، مصروف، تسوية)',
              style: TextStyle(fontSize: 11.5),
            ),
          ),
        ),
        if (_showMoreTypes) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: OpType.values
                .where((t) => t != OpType.debit && t != OpType.credit)
                .map((t) {
              final sel = t == _type;
              return ChoiceChip(
                selected: sel,
                onSelected: (_) => setState(() => _type = t),
                avatar: Text(t.icon, style: const TextStyle(fontSize: 13)),
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
      ],
    );
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
