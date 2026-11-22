import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/theme.dart';
import 'tx_form.dart';
import '../core/models.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import 'account_detail.dart';
import 'account_form.dart';
import 'widgets.dart';

/// (تصحيح 2026-11-03) هل شريط البحث مفتوح في شاشة الحسابات؟
/// البحث صار أيقونة بجوار الجرس أعلى يسار الشاشة — يُفتح من هناك
/// بدل خانة دائمة تستهلك من مساحة الصفحة.
final accountsSearchOpenProvider = StateProvider<bool>((ref) => false);

/// صفحة التصنيف الحالية (الكل/عملاء/موردين/حساب عام) — تربط
/// شرائح التصنيف بصفحات السحب.
final _kindPageProvider = StateProvider<int>((ref) => 0);

/// شاشة الحسابات: تصنيف **نوع الحساب** (الكل / عملاء / موردين /
/// حساب عام) — الشاشة كلها قابلة للسحب للتنقل بين التصنيفات،
/// والبحث أيقونة في شريط التطبيق (لا خانة دائمة أعلى القائمة).
/// رقم صفحة التصنيف المطلوبة من حوار الفلترة في الشريط العلوي.
final accountsFilterPage = ValueNotifier<int>(-1);

class AccountsScreen extends ConsumerStatefulWidget {
  const AccountsScreen({super.key});

  @override
  ConsumerState<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends ConsumerState<AccountsScreen> {
  static const _pages = <(String, AccountKind?)>[
    ('الكل', null),
    ('عملاء', AccountKind.customer),
    ('موردين', AccountKind.supplier),
    ('حساب عام', AccountKind.general),
  ];

  final _pageController = PageController(initialPage: 0);

  @override
  void initState() {
    super.initState();
    accountsFilterPage.addListener(_onFilter);
  }

  void _onFilter() {
    final i = accountsFilterPage.value;
    if (i >= 0 && _pageController.hasClients) {
      _pageController.animateToPage(i,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    accountsFilterPage.removeListener(_onFilter);
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final searchOpen = ref.watch(accountsSearchOpenProvider);
    final filter = ref.watch(accountFilterProvider);

    return Column(
      children: [
        // البحث — يظهر فقط عند فتحه من أيقونة شريط التطبيق.
        if (searchOpen)
          _SearchBar(
            filter: filter,
            onClose: () {
              ref.read(accountsSearchOpenProvider.notifier).state = false;
              if (filter.query.isNotEmpty) {
                ref.read(accountFilterProvider.notifier).state =
                    filter.copyWith(query: '');
              }
            },
          ),
        // شرائح التصنيف — تعكس صفحة السحب الحالية
        _KindTabs(controller: _pageController),
        // قوائم الحسابات: سحب أفقي على كامل الشاشة يبدّل التصنيف
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            itemCount: _pages.length,
            onPageChanged: (i) {
              Sfx.tap();
              ref.read(_kindPageProvider.notifier).state = i;
            },
            itemBuilder: (context, i) => _CustomerListPage(
              kind: _pages[i].$2,
              kindLabel: _pages[i].$1,
              currencies: curs,
            ),
          ),
        ),
      ],
    );
  }
}

/// صفحة واحدة من قوائم الحسابات بتصنيف نوع محدد — التصفية بالنوع
/// محلية حتى تبقى صفحة «الكل» كاملة بينما يعمل البحث في الجميع.
class _CustomerListPage extends ConsumerWidget {
  final AccountKind? kind;
  final String kindLabel;
  final List<CurrencyDef> currencies;

