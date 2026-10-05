import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../core/accounting.dart';
import '../core/desktop.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/thermal_invoice_doc.dart';
import '../core/shell_nav.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/pos_cart.dart';
import '../data/providers.dart';
import '../data/sync/subscription_guard.dart' show Feature;
import 'barcode_scanner.dart';
import 'pos_gate.dart';
import 'pos_items_grid.dart';
import 'trial_ui.dart' show featureNeedsStamp;
import 'tx_share.dart';
import 'widgets.dart';
import '../core/data_change.dart';

enum _PosPayment {
  cash('نقداً 💵', 'cash'),
  credit('آجل 📑', 'credit'),
  partial('جزئي ⚖️', 'partial');

  final String label;
  final String code;
  const _PosPayment(this.label, this.code);

  static _PosPayment fromCode(String c) => _PosPayment.values
      .firstWhere((p) => p.code == c, orElse: () => _PosPayment.cash);
}

/// شاشة نقطة البيع ونظام المبيعات المتكامل
class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  /// جسر الزر المركزي (Omni): عندما تكون شاشة POS ظاهرة يفتح زر
  /// الإجراء الموحد درج الدفع مباشرة عبر هذا المرجع.
  static void Function()? openCheckoutBridge;

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int? _selectedCategoryId;
  // (2026-09-22) القسم المختار في الشريط اللمسي (null = الكل، -1 = عام).
  int? _selectedSectionId;

  /// (2026-09-24) هل نحن في **بوابة الأقسام** (المستوى 1)؟
  /// نقطة البيع تفتح على الأقسام فقط؛ اختيار قسم ينقل إلى مستوى الأصناف.
  bool _atSectionsGate = true;

  String _searchQuery = '';

  /// (2026-09-24) ترتيب شبكة الأصناف: 0 الاسم · 1 السعر · 2 الكمية.
  int _posSort = 0;
  final TextEditingController _searchCtrl = TextEditingController();
  bool _saving = false;

  /// «السماح بالبيع عند نفاد الرصيد الدفتري» — إعداد المخزون.
  bool get _allowNegative =>
      (ref.read(settingsProvider).valueOrNull ?? const {})['allowNegativeStock'] ==
      '1';

  // السلة الحية تعيش في Riverpod (pos_cart.dart) — التنقل لا يفقدها.
  PosDraft get _draft => ref.read(posDraftProvider);
  PosDraftNotifier get _cartCtl => ref.read(posDraftProvider.notifier);

  // جسور قراءة من المسودة — تبقي بقية الشيفرة كما هي.
  Map<int, CartEntry> get _cart => _draft.cart;
  int? get _selectedCustomerId => _draft.customerId;
  _PosPayment get _payment => _PosPayment.fromCode(_draft.payment);
  double get _subtotal => _draft.subtotal;
  double get _discount => _draft.discountValue;
  double get _netTotal => _draft.netTotal;
  int get _itemCount => _draft.itemCount;
  // حقول نصية تُستعاد من المسودة عند إعادة بناء الشاشة (تُهيأ في
  // initState — التهيئة الكسولة تنفجر لو أول وصول كان في dispose).
  late final TextEditingController _paidCtrl;
  late final TextEditingController _discountCtrl;
  late final TextEditingController _notesCtrl;

  /// (3.70) صلاحية الخصم المحلية — تُحجب عن الكاشير فوراً (بلا شبكة).
  bool _canDiscount = true;
  /// اعتماد المشرف لتخطي حجب الخصم في الفاتورة الحالية فقط (Supervisor Override)
  bool _supervisorOverride = false;

  bool get _hasDiscountPermission {
    if (_supervisorOverride) return true;
    final user = ref.read(currentUserProvider).valueOrNull;
    if (user != null) {
      return user.role == UserRole.admin ||
          user.role == UserRole.agent ||
          user.can('can_discount');
    }
    return _canDiscount;
  }

  Future<void> _promptSupervisorOverride(StateSetter setSheetState) async {
    final pinCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('الموافقة على الخصم (مشرف/مدير)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('أدخل رمز PIN للمشرف أو المدير لتخطي حجب الخصم لهذه الفاتورة:'),
            const SizedBox(height: 12),
            TextField(
              controller: pinCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              autofocus: true,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'رمز PIN',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () async {
              final repo = ref.read(repoProvider);
              final st = await repo.settings();
              final masterPin = st['pos.master_pin'] ?? '1234';
              if (pinCtrl.text.trim() == masterPin) {
                if (ctx.mounted) Navigator.pop(ctx, true);
              } else {
                if (ctx.mounted) showSnack(ctx, 'رمز PIN غير صحيح', error: true);
              }
            },
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() {
        _supervisorOverride = true;
      });
      setSheetState(() {});
      showSnack(context, 'تمت الموافقة على الخصم بواسطة المشرف ✅');
    }
  }

  @override
  void initState() {
    super.initState();
    final d = ref.read(posDraftProvider);
    _paidCtrl = TextEditingController(text: d.paidText);
    _discountCtrl = TextEditingController(text: d.discountText);
    _notesCtrl = TextEditingController(text: d.notesText);
    _tabController = TabController(length: 2, vsync: this);
    // (2026-09-24) بيع من الزر العائم ⇒ حدّث الأرصدة والمسودة فوراً.
    dataChangeTick.addListener(_onExternalDataChange);
    // (3.70 — المرحلة 4) RBAC محلي Offline-Ready: حقل الخصم يظهر فقط
    // لصاحب صلاحية can_discount.
    ref.read(repoProvider).effectivePermissions().then((p) {
      if (mounted && p.canDiscount != _canDiscount) {
        setState(() => _canDiscount = p.canDiscount);
      }
    });
    // ربط الزر المركزي الموحد: على شاشة POS يفتح درج الدفع مباشرة.
    PosScreen.openCheckoutBridge = () {
      if (!mounted) return;
      if (_draft.cart.isEmpty) {
        Sfx.reject();
        showSnack(context, 'السلة فارغة — أضف أصنافاً أولاً', error: true);
        return;
      }
      _openCheckoutSheet();
    };
  }

  /// (2026-09-24) كتابة خارجية (الزر العائم): أعد قراءة الأصناف فتظهر
  /// الأرصدة الحديثة، وحدّث المسودة المعروضة.
  void _onExternalDataChange() {
    if (!mounted) return;
    bump(ref);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    dataChangeTick.removeListener(_onExternalDataChange);
    if (PosScreen.openCheckoutBridge != null) {
      PosScreen.openCheckoutBridge = null;
    }
    _tabController.dispose();
    _searchCtrl.dispose();
    _paidCtrl.dispose();
    _discountCtrl.dispose();
    _notesCtrl.dispose();
    _shortcutFocus.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// يضيف الصنف إلى السلة بكمية (الافتراضي 1).
  void _addItem(Item item, {double quantity = 1}) {
    final allowNeg = _allowNegative;
    if (!allowNeg && item.quantity <= 0) {
      Sfx.reject();
      showSnack(context, 'الصنف «${item.name}» نفد من المخزون', error: true);
      return;
    }
    final ok = _cartCtl.addItem(item, allowNegative: allowNeg, quantity: quantity);
    if (!ok) {
      Sfx.reject();
      showSnack(
        context,
        'الكمية المتاحة من «${item.name}»: ${item.quantity.toStringAsFixed(0)} ${item.unit} فقط',
        error: true,
      );
      return;
    }
    if (allowNeg && item.quantity - (_draft.cart[item.id]?.quantity ?? 0) < 0) {
      showSnack(context,
          '⚠️ «${item.name}»: البيع تجاوز الرصيد الدفتري (رصيد سالب)',
          error: true, silent: true);
    }
    Sfx.click();
  }

  /// إدخال كمية مباشر: نقرة على رقم الكمية تفتح لوحة إدخال سريعة بدل
  /// تكرار «+» للأعداد الكبيرة.
  Future<void> _editQuantity(CartEntry entry) async {
    final qty = await showQuickAmountPad(
      context,
      title: 'كمية «${entry.item.name}»',
      initial: entry.quantity,
      hint: 'المتاح: ${Fmt.money(entry.item.quantity)} ${entry.item.unit}',
    );
    if (qty == null) return;
    final ok = _cartCtl.setQuantity(entry.item.id!, qty,
        allowNegative: _allowNegative);
    if (!ok) {
      Sfx.reject();
      if (mounted) {
        showSnack(
          context,
          'الكمية المتاحة: ${entry.item.quantity.toStringAsFixed(0)} ${entry.item.unit} فقط',
          error: true,
        );
      }
    }
  }

  void _clearCart() {
    _cartCtl.clear();
    _paidCtrl.clear();
    _discountCtrl.clear();
    _notesCtrl.clear();
    _supervisorOverride = false;
    setState(() {});
  }

  // ---------------- اختصارات لوحة مفاتيح سطح المكتب ----------------
  // F1 دفع نقدي فوري • F2 آجل • F3 تركيز بحث العميل/الأصناف •
  // F12 تعليق الفاتورة • Esc إفراغ السلة / إغلاق النافذة النشطة.
  final FocusNode _shortcutFocus = FocusNode();
  final FocusNode _searchFocus = FocusNode();

  KeyEventResult _handleDesktopKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.f1) {
      _quickSettle(_PosPayment.cash);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f2) {
      _quickSettle(_PosPayment.credit);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f3) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f12) {
      _holdInvoice();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_cart.isNotEmpty) {
        _clearCart();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// تسوية سريعة من الاختصار: نقدي ينفّذ فوراً؛ آجل يتطلب عميلاً —
  /// إن لم يُحدد نفتح درج الدفع على وضع الآجل ليختار.
  void _quickSettle(_PosPayment mode) {
    if (_cart.isEmpty) {
      Sfx.reject();
      showSnack(context, 'السلة فارغة — أضف أصنافاً أولاً', error: true);
      return;
    }
    _cartCtl.setPayment(mode.code);
    if (mode == _PosPayment.cash) {
      _executeSale(null);
    } else if (_selectedCustomerId != null) {
      _executeSale(null);
    } else {
      _openCheckoutSheet();
    }
  }

  /// تعليق الفاتورة الحالية (F12) — تُحفظ في قائمة المعلّقات وتُفرغ السلة.
  void _holdInvoice() {
    if (_cart.isEmpty) {
      Sfx.reject();
      showSnack(context, 'لا توجد فاتورة لتعليقها', error: true);
      return;
    }
    final held = ref.read(heldInvoicesProvider);
    ref.read(heldInvoicesProvider.notifier).state = [...held, _draft];
    _clearCart();
    Sfx.pop();
    showSnack(context, 'عُلّقت الفاتورة ⏸️ — استأنفها من زر المعلّقات');
  }

  /// استئناف فاتورة معلّقة (تحل محل السلة الحالية إن كانت فارغة).
  void _resumeHeld(int index) {
    final held = List<PosDraft>.of(ref.read(heldInvoicesProvider));
    if (index < 0 || index >= held.length) return;
    if (_cart.isNotEmpty) {
      Sfx.reject();
      showSnack(context, 'أفرغ السلة الحالية أو علّقها أولاً', error: true);
      return;
    }
    final d = held.removeAt(index);
    ref.read(heldInvoicesProvider.notifier).state = held;
    _cartCtl.restore(d);
    _paidCtrl.text = d.paidText;
    _discountCtrl.text = d.discountText;
    _notesCtrl.text = d.notesText;
    setState(() {});
    Sfx.pop();
  }

  @override
  Widget build(BuildContext context) {
    // مراقبة المسودة: أي تغيير في السلة (حتى من جلسة سابقة قبل تنقل
    // عرضي بين التبويبات) يعيد بناء الشريط السفلي فوراً.
    ref.watch(posDraftProvider);
    // سطح المكتب (>900dp): مركز قيادة ثنائي اللوحين مع اختصارات لوحة
    // المفاتيح؛ الهاتف يبقى على التبويبات المعتادة.
    if (isDesktopLayout(context)) {
      return Focus(
        focusNode: _shortcutFocus,
        onKeyEvent: _handleDesktopKey,
        autofocus: true,
        child: _buildDesktopPos(),
      );
    }
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Container(
          color: Theme.of(context).colorScheme.surface,
          child: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(icon: Icon(Icons.point_of_sale_outlined), text: 'نقطة البيع'),
              Tab(icon: Icon(Icons.history_edu_outlined), text: 'سجل المبيعات'),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildPosSaleTab(), const _PosHistoryTab()],
      ),
      bottomNavigationBar: _tabController.index == 0 && _cart.isNotEmpty
          ? _buildCartBottomBar()
          : null,
    );
  }

  /// تخطيط سطح المكتب: يمين (60%) كتالوج الأصناف والبحث؛ يسار (40%)
  /// لوح الفاتورة الحية بإطار بارز مع الملخص المالي وأزرار التسوية.
  Widget _buildDesktopPos() {
    final currencies =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final cur = currencies.first;
    final held = ref.watch(heldInvoicesProvider);
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- اللوح الأيمن في RTL (الأول): الكتالوج 60% ----
            Expanded(
              flex: 6,
              child: DesktopPanel(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                      child: Row(
                        children: [
                          const Icon(Icons.point_of_sale_outlined, size: 20),
                          const SizedBox(width: 8),
                          Text('نقطة البيع',
                              style:
                                  Theme.of(context).textTheme.titleMedium),
                          const Spacer(),
                          if (held.isNotEmpty)
                            TextButton.icon(
                              onPressed: () => _showHeldSheet(),
                              icon: const Icon(Icons.pause_circle_outline,
                                  size: 18),
                              label: Text('معلّقة (${held.length})'),
                            ),
                          TextButton.icon(
                            onPressed: () => showModalBottomSheet(
                              context: context,
                              isScrollControlled: true,
                              builder: (_) => const FractionallySizedBox(
                                heightFactor: 0.85,
                                child: _PosHistoryTab(),
                              ),
                            ),
                            icon: const Icon(Icons.history_edu_outlined,
                                size: 18),
                            label: const Text('سجل المبيعات'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: _buildPosSaleTab()),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            // ---- اللوح الأيسر: الفاتورة الحية 40% ----
            Expanded(
              flex: 4,
              child: DesktopPanel(
                padding: EdgeInsets.zero,
                child: _buildDesktopInvoicePane(cur),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// قائمة الفواتير المعلّقة (استئناف بنقرة).
  void _showHeldSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final held = ref.read(heldInvoicesProvider);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (var i = 0; i < held.length; i++)
                ListTile(
                  leading: const Icon(Icons.pause_circle_outline),
                  title: Text(
                      'فاتورة معلّقة ${i + 1} — ${held[i].itemCount} صنف'),
                  subtitle: Text('الإجمالي: ${Fmt.money(held[i].netTotal)}'),
                  trailing: FilledButton.tonal(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _resumeHeld(i);
                    },
                    child: const Text('استئناف'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// لوح الفاتورة المكتبي: بنود السلة + محددات كمية مباشرة + ملخص مالي
  /// حي (الإجمالي/الخصم/الصافي) + أزرار تسوية عريضة مع قفل فوري.
  Widget _buildDesktopInvoicePane(CurrencyDef cur) {
    final entries = _cart.values.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.primaryOf(context).withValues(alpha: 0.06),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(
            children: [
              const Icon(Icons.receipt_long_outlined, size: 20),
              const SizedBox(width: 8),
              Text('الفاتورة الحالية',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text('$_itemCount صنف',
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.text2Of(context))),
              if (_cart.isNotEmpty) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'إفراغ السلة (Esc)',
                  icon: const Icon(Icons.delete_sweep_outlined,
                      color: AppColors.red, size: 20),
                  onPressed: _clearCart,
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? const EmptyState(
                  icon: Icons.shopping_cart_outlined,
                  title: 'السلة فارغة',
                  message: 'انقر أصنافاً من الكتالوج لإضافتها للفاتورة.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(10),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final e = entries[i];
                    return HoverLift(
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(e.item.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13.5)),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${Fmt.money(e.unitPrice)} × ${Fmt.money(e.quantity)} = ${Fmt.money(e.total)} ${cur.symbol}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color:
                                            AppColors.text2Of(context)),
                                  ),
                                ],
                              ),
                            ),
                            // محدد كمية مباشر: − / كمية قابلة للنقر / +
                            IconButton(
                              tooltip: 'إنقاص',
                              iconSize: 19,
                              icon: const Icon(
                                  Icons.remove_circle_outline),
                              onPressed: () {
                                _cartCtl.setQuantity(
                                    e.item.id!, e.quantity - 1,
                                    allowNegative: _allowNegative);
                                setState(() {});
                              },
                            ),
                            InkWell(
                              onTap: () async {
                                await _editQuantity(e);
                                setState(() {});
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryOf(context)
                                      .withValues(alpha: 0.1),
                                  borderRadius:
                                      BorderRadius.circular(8),
                                ),
                                child: Text(
                                  Fmt.money(e.quantity),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'زيادة',
                              iconSize: 19,
                              icon:
                                  const Icon(Icons.add_circle_outline),
                              onPressed: () => _addItem(e.item),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        // الملخص المالي الحي.
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: BorderDirectional(
              top: BorderSide(
                color:
                    Theme.of(context).dividerColor.withValues(alpha: 0.18),
                width: 1.2,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _summaryRow('الإجمالي', _subtotal, cur),
              if (_discount > 0) _summaryRow('الخصم', -_discount, cur),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('الصافي',
                      style: Theme.of(context).textTheme.titleLarge),
                  Text(
                    '${Fmt.money(_netTotal)} ${cur.symbol}',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: AppColors.primaryOf(context),
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // أزرار تسوية عريضة + تلميحات الاختصارات.
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: _saving || _cart.isEmpty
                          ? null
                          : () => _quickSettle(_PosPayment.cash),
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('دفع نقدي (F1)'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: _saving || _cart.isEmpty
                          ? null
                          : () => _quickSettle(_PosPayment.credit),
                      icon: const Icon(Icons.schedule_outlined),
                      label: const Text('آجل (F2)'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed:
                    _saving || _cart.isEmpty ? null : _openCheckoutSheet,
                icon: const Icon(Icons.tune),
                label: const Text('خيارات الدفع الكاملة (خصم/جزئي)'),
              ),
              const SizedBox(height: 6),
              Text(
                'F3 بحث • F12 تعليق الفاتورة • Esc إفراغ',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11, color: AppColors.text3Of(context)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _summaryRow(String label, double value, CurrencyDef cur) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 13.5, color: AppColors.text2Of(context))),
            Text(
              '${Fmt.money(value)} ${cur.symbol}',
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      );

  Widget _buildPosSaleTab() {
    final categories = ref.watch(itemCategoriesProvider).valueOrNull ?? [];
    final allItems = ref.watch(itemsProvider).valueOrNull ?? [];
    final currencies =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final cur = currencies.first;

    final catsInSection = <int>{
      for (final c in categories)
        if (_sectionMatches(c.sectionId)) c.id!,
    };
    final filteredItems = allItems.where((item) {
      if (_selectedCategoryId != null &&
          item.categoryId != _selectedCategoryId) {
        return false;
      }
      // القسم: صنف ضمن فئات القسم المختار (أو بلا قسم في «عام»).
      if (_selectedSectionId != null &&
          _selectedCategoryId == null &&
          (item.categoryId == null ||
              !catsInSection.contains(item.categoryId))) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        // بحث ذكي: استعلام رقمي → باركود/SKU أولاً؛ نصي → تطبيع عربي
        // (تجاهل التشكيل وتوحيد أ/إ/آ→ا، ة→ه، ى→ي).
        if (Fmt.isNumericQuery(_searchQuery)) {
          final q = Fmt.normArabic(_searchQuery);
          return item.sku.contains(q) || Fmt.smartContains(item.name, q);
        }
        return Fmt.smartContains(item.name, _searchQuery) ||
            Fmt.smartContains(item.sku, _searchQuery);
      }
      return true;
    }).toList();

    // (2026-09-24) الترتيب المختار من زر الفلاتر — **لا يغيّر أرقام PLU**:
    // الأرقام ثابتة للأبد ومستقلة عن أي فرز معروض.
    switch (_posSort) {
      case 1:
        filteredItems.sort((a, b) => b.sellPrice.compareTo(a.sellPrice));
      case 2:
        filteredItems.sort((a, b) => b.quantity.compareTo(a.quantity));
      default:
        filteredItems.sort((a, b) => a.name.compareTo(b.name));
    }

    return Column(
      children: [
        // الشريط العلوي: تدرّج أزرق ملكي + بحث بيضاوي (Enter = PLU).
        _buildPosHeader(),
        // المستوى 1 — بوابة الأقسام (الوضع الافتراضي عند فتح الشاشة).
        if (_atSectionsGate)
          Expanded(
            child: Consumer(
              builder: (ctx, rref, _) {
                final sections =
                    rref.watch(sectionsProvider).valueOrNull ?? const <Section>[];
                final roots =
                    rref.watch(itemCategoryTreeProvider).valueOrNull ??
                        const <ItemCategory>[];
                return PosSectionsGate(
                  sections: sections,
                  roots: roots,
                  items: allItems,
                  onOpen: (sid) => setState(() {
                    _selectedSectionId = sid;
                    _selectedCategoryId = null;
                    _atSectionsGate = false;
                  }),
                );
              },
            ),
          )
        // المستوى 2 — الفئات + شبكة الأصناف داخل القسم المختار.
        else ...[
          Consumer(
            builder: (ctx, rref, _) {
              final sections =
                  rref.watch(sectionsProvider).valueOrNull ?? const <Section>[];
              return _buildSectionBar(sections, categories);
            },
          ),
          Consumer(
            builder: (ctx, rref, _) {
              final roots =
                  rref.watch(itemCategoryTreeProvider).valueOrNull ??
                      const <ItemCategory>[];
              return PosCategoryStrip(
                categories: _categoriesOfSection(roots, categories),
                selectedId: _selectedCategoryId,
                onPick: (cid) =>
                    setState(() => _selectedCategoryId = cid),
              );
            },
          ),
          Expanded(
            child: filteredItems.isEmpty
                ? const EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: 'لا توجد أصناف مطابقة',
                    message: 'أضف أصنافاً من شاشة المخزون أو غيّر نص البحث.',
                  )
                : PosItemsGrid(
                    items: filteredItems,
                    symbol: cur.symbol,
                    quantityInCart: (it) => _cart[it.id]?.quantity ?? 0,
                    canAdd: (it) => it.quantity > 0 || _allowNegative,
                    onAdd: (it) => _addItem(it),
                  ),
          ),
        ],
      ],
    );
  }

  /// فئات القسم النشط (بلا فروع) مرتّبة للعرض في الشريط العلوي.
  List<ItemCategory> _categoriesOfSection(
    List<ItemCategory> roots,
    List<ItemCategory> flat,
  ) {
    final out = <ItemCategory>[];
    void collect(ItemCategory c) {
      if (_sectionMatches(c.sectionId)) out.add(c);
    }

    if (roots.isNotEmpty) {
      for (final c in roots) {
        collect(c);
      }
    } else {
      for (final c in flat) {
        collect(c);
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// شريط القسم النشط مع تنقّل سريع للقسم المجاور (بلا رجوع للبوابة).
  Widget _buildSectionBar(List<Section> sections, List<ItemCategory> cats) {
    final items = ref.watch(itemsProvider).valueOrNull ?? const <Item>[];
    // تسلسل التنقل: [كل الأقسام] ثم [عام] (إن كان فيه أصناف) ثم الأقسام.
    final generalCount = items
        .where((i) => (i.sectionId ?? _sectionOfCat(cats, i.categoryId)) == null)
        .length;
    final seq = <(int?, String)>[
      (null, 'كل الأقسام'),
      if (generalCount > 0) (kGeneralSectionId, 'عام'),
      for (final s in sections) (s.id, s.name),
    ];
    final idx = seq.indexWhere((e) => e.$1 == _selectedSectionId);
    final prev = idx > 0 ? seq[idx - 1] : null;
    final next = (idx >= 0 && idx < seq.length - 1) ? seq[idx + 1] : null;
    final title = idx >= 0 ? seq[idx].$2 : 'كل الأقسام';

    return PosSectionBar(
      title: title,
      onBackToGate: () => setState(() {
        _atSectionsGate = true;
        _selectedSectionId = null;
        _selectedCategoryId = null;
      }),
      onPrev: prev == null
          ? null
          : () => setState(() {
                _selectedSectionId = prev.$1;
                _selectedCategoryId = null;
              }),
      onNext: next == null
          ? null
          : () => setState(() {
                _selectedSectionId = next.$1;
                _selectedCategoryId = null;
              }),
    );
  }

  int? _sectionOfCat(List<ItemCategory> cats, int? catId) {
    if (catId == null) return null;
    for (final c in cats) {
      if (c.id == catId) return c.sectionId;
    }
    return null;
  }

  /// هل تنتمي الفئة إلى القسم المختار حالياً؟
  bool _sectionMatches(int? sectionId) {
    if (_selectedSectionId == null) return true;
    return _selectedSectionId == kGeneralSectionId
        ? sectionId == null
        : sectionId == _selectedSectionId;
  }

  /// الشريط العلوي لنقطة البيع (أزرق ملكي متدرّج).
  Widget _buildPosHeader() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: dark
              ? const [Color(0xFF0B2A5B), Color(0xFF14407E)]
              : [AppColors.primary2, AppColors.primary],
        ),
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(AppRadius.sheet),
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: .26),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 14),
          child: Row(
            children: [
              _headerCircleButton(
                icon: Icons.home_rounded,
                tooltip: 'الرئيسية',
                onTap: () => ShellNav.go(ShellNav.home),
              ),
              const SizedBox(width: 8),
              Expanded(child: _buildPillSearch()),
              const SizedBox(width: 8),
              _headerCircleButton(
                icon: Icons.tune_rounded,
                tooltip: 'ترتيب الأصناف',
                onTap: _openPosSortSheet,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerCircleButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) =>
      SizedBox(
        width: 44,
        height: 44,
        child: Material(
          color: Colors.white.withValues(alpha: .18),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            tooltip: tooltip,
            icon: Icon(icon, color: Colors.white, size: 21),
            onPressed: onTap,
          ),
        ),
      );

  /// حقل البحث البيضاوي (Pill) بخلفية بيضاء نظيفة.
  Widget _buildPillSearch() => SizedBox(
        height: 46,
        child: TextField(
          controller: _searchCtrl,
          focusNode: _searchFocus,
          // على سطح المكتب: تركيز تلقائي لحقل الباركود/البحث — قارئ
          // الباركود يكتب مباشرة بلا نقرة.
          autofocus: isDesktopLayout(context),
          style: const TextStyle(fontSize: 14.5, color: Color(0xFF12223A)),
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            hintText: 'ابحث باسم الصنف أو الباركود…',
            hintStyle:
                const TextStyle(color: Color(0xFF9AA6B8), fontSize: 13.5),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14),
            prefixIcon: const Icon(Icons.search_rounded,
                size: 20, color: Color(0xFF9AA6B8)),
            prefixIconConstraints:
                const BoxConstraints(minWidth: 40, minHeight: 40),
            border: _pillBorder(Colors.transparent),
            enabledBorder: _pillBorder(Colors.transparent),
            focusedBorder: _pillBorder(Colors.transparent),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'مسح الباركود',
                  icon: const Icon(Icons.barcode_reader,
                      size: 20, color: Color(0xFF9AA6B8)),
                  onPressed: () async {
                    final code = await scanBarcode(context);
                    if (code != null && code.isNotEmpty) {
                      _searchCtrl.text = code;
                      setState(() => _searchQuery = code.trim());
                    }
                  },
                ),
                if (_searchQuery.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear,
                        size: 20, color: Color(0xFF9AA6B8)),
                    onPressed: () {
                      _searchCtrl.clear();
                      setState(() => _searchQuery = '');
                    },
                  ),
              ],
            ),
          ),
          onChanged: (v) => setState(() => _searchQuery = v.trim()),
          // Enter: رقم PLU (أو رقم×كمية) يضيف للسلة مباشرة، وإلا فالبحث.
          onSubmitted: (v) {
            if (_handleQuickIndex(v)) return;
            setState(() => _searchQuery = v.trim());
          },
        ),
      );

  OutlineInputBorder _pillBorder(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(999),
        borderSide: BorderSide(color: c),
      );

  /// (2026-09-24) **نظام الترقيم السريع (PLU)** — معالجة الإدخال الرقمي.
  ///
  /// • `7` + Enter      ⇒ يضيف حبة واحدة من الصنف صاحب الرقم 7.
  /// • `7*3` / `7×3`    ⇒ يضيف ثلاث حبات دفعة واحدة (تحقّق ذرّي من الرصيد).
  ///
  /// الرقم ثابت للأبد: لا يتأثر بالفرز ولا يُعاد استخدامه بعد الحذف.
  /// إن لم يطابق الإدخال أي PLU يُترك للبحث النصي/الباركود كما كان.
  bool _handleQuickIndex(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return false;
    final m = RegExp(r'^(\d+)\s*(?:[*x×])\s*(\d+)$').firstMatch(text);
    int? plu;
    double qty = 1;
    if (m != null) {
      plu = int.tryParse(m.group(1)!);
      qty = double.tryParse(m.group(2)!) ?? 1;
    } else {
      plu = int.tryParse(text);
    }
    if (plu == null || qty <= 0) return false;

    final items = ref.read(itemsProvider).valueOrNull ?? const <Item>[];
    Item? hit;
    for (final it in items) {
      if (it.plu == plu) {
        hit = it;
        break;
      }
    }
    if (hit == null) return false;

    _addItem(hit, quantity: qty);
    _searchCtrl.clear();
    setState(() => _searchQuery = '');
    // إبقاء التركيز في الحقل: الكاشير يواصل الإدخال بلا لمس الشاشة.
    _searchFocus.requestFocus();
    showSnack(
      context,
      'أُضيف ${Fmt.money(qty)} ${hit.unit} من «${hit.name}» (رقم $plu)',
      silent: true,
    );
    return true;
  }

  /// ترتيب شبكة الأصناف — شريحة سفلية صغيرة.
  void _openPosSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(ctx),
          borderRadius: AppRadius.sheetTop,
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderOf(ctx),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text('ترتيب الأصناف',
                style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 8),
            for (final e in const [
              (0, 'بالاسم', Icons.sort_by_alpha),
              (1, 'الأعلى سعراً', Icons.trending_up),
              (2, 'الأكثر توفراً', Icons.inventory_2_outlined),
            ])
              ListTile(
                leading: Icon(e.$3),
                title: Text(e.$2),
                trailing: _posSort == e.$1
                    ? Icon(Icons.check_circle,
                        color: AppColors.primaryOf(ctx))
                    : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                onTap: () {
                  setState(() => _posSort = e.$1);
                  Navigator.pop(ctx);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// شريط السلة العائم السفلي: بطاقة إحصائية بعدد الأصناف، الإجمالي
  /// في المنتصف بخط عريض، وزر أزرق ملكي عريض لعرض السلة.
  Widget _buildCartBottomBar() {
    final currencies =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final cur = currencies.first;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .10),
            blurRadius: 20,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // بطاقة إحصائية: عدد الأصناف بالسلة.
            Container(
              width: 62,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primarySoftOf(context),
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shopping_bag_outlined,
                      size: 18, color: AppColors.primaryOf(context)),
                  const SizedBox(height: 2),
                  Text(
                    '$_itemCount',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: AppColors.primaryOf(context),
                    ),
                  ),
                  Text(
                    'أصناف',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.text2Of(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // الإجمالي في المنتصف.
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'الإجمالي',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.text2Of(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${Fmt.money(_netTotal)} ${cur.symbol}',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: AppColors.greenOf(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // دفع نقدي سريع + إفراغ — تبقى الاختصارات ولا تزاحم الزر الرئيسي.
            IconButton.outlined(
              tooltip: 'إفراغ السلة',
              icon: Icon(Icons.delete_sweep_outlined,
                  color: AppColors.dangerOf(context)),
              onPressed: _clearCart,
            ),
            const SizedBox(width: 8),
            // الزر الأزرق الملكي العريض: عرض السلة.
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: _openCheckoutSheet,
                icon: const Icon(Icons.shopping_cart_checkout, size: 19),
                label: Text('عرض السلة ($_itemCount)'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.button),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// درج الدفع المنزلق (Slide-to-Pay): قائمة الأصناف تبقى ملء الشاشة،
  /// وكل الإدخال المالي في درج سفلي موسع — لا تغطية من لوحة المفاتيح.
  void _openCheckoutSheet() {
    ref.read(repoProvider).effectivePermissions().then((p) {
      if (mounted && p.canDiscount != _canDiscount) {
        setState(() => _canDiscount = p.canDiscount);
      }
    });
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              final accounts = ref.watch(allAccountsProvider).valueOrNull ?? [];
              final currencies = ref.watch(currenciesProvider).valueOrNull ??
                  kDefaultCurrencies;
              final cur = currencies.first;
              final customers = accounts
                  .where(
                    (a) =>
                        a.kind == AccountKind.customer ||
                        a.kind == AccountKind.general,
                  )
                  .toList();
              final needsAccount = _payment != _PosPayment.cash;
              final accountMissing = needsAccount && _selectedCustomerId == null;

              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'إتمام الفاتورة 🛒',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                    const Divider(),

                    // قائمة أصناف السلة — الكمية قابلة للنقر لإدخال مباشر.
                    for (final entry in _cart.values) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.item.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '${Fmt.money(entry.unitPrice)} ${cur.symbol} / ${entry.item.unit}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.text2Of(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.remove_circle_outline,
                                  size: 20,
                                ),
                                onPressed: () {
                                  final q = entry.quantity - 1;
                                  _cartCtl.setQuantity(entry.item.id!, q,
                                      allowNegative: _allowNegative);
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                              // نقرة على الكمية = لوحة إدخال رقمي سريعة.
                              InkWell(
                                onTap: () async {
                                  await _editQuantity(entry);
                                  setSheetState(() {});
                                  setState(() {});
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: AppColors.primaryOf(context)
                                            .withValues(alpha: .4)),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    Fmt.money(entry.quantity),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.add_circle_outline,
                                  size: 20,
                                ),
                                onPressed: () {
                                  final ok = _cartCtl.setQuantity(
                                      entry.item.id!, entry.quantity + 1,
                                      allowNegative: _allowNegative);
                                  if (!ok) {
                                    Sfx.reject();
                                    showSnack(
                                      context,
                                      'الكمية المتاحة: ${entry.item.quantity.toStringAsFixed(0)} ${entry.item.unit} فقط',
                                      error: true,
                                    );
                                    return;
                                  }
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                          SizedBox(
                            width: 75,
                            child: Text(
                              '${Fmt.money(entry.total)} ${cur.symbol}',
                              textAlign: TextAlign.end,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 12),
                    ],

                    const SizedBox(height: 10),

                    // طريقة الدفع أولاً — تحدد هل نحتاج حساب عميل.
                    SegmentedButton<_PosPayment>(
                      segments: _PosPayment.values
                          .map(
                            (p) =>
                                ButtonSegment(value: p, label: Text(p.label)),
                          )
                          .toList(),
                      selected: {_payment},
                      onSelectionChanged: (set) {
                        _cartCtl.setPayment(set.first.code);
                        setSheetState(() {});
                        setState(() {});
                      },
                    ),

                    const SizedBox(height: 12),

                    // اختيار العميل — يتوهج بالأحمر إذا كان الدفع آجلاً
                    // بلا حساب محدد (تنبيه بصري لا نصي فقط).
                    Container(
                      decoration: accountMissing
                          ? BoxDecoration(
                              border: Border.all(
                                  color: AppColors.dangerOf(context),
                                  width: 2),
                              borderRadius: BorderRadius.circular(10),
                            )
                          : null,
                      padding:
                          accountMissing ? const EdgeInsets.all(6) : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (accountMissing)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                '⚠️ البيع الآجل يتطلب اختيار حساب العميل',
                                style: TextStyle(
                                  color: AppColors.dangerOf(context),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          // آخر 3 مدينين — اختيار بنقرة واحدة في وضع الآجل.
                          if (needsAccount)
                            FutureBuilder<List<Account>>(
                              future: _recentDebtors(customers),
                              builder: (c, snap) {
                                final recents = snap.data ?? const <Account>[];
                                if (recents.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: SizedBox(
                                    height: 38,
                                    child: ListView(
                                      scrollDirection: Axis.horizontal,
                                      children: [
                                        for (final a in recents)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                left: 6),
                                            child: ChoiceChip(
                                              label: Text(a.name,
                                                  overflow:
                                                      TextOverflow.ellipsis),
                                              selected:
                                                  _selectedCustomerId == a.id,
                                              onSelected: (_) {
                                                _cartCtl.setCustomer(a.id);
                                                setSheetState(() {});
                                                setState(() {});
                                              },
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          DropdownButtonFormField<int?>(
                            initialValue: _selectedCustomerId,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'العميل',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                            items: [
                              const DropdownMenuItem<int?>(
                                value: null,
                                child: Text('عميل نقدي (بدون حساب)'),
                              ),
                              for (final c in customers)
                                DropdownMenuItem<int?>(
                                  value: c.id,
                                  child: Text(
                                    '${c.name} (${c.phone.isNotEmpty ? c.phone : 'بدون هاتف'})',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (val) {
                              _cartCtl.setCustomer(val);
                              setSheetState(() {});
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),

                    // تحذير تجاوز حد الائتمان — قبل السماح بالتأكيد.
                    if (needsAccount && _selectedCustomerId != null)
                      FutureBuilder<_CreditCheck?>(
                        future: _checkCreditLimit(),
                        builder: (c, snap) {
                          final chk = snap.data;
                          if (chk == null || !chk.exceeded) {
                            return const SizedBox.shrink();
                          }
                          return Container(
                            margin: const EdgeInsets.only(top: 10),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.dangerOf(context)
                                  .withValues(alpha: .1),
                              border: Border.all(
                                  color: AppColors.dangerOf(context)),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '🚨 هذه الفاتورة تتجاوز حد الائتمان للعميل!\n'
                              'الحد: ${Fmt.money(chk.limit)} ${cur.symbol} — '
                              'الدين الحالي: ${Fmt.money(chk.currentDebt)} ${cur.symbol}\n'
                              'المتبقي من الحد: ${Fmt.money(chk.remaining)} ${cur.symbol}',
                              style: TextStyle(
                                color: AppColors.dangerOf(context),
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                                height: 1.6,
                              ),
                            ),
                          );
                        },
                      ),

                    if (_payment == _PosPayment.partial) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _paidCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: const [ThousandsFormatter()],
                        decoration: InputDecoration(
                          labelText: 'المبلغ المدفوع مقدماً',
                          prefixIcon: const Icon(Icons.payments_outlined),
                          isDense: true,
                          // أزرار الأصفار السريعة داخل الحقل.
                          suffixIcon: _ZeroButtons(controller: _paidCtrl,
                              onChanged: () {
                            _cartCtl.setPaid(_paidCtrl.text);
                            setSheetState(() {});
                            setState(() {});
                          }),
                        ),
                        onChanged: (v) {
                          _cartCtl.setPaid(v);
                          setSheetState(() {});
                          setState(() {});
                        },
                      ),
                      AmountWords(controller: _paidCtrl),
                    ],

                    const SizedBox(height: 12),

                    // الخصم المزدوج: نسبة % أو مبلغ مقطوع — صلاحية الخصم مع تخطي المشرف (Supervisor Override)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: _hasDiscountPermission
                                ? null
                                : () => _promptSupervisorOverride(setSheetState),
                            child: IgnorePointer(
                              ignoring: !_hasDiscountPermission,
                              child: TextField(
                                controller: _discountCtrl,
                                enabled: _hasDiscountPermission,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                inputFormatters: _draft.discountIsPercent
                                    ? null
                                    : const [ThousandsFormatter()],
                                decoration: InputDecoration(
                                  labelText: _draft.discountIsPercent
                                      ? 'نسبة الخصم %'
                                      : 'مبلغ الخصم',
                                  prefixIcon:
                                      const Icon(Icons.discount_outlined),
                                  suffixIcon: !_hasDiscountPermission
                                      ? Tooltip(
                                          message:
                                              'طلب إذن المشرف لتطبيق الخصم',
                                          child: IconButton(
                                            icon: const Icon(
                                              Icons.lock_outline_rounded,
                                              color: Colors.amber,
                                            ),
                                            onPressed: () =>
                                                _promptSupervisorOverride(
                                                    setSheetState),
                                          ),
                                        )
                                      : (_supervisorOverride
                                          ? const Icon(Icons.verified,
                                              color: Colors.green)
                                          : null),
                                  helperText: !_hasDiscountPermission
                                      ? 'الخصم مقفل — انقر لطلب إذن المشرف برمز PIN'
                                      : (_supervisorOverride
                                          ? 'معتمد من المشرف ✅'
                                          : null),
                                  helperStyle: !_hasDiscountPermission
                                      ? const TextStyle(
                                          color: Colors.amber, fontSize: 11)
                                      : const TextStyle(
                                          color: Colors.green, fontSize: 11),
                                  isDense: true,
                                  filled: !_hasDiscountPermission,
                                  fillColor: !_hasDiscountPermission
                                      ? (Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white10
                                          : Colors.black.withValues(alpha: .04))
                                      : null,
                                ),
                                onChanged: (v) {
                                  _cartCtl.setDiscount(v);
                                  setSheetState(() {});
                                  setState(() {});
                                },
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Opacity(
                          opacity: _hasDiscountPermission ? 1.0 : 0.5,
                          child: IgnorePointer(
                            ignoring: !_hasDiscountPermission,
                            child: SegmentedButton<bool>(
                              style: const ButtonStyle(
                                visualDensity: VisualDensity.compact,
                              ),
                              segments: const [
                                ButtonSegment(value: false, label: Text('مبلغ')),
                                ButtonSegment(value: true, label: Text('٪')),
                              ],
                              selected: {_draft.discountIsPercent},
                              onSelectionChanged: (set) {
                                _cartCtl.setDiscountIsPercent(set.first);
                                setSheetState(() {});
                                setState(() {});
                              },
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // الملخص المالي
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.primarySoftOf(context),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('المجموع الفرعي:'),
                              Text('${Fmt.money(_subtotal)} ${cur.symbol}'),
                            ],
                          ),
                          if (_discount > 0) ...[
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _draft.discountIsPercent
                                      ? 'الخصم (${_draft.discountText.trim()}٪):'
                                      : 'الخصم:',
                                  style:
                                      const TextStyle(color: AppColors.red),
                                ),
                                Text(
                                  '-${Fmt.money(_discount)} ${cur.symbol}',
                                  style: const TextStyle(color: AppColors.red),
                                ),
                              ],
                            ),
                          ],
                          const Divider(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'الصافي الإجمالي:',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                '${Fmt.money(_netTotal)} ${cur.symbol}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                  color: AppColors.primaryOf(context),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // زر تأكيد عريض مع قفل فوري ضد النقر المزدوج.
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _saving ? null : () => _executeSale(ctx),
                        icon: _saving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check_circle_outline),
                        label: Text(
                          _saving ? 'جارٍ الحفظ…' : 'تأكيد وإصدار الفاتورة',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// أحدث 3 عملاء لهم مبيعات آجلة — للاختيار بنقرة واحدة.
  Future<List<Account>> _recentDebtors(List<Account> customers) async {
    try {
      final repo = ref.read(repoProvider);
      final txs = await repo.transactions();
      final seen = <int>{};
      final out = <Account>[];
      for (final t in txs) {
        if (t.type != OpType.debit || t.accountId == null) continue;
        if (!seen.add(t.accountId!)) continue;
        final a = customers.where((c) => c.id == t.accountId).firstOrNull;
        if (a != null) out.add(a);
        if (out.length >= 3) break;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// فحص حد الائتمان للعميل المحدد مقابل صافي الفاتورة الحالية.
  Future<_CreditCheck?> _checkCreditLimit() async {
    final id = _selectedCustomerId;
    if (id == null) return null;
    try {
      final repo = ref.read(repoProvider);
      final acc = await repo.account(id);
      if (acc == null || acc.creditLimit == null || acc.creditLimit! <= 0) {
        return null;
      }
      final balance = await repo.balanceOf(acc);
      // الرصيد الموجب = دين على العميل. الجزئي يضيف المتبقي فقط.
      final debt = balance > 0 ? balance : 0.0;
      var added = _netTotal;
      if (_payment == _PosPayment.partial) {
        final paid =
            Fmt.parseAmount(ThousandsFormatter.strip(_paidCtrl.text)) ?? 0.0;
        added = (_netTotal - paid).clamp(0.0, double.infinity);
      }
      final limit = acc.creditLimit!;
      return _CreditCheck(
        limit: limit,
        currentDebt: debt,
        exceeded: debt + added > limit,
        remaining: (limit - debt).clamp(0.0, double.infinity),
      );
    } catch (_) {
      return null;
    }
  }

  /// ينفّذ البيع. [sheetCtx] سياق درج الدفع ليُغلق بعد النجاح —
  /// null عند التنفيذ المباشر (اختصارات سطح المكتب F1/F2) بلا درج.
  Future<void> _executeSale(BuildContext? sheetCtx) async {
    if (_cart.isEmpty || _saving) return;

    if ((_payment == _PosPayment.credit || _payment == _PosPayment.partial) &&
        _selectedCustomerId == null) {
      Sfx.reject();
      showSnack(
        context,
        'البيع الآجل أو الجزئي يتطلب اختيار حساب العميل.',
        error: true,
        silent: true,
      );
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(repoProvider);

    try {
      final currencies = await repo.currencies();
      final cur = currencies.first;
      // رقم فاتورة تسلسلي رقمي بحت (بدون أحرف)
      final refNum = await repo.nextTxNumber();

      // 0. تحقق نهائي من توفر المخزون (دفاع ضد بيانات تغيّرت أثناء الجلسة).
      // إعداد «السماح بالبيع عند نفاد الرصيد» يتخطى الحظر مع تنبيه بصري.
      if (!_allowNegative) {
        for (final e in _cart.values) {
          if (e.item.id == null) continue;
          final fresh = await repo.item(e.item.id!);
          final available = fresh?.quantity ?? e.item.quantity;
          if (available < e.quantity) {
            throw StateError(
              'الكمية المطلوبة من «${e.item.name}» غير متوفرة. '
              'المتاح: ${available.toStringAsFixed(0)} ${e.item.unit}.',
            );
          }
        }
      }

      // 1. تجهيز أسطر الفاتورة
      final lines = _cart.values.map((e) {
        return InvoiceLine(
          itemId: e.item.id,
          name: e.item.name,
          unit: e.item.unit,
          quantity: e.quantity,
          unitPrice: e.unitPrice,
          total: e.total,
        );
      }).toList();

      // 2. تحديد نوع وسجل العملية المالية
      late final int txId;
      final now = DateTime.now();
      final user = ref.read(currentUserProvider).valueOrNull;
      final int? creatorId = user?.id;
      final cashierName = user?.name.trim().isNotEmpty == true ? user!.name : 'الكاشير';
      final supNote = _supervisorOverride
          ? '\n[تم اعتماد الخصم بواسطة المشرف]'
          : '';

      if (_payment == _PosPayment.cash) {
        // مبيعات نقدية: إيراد
        final tx = Tx(
          accountId: _selectedCustomerId,
          amount: _netTotal,
          currency: cur.code,
          type: OpType.revenue,
          date: now,
          description: 'فاتورة مبيعات نقدية رقم #$refNum',
          reference: refNum,
          notes: 'طريقة الدفع: نقداً$supNote',
          createdByUserId: creatorId,
          cashierName: cashierName,
          createdAt: now,
          updatedAt: now,
        );
        txId = await repo.saveTx(tx, items: lines);
      } else if (_payment == _PosPayment.credit) {
        // مبيعات آجلة: قيد مدين على العميل (عليه)
        final tx = Tx(
          accountId: _selectedCustomerId!,
          amount: _netTotal,
          currency: cur.code,
          type: OpType.debit,
          date: now,
          description: 'فاتورة مبيعات آجلة رقم #$refNum',
          reference: refNum,
          notes: 'طريقة الدفع: آجل (على الحساب)$supNote',
          createdByUserId: creatorId,
          cashierName: cashierName,
          createdAt: now,
          updatedAt: now,
        );
        txId = await repo.saveTx(tx, items: lines);
      } else {
        // مبيعات جزئية: قيد بالباقي + قبض بالمقدم
        final paid =
            Fmt.parseAmount(ThousandsFormatter.strip(_paidCtrl.text)) ?? 0.0;
        final remainder = (_netTotal - paid).clamp(0.0, double.infinity);

        // تسجيل المبلغ الكامل كمدين
        final debitTx = Tx(
          accountId: _selectedCustomerId!,
          amount: _netTotal,
          currency: cur.code,
          type: OpType.debit,
          date: now,
          description:
              'فاتورة مبيعات جزئية رقم #$refNum (إجمالي ${Fmt.money(_netTotal)} ${cur.symbol} — مدفوع ${Fmt.money(paid)} ${cur.symbol} — متبقي ${Fmt.money(remainder)} ${cur.symbol})',
          reference: refNum,
          notes:
              'طريقة الدفع: جزئي (مقدم + آجل)\nالمبلغ المدفوع: ${Fmt.money(paid)} ${cur.symbol}\nالمبلغ المتبقي: ${Fmt.money(remainder)} ${cur.symbol}$supNote',
          createdByUserId: creatorId,
          cashierName: cashierName,
          createdAt: now,
          updatedAt: now,
        );
        txId = await repo.saveTx(debitTx, items: lines);

        // تسجيل الدفعة المسددة كقبض إن وجدت
        if (paid > 0) {
          final payTx = Tx(
            accountId: _selectedCustomerId!,
            amount: paid,
            currency: cur.code,
            type: OpType.inflow,
            date: now,
            description:
                'دفعة مقدمة من فاتورة #$refNum (المتبقي: ${Fmt.money(remainder)} ${cur.symbol})',
            reference: '',
            createdByUserId: creatorId,
            cashierName: cashierName,
            createdAt: now,
            updatedAt: now,
          );
          await repo.saveTx(payTx);
        }
      }

      // 3. خصم الكميات تلقائياً من المخزون
      for (final line in lines) {
        if (line.itemId != null) {
          try {
            await repo.addStockMove(
              StockMove(
                itemId: line.itemId!,
                quantity: line.quantity,
                kind: StockKind.sale,
                date: now,
                createdAt: now,
                notes: 'مبيع نقطة بيع #$refNum',
              ),
            );
          } catch (e) {
            debugPrint('Failed to reduce stock for ${line.name}: $e');
          }
        }
      }

      // تحديث البيانات
      bump(ref);
      if (mounted && (await repo.settings())['warnLowStock'] != '0') {
        final low = <String>[];
        for (final line in lines) {
          if (line.itemId == null) continue;
          final it = await repo.item(line.itemId!);
          if (it != null &&
              it.minQuantity > 0 &&
              it.quantity <= it.minQuantity) {
            low.add(
              '${it.name} (${it.quantity.toStringAsFixed(0)} ${it.unit})',
            );
          }
        }
        if (low.isNotEmpty && mounted) {
          Sfx.warning();
          showSnack(
            context,
            '⚠️ أصناف وصلت حد إعادة الطلب: ${low.join('، ')}',
            error: true,
            silent: true,
          );
        }
      }

      if (mounted && (await repo.settings())['warnLowStock'] != '0') {
        final low = <String>[];
        for (final line in lines) {
          if (line.itemId == null) continue;
          final it = await repo.item(line.itemId!);
          if (it != null &&
              it.minQuantity > 0 &&
              it.quantity <= it.minQuantity) {
            low.add(
              '${it.name} (${it.quantity.toStringAsFixed(0)} ${it.unit})',
            );
          }
        }
        if (low.isNotEmpty && mounted) {
          Sfx.warning();
          showSnack(
            context,
            '⚠️ أصناف وصلت حد إعادة الطلب:\n${low.join('، ')}',
            error: true,
            silent: true,
          );
        }
      }

      if (mounted) {
        if (sheetCtx != null && sheetCtx.mounted) Navigator.pop(sheetCtx);
        Sfx.opCreated(); // صوت الدفع + اهتزاز طويل (1.5 ث) عند إنشاء العملية.
        _showSuccessDialog(txId, refNum, lines);
        _clearCart();
      }
    } catch (e) {
      if (mounted) {
        Sfx.error();
        showSnack(
          context,
          'تعذّر إتمام الفاتورة: $e',
          error: true,
          silent: true,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showSuccessDialog(int txId, String refNum, List<InvoiceLine> lines) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: AppColors.green),
              SizedBox(width: 8),
              Text('تمت العملية بنجاح ✅'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('رقم الفاتورة: $refNum'),
              Text('عدد الأصناف: ${lines.length}'),
              const SizedBox(height: 12),
              const Text(
                'يمكنك طباعة الإيصال الحراري أو مشاركة الفاتورة عبر واتساب مباشرة:',
              ),
            ],
          ),
          actions: [
            OutlinedButton.icon(
              icon: const Icon(Icons.print_outlined),
              label: const Text('طباعة إيصال حراري (80mm)'),
              onPressed: () async {
                final repo = ref.read(repoProvider);
                final txs = await repo.transactions();
                final tx = txs.firstWhere((t) => t.id == txId);
                final accs = await repo.accounts(includeArchived: true);
                final acc = accs.where((a) => a.id == tx.accountId).firstOrNull;
                final stamp = await featureNeedsStamp(
                    ref, Feature.reportsExport);
                if (context.mounted) {
                  await _printThermalInvoice(tx, acc, lines, stamp: stamp);
                }
              },
            ),
            FilledButton.icon(
              icon: const Icon(Icons.send_outlined),
              label: const Text('إرسال واتساب'),
              onPressed: () async {
                final repo = ref.read(repoProvider);
                final txs = await repo.transactions();
                if (!mounted) return;
                final tx = txs.firstWhere((t) => t.id == txId);
                final accs = await repo.accounts(includeArchived: true);
                if (!mounted) return;
                final acc = accs.where((a) => a.id == tx.accountId).firstOrNull;
                if (acc == null || acc.phone.isEmpty) {
                  showSnack(
                    context,
                    'لا يوجد رقم هاتف مسجل للعميل',
                    error: true,
                  );
                  return;
                }
                await TxShare.sendNow(context, ref, tx: tx, account: acc);
              },
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('فاتورة جديدة'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _printThermalInvoice(
    Tx tx,
    Account? account,
    List<InvoiceLine> lines, {
    bool stamp = false,
  }) async {
    final repo = ref.read(repoProvider);
    final st = await repo.settings();
    final orgName = (st['businessName'] ?? 'المتجر').trim();
    final orgPhone = (st['phone'] ?? '').trim();
    final footer = (st['voucherFooter'] ?? 'شكراً لزيارتكم!').trim();

    // (2026-09-24) بناء الفاتورة انتقل إلى thermal_invoice_doc.dart: المستند
    // صار يحمل الخط العربي المدمج (Cairo) واتجاه RTL، بدل مستند بلا ثيم
    // الذي كان يُخرج الحروف العربية مربعات «▯» في المعاينة والطباعة.
    final bytes = await buildThermalInvoicePdf(
      tx: tx,
      account: account,
      lines: lines,
      orgName: orgName,
      orgPhone: orgPhone,
      footer: footer,
      stamp: stamp,
    );

    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: 'invoice-${tx.reference}.pdf',
    );
  }
}
/// تبويب سجل فواتير المبيعات
class _PosHistoryTab extends ConsumerWidget {
  const _PosHistoryTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txData = ref.watch(txPageProvider);

    return txData.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'تعذّر تحميل سجل المبيعات',
        message: '$e',
      ),
      data: (page) {
        // تصفية فواتير المبيعات فقط (وصفها فاتورة، نستثني الدفعات المقدمة)
        final posTxs = page.items
            .where(
              (t) =>
                  (t.description.contains('فاتورة') &&
                      !t.description.startsWith('دفعة مقدمة')) ||
                  t.type == OpType.revenue,
            )
            .toList();

        if (posTxs.isEmpty) {
          return const EmptyState(
            icon: Icons.receipt_long_outlined,
            title: 'لا توجد فواتير مبيعات مسجلة',
            message: 'قم بإجراء عمليات بيع من تبويب نقطة البيع وستظهر هنا.',
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: posTxs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final tx = posTxs[i];
            final account = page.accounts[tx.accountId];

            return Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primarySoftOf(context),
                  child: const Icon(Icons.receipt, color: AppColors.teal),
                ),
                title: Text(
                  tx.reference.isNotEmpty
                      ? 'فاتورة #${tx.reference}'
                      : tx.description,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  '${account?.name ?? 'عميل نقدي'} • ${Fmt.date(tx.date)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.text2Of(context),
                  ),
                ),
                trailing: Text(
                  '${Fmt.money(tx.amount)} ${tx.currency}',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    color: AppColors.primaryOf(context),
                  ),
                ),
                onTap: () async {
                  final repo = ref.read(repoProvider);
                  final items = await repo.transactionItems(tx.id!);
                  if (context.mounted) {
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text('تفاصيل ${tx.reference}'),
                        content: SizedBox(
                          width: double.maxFinite,
                          child: items.isEmpty
                              ? const Text('لا توجد أصناف مسجلة لهذه الفاتورة.')
                              : ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: items.length,
                                  itemBuilder: (_, idx) {
                                    final it = items[idx];
                                    return ListTile(
                                      title: Text(it.name),
                                      trailing: Text(
                                        '${it.quantity} × ${Fmt.money(it.unitPrice)} = ${Fmt.money(it.total)}',
                                      ),
                                    );
                                  },
                                ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('إغلاق'),
                          ),
                        ],
                      ),
                    );
                  }
                },
              ),
            );
          },
        );
      },
    );
  }
}

/// نتيجة فحص حد الائتمان للعميل قبل تأكيد فاتورة آجلة.
class _CreditCheck {
  final double limit;
  final double currentDebt;
  final double remaining;
  final bool exceeded;
  const _CreditCheck({
    required this.limit,
    required this.currentDebt,
    required this.remaining,
    required this.exceeded,
  });
}

/// زرا «+00» و«+000» المدمجان في حقول المبالغ لتسريع الإدخال.
class _ZeroButtons extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onChanged;
  const _ZeroButtons({required this.controller, required this.onChanged});

  void _append(String zeros) {
    final raw = ThousandsFormatter.strip(controller.text);
    if (raw.isEmpty || raw == '0' || raw.contains('.')) return;
    controller.value = const ThousandsFormatter().formatEditUpdate(
      controller.value,
      TextEditingValue(text: '$raw$zeros'),
    );
    Sfx.click();
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(38, 32),
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          onPressed: () => _append('00'),
          child: const Text('+00',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        ),
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(38, 32),
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          onPressed: () => _append('000'),
          child: const Text('+000',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }
}
