import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/media_paths.dart';
import '../core/models.dart';
import '../core/receipt_image.dart';
import '../core/theme.dart';
import '../core/whatsapp.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import 'widgets.dart';

String _quantity(double value) =>
    value == value.roundToDouble() ? Fmt.money(value) : Fmt.money(value, 2);

/// توليد صورة إيصال العملية وإرسالها عبر واتساب.
///
/// المسار كاملًا بلا نافذة مشاركة: تُولَّد الصورة، تُحفظ في العملية، ثم
/// تُفتح محادثة العميل مباشرة ومعها الصورة والنص.
enum TxShareOutcome { skipped, opened, failed }

class TxShare {
  /// يولّد الصورة ويحفظ مسارها في العملية، ويعيد المسار.
  static Future<String> generate({
    required Repo repo,
    required Tx tx,
    required Account? account,
  }) async {
    final settings = await repo.settings();
    final currencies = await repo.currencies();
    final items = tx.id == null
        ? const <InvoiceLine>[]
        : await repo.transactionItems(tx.id!);
    final cur = currencies.firstWhere(
      (c) => c.code == tx.currency,
      orElse: () => kDefaultCurrencies.first,
    );
    double? after;
    if (account != null) {
      try {
        after = await repo.balanceOf(account);
      } catch (_) {
        after = null;
      }
    }

    final path = await buildReceiptImage(
      ReceiptData.fromTx(
        tx: tx,
        account: account,
        currency: cur,
        balanceAfter: after,
        settings: settings,
        items: items,
      ),
    );

    if (tx.id != null) {
      await repo.updateTxImage(tx.id!, path);
    }
    return path;
  }

  /// نص الرسالة المرافقة للصورة.
  static Future<String> caption({
    required Repo repo,
    required Tx tx,
    required Account? account,
  }) async {
    final st = await repo.settings();
    final org = (st['businessName'] ?? '').trim();
    final currencies = await repo.currencies();
    final cur = currencies.firstWhere(
      (c) => c.code == tx.currency,
      orElse: () => kDefaultCurrencies.first,
    );
    final items = tx.id == null
        ? const <InvoiceLine>[]
        : await repo.transactionItems(tx.id!);
    // عنوان واضح حسب نوع العملية (فاتورة مبيعات، قبض، صرف، عليه، له…).
    String title;
    if (tx.type == OpType.debit && items.isNotEmpty) {
      title = '🧾 فاتورة مبيعات (آجل)';
    } else if (tx.type == OpType.revenue || tx.type == OpType.inflow) {
      title = '🧾 فاتورة مبيعات / سند قبض';
    } else {
      title = '${tx.type.icon} ${tx.type.label}';
    }

    String amountLine;
    switch (tx.type) {
      case OpType.inflow:
      case OpType.revenue:
      case OpType.credit:
        amountLine =
            '✅ المبلغ المستلَم (له): ${Fmt.money(tx.amount, cur.decimal)} ${cur.symbol}';
        break;
      case OpType.outflow:
      case OpType.expense:
      case OpType.debit:
        amountLine =
            '🔴 المبلغ المطلوب (عليه): ${Fmt.money(tx.amount, cur.decimal)} ${cur.symbol}';
        break;
      default:
        amountLine =
            '💵 المبلغ: ${Fmt.money(tx.amount, cur.decimal)} ${cur.symbol}';
    }

    final lines = <String>[
      if (org.isNotEmpty) '*🏪 $org*',
      '━━━━━━━━━━━━━',
      title,
      '━━━━━━━━━━━━━',
      'العميل: ${account?.name ?? '—'}',
      amountLine,
      'التاريخ: ${Fmt.date(tx.date)}',
      if (tx.reference.trim().isNotEmpty) 'رقم العملية: ${tx.reference.trim()}',
      if (tx.description.trim().isNotEmpty) 'البيان: ${tx.description.trim()}',
    ];
    if (items.isNotEmpty) {
      lines.add('━━━━━━━━━━━━━');
      lines.add('🛒 أصناف الفاتورة:');
      for (var i = 0; i < items.length; i++) {
        final line = items[i];
        lines.add(
          '${i + 1}. ${line.name} × ${_quantity(line.quantity)} ${line.unit} = '
          '${Fmt.money(line.total, cur.decimal)} ${cur.symbol}',
        );
      }
      final total = items.fold<double>(0, (sum, line) => sum + line.total);
      lines.add('━━━━━━━━━━━━━');
      lines.add(
        '💰 إجمالي الفاتورة: ${Fmt.money(total, cur.decimal)} ${cur.symbol}',
      );
    }

    // رصيد العميل الحالي بعد العملية (وضوح كامل للمطلوب).
    if (account != null && account.id != null) {
      try {
        final bal = await repo.balanceOf(account);
        final oweLabel = (st['labelOweUs'] ?? '').trim().isNotEmpty
            ? st['labelOweUs']!.trim()
            : 'المطلوب لدينا (عليه)';
        final themLabel = (st['labelOweThem'] ?? '').trim().isNotEmpty
            ? st['labelOweThem']!.trim()
            : 'المطلوب منا (له)';
        if (bal.abs() > 0.001) {
          final label = bal > 0 ? oweLabel : themLabel;
          lines.add(
            '📊 $label: ${Fmt.money(bal.abs(), cur.decimal)} ${cur.symbol}',
          );
        } else {
          lines.add('📊 الرصيد الحالي: صفر — جميع المستحقات مسددة ✅');
        }
      } catch (_) {}
    }

    final orgPhone = (st['phone'] ?? '').trim();
    if (orgPhone.isNotEmpty) lines.add('📞 للتواصل: $orgPhone');
    final footer = (st['voucherFooter'] ?? '').trim();
    if (footer.isNotEmpty) {
      lines.add('━━━━━━━━━━━━━');
      lines.add(footer);
    } else {
      lines.add('شكراً لتعاملكم معنا 🌿');
    }
    return lines.join('\n');
  }

