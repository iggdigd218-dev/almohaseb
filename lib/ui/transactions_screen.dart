import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'tx_form.dart';
import 'trial_ui.dart' show ensureFeatureUnlocked;
import 'tx_share.dart';
import 'widgets.dart';

class TransactionsScreen extends ConsumerWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(txPageProvider);
    final hidden = ref.watch(hideBalancesProvider);
    // (قانون 2026-09-19) زر «إضافة عملية» صريح داخل الشاشة نفسها.
    final me = ref.watch(currentUserProvider).valueOrNull;
    final canAdd = me != null && me.can('add_tx');

    return Column(
      children: [
        const _TxFilterBar(),
        if (canAdd)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.icon(
                onPressed: () => openTxForm(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('إضافة عملية'),
              ),
            ),
          ),
        Expanded(
          child: page.when(
            skipLoadingOnReload: true,
            skipLoadingOnRefresh: true,
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('جارٍ تحميل العمليات…'),
                  ],
                ),
              ),
            ),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    EmptyState(
                      icon: Icons.error_outline,
                      title: 'تعذّر تحميل العمليات',
                      message:
                          '$e'.length > 200 ? '${'$e'.substring(0, 200)}…' : '$e',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => bump(ref),
                      icon: const Icon(Icons.refresh),
                      label: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              ),
            ),
            data: (p) {
              if (p.items.isEmpty) {
                return EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'لا توجد عمليات مطابقة',
                  message: 'غيّر معايير البحث أو سجّل عملية جديدة.',
                  action: canAdd
                      ? FilledButton.icon(
                          onPressed: () => openTxForm(context, ref),
                          icon: const Icon(Icons.add),
                          label: const Text('إضافة عملية'),
                        )
                      : null,
                );
              }
              // (دفعة 58) سحب للأسفل = إعادة تحميل + مزامنة فورية.
              return RefreshIndicator(
                onRefresh: () async => bump(ref),
                child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 96),
                itemCount: p.items.length + 1,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  if (i == 0) return _Totals(page: p, hidden: hidden);
                  final t = p.items[i - 1];
                  return _TxCard(
                    tx: t,
                    account: t.type == OpType.transfer
                        ? p.accounts[t.fromId]
                        : p.accounts[t.accountId],
                    toAccount: p.accounts[t.toId],
                    hidden: hidden,
                  );
                },
              ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// شريط البحث والمرشّحات — يطابق أدوات نسخة الويب.
class _TxFilterBar extends ConsumerStatefulWidget {
  const _TxFilterBar();

  @override
  ConsumerState<_TxFilterBar> createState() => _TxFilterBarState();
}

class _TxFilterBarState extends ConsumerState<_TxFilterBar> {
  late final TextEditingController _q;

