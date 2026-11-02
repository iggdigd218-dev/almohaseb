import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import 'account_detail.dart';
import 'account_form.dart';
import 'widgets.dart';

import '../core/theme.dart';
enum _BalanceFilter { all, debt, credit, settled }

final _balanceFilterProvider =
    StateProvider<_BalanceFilter>((ref) => _BalanceFilter.all);

/// شاشة العملاء: بحث وفلاتر عملة + قوائم قابلة للسحب يمينًا/يسارًا
/// للتنقل بين التصنيفات (الكل / عليكم / لكم / مسدد) + بطاقة ملخص
/// نحيفة أسفل الشاشة فوق الشريط السفلي.
class AccountsScreen extends ConsumerStatefulWidget {
  const AccountsScreen({super.key});

  @override
  ConsumerState<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends ConsumerState<AccountsScreen> {
  static const _pages = _BalanceFilter.values;
  final _pageController = PageController(initialPage: 0);

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(accountFilterProvider);
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final summary = ref.watch(summaryProvider).valueOrNull;

    return Column(
      children: [
        // البحث وفلاتر العملة
        _EnhancedFilterBar(
          filter: filter,
          currencies: curs,
        ),
        // شرائح التصنيف — تعكس صفحة السحب الحالية
        _CategoryTabs(controller: _pageController),
        // قوائم العملاء: سحب أفقي يبدّل التصنيف
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: _pages.length,
            onPageChanged: (i) {
              Sfx.tap();
              ref.read(_balanceFilterProvider.notifier).state = _pages[i];
            },
            itemBuilder: (context, i) => _CustomerListPage(
              balanceFilter: _pages[i],
              currencies: curs,
            ),
          ),
        ),
        // البطاقة النحيفة: ملخص العملة النشطة + تبديل بالسحب/الأسهم
        _SlimCurrencyBar(
          currencies: curs,
          summary: summary,
        ),
      ],
    );
  }
}

/// صفحة واحدة من قوائم العملاء بتصنيف رصيد محدد.
class _CustomerListPage extends ConsumerWidget {
  final _BalanceFilter balanceFilter;
  final List<CurrencyDef> currencies;

  const _CustomerListPage({
    required this.balanceFilter,
    required this.currencies,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(accountsProvider);
    final filter = ref.watch(accountFilterProvider);
    final hidden = ref.watch(hideBalancesProvider);
    final txCounts =
        ref.watch(accountTxCountsProvider).valueOrNull ?? const {};

    return list.when(
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
              Text('جارٍ تحميل الحسابات…',
                  style: TextStyle(fontFamily: 'AppNaskh')),
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
                title: 'تعذّر تحميل الحسابات',
                message:
                    '$e'.length > 200 ? '${'$e'.substring(0, 200)}…' : '$e',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => bump(ref),
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة',
                    style: TextStyle(fontFamily: 'AppNaskh')),
              ),
            ],
          ),
        ),
      ),
      data: (rawItems) {
        final items = rawItems.where((it) {
          switch (balanceFilter) {
            case _BalanceFilter.all:
              return true;
            case _BalanceFilter.debt:
              return it.balance < -Fmt.moneyEpsilon;
            case _BalanceFilter.credit:
              return it.balance > Fmt.moneyEpsilon;
            case _BalanceFilter.settled:
              return it.balance.abs() <= Fmt.moneyEpsilon;
          }
        }).toList();

        if (items.isEmpty) {
          return EmptyState(
            icon: balanceFilter == _BalanceFilter.all
                ? Icons.people_outline
                : Icons.filter_alt_outlined,
            title: filter.query.isEmpty && filter.kind == null
                ? (balanceFilter == _BalanceFilter.all
                    ? 'لا توجد حسابات بعد'
                    : 'لا يوجد عملاء في هذا التصنيف')
                : 'لا نتائج مطابقة',
            message: filter.query.isEmpty && filter.kind == null
                ? (balanceFilter == _BalanceFilter.all
                    ? 'أضف أول حساب لعميل أو مورد'
                    : 'اسحب يمينًا أو يسارًا للتنقل بين التصنيفات')
                : 'جرّب تغيير كلمة البحث أو الفلاتر',
            action: filter.query.isEmpty && balanceFilter == _BalanceFilter.all
                ? FilledButton.icon(
                    onPressed: () => openAccountForm(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة حساب',
                        style: TextStyle(fontFamily: 'AppNaskh')),
                  )
                : null,
          );
        }
        return RefreshIndicator(
          onRefresh: () async => bump(ref),
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _AccountCard(
              item: items[i],
              currencies: currencies,
              hidden: hidden,
              txCount: txCounts[items[i].account.id] ?? 0,
            ),
          ),
        );
      },
    );
  }
}

