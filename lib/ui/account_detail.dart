import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'account_form.dart';
import 'tx_form.dart';
import '../data/sync/subscription_guard.dart'
    show Feature, kWatermarkText;
import 'trial_ui.dart' show featureNeedsStamp;
import 'widgets.dart';

/// كشف حساب: الرصيد والسجل الزمني وأدوات التواصل.
class AccountDetailScreen extends ConsumerStatefulWidget {
  final int accountId;
  const AccountDetailScreen({super.key, required this.accountId});

  @override
  ConsumerState<AccountDetailScreen> createState() =>
      _AccountDetailScreenState();
}

class _AccountDetailScreenState extends ConsumerState<AccountDetailScreen> {
  int get accountId => widget.accountId;

  /// فلتر كبسولة العملة: null = عرض كل العملات.
  String? _capsuleCur;

  @override
  Widget build(BuildContext context) {
    ref.watch(refreshProvider);
    final curs =
        ref.watch(currenciesProvider).valueOrNull ?? kDefaultCurrencies;
    final hidden = ref.watch(hideBalancesProvider);
    // (2026-09-22) التحكم يظهر حسب صلاحية العضو: التعديل/الأرشفة
    // بإذن تعديل العمليات، والحذف النهائي بإذن الحذف — المدير يرى الكل.
    final me = ref.watch(currentUserProvider).valueOrNull;
    final canEdit = me != null && me.can('edit_tx');
    final canDelete = me != null && me.can('delete_tx');

    return FutureBuilder<Account?>(
      future: ref.read(repoProvider).account(accountId),
      builder: (context, snap) {
        final a = snap.data;
        if (a == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.person_off_outlined,
              title: 'الحساب غير موجود',
            ),
          );
        }
        final allTxs =
            ref.watch(accountTxProvider(accountId)).valueOrNull ?? [];

        // فصل الأرصدة لكل عملة: لا دمج بقيمة محوّلة واحدة — الحساب
        // متعدد العملات يعرض رصيداً مستقلاً لكل عملة (كبسولات).
        final balByCur = <String, double>{a.currency: a.openingBalance};
        for (final t in allTxs) {
          final e = t.effectOn(accountId);
          if (e == null) continue;
          balByCur[t.currency] = (balByCur[t.currency] ?? 0.0) + e;
        }
        // العملات مرتبة: عملة الحساب أولاً ثم البقية.
        final curCodes = balByCur.keys.toList()
          ..sort((x, y) {
            if (x == a.currency) return -1;
            if (y == a.currency) return 1;
            return x.compareTo(y);
          });
        CurrencyDef defOf(String code) => curs.firstWhere(
              (x) => x.code == code,
              orElse: () => kDefaultCurrencies.first,
            );
        // إن اختفت العملة المفلترة (حذف عملياتها) نعود للعرض الكامل.
        if (_capsuleCur != null && !balByCur.containsKey(_capsuleCur)) {
          _capsuleCur = null;
        }
        final activeCur = _capsuleCur ?? a.currency;
        final c = defOf(activeCur);
        // السجل المعروض: كل العمليات أو عملة الكبسولة المختارة فقط.
        final txs = _capsuleCur == null
            ? allTxs
            : allTxs.where((t) => t.currency == _capsuleCur).toList();
        final balance = balByCur[activeCur] ?? 0.0;

        var totalDebit = 0.0;
        var totalCredit = 0.0;
        for (final t in txs) {
          if (t.currency != activeCur) continue;
          final e = t.effectOn(accountId);
          if (e == null) continue;
          if (e > 0) {
            totalDebit += e;
          } else {
            totalCredit += e.abs();
          }
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(a.name, overflow: TextOverflow.ellipsis),
            actions: [
              if (canEdit)
                IconButton(
                  tooltip: 'تعديل',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () async {
                    await openAccountForm(context, ref, existing: a);
                    bump(ref);
                  },
                ),
              if (canEdit || canDelete)
                PopupMenuButton<String>(
                  onSelected: (v) => _action(context, ref, a, v),
                  itemBuilder: (_) => [
                    if (canEdit)
                      PopupMenuItem(
                        value: 'archive',
                        child: Text(a.archived ? 'إلغاء الأرشفة' : 'أرشفة'),
                      ),
                    if (canDelete)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('حذف نهائي'),
                      ),
                  ],
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 90),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.teal.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              a.kind.icon,
                              style: const TextStyle(fontSize: 21),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  a.name,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${a.kind.label} · ${c.name}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context).hintColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      const SizedBox(height: 14),
                      // كبسولات العملات: رصيد مستقل لكل عملة، والنقر
                      // يفلتر السجل أدناه على تلك العملة فقط.
                      if (curCodes.length > 1) ...[
                        SizedBox(
                          height: 40,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final code in curCodes)
                                Padding(
                                  padding:
                                      const EdgeInsetsDirectional.only(end: 7),
                                  child: _CurrencyCapsule(
                                    code: code,
                                    def: defOf(code),
                                    balance: balByCur[code] ?? 0.0,
                                    hidden: hidden,
                                    selected: _capsuleCur == code,
                                    onTap: () => setState(() => _capsuleCur =
                                        _capsuleCur == code ? null : code),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text(
                        _capsuleCur == null
                            ? 'الرصيد الحالي'
                            : 'الرصيد الحالي (${c.name})',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                      const SizedBox(height: 6),
                      BalanceText(
                        value: balance,
                        currency: c,
                        hidden: hidden,
                        size: 26,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: _MiniStat(
                              label: 'إجمالي عليه',
                              value: hidden
                                  ? '••••'
                                  : Fmt.money(totalDebit, c.decimal),
                              color: AppColors.green,
                            ),
                          ),
                          Container(
                            width: 1,
                            height: 32,
                            color: Theme.of(context).dividerColor,
                          ),
                          Expanded(
                            child: _MiniStat(
                              label: 'إجمالي له',
                              value: hidden
                                  ? '••••'
                                  : Fmt.money(totalCredit, c.decimal),
                              color: AppColors.red,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (a.contactNumber.isNotEmpty)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        // 🔒 رسائل الرصيد للعملاء ميزة مدفوعة.
                        // (دفعة 65-ب) الإشعار المباشر مسموح دائماً —
                        // الحساب المقيد يُرسل الإجمالي مختوماً فقط.
                        onPressed: () async {
                          final stamp = await featureNeedsStamp(
                              ref, Feature.whatsappClaims);
                          if (context.mounted) {
                            await _whatsapp(context, a, balance, c,
                                stamp: stamp);
                          }
                        },
                        icon: const Icon(Icons.chat, size: 18),
                        label: const Text('واتساب'),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _call(context, a),
                        icon: const Icon(Icons.call, size: 18),
                        label: const Text('اتصال'),
                      ),
                    ),
                  ],
                ),
              if (a.address.isNotEmpty || a.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (a.address.isNotEmpty)
                          _InfoRow(icon: Icons.place_outlined, text: a.address),
                        if (a.notes.isNotEmpty)
                          _InfoRow(icon: Icons.notes, text: a.notes),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              SectionTitle(_capsuleCur == null
                  ? 'سجل العمليات (${txs.length})'
                  : 'سجل عمليات ${c.name} (${txs.length})'),
              if (txs.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: EmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: 'لا عمليات على هذا الحساب',
                    ),
                  ),
                )
              else
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < txs.length; i++) ...[
                        if (i > 0) const Divider(height: 1, indent: 52),
                        // كل سطر يعرض عملته الحقيقية لا عملة الحساب —
                        // فصل صارم للعملات في الكشف.
                        _TxTile(
                          tx: txs[i],
                          accountId: accountId,
                          currency: defOf(txs[i].currency),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () async {
              await openTxForm(context, ref, presetAccountId: accountId);
              bump(ref);
            },
            icon: const Icon(Icons.add),
            label: const Text('عملية جديدة'),
          ),
        );
      },
    );
  }

  Future<void> _action(
    BuildContext context,
    WidgetRef ref,
    Account a,
    String v,
  ) async {
    final repo = ref.read(repoProvider);
    if (v == 'archive') {
      await repo.archiveAccount(a.id!, !a.archived);
      bump(ref);
      if (context.mounted) {
        showSnack(context, a.archived ? 'تمت الاستعادة' : 'تمت الأرشفة');
      }
    } else if (v == 'delete') {
      final ok = await confirmDialog(
        context,
        title: 'حذف الحساب',
        message:
            'سيُحذف «${a.name}» وكل عملياته. يمكن استرجاعه من سلة المحذوفات.',
        confirmText: 'حذف',
        danger: true,
      );
      if (!ok) return;
      await repo.deleteAccount(a.id!);
      bump(ref);
      if (context.mounted) {
        Navigator.pop(context);
        showSnack(context, 'تم حذف الحساب');
      }
    }
  }

  Future<void> _whatsapp(
    BuildContext context,
    Account a,
    double balance,
    CurrencyDef c, {
    bool stamp = false,
  }) async {
    final nature = balance > 0 ? 'عليكم' : 'لكم';
    // (دفعة 65-ب) الإجمالي فقط — لا تفصيل — وختم التطبيق للحساب المقيد.
    final text = 'مرحباً ${a.name}\n'
        'رصيدكم الحالي: ${Fmt.money(balance.abs(), c.decimal)} ${c.symbol} '
        '($nature)'
        '${stamp ? '\n―\n$kWatermarkText' : ''}';
    final uri = Uri.parse(
      'https://wa.me/${Fmt.waNumber(a.contactNumber)}?text=${Uri.encodeComponent(text)}',
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        showSnack(context, 'تعذّر فتح واتساب', error: true);
      }
    }
  }

  Future<void> _call(BuildContext context, Account a) async {
    final uri = Uri.parse('tel:${a.phone.isEmpty ? a.whatsapp : a.phone}');
    if (!await launchUrl(uri)) {
      if (context.mounted) showSnack(context, 'تعذّر الاتصال', error: true);
    }
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _MiniStat({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            label,
            style:
                TextStyle(fontSize: 11.5, color: Theme.of(context).hintColor),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      );
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: Theme.of(context).hintColor),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}