  const _CustomerListPage({
    required this.kind,
    required this.kindLabel,
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
        final items = rawItems
            .where((it) => kind == null || it.account.kind == kind)
            .toList();

        if (items.isEmpty) {
          final searching = filter.query.isNotEmpty;
          return EmptyState(
            icon: searching
                ? Icons.search_off
                : (kind == null ? Icons.people_outline : Icons.folder_off),
            title: searching
                ? 'لا نتائج مطابقة'
                : (kind == null ? 'لا توجد حسابات بعد' : 'لا يوجد $kindLabel'),
            message: searching
                ? 'جرّب كلمة بحث أخرى'
                : (kind == null
                    ? 'أضف أول حساب لعميل أو مورد'
                    : 'اسحب يمينًا أو يسارًا للتنقل بين التصنيفات'),
            action: !searching && kind == null
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

/// شرائح نوع الحساب: الكل / عملاء / موردين / حساب عام — مؤشر مرئي
/// لصفحة السحب الحالية، والنقر يقفز إليها بانسيابية.
class _KindTabs extends ConsumerWidget {
  final PageController controller;

  const _KindTabs({required this.controller});

  static const _colors = <AccountKind?, Color>{
    null: Color(0xFF0284C7),
    AccountKind.customer: Color(0xFF2563EB),
    AccountKind.supplier: Color(0xFFF59E0B),
    AccountKind.general: Color(0xFF10B981),
  };

  static const _labels = <AccountKind?, String>{
    null: 'الكل',
    AccountKind.customer: 'عملاء',
    AccountKind.supplier: 'موردين',
    AccountKind.general: 'حساب عام',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(_kindPageProvider);
    final kinds = _labels.keys.toList(growable: false);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
      child: Row(
        children: [
          for (var i = 0; i < kinds.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () {
                  Sfx.tap();
                  controller.animateToPage(
                    i,
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
                    color: current == i
                        ? _colors[kinds[i]]!
                            .withValues(alpha: isDark ? 0.26 : 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: current == i
                          ? _colors[kinds[i]]!
                          : Colors.transparent,
                      width: 1.1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _labels[kinds[i]]!,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight:
                          current == i ? FontWeight.w800 : FontWeight.w600,
                      color: current == i
                          ? _colors[kinds[i]]!
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

/// شريط البحث — يُفتح من أيقونة البحث بجوار الجرس، ويُغلق بزر ✕
/// الذي يمسح الكلمة أيضًا.
class _SearchBar extends ConsumerWidget {
  final AccountFilter filter;
  final VoidCallback onClose;

  const _SearchBar({
    required this.filter,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(accountFilterProvider.notifier);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
      child: TextField(
        autofocus: true,
        decoration: InputDecoration(
          hintText: 'بحث بالاسم أو الهاتف أو الملاحظات…',
          hintStyle: const TextStyle(fontFamily: 'AppNaskh', fontSize: 13),
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: IconButton(
            tooltip: 'إغلاق البحث',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClose,
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

/// بطاقة الحساب النحيفة — اسم بار بخط أسود عريض بلا دائرة مجاورة،
/// والرصيد بلونه (عليه/له/مسدد) بعملة الحساب.
class _AccountCard extends ConsumerWidget {
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = item.account;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = currencies.firstWhere(
      (x) => x.code == a.currency,
      orElse: () => kDefaultCurrencies.first,
    );

    // (إصلاح فادح 2026-11-03) الاتجاه الصحيح المتسق مع شاشة الحساب
    // وopEffect: debit (عليه) يزيد الرصيد ← الموجب «عليه» أخضر،
    // والسالب «له» أحمر — القائمة القديمة كانت تعكسهما.
    final isOwe = item.balance > Fmt.moneyEpsilon; // عليه — مستحق لنا
    final isOwed = item.balance < -Fmt.moneyEpsilon; // له — مستحق علينا
    final stateColor = isOwe
        ? const Color(0xFF10B981)
        : (isOwed ? const Color(0xFFEF4444) : null);
    final stateIcon = isOwe
        ? Icons.arrow_circle_up
        : (isOwed ? Icons.arrow_circle_down : Icons.remove_circle_outline);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE6E6E6),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // ▼ أحمر «عليه» / ▲ أخضر «له» — كالمخطط المعتمد
                Expanded(
                  flex: 12,
                  child: isOwe
                      ? const Icon(Icons.arrow_drop_down,
                          size: 34, color: Color(0xFFE8352B))
                      : (isOwed
                          ? const Icon(Icons.arrow_drop_up,
                              size: 34, color: Color(0xFF3CCC3C))
                          : const Icon(Icons.remove,
                              size: 22, color: AppColors.text3)),
                ),
                // الرصيد
                Expanded(
                  flex: 17,
                  child: hidden
                      ? const Text('••••••',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 2))
                      : Text(
                          Fmt.moneyFor(item.balance.abs(), c),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.text,
                          ),
                        ),
                ),
                // شارة عدد العمليات
                Expanded(
                  flex: 12,
                  child: Center(
                    child: Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.badgeBg,
                      ),
                      child: Text(
                        '$txCount',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.navy,
                        ),
                      ),
                    ),
                  ),
                ),
                // الاسم كحلي
                Expanded(
                  flex: 20,
                  child: Text(
                    a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppColors.navy,
                    ),
                  ),
                ),
                // + كحلي غليظ — إضافة مبلغ لهذا الحساب
                Expanded(
                  flex: 12,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: () async {
                      Sfx.tap();
                      await openTxForm(context, ref, presetAccountId: a.id);
                    },
                    icon: const Text('+',
                        style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            color: AppColors.navy,
                            height: 1)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