/// شرائح التصنيفات — مؤشر مرئي لصفحة السحب الحالية، والنقر يقفز إليها.
class _CategoryTabs extends ConsumerWidget {
  final PageController controller;

  const _CategoryTabs({required this.controller});

  static const _labels = {
    _BalanceFilter.all: ('الكل', null),
    _BalanceFilter.debt: ('عليكم', Color(0xFFEF4444)),
    _BalanceFilter.credit: ('لكم', Color(0xFF10B981)),
    _BalanceFilter.settled: ('مسدد', Color(0xFF64748B)),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(_balanceFilterProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Row(
        children: [
          for (final f in _BalanceFilter.values)
            Expanded(
              child: GestureDetector(
                onTap: () {
                  Sfx.tap();
                  ref.read(_balanceFilterProvider.notifier).state = f;
                  controller.animateToPage(
                    f.index,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                  );
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding:
                      const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                  decoration: BoxDecoration(
                    color: current == f
                        ? (_labels[f]!.$2 ?? const Color(0xFF0284C7))
                            .withValues(alpha: isDark ? 0.26 : 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: current == f
                          ? (_labels[f]!.$2 ?? const Color(0xFF0284C7))
                          : Colors.transparent,
                      width: 1.1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _labels[f]!.$1,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight:
                          current == f ? FontWeight.w800 : FontWeight.w600,
                      color: current == f
                          ? (_labels[f]!.$2 ?? const Color(0xFF0284C7))
                          : (isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF475569)),
                      fontFamily: 'AppNaskh',
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// البطاقة النحيفة السفلية: ملخص العملة النشطة (عليكم/لكم/عدد العملاء)
/// مع تبديل العملة بالسحب الأفقي أو الأسهم — تجلس فوق الشريط السفلي.
class _SlimCurrencyBar extends ConsumerStatefulWidget {
  final List<CurrencyDef> currencies;
  final Summary? summary;

  const _SlimCurrencyBar({
    required this.currencies,
    required this.summary,
  });

  @override
  ConsumerState<_SlimCurrencyBar> createState() => _SlimCurrencyBarState();
}

class _SlimCurrencyBarState extends ConsumerState<_SlimCurrencyBar> {
  int _index = 0;

  CurrencyDef? get _active {
    if (widget.currencies.isEmpty) return null;
    final filter = ref.read(accountFilterProvider);
    final code = filter.currency;
    if (code != null) {
      final i = widget.currencies.indexWhere((c) => c.code == code);
      if (i >= 0) return widget.currencies[i];
    }
    return widget.currencies[_index.clamp(0, widget.currencies.length - 1)];
  }

  void _switchTo(int i) {
    if (widget.currencies.isEmpty) return;
    final next = (i % widget.currencies.length + widget.currencies.length) %
        widget.currencies.length;
    setState(() => _index = next);
    final code = widget.currencies[next].code;
    final n = ref.read(accountFilterProvider.notifier);
    final cur = ref.read(accountFilterProvider);
    n.state = cur.currency == code
        ? cur
        : cur.copyWith(currency: code);
    Sfx.tap();
  }

  @override
  Widget build(BuildContext context) {
    final c = _active;
    if (c == null) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final allAccounts = ref.watch(allAccountsProvider).valueOrNull ?? const [];
    final debt = widget.summary?.owedByUs[c.code] ?? 0;
    final credit = widget.summary?.owedToUs[c.code] ?? 0;
    final count = allAccounts.where((a) => a.currency == c.code).length;
    final multi = widget.currencies.length > 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
      child: GestureDetector(
        onHorizontalDragEnd: (d) {
          if (!multi) return;
          final v = d.primaryVelocity ?? 0;
          if (v > 120) {
            _switchTo(_activeIndex() - 1); // سحب لليمين (RTL: السابقة)
          } else if (v < -120) {
            _switchTo(_activeIndex() + 1);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFF0284C7),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: (isDark ? Colors.black : const Color(0xFF0284C7))
                    .withValues(alpha: 0.22),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              // سهم العملة السابقة
              if (multi)
                _arrow(isDark, Icons.chevron_right_rounded,
                    () => _switchTo(_activeIndex() - 1)),
              // هوية العملة
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(c.flag, style: const TextStyle(fontSize: 15)),
                    const SizedBox(width: 5),
                    Text(
                      c.code,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'AppNaskh',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // الإجمالي عليكم
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'عليكم',
                      style: TextStyle(
                          color: Color(0xFFFECACA),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'AppNaskh'),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        Fmt.moneyFor(debt, c),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w900,
                          fontFamily: 'AppNaskh',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // الإجمالي لكم
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'لكم',
                      style: TextStyle(
                          color: Color(0xFFA7F3D0),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'AppNaskh'),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        Fmt.moneyFor(credit, c),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w900,
                          fontFamily: 'AppNaskh',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              // عدد العملاء
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'AppNaskh',
                  ),
                ),
              ),
              // سهم العملة التالية
              if (multi)
                _arrow(isDark, Icons.chevron_left_rounded,
                    () => _switchTo(_activeIndex() + 1)),
            ],
          ),
        ),
      ),
    );
  }

  int _activeIndex() {
    final c = _active;
    final i = widget.currencies.indexWhere((x) => x.code == c?.code);
    return i >= 0 ? i : _index;
  }

  Widget _arrow(bool isDark, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Icon(icon, color: Colors.white70, size: 20),
    );
  }
}

class _EnhancedFilterBar extends ConsumerWidget {
  final AccountFilter filter;
  final List<CurrencyDef> currencies;

  const _EnhancedFilterBar({
    required this.filter,
    required this.currencies,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(accountFilterProvider.notifier);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // حقل البحث
          TextField(
            decoration: InputDecoration(
              hintText: 'بحث بالاسم أو الهاتف أو الملاحظات…',
              hintStyle: const TextStyle(fontFamily: 'AppNaskh', fontSize: 13),
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: filter.query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => n.state = filter.copyWith(query: ''),
                    ),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              filled: true,
              fillColor:
                  isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            style: const TextStyle(fontFamily: 'AppNaskh', fontSize: 13.5),
            controller: TextEditingController(
              text: filter.query,
            )..selection = TextSelection.collapsed(offset: filter.query.length),
            onChanged: (v) => n.state = filter.copyWith(query: v),
          ),
          const SizedBox(height: 7),
          // فلاتر العملات وفلاتر الأرصدة
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                // فلتر نوع العملة
                _chip(
                  context,
                  'كل العملات',
                  filter.currency == null,
                  () => n.state = filter.copyWith(clearCurrency: true),
                ),
                for (final c in currencies)
                  _chip(
                    context,
                    '${c.name} ${c.flag}',
                    filter.currency == c.code,
                    () => n.state = filter.copyWith(
                      currency: filter.currency == c.code ? null : c.code,
                      clearCurrency: filter.currency == c.code,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext c,
    String label,
    bool active,
    VoidCallback onTap, {
    Color? color,
  }) {
    final effectiveColor = color ?? const Color(0xFF0284C7);
    final isDark = Theme.of(c).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: InkWell(
        onTap: () {
          Sfx.tap();
          onTap();
        },
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
          decoration: BoxDecoration(
            color: active
                ? effectiveColor.withValues(alpha: isDark ? 0.28 : 0.14)
                : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? effectiveColor : Colors.transparent,
              width: 1.2,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              color: active
                  ? effectiveColor
                  : (isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF475569)),
              fontFamily: 'AppNaskh',
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final AccountWithBalance item;
  final List<CurrencyDef> currencies;
  final bool hidden;
  final int txCount;

  const _AccountCard({
    required this.item,
    required this.currencies,
    required this.hidden,
    required this.txCount,
  });

  String _getInitials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '؟';
    if (parts.length == 1) {
      return parts[0].length >= 2 ? parts[0].substring(0, 2) : parts[0];
    }
    final first = parts[0].isNotEmpty ? parts[0].substring(0, 1) : '';
    final second = parts[1].isNotEmpty ? parts[1].substring(0, 1) : '';
    return '$first$second';
  }

  Color _avatarColor(String name) {
    final colors = [
      const Color(0xFF0284C7),
      AppColors.primary2,
      const Color(0xFF7C3AED),
      const Color(0xFFEA580C),
      const Color(0xFF4F46E5),
      const Color(0xFFDB2777),
    ];
    return colors[name.hashCode.abs() % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final a = item.account;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = currencies.firstWhere(
      (x) => x.code == a.currency,
      orElse: () => kDefaultCurrencies.first,
    );

    final isDebt = item.balance < -Fmt.moneyEpsilon;
    final isCredit = item.balance > Fmt.moneyEpsilon;
    final initials = _getInitials(a.name);
    final accent = _avatarColor(a.name);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            Sfx.tap();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AccountDetailScreen(accountId: a.id!),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                // الدائرة التعبيرية مع الحرفين الأولين من الاسم
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: isDark ? 0.22 : 0.12),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: accent.withValues(alpha: 0.3),
                      width: 1.2,
                    ),
                  ),
                  child: Text(
                    initials,
                    style: TextStyle(
                      color: accent,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'AppNaskh',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // اسم العميل ومعلوماته
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          fontFamily: 'AppNaskh',
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (a.phone.isNotEmpty) a.phone,
                          if (txCount > 0) '$txCount حركة' else 'لا حركات',
                          c.name,
                        ].join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : const Color(0xFF64748B),
                          fontFamily: 'AppNaskh',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // الرصيد الواضح باللون الأحمر أو الأخضر مع العملة
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (hidden)
                      const Text(
                        '••••••',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                        ),
                      )
                    else
                      Text(
                        isDebt
                            ? '${Fmt.moneyFor(item.balance.abs(), c)} ${c.symbol}'
                            : (isCredit
                                ? '+ ${Fmt.moneyFor(item.balance, c)} ${c.symbol}'
                                : '0 ${c.symbol}'),
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w900,
                          color: isDebt
                              ? const Color(0xFFEF4444)
                              : (isCredit
                                  ? const Color(0xFF10B981)
                                  : (isDark
                                      ? const Color(0xFF94A3B8)
                                      : const Color(0xFF64748B))),
                          fontFamily: 'AppNaskh',
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      isDebt ? 'عليكم' : (isCredit ? 'لكم' : 'مسدد'),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: isDebt
                            ? const Color(0xFFEF4444)
                            : (isCredit
                                ? const Color(0xFF10B981)
                                : (isDark
                                    ? const Color(0xFF64748B)
                                    : const Color(0xFF94A3B8))),
                        fontFamily: 'AppNaskh',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