  /// المسار الكامل: توليد + حفظ + فتح واتساب على رقم العميل.
  ///
  /// يعمل نفسه للعملية الجديدة ولإعادة الإرسال لعملية قديمة.
  static Future<TxShareOutcome> sendNow(
    BuildContext context,
    WidgetRef ref, {
    required Tx tx,
    Account? account,
    bool silentIfNoPhone = false,
  }) async {
    final repo = ref.read(repoProvider);
    final acc = account ??
        (tx.accountId == null ? null : await repo.account(tx.accountId!));

    // نحدد القناة من بيانات الحساب نفسه (لكل عميل تفضيله).
    final channel = (acc?.notifyChannel ?? 'whatsapp').trim();
    final phone = _phoneOf(acc, channel);

    if (channel == 'none') {
      return TxShareOutcome.skipped; // المستخدم فضّل عدم الإرسال.
    }

    if (phone.isEmpty) {
      if (!silentIfNoPhone && context.mounted) {
        showSnack(
          context,
          channel == 'sms'
              ? 'لا يوجد رقم هاتف لهذا الحساب لإرسال رسالة نصية'
              : 'لا يوجد رقم واتساب لهذا الحساب',
          error: true,
        );
      }
      return TxShareOutcome.skipped;
    }

    if (context.mounted) {
      showSnack(
        context,
        channel == 'sms'
            ? 'جارٍ تجهيز الرسالة وفتح تطبيق الرسائل…'
            : 'جارٍ تجهيز الإيصال وفتح واتساب…',
      );
    }

    late final List<InvoiceLine> itemLines;
    late final Map<String, String> currentSettings;
    try {
      itemLines = tx.id == null
          ? const <InvoiceLine>[]
          : await repo.transactionItems(tx.id!);
      currentSettings = await repo.settings();
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر تحميل بيانات السند: $e', error: true);
      }
      return TxShareOutcome.failed;
    }
    final hasLogo = (currentSettings['logo'] ?? '').trim().isNotEmpty;
    final needsFreshReceipt =
        tx.type == OpType.debit || itemLines.isNotEmpty || hasLogo;