  @override
  void initState() {
    super.initState();
    _q = TextEditingController(text: ref.read(txFilterProvider).query);
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _set(TxFilter f) => ref.read(txFilterProvider.notifier).state = f;

  @override
  Widget build(BuildContext context) {
    final f = ref.watch(txFilterProvider);
    final accounts = ref.watch(allAccountsProvider).valueOrNull ?? [];
    final currencies = ref.watch(currenciesProvider).valueOrNull ?? [];

    return Container(
      color: AppColors.surfaceOf(context),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        children: [
          TextField(
            controller: _q,
            decoration: InputDecoration(
              hintText: 'بحث بالبيان أو المرجع أو الحساب...',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              suffixIcon: f.query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _q.clear();
                        _set(f.copyWith(query: ''));
                      },
                    ),
            ),
            onChanged: (v) => _set(f.copyWith(query: v)),
          ),
          const SizedBox(height: 8),
          // صف مدمج: زر «تصفية» واحد يفتح كل خيارات الفلترة في نافذة سفلية،
          // مع عدد الفلاتر النشطة وزر مسح — بدل صف أزرار مزدحم.
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  // 🔒 البحث المتقدم ميزة مدفوعة — يبقى الزر ظاهراً
                  // ويقود لشاشة الشراء عند القفل.
                  onPressed: () async {
                    final ok = await ensureFeatureUnlocked(context, ref,
                        featureKey: 'advanced_search',
                        featureName: 'البحث الشامل المتقدم',
                        description:
                            'فلترة عميقة بالحساب والعملة والنوع والفترة '
                            'الزمنية للوصول لأي عملية في ثوانٍ.');
                    if (ok) _openFilters(f, accounts, currencies);
                  },
                  icon: Icon(
                    Icons.tune,
                    size: 18,
                    color: f.isActive
                        ? AppColors.primaryOf(context)
                        : AppColors.text2Of(context),
                  ),
                  label: Text(
                    f.isActive
                        ? 'الفلاتر مفعّلة (${_activeCount(f)}) — اضغط للتعديل'
                        : 'تصفية وبحث متقدّم',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: f.isActive
                          ? AppColors.primaryOf(context)
                          : AppColors.text2Of(context),
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: f.isActive
                          ? AppColors.primaryOf(context)
                          : AppColors.borderOf(context),
                    ),
                    backgroundColor: f.isActive
                        ? AppColors.primarySoftOf(context)
                        : AppColors.surface2Of(context),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              if (f.isActive) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'مسح كل الفلاتر',
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 20),
                  color: AppColors.dangerOf(context),
                  onPressed: () {
                    _q.clear();
                    _set(const TxFilter());
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickType(TxFilter f) async {
    final v = await showModalBottomSheet<Object>(
      context: context,
      builder: (_) => _SheetList(
        title: 'نوع العملية',
        items: [
          const _SheetItem(value: '', label: 'كل الأنواع'),
          ...OpType.values.map(
            (t) => _SheetItem(value: t, label: '${t.icon}  ${t.label}'),
          ),
        ],
      ),
    );
    if (v == null) return;
    _set(v is OpType ? f.copyWith(type: v) : f.copyWith(clearType: true));
  }

  Future<void> _pickAccount(TxFilter f, List<Account> accounts) async {
    final v = await showModalBottomSheet<Object>(
      context: context,
      builder: (_) => _SheetList(
        title: 'الحساب',
        items: [
          const _SheetItem(value: '', label: 'كل الحسابات'),
          ...accounts.map(
            (a) => _SheetItem(value: a.id!, label: '${a.kind.icon}  ${a.name}'),
          ),
        ],
      ),
    );
    if (v == null) return;
    _set(v is int ? f.copyWith(accountId: v) : f.copyWith(clearAccount: true));
  }

  Future<void> _pickCurrency(TxFilter f, List<CurrencyDef> curs) async {
    final v = await showModalBottomSheet<Object>(
      context: context,
      builder: (_) => _SheetList(
        title: 'العملة',
        items: [
          const _SheetItem(value: '', label: 'كل العملات'),
          ...curs.map(
            (c) => _SheetItem(value: c.code, label: '${c.symbol}  ${c.name}'),
          ),
        ],
      ),
    );
    if (v == null) return;
    _set(
      v is String && v.isNotEmpty
          ? f.copyWith(currency: v)
          : f.copyWith(clearCurrency: true),
    );
  }

  Future<void> _pickSort(TxFilter f) async {
    final v = await showModalBottomSheet<Object>(
      context: context,
      builder: (_) => _SheetList(
        title: 'الترتيب',
        items: TxSort.values
            .map((s) => _SheetItem(value: s, label: s.label))
            .toList(),
      ),
    );
    if (v is TxSort) _set(f.copyWith(sort: v));
  }

  Future<void> _pickRange(TxFilter f) async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2015),
      lastDate: DateTime(2100),
      locale: const Locale('ar'),
      initialDateRange: f.from != null && f.to != null
          ? DateTimeRange(start: f.from!, end: f.to!)
          : null,
    );
    if (r == null) return;
    _set(
      f.copyWith(
        from: DateTime(r.start.year, r.start.month, r.start.day),
        to: DateTime(r.end.year, r.end.month, r.end.day, 23, 59, 59),
      ),
    );
  }

  /// عدد الفلاتر المفعّلة حالياً (يظهر على زر التصفية).
  int _activeCount(TxFilter f) {
    var n = 0;
    if (f.type != null) n++;
    if (f.accountId != null) n++;
    if (f.currency != null) n++;
    if (f.from != null || f.to != null) n++;
    if (f.sort != TxSort.newest) n++;
    return n;
  }

  String _accountLabel(TxFilter f, List<Account> accounts) =>
      f.accountId == null
          ? 'كل الحسابات'
          : (accounts.where((a) => a.id == f.accountId).firstOrNull?.name ??
              'حساب محدد');

  String _rangeLabel(TxFilter f) => f.from == null && f.to == null
      ? 'كل الفترات'
      : '${f.from != null ? Fmt.date(f.from!) : '…'} → ${f.to != null ? Fmt.date(f.to!) : '…'}';

  /// نافذة واحدة تجمع كل خيارات الفلترة (النوع/الحساب/العملة/الفترة/الترتيب/مسح).
  Future<void> _openFilters(
    TxFilter f,
    List<Account> accounts,
    List<CurrencyDef> currencies,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        Widget tile(
          IconData icon,
          String title,
          String value,
          VoidCallback onTap, {
          bool active = false,
        }) {
          return ListTile(
            leading: Icon(
              icon,
              color: active
                  ? AppColors.primaryOf(sheetCtx)
                  : AppColors.text2Of(sheetCtx),
            ),
            title: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(value),
            trailing: const Icon(
              Icons.chevron_left,
              color: Colors.grey,
              size: 22,
            ),
            onTap: () {
              Navigator.pop(sheetCtx);
              onTap();
            },
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'تصفية العمليات',
                  style: Theme.of(sheetCtx).textTheme.titleMedium,
                ),
              ),
              const Divider(height: 1),
              tile(
                Icons.category_outlined,
                'نوع العملية',
                f.type?.label ?? 'كل الأنواع',
                () => _pickType(f),
                active: f.type != null,
              ),
              tile(
                Icons.people_alt_outlined,
                'الحساب',
                _accountLabel(f, accounts),
                () => _pickAccount(f, accounts),
                active: f.accountId != null,
              ),
              tile(
                Icons.currency_exchange,
                'العملة',
                f.currency ?? 'كل العملات',
                () => _pickCurrency(f, currencies),
                active: f.currency != null,
              ),
              tile(
                Icons.date_range_outlined,
                'الفترة الزمنية',
                _rangeLabel(f),
                () => _pickRange(f),
                active: f.from != null || f.to != null,
              ),
              tile(
                Icons.sort,
                'الترتيب',
                f.sort.label,
                () => _pickSort(f),
                active: f.sort != TxSort.newest,
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  Icons.filter_alt_off_outlined,
                  color: AppColors.dangerOf(sheetCtx),
                ),
                title: Text(
                  'مسح كل الفلاتر',
                  style: TextStyle(
                    color: AppColors.dangerOf(sheetCtx),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                enabled: f.isActive,
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _q.clear();
                  _set(const TxFilter());
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _SheetItem {
  final Object value;
  final String label;
  const _SheetItem({required this.value, required this.label});
}

class _SheetList extends StatelessWidget {
  final String title;
  final List<_SheetItem> items;
  const _SheetList({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: items.length,
              itemBuilder: (context, i) => ListTile(
                title: Text(items[i].label),
                onTap: () => Navigator.pop(context, items[i].value),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  final TxPage page;
  final bool hidden;
  const _Totals({required this.page, required this.hidden});

  @override
  Widget build(BuildContext context) {
    final codes = {
      ...page.inflowByCurrency.keys,
      ...page.outflowByCurrency.keys,
    }.toList();
    if (codes.isEmpty) return const SizedBox.shrink();

    // ملخّص بنمط «دفتر الحسابات»: سطر أزرق واحد يجمع الوارد/الصادر
    // لكل عملة، ثم عدّاد العمليات الرمادي — بلا بطاقات إحصاء ملوّنة.
    return OpTotalsBar(
      codes: codes,
      inflow: page.inflowByCurrency,
      outflow: page.outflowByCurrency,
      count: page.items.length,
      hidden: hidden,
    );
  }
}

/// شريط إجماليات العمليات — نمط موحّد مع بقية الشاشات.
class OpTotalsBar extends StatelessWidget {
  final List<String> codes;
  final Map<String, double> inflow;
  final Map<String, double> outflow;
  final int count;
  final bool hidden;

  const OpTotalsBar({
    super.key,
    required this.codes,
    required this.inflow,
    required this.outflow,
    required this.count,
    this.hidden = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final code in codes)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Wrap(
                spacing: 16,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const Text('▲ ',
                        style: TextStyle(
                            fontSize: 15, color: Color(0xFF7BEF7B))),
                    Text('وارد: ',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                    Text(hidden ? '••••' : Fmt.money(inflow[code] ?? 0),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                  ]),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const Text('▼ ',
                        style: TextStyle(
                            fontSize: 15, color: Color(0xFFFF9A92))),
                    Text('صادر: ',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                    Text(hidden ? '••••' : Fmt.money(outflow[code] ?? 0),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                  ]),
                  Text('($code)',
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 11.5)),
                ],
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              '$count عملية',
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text2),
            ),
          ),
        ],
      ),
    );
  }
}

