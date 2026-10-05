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

/// شاشة الحسابات: بطاقة الملخص المالي للعملات + بحث وفلترة وقائمة الحسابات.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(accountsProvider);
    final filter = ref.watch(accountFilterProvider);
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final hidden = ref.watch(hideBalancesProvider);
    final balanceFilter = ref.watch(_balanceFilterProvider);
    final txCounts =
        ref.watch(accountTxCountsProvider).valueOrNull ?? const {};
    final summary = ref.watch(summaryProvider).valueOrNull;

    return Column(
      children: [
        // بطاقة ملخص العملات العلوية القابلة للسحب
        _CurrencySwipeHeader(
          currencies: curs,
          summary: summary,
        ),
        // شريط الفلترة المتقدم والبحث
        _EnhancedFilterBar(
          filter: filter,
          currencies: curs,
          balanceFilter: balanceFilter,
          summary: summary,
        ),
        Expanded(
          child: list.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('جارٍ تحميل الحسابات…',
                        style: TextStyle(fontFamily: 'Tajawal')),
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
                          style: TextStyle(fontFamily: 'Tajawal')),
                    ),
                  ],
                ),
              ),
            ),
            data: (rawItems) {
              // تطبيق فلتر الرصيد (الكل، عليكم، لكم، مسدد)
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
                  icon: Icons.people_outline,
                  title: filter.query.isEmpty &&
                          filter.kind == null &&
                          balanceFilter == _BalanceFilter.all
                      ? 'لا توجد حسابات بعد'
                      : 'لا نتائج مطابقة',
                  message: filter.query.isEmpty &&
                          filter.kind == null &&
                          balanceFilter == _BalanceFilter.all
                      ? 'أضف أول حساب لعميل أو مورد'
                      : 'جرّب تغيير كلمة البحث أو الفلاتر',
                  action: filter.query.isEmpty
                      ? FilledButton.icon(
                          onPressed: () => openAccountForm(context, ref),
                          icon: const Icon(Icons.add),
                          label: const Text('إضافة حساب',
                              style: TextStyle(fontFamily: 'Tajawal')),
                        )
                      : null,
                );
              }
              return RefreshIndicator(
                onRefresh: () async => bump(ref),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 90),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _AccountCard(
                    item: items[i],
                    currencies: curs,
                    hidden: hidden,
                    txCount: txCounts[items[i].account.id] ?? 0,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CurrencySwipeHeader extends ConsumerStatefulWidget {
  final List<CurrencyDef> currencies;
  final Summary? summary;

  const _CurrencySwipeHeader({
    required this.currencies,
    required this.summary,
  });

  @override
  ConsumerState<_CurrencySwipeHeader> createState() =>
      _CurrencySwipeHeaderState();
}

class _CurrencySwipeHeaderState extends ConsumerState<_CurrencySwipeHeader> {
  final _pageController = PageController(viewportFraction: 0.94);
  int _currentPage = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.currencies.isEmpty) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final allAccounts = ref.watch(allAccountsProvider).valueOrNull ?? const [];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 168,
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.currencies.length,
            onPageChanged: (i) => setState(() => _currentPage = i),
            itemBuilder: (context, i) {
              final c = widget.currencies[i];
              final debt = widget.summary?.owedByUs[c.code] ?? 0;
              final credit = widget.summary?.owedToUs[c.code] ?? 0;
              final count =
                  allAccounts.where((a) => a.currency == c.code).length;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    gradient: LinearGradient(
                      colors: isDark
                          ? const [Color(0xFF0F172A), Color(0xFF1E293B)]
                          : const [Color(0xFF0284C7), Color(0xFF0369A1)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (isDark ? Colors.black : const Color(0xFF0284C7))
                            .withValues(alpha: 0.28),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      // الصف العلوي: العلم والاسم
                      Row(
                        children: [
                          Text(c.flag, style: const TextStyle(fontSize: 18)),
                          const SizedBox(width: 8),
                          Text(
                            c.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              fontFamily: 'Tajawal',
                            ),
                          ),
                          const Spacer(),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // بطاقتان مدمجتان: الإجمالي عليكم والإجمالي لكم
                      Row(
                        children: [
                          // الإجمالي عليكم
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 8, horizontal: 10),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'الإجمالي عليكم',
                                    style: TextStyle(
                                      color: Color(0xFFFECACA),
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: 'Tajawal',
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      '${Fmt.moneyFor(debt, c)} ${c.symbol}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w900,
                                        fontFamily: 'Tajawal',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // الإجمالي لكم
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 8, horizontal: 10),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'الإجمالي لكم',
                                    style: TextStyle(
                                      color: Color(0xFFA7F3D0),
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      fontFamily: 'Tajawal',
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      '${Fmt.moneyFor(credit, c)} ${c.symbol}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w900,
                                        fontFamily: 'Tajawal',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      // الصف السفلي: عدد العملاء
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'عدد العملاء $count',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'Tajawal',
                              ),
                            ),
                          ),
                          const Text(
                            'اسحب البطاقات للتبديل بين العملات',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 10.5,
                              fontFamily: 'Tajawal',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        // مؤشر الصفحات النقطي
        if (widget.currencies.length > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              widget.currencies.length,
              (index) => AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                width: _currentPage == index ? 16 : 6,
                height: 5,
                decoration: BoxDecoration(
                  color: _currentPage == index
                      ? const Color(0xFF0284C7)
                      : (isDark
                          ? const Color(0xFF475569)
                          : const Color(0xFFCBD5E1)),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EnhancedFilterBar extends ConsumerWidget {
  final AccountFilter filter;
  final List<CurrencyDef> currencies;
  final _BalanceFilter balanceFilter;
  final Summary? summary;

  const _EnhancedFilterBar({
    required this.filter,
    required this.currencies,
    required this.balanceFilter,
    required this.summary,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(accountFilterProvider.notifier);
    final bNotifier = ref.read(_balanceFilterProvider.notifier);
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
              hintStyle: const TextStyle(fontFamily: 'Tajawal', fontSize: 13),
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
            style: const TextStyle(fontFamily: 'Tajawal', fontSize: 13.5),
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
                const VerticalDivider(width: 14, indent: 4, endIndent: 4),
                // فلاتر حالة الرصيد
                _chip(
                  context,
                  'الكل',
                  balanceFilter == _BalanceFilter.all,
                  () => bNotifier.state = _BalanceFilter.all,
                ),
                _chip(
                  context,
                  'عليكم',
                  balanceFilter == _BalanceFilter.debt,
                  () => bNotifier.state = _BalanceFilter.debt,
                  color: const Color(0xFFEF4444),
                ),
                _chip(
                  context,
                  'لكم',
                  balanceFilter == _BalanceFilter.credit,
                  () => bNotifier.state = _BalanceFilter.credit,
                  color: const Color(0xFF10B981),
                ),
                _chip(
                  context,
                  'مسدد',
                  balanceFilter == _BalanceFilter.settled,
                  () => bNotifier.state = _BalanceFilter.settled,
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
              fontFamily: 'Tajawal',
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
                      fontFamily: 'Tajawal',
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
                          fontFamily: 'Tajawal',
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
                          fontFamily: 'Tajawal',
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
                          fontFamily: 'Tajawal',
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
                        fontFamily: 'Tajawal',
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
