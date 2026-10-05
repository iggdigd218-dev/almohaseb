import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'widgets.dart';
import 'home_shell.dart' show AppScreen;

/// لوحة التحكم الرئيسية — تصميم مبسّط:
///  - بطاقة ملخّص الحساب أعلى الشاشة مع سحب أفقي بين العملات.
///  - ٦ أيقونات رئيسية كبيرة وواضحة.
///  - قسم «أقسام أخرى» لبقية الميزات حتى لا يُخفى شيء.
///  - التنبيهات وآخر العمليات.
/// كل الأرقام تُقرأ من بيانات التطبيق الفعلية (لا قيم ثابتة).
class DashboardScreen extends ConsumerWidget {
  final void Function(AppScreen)? onOpen;
  const DashboardScreen({super.key, this.onOpen});

  /// الأيقونات الست الرئيسية (كما في التصميم المرجعي): دوائر متدرجة بأيقونات بيضاء.
  static const _mainTiles = <_Tile>[
    // (3.70.0 — توحيد الثيم) تدرجات مطابقة تماماً لألوان أقسام القائمة
    // الجانبية (_colorOf في home_shell) — لا درجات شاذة خارج اللوحة.
    _Tile(
      'المبيعات',
      Icons.shopping_cart_rounded,
      Color(0xFF22C55E),
      Color(0xFF16A34A),
      AppScreen.pos,
    ),
    _Tile(
      'العملاء',
      Icons.groups_rounded,
      Color(0xFF3B82F6),
      Color(0xFF2563EB),
      AppScreen.accounts,
    ),
    _Tile(
      'الديون',
      Icons.credit_card_rounded,
      Color(0xFFFBBF24),
      Color(0xFFF59E0B),
      AppScreen.vouchers,
    ),
    _Tile(
      'إدارة المنتجات',
      Icons.inventory_2_rounded,
      Color(0xFFA78BFA),
      Color(0xFF8B5CF6),
      AppScreen.inventory,
    ),
    _Tile(
      'المعاملات',
      Icons.description_rounded,
      Color(0xFF38BDF8),
      Color(0xFF0EA5E9),
      AppScreen.transactions,
    ),
    _Tile(
      'التقارير',
      Icons.bar_chart_rounded,
      Color(0xFF818CF8),
      Color(0xFF6366F1),
      AppScreen.reports,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(summaryProvider);
    final currencies = ref.watch(currenciesProvider);
    final hidden = ref.watch(hideBalancesProvider);
    // (إصلاح أندرويد 7) تحصين مزدوج: وضع host = مدير حتى لو تأخرت قراءة
    // is_owner على الأجهزة البطيئة — لا تختفي «إدارة المجموعة» عن المالك.
    final isOwner =
        (ref.watch(isOwnerProvider).valueOrNull ?? true) ||
        ref.watch(workspaceModeProvider).valueOrNull == 'host';

    return RefreshIndicator(
      onRefresh: () async => bump(ref),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 96),
        children: [
          summary.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 90),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  EmptyState(
                    icon: Icons.error_outline,
                    title: 'تعذّر تحميل الملخّص',
                    message:
                        '${e.toString().length > 200 ? '${e.toString().substring(0, 200)}…' : e}',
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
            data: (s) {
              final curs = currencies.valueOrNull ?? kDefaultCurrencies;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CurrencyCard(
                    currencies: curs,
                    net: s.net,
                    owedToUs: s.owedToUs,
                    owedByUs: s.owedByUs,
                    hidden: hidden,
                  ),
                  const SizedBox(height: 18),
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.82,
                    children: [
                      for (final t in _mainTiles)
                        _FeatureTile(
                          tile: t,
                          big: true,
                          onTap: () => onOpen?.call(t.target),
                        ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  const SectionTitle('أقسام أخرى'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _ChipSection(
                        label: 'العملات',
                        icon: Icons.currency_exchange_rounded,
                        color: AppColors.infoOf(context),
                        onTap: () => onOpen?.call(AppScreen.currencies),
                      ),
                      _ChipSection(
                        label: 'الدردشة',
                        icon: Icons.forum_rounded,
                        color: AppColors.primaryOf(context),
                        onTap: () => onOpen?.call(AppScreen.chat),
                      ),
                      if (isOwner)
                        _ChipSection(
                          label: 'إدارة المجموعة',
                          icon: Icons.groups_rounded,
                          color: AppColors.violetOf(context),
                          onTap: () => onOpen?.call(AppScreen.group),
                        ),
                      _ChipSection(
                        label: 'سجل النشاط',
                        icon: Icons.history_rounded,
                        color: AppColors.text2Of(context),
                        onTap: () => onOpen?.call(AppScreen.activity),
                      ),
                      _ChipSection(
                        label: 'سلة المهملات',
                        icon: Icons.delete_outline_rounded,
                        color: AppColors.dangerOf(context),
                        onTap: () => onOpen?.call(AppScreen.trash),
                      ),
                      _ChipSection(
                        label: 'الإعدادات',
                        icon: Icons.settings_rounded,
                        color: AppColors.text3Of(context),
                        onTap: () => onOpen?.call(AppScreen.settings),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Expanded(
                        child: StatCard(
                          title: 'الحسابات',
                          value: '${s.accountsCount}',
                          icon: Icons.people_alt_outlined,
                          color: AppColors.infoOf(context),
                          onTap: () => onOpen?.call(AppScreen.accounts),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: StatCard(
                          title: 'العمليات',
                          value: '${s.txCount}',
                          icon: Icons.receipt_long_outlined,
                          color: AppColors.violetOf(context),
                          onTap: () => onOpen?.call(AppScreen.transactions),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: StatCard(
                          title: 'الإيرادات والقبض',
                          value: hidden ? '••••' : Fmt.money(s.inflow),
                          icon: Icons.south_west,
                          color: AppColors.greenOf(context),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: StatCard(
                          title: 'المصروفات والصرف',
                          value: hidden ? '••••' : Fmt.money(s.outflow),
                          icon: Icons.north_east,
                          color: AppColors.dangerOf(context),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          const _Alerts(),
          const SizedBox(height: 8),
          _Recent(onOpen: onOpen),
        ],
      ),
    );
  }
}

// ===========================================================================
// بطاقة العملات — سحب أفقي بين العملات داخل نفس البطاقة.
// ===========================================================================

class _CurrencyCard extends StatefulWidget {
  final List<CurrencyDef> currencies;
  final Map<String, double> net;
  final Map<String, double> owedToUs; // مستحق لنا (عليه)
  final Map<String, double> owedByUs; // مستحق علينا (له)
  final bool hidden;
  const _CurrencyCard({
    required this.currencies,
    required this.net,
    required this.owedToUs,
    required this.owedByUs,
    required this.hidden,
  });

  @override
  State<_CurrencyCard> createState() => _CurrencyCardState();
}

class _CurrencyCardState extends State<_CurrencyCard> {
  final _controller = PageController();
  int _page = 0;

  // (3.70.0 — توحيد الثيم) لوحة مشتقة من ألوان التطبيق المعتمدة:
  // المحلية = primaryOf (0F766E)، SAR = infoOf، USD = violetOf، مع نسخ
  // لينة (Soft) وتدرّجات محسوبة — تتكيف مع الفاتح/ الداكن تلقائياً.
  (Color, Color, Color, Color) _themePalette(
    String code,
    BuildContext context,
  ) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = switch (code) {
      'SAR' => AppColors.infoOf(context),
      'USD' => AppColors.violetOf(context),
      _ => AppColors.primaryOf(context),
    };
    final soft = switch (code) {
      'SAR' => AppColors.infoSoftOf(context),
      'USD' => AppColors.violetSoftOf(context),
      _ => AppColors.primarySoftOf(context),
    };
    final g2 = Color.lerp(soft, fg, dark ? .16 : .08)!;
    final badge = Color.lerp(soft, fg, dark ? .26 : .14)!;
    return (fg, soft, g2, badge);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curs = widget.currencies.isEmpty
        ? kDefaultCurrencies
        : widget.currencies;
    return Column(
      children: [
        SizedBox(
          height: 188,
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (i) => setState(() => _page = i),
            itemCount: curs.length,
            itemBuilder: (context, i) {
              final c = curs[i];
              final (fg, g1, g2, badgeBg) = _themePalette(c.code, context);
              final netV = widget.net[c.code] ?? 0;
              final toUs = widget.owedToUs[c.code] ?? 0;
              final byUs = widget.owedByUs[c.code] ?? 0;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topRight,
                      end: Alignment.bottomLeft,
                      colors: [g1, g2],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: fg.withValues(alpha: .12)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: badgeBg,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.account_balance_wallet_rounded,
                              color: fg,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(c.flag, style: const TextStyle(fontSize: 18)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${c.name} (${c.symbol})',
                              style: TextStyle(
                                color: fg,
                                fontWeight: FontWeight.w800,
                                fontSize: 14.5,
                                fontFamily: 'Tajawal',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // المبلغ البارز (صافي الرصيد لهذه العملة).
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            widget.hidden
                                ? '••••••'
                                : Fmt.money(netV, c.decimal),
                            style: TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textOf(context),
                              letterSpacing: .5,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            c.symbol,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: fg,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _AmountPill(
                              label: 'لك',
                              arrow: Icons.arrow_upward_rounded,
                              value: toUs,
                              currency: c,
                              hidden: widget.hidden,
                              positive: true,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _AmountPill(
                              label: 'عليك',
                              arrow: Icons.arrow_downward_rounded,
                              value: byUs,
                              currency: c,
                              hidden: widget.hidden,
                              positive: false,
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
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < curs.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _page ? 20 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: i == _page
                      ? AppColors.primaryOf(context)
                      : AppColors.borderOf(context),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'اسحب البطاقة يميناً أو يساراً للتنقل بين العملات',
          style: TextStyle(fontSize: 11, color: AppColors.text3Of(context)),
        ),
      ],
    );
  }
}

class _AmountPill extends StatelessWidget {
  final String label;
  final IconData arrow;
  final double value;
  final CurrencyDef currency;
  final bool hidden;
  final bool positive;
  const _AmountPill({
    required this.label,
    required this.arrow,
    required this.value,
    required this.currency,
    required this.hidden,
    required this.positive,
  });

  @override
  Widget build(BuildContext context) {
    final color = positive
        ? AppColors.greenOf(context)
        : AppColors.dangerOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        borderRadius: BorderRadius.circular(13),
        boxShadow: [
          BoxShadow(
            color: AppColors.textOf(context).withValues(alpha: .05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(arrow, size: 15, color: color),
          ),
          const SizedBox(width: 8),
          // (الهوية البصرية) العمود يتمدد داخل الحبّة فيُقيَّد عرض النص
          // ويُقصّ بـ ellipsis بدل تجاوز الحدّ — الخط الأعرض كشف تجاوزاً
          // قدره 12px على شاشة 360 في اختبار التخطيط.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.text3Of(context),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  hidden
                      ? '••••'
                      : '${Fmt.money(value, currency.decimal)} ${currency.symbol}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textOf(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// عناصر الأيقونات
// ===========================================================================

class _Tile {
  final String label;
  final IconData icon;
  final Color g1;
  final Color g2;
  final AppScreen target;
  const _Tile(this.label, this.icon, this.g1, this.g2, this.target);
}

class _FeatureTile extends StatelessWidget {
  final _Tile tile;
  final bool big;
  final VoidCallback onTap;
  const _FeatureTile({
    required this.tile,
    required this.onTap,
    this.big = true,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceOf(context),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.borderOf(context)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: big ? 56 : 48,
                height: big ? 56 : 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [tile.g1, tile.g2],
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: tile.g2.withValues(alpha: .38),
                      blurRadius: 14,
                      offset: const Offset(0, 7),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Icon(
                  tile.icon,
                  color: Colors.white,
                  size: big ? 28 : 24,
                  shadows: const [
                    Shadow(
                      color: Colors.black26,
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 7),
              Text(
                tile.label,
                style: TextStyle(
                  fontSize: big ? 13 : 12.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textOf(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChipSection extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _ChipSection({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceOf(context),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.borderOf(context)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textOf(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// التنبيهات
// ===========================================================================

class _Alerts extends ConsumerWidget {
  const _Alerts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider).valueOrNull ?? [];
    if (alerts.isEmpty) return const SizedBox.shrink();
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('تنبيهات'),
        Card(
          child: Column(
            children: alerts.map((a) {
              final c = curs.firstWhere(
                (x) => x.code == a.account.currency,
                orElse: () => kDefaultCurrencies.first,
              );
              return ListTile(
                leading: Icon(
                  Icons.warning_amber_rounded,
                  color: AppColors.accentOf(context),
                ),
                title: Text(
                  a.account.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                subtitle: Text(
                  'تجاوز الحد الائتماني '
                  '(${Fmt.money(a.account.creditLimit ?? 0, c.decimal)} ${c.symbol})',
                  style: const TextStyle(fontSize: 13.5),
                ),
                trailing: Text(
                  '${Fmt.money(a.balance, c.decimal)} ${c.symbol}',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: AppColors.accentOf(context),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }
}

class _Recent extends ConsumerWidget {
  final void Function(AppScreen)? onOpen;
  const _Recent({this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txs = ref.watch(recentTxProvider).valueOrNull ?? [];
    final accounts = ref.watch(allAccountsProvider).valueOrNull ?? [];
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          'آخر العمليات',
          actionLabel: txs.isEmpty ? null : 'عرض الكل',
          onAction: () => onOpen?.call(AppScreen.transactions),
        ),
        if (txs.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 26),
              child: EmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'لا توجد عمليات بعد',
                message: 'ابدأ بتسجيل أول عملية مالية',
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < txs.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 56),
                  _TxRow(tx: txs[i], accounts: accounts, currencies: curs),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _TxRow extends StatelessWidget {
  final dynamic tx;
  final List accounts;
  final List<CurrencyDef> currencies;
  const _TxRow({
    required this.tx,
    required this.accounts,
    required this.currencies,
  });

  @override
  Widget build(BuildContext context) {
    final c = currencies.firstWhere(
      (x) => x.code == tx.currency,
      orElse: () => kDefaultCurrencies.first,
    );
    final acc = accounts.where((a) => a.id == tx.accountId).toList();
    final name = acc.isEmpty
        ? (tx.type == OpType.transfer ? 'تحويل' : '—')
        : acc.first.name;
    final group = opGroup(tx.type);
    final color = group == 'inflow'
        ? AppColors.greenOf(context)
        : (group == 'outflow'
              ? AppColors.dangerOf(context)
              : AppColors.primaryOf(context));

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(tx.type.icon, style: const TextStyle(fontSize: 20)),
      ),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        '${tx.type.label} · ${Fmt.date(tx.date)}'
        '${tx.description.isEmpty ? '' : ' · ${tx.description}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      trailing: Text(
        '${Fmt.money(tx.amount, c.decimal)} ${c.symbol}',
        style: TextStyle(
          fontSize: 16.5,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}