class _TxTile extends StatelessWidget {
  final Tx tx;
  final int accountId;
  final CurrencyDef currency;
  const _TxTile({
    required this.tx,
    required this.accountId,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final effect = tx.effectOn(accountId) ?? 0;
    final color = effect > 0 ? AppColors.green : AppColors.red;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
      leading: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(tx.type.icon, style: const TextStyle(fontSize: 16)),
      ),
      title: Text(
        tx.type.label,
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
      ),
      // (دفعة 58 — متطلب 10) وقت التنفيذ HH:MM بجانب التاريخ.
      subtitle: Text(
        '${Fmt.date(tx.date)} · ${Fmt.clock(tx.createdAt)}'
        '${tx.description.isEmpty ? '' : ' · ${tx.description}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: Text(
        '${effect > 0 ? '+' : '−'}${Fmt.money(effect.abs(), currency.decimal)} ${currency.symbol}',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

/// كبسولة عملة: رصيد مستقل بعملة واحدة + طبيعة الرصيد (له/عليه).
/// النقر يفلتر كشف الحساب على هذه العملة، ونقرة ثانية تلغي الفلتر.
class _CurrencyCapsule extends StatelessWidget {
  final String code;
  final CurrencyDef def;
  final double balance;
  final bool hidden;
  final bool selected;
  final VoidCallback onTap;
  const _CurrencyCapsule({
    required this.code,
    required this.def,
    required this.balance,
    required this.hidden,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = balance > 0
        ? AppColors.green
        : (balance < 0 ? AppColors.red : Theme.of(context).hintColor);
    final nature = balance > 0 ? 'عليه' : (balance < 0 ? 'له' : '—');
    final amount =
        hidden ? '••••' : Fmt.money(balance.abs(), def.decimal);
    return Material(
      color: selected
          ? color.withValues(alpha: 0.16)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? color : Theme.of(context).dividerColor,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$amount ${def.symbol}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: color,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                nature,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
