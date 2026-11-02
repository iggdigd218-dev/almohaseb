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

/// شاشة الحسابات (تصحيح 2026-11-03): بحث + تصنيف **نوع الحساب**
/// (الكل / عملاء / موردين / حساب عام) وقائمة واحدة مباشرة.
/// لا فلاتر عملة في رأس الشاشة، ولا فرز أرصدة (لكم/عليكم) بالسحب —
/// كل حساب يعرض رصيده بعملته داخل بطاقته.
class AccountsScreen extends ConsumerStatefulWidget {
  const AccountsScreen({super.key});

  @override
  ConsumerState<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends ConsumerState<AccountsScreen> {
  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(accountFilterProvider);
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;

    return Column(
      children: [
        // البحث
        _SearchBar(filter: filter),
        // تصنيف نوع الحساب
        const _KindTabs(),
        // قائمة الحسابات الوحيدة — التصفية بالنوع تتم داخل accountsProvider
        Expanded(
          child: _CustomerListPage(currencies: curs),
        ),
      ],
    );
  }
}

/// قائمة الحسابات — تصفية النوع/البحث تتم في accountsProvider (kind).
class _CustomerListPage extends ConsumerWidget {
  final List<CurrencyDef> currencies;

  const _CustomerListPage({
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
      data: (items) {
        if (items.isEmpty) {
          return EmptyState(
            icon: filter.kind == null
                ? Icons.people_outline
                : Icons.filter_alt_outlined,
            title: filter.query.isEmpty && filter.kind == null
                ? 'لا توجد حسابات بعد'
                : (filter.query.isEmpty
                    ? 'لا يوجد حسابات في هذا التصنيف'
                    : 'لا نتائج مطابقة'),
            message: filter.query.isEmpty && filter.kind == null
                ? 'أضف أول حساب لعميل أو مورد'
                : 'جرّب تصنيفًا آخر أو غيّر كلمة البحث',
            action: filter.query.isEmpty && filter.kind == null
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

/// شرائح نوع الحساب: الكل / عملاء / موردين / حساب عام —
/// تصنيف واحد واضح يعتمد نوع الحساب لا عملته ولا رصيده.
class _KindTabs extends ConsumerWidget {
  const _KindTabs();

  static const _tabs = <(String, AccountKind?, Color)>[
    ('الكل', null, Color(0xFF0284C7)),
    ('عملاء', AccountKind.customer, Color(0xFF2563EB)),
    ('موردين', AccountKind.supplier, Color(0xFFF59E0B)),
    ('حساب عام', AccountKind.general, Color(0xFF10B981)),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(accountFilterProvider);
    final n = ref.read(accountFilterProvider.notifier);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Row(
        children: [
          for (final (label, kind, color) in _tabs)
            Expanded(
              child: GestureDetector(
                onTap: () {
                  Sfx.tap();
                  n.state = kind == null
                      ? filter.copyWith(clearKind: true)
                      : filter.copyWith(kind: kind, clearCurrency: true);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding:
                      const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                  decoration: BoxDecoration(
                    color: filter.kind == kind
                        ? color.withValues(alpha: isDark ? 0.26 : 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: filter.kind == kind ? color : Colors.transparent,
                      width: 1.1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight:
                          filter.kind == kind ? FontWeight.w800 : FontWeight.w600,
                      color: filter.kind == kind
                          ? color
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

/// شريط البحث وحده — بلا شرائح عملة (تصحيح 2026-11-03).
class _SearchBar extends ConsumerWidget {
  final AccountFilter filter;

  const _SearchBar({
    required this.filter,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(accountFilterProvider.notifier);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
      child: TextField(
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
                // اسم الحساب ومعلوماته
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
                      isDebt ? 'عليه' : (isCredit ? 'له' : 'مسدد'),
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