class _TxCard extends ConsumerWidget {
  final Tx tx;
  final Account? account;
  final Account? toAccount;
  final bool hidden;
  const _TxCard({
    required this.tx,
    required this.account,
    required this.toAccount,
    required this.hidden,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isTransfer = tx.type == OpType.transfer;
    final group = opGroup(tx.type);
    // اتجاه العملية بنمط «دفتر الحسابات»: له = ▲ أخضر، عليه = ▼ أحمر.
    final isIn = group == 'inflow';
    final color = isIn ? AppColors.green : AppColors.danger;

    final who = isTransfer
        ? '${account?.name ?? '—'}  ←  ${toAccount?.name ?? '—'}'
        : (account?.name ?? '—');

    // صف مسطّح بخط فاصل رقيق — بدل بطاقة مرفوعة بظل وزوايا.
    return InkWell(
      onTap: () => _menu(context, ref),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        decoration: const BoxDecoration(
          border: Border(
              bottom: BorderSide(color: AppColors.border, width: 0.7)),
        ),
        child: Row(
          children: [
            // 1) المثلث الملوّن (اتجاه العملية).
            SizedBox(
              width: 26,
              child: Text(
                isIn ? '▲' : '▼',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 15,
                    height: 1,
                    color: color,
                    fontWeight: FontWeight.w700),
              ),
            ),
            // 2) المبلغ — الرقم هو بطل الصف.
            SizedBox(
              width: 92,
              child: Text(
                hidden ? '••••' : Fmt.money(tx.amount),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.text,
                ),
              ),
            ),
            const SizedBox(width: 4),
            // 3) التفاصيل + اسم الحساب.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tx.description.isEmpty ? tx.type.label : tx.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.text),
                  ),
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          who,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11.5, color: AppColors.text3),
                        ),
                      ),
                      const SizedBox(width: 5),
                      _deliveryBadge(context, ref),
                    ],
                  ),
                ],
              ),
            ),
            // 4) العملة + الوقت.
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tx.currency,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text3),
                ),
                const SizedBox(height: 1),
                Text(
                  Fmt.clock(tx.createdAt),
                  style: const TextStyle(
                      fontSize: 10.5, color: AppColors.text3),
                ),
              ],
            ),
            // 5) التاريخ — آخر الخلية كما في جدول التصميم.
            SizedBox(
              width: 78,
              child: Text(
                Fmt.date(tx.date),
                textAlign: TextAlign.end,
                style: const TextStyle(
                    fontSize: 11, color: AppColors.text3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// شارة صغيرة بعدد الأجهزة التي استلمت العملية؛ ✅ عند وصولها للجميع.
  Widget _deliveryBadge(BuildContext context, WidgetRef ref) {
    final badges = ref.watch(txDeliveryBadgesProvider).valueOrNull;
    final b = badges?['${tx.id}'];
    if (b == null || b.total <= 0) return const SizedBox.shrink();
    if (b.all) {
      return const Icon(Icons.check_circle, size: 16, color: Colors.green);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        '${b.delivered}/${b.total}',
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: Colors.blue,
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            // «عرض العملية» أول الخيارات: نافذة تفاصيل كاملة للقراءة فقط.
            ListTile(
              leading: Icon(Icons.visibility_outlined,
                  color: AppColors.infoOf(context)),
              title: const Text('عرض العملية'),
              subtitle: const Text('كل تفاصيل العملية في نافذة واحدة'),
              onTap: () => Navigator.pop(context, 'view'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('تعديل العملية'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('تكرار العملية'),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            ListTile(
              leading: Icon(Icons.send, color: AppColors.primaryOf(context)),
              title: const Text('إرسال واتساب'),
              subtitle: const Text('يفتح محادثة العميل بالصورة والنص'),
              onTap: () => Navigator.pop(context, 'send'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('صورة الإيصال'),
              subtitle: const Text('معاينة وإعادة التوليد'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: AppColors.dangerOf(context),
              ),
              title: Text(
                'حذف العملية',
                style: TextStyle(color: AppColors.dangerOf(context)),
              ),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'view':
        await showTxDetails(context, ref,
            tx: tx, account: account, toAccount: toAccount);
      case 'edit':
        await openTxForm(context, ref, existing: tx);
      case 'copy':
        await openTxForm(context, ref, existing: tx, isCopy: true);
      case 'send':
        // إعادة الإرسال تسلك المسار نفسه تمامًا كعملية جديدة.
        await TxShare.sendNow(context, ref, tx: tx);
      case 'image':
        await showReceiptPreview(context, ref, tx: tx);
      case 'delete':
        final ok = await confirmDialog(
          context,
          title: 'حذف عملية',
          message:
              'سيُحذف السجل ويُحدَّث رصيد الحساب تلقائيًا. هل تريد المتابعة؟',
          danger: true,
        );
        if (ok == true) {
          await ref.read(repoProvider).deleteTx(tx.id!);
          bump(ref);
          if (context.mounted) {
            showSnack(context, 'تم حذف العملية وتحديث الرصيد');
          }
        }
    }
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  const _Badge({required this.label, required this.color, required this.icon});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// نافذة «عرض العملية»: كل تفاصيل العملية للقراءة فقط في نافذة واحدة —
/// النوع والحساب والمبلغ والعملة والبيان والمرجع والملاحظات والتصنيف
/// والحالة وحالة المزامنة والتواريخ.
Future<void> showTxDetails(
  BuildContext context,
  WidgetRef ref, {
  required Tx tx,
  Account? account,
  Account? toAccount,
}) async {
  final isTransfer = tx.type == OpType.transfer;
  final group = opGroup(tx.type);
  final color = switch (group) {
    'inflow' => AppColors.greenOf(context),
    'outflow' => AppColors.dangerOf(context),
    'receivable' => AppColors.infoOf(context),
    'payable' => AppColors.accentOf(context),
    _ => AppColors.violetOf(context),
  };
  final statusLabel = switch (tx.status) {
    'pending' => 'قيد التنفيذ',
    'failed' || 'cancelled' => 'فاشلة',
    _ => 'ناجحة',
  };
  final syncLabel = switch (tx.syncState) {
    'synced' => 'تمت المزامنة ✅',
    'syncing' => 'جاري المزامنة',
    'failed' => 'فشلت المزامنة',
    'pending' => 'بانتظار المزامنة',
    _ => 'محلية فقط',
  };

  final rows = <(String, String)>[
    ('النوع', '${tx.type.icon} ${tx.type.label}'),
    if (isTransfer)
      ('من ← إلى', '${account?.name ?? '—'} ← ${toAccount?.name ?? '—'}')
    else
      ('الحساب', account?.name ?? '—'),
    ('المبلغ', '${Fmt.money(tx.amount)} ${tx.currency}'),
    if (tx.rate != 0 && tx.rate != 1) ('سعر الصرف', '${tx.rate}'),
    if (tx.description.trim().isNotEmpty) ('البيان', tx.description.trim()),
    if (tx.reference.trim().isNotEmpty) ('المرجع', tx.reference.trim()),
    if (tx.category.trim().isNotEmpty) ('التصنيف', tx.category.trim()),
    if (tx.notes.trim().isNotEmpty) ('ملاحظات', tx.notes.trim()),
    ('الحالة', statusLabel),
    ('المزامنة', syncLabel),
    ('تاريخ العملية', Fmt.date(tx.date)),
    ('أُنشئت', Fmt.dateTime(tx.createdAt)),
    if (tx.updatedAt != tx.createdAt) ('آخر تعديل', Fmt.dateTime(tx.updatedAt)),
    if (tx.id != null) ('رقم السجل', '${tx.id}'),
  ];

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(tx.type.icon, style: const TextStyle(fontSize: 22)),
      ),
      title: Text('تفاصيل العملية',
          style: TextStyle(fontSize: 17, color: color)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 90,
                      child: Text(
                        r.$1,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppColors.text3Of(ctx),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        r.$2,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('إغلاق'),
        ),
        FilledButton.icon(
          onPressed: () async {
            Navigator.pop(ctx);
            await openTxForm(context, ref, existing: tx);
          },
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: const Text('تعديل'),
        ),
      ],
    ),
  );
}