    late final String text;
    try {
      text = await caption(repo: repo, tx: tx, account: acc);
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر تجهيز نص الإشعار: $e', error: true);
      }
      return TxShareOutcome.failed;
    }

    // === فرع الرسائل النصية ===
    if (channel == 'sms') {
      // SMS لا يدعم إرفاق صور عبر النية العادية، لذا نولّد السند في الخلفية
      // للتخزين، لكن نفتح تطبيق الرسائل بالنص فقط.
      try {
        if (needsFreshReceipt ||
            tx.image.isEmpty ||
            !MediaPaths.exists(tx.image)) {
          unawaited(
            generate(
              repo: repo,
              tx: tx,
              account: acc,
            ).timeout(const Duration(seconds: 5)).then<void>((_) {},
                onError: (Object e, StackTrace st) {
              debugPrint('Receipt generation failed: $e');
            }),
          );
        }
      } catch (_) {}
      final ok = await SmsSender.send(phone: phone, body: text);
      bump(ref);
      if (context.mounted) {
        showSnack(
          context,
          ok
              ? 'تم فتح تطبيق الرسائل النصية — يمكنك إرفاق صورة السند يدوياً إن أردت.'
              : 'تعذّر فتح تطبيق الرسائل النصية',
          error: !ok,
        );
      }
      return ok ? TxShareOutcome.opened : TxShareOutcome.failed;
    }

    // === فرع واتساب ===
    String path;
    try {
      if (needsFreshReceipt) {
        path = await generate(repo: repo, tx: tx, account: acc);
      } else if (tx.image.isNotEmpty && MediaPaths.exists(tx.image)) {
        path = MediaPaths.toAbsolute(tx.image);
      } else {
        path = await generate(repo: repo, tx: tx, account: acc);
      }
    } catch (_) {
      if (context.mounted) {
        showSnack(
          context,
          'تعذّر تجهيز صورة السند، لم يتم إرسال إشعار نصي فقط.',
          error: true,
        );
      }
      return TxShareOutcome.failed;
    }

    if (path.isEmpty || !File(path).existsSync()) {
      if (context.mounted) {
        showSnack(
          context,
          'تعذّر العثور على صورة السند، لم يتم إرسال النص وحده.',
          error: true,
        );
      }
      return TxShareOutcome.failed;
    }

    late final WaResult res;
    try {
      // نختار حزمة واتساب المناسبة حسب ما هو مثبّت — لا نعتمد على إعداد عام.
      final installed = await WhatsApp.installed();
      String? pkg;
      if (installed.contains('com.whatsapp.w4b')) {
        pkg = 'com.whatsapp.w4b';
      } else if (installed.contains('com.whatsapp')) {
        pkg = null; // العادي هو الافتراضي.
      }
      res = await WhatsApp.send(
        phone: phone,
        text: text,
        imagePath: path,
        package: pkg,
      );
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر إرسال السند بالصورة والنص: $e', error: true);
      }
      return TxShareOutcome.failed;
    }

    bump(ref);
    if (res == WaResult.imageFailed || res == WaResult.error) {
      final shared = await _shareImageWithText(path, text);
      if (context.mounted) {
        showSnack(
          context,
          shared
              ? 'تم فتح مشاركة السند بالصورة والنص.'
              : WhatsApp.messageFor(res),
          error: !shared,
        );
      }
      return shared ? TxShareOutcome.opened : TxShareOutcome.failed;
    } else if (context.mounted && res != WaResult.ok) {
      showSnack(context, WhatsApp.messageFor(res), error: true);
    }
    return res == WaResult.ok ? TxShareOutcome.opened : TxShareOutcome.failed;
  }

  /// مشاركة احتياطية تحفظ الصورة والنص معًا عبر نافذة مشاركة أندرويد.
  /// تُستخدم فقط إذا رفض إصدار واتساب الإرسال المباشر.
  static Future<bool> _shareImageWithText(String path, String text) async {
    try {
      await Share.shareXFiles(
        [XFile(path)],
        text: text,
        subject: 'سند العملية — إدارة البيانات',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _phoneOf(Account? a, String channel) {
    if (a == null) return '';
    if (channel == 'sms') return a.phone.trim();
    final w = a.whatsapp.trim();
    return w.isNotEmpty ? w : a.phone.trim();
  }
}

/// معاينة صورة الإيصال مع أزرار الإرسال وإعادة التوليد.
Future<void> showReceiptPreview(
  BuildContext context,
  WidgetRef ref, {
  required Tx tx,
  Account? account,
}) async {
  final repo = ref.read(repoProvider);
  final acc = account ??
      (tx.accountId == null ? null : await repo.account(tx.accountId!));
  var path = MediaPaths.toAbsolute(tx.image);
  final itemLines = tx.id == null
      ? const <InvoiceLine>[]
      : await repo.transactionItems(tx.id!);
  final currentSettings = await repo.settings();
  final hasLogo = (currentSettings['logo'] ?? '').trim().isNotEmpty;
  final needsFreshReceipt =
      tx.type == OpType.debit || itemLines.isNotEmpty || hasLogo;
  try {
    if (path.isEmpty || !File(path).existsSync() || needsFreshReceipt) {
      path = await TxShare.generate(repo: repo, tx: tx, account: acc);
    }
  } catch (e) {
    if (context.mounted) {
      showSnack(context, 'تعذّر تجهيز صورة الإيصال: $e', error: true);
    }
    return;
  }
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: .85,
      expand: false,
      builder: (ctx, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Row(
              children: [
                Icon(Icons.image_outlined, color: AppColors.primaryOf(ctx)),
                const SizedBox(width: 8),
                Text(
                  'إيصال العملية',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: controller,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(File(path)),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        try {
                          await TxShare.generate(
                            repo: repo,
                            tx: tx,
                            account: acc,
                          );
                          bump(ref);
                          if (context.mounted) {
                            showSnack(context, 'أُعيد توليد الصورة');
                          }
                        } catch (e) {
                          if (context.mounted) {
                            showSnack(
                              context,
                              'تعذّرت إعادة توليد الصورة: $e',
                              error: true,
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('إعادة التوليد'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        TxShare.sendNow(
                          context,
                          ref,
                          tx: tx.copyWith(image: path),
                          account: acc,
                        );
                      },
                      icon: const Icon(Icons.send),
                      label: const Text('إرسال واتساب'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
