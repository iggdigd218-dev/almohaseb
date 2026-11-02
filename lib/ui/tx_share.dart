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
    // عنوان واضح حسب نوع العملية (قبض، صرف، عليه، له…).
    String title;
    if (tx.type == OpType.revenue || tx.type == OpType.inflow) {
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

    late final Map<String, String> currentSettings;
    try {
      currentSettings = await repo.settings();
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر تحميل بيانات السند: $e', error: true);
      }
      return TxShareOutcome.failed;
    }
    final hasLogo = (currentSettings['logo'] ?? '').trim().isNotEmpty;
    final needsFreshReceipt = tx.type == OpType.debit || hasLogo;

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

  /// يفتح محادثة العميل في واتساب مباشرة مع صورة السند والنص.
  static Future<bool> sendWhatsAppDirect(
    BuildContext context,
    WidgetRef ref, {
    required Tx tx,
    Account? account,
  }) async {
    final repo = ref.read(repoProvider);
    final acc = account ??
        (tx.accountId == null ? null : await repo.account(tx.accountId!));
    final phone = _phoneOf(acc, 'whatsapp');

    if (phone.isEmpty) {
      if (context.mounted) {
        showSnack(context, 'لا يوجد رقم هاتف/واتساب مسجل لهذا الحساب', error: true);
      }
      return false;
    }

    if (context.mounted) {
      showSnack(context, 'جارٍ تجهيز الإيصال وفتح محادثة واتساب…');
    }

    String path;
    try {
      if (tx.image.isNotEmpty && MediaPaths.exists(tx.image)) {
        path = MediaPaths.toAbsolute(tx.image);
      } else {
        path = await generate(repo: repo, tx: tx, account: acc);
      }
    } catch (_) {
      path = '';
    }

    late final String text;
    try {
      text = await caption(repo: repo, tx: tx, account: acc);
    } catch (_) {
      text = 'سند عملية — ${tx.type.label}: ${tx.amount}';
    }

    final installed = await WhatsApp.installed();
    String? pkg;
    if (installed.contains('com.whatsapp.w4b')) {
      pkg = 'com.whatsapp.w4b';
    }

    final res = await WhatsApp.send(
      phone: phone,
      text: text,
      imagePath: path.isNotEmpty && File(path).existsSync() ? path : null,
      package: pkg,
    );

    bump(ref);
    if (context.mounted) {
      showSnack(context, WhatsApp.messageFor(res), error: res != WaResult.ok);
    }
    return res == WaResult.ok;
  }

  /// يفتح تطبيق الرسائل النصية على رقم العميل مع النص.
  static Future<bool> sendSmsDirect(
    BuildContext context,
    WidgetRef ref, {
    required Tx tx,
    Account? account,
  }) async {
    final repo = ref.read(repoProvider);
    final acc = account ??
        (tx.accountId == null ? null : await repo.account(tx.accountId!));
    final phone = _phoneOf(acc, 'sms');

    if (phone.isEmpty) {
      if (context.mounted) {
        showSnack(context, 'لا يوجد رقم هاتف مسجل لهذا الحساب', error: true);
      }
      return false;
    }

    late final String text;
    try {
      text = await caption(repo: repo, tx: tx, account: acc);
    } catch (_) {
      text = 'سند عملية — ${tx.type.label}: ${tx.amount}';
    }

    final ok = await SmsSender.send(phone: phone, body: text);
    bump(ref);
    if (context.mounted) {
      showSnack(
        context,
        ok ? 'تم فتح تطبيق الرسائل النصية' : 'تعذّر فتح تطبيق الرسائل',
        error: !ok,
      );
    }
    return ok;
  }

  /// يفتح نافذة مشاركة النظام الرسمية (Native System Share Dialog).
  static Future<bool> shareSystem(
    BuildContext context,
    WidgetRef ref, {
    required Tx tx,
    Account? account,
  }) async {
    final repo = ref.read(repoProvider);
    final acc = account ??
        (tx.accountId == null ? null : await repo.account(tx.accountId!));

    if (context.mounted) {
      showSnack(context, 'جارٍ فتح نافذة مشاركة النظام…');
    }

    String path;
    try {
      if (tx.image.isNotEmpty && MediaPaths.exists(tx.image)) {
        path = MediaPaths.toAbsolute(tx.image);
      } else {
        path = await generate(repo: repo, tx: tx, account: acc);
      }
    } catch (_) {
      path = '';
    }

    late final String text;
    try {
      text = await caption(repo: repo, tx: tx, account: acc);
    } catch (_) {
      text = 'سند عملية — ${tx.type.label}: ${tx.amount}';
    }

    try {
      if (path.isNotEmpty && File(path).existsSync()) {
        await Share.shareXFiles(
          [XFile(path)],
          text: text,
          subject: 'سند العملية — ${tx.type.label}',
        );
      } else {
        await Share.share(
          text,
          subject: 'سند العملية — ${tx.type.label}',
        );
      }
      return true;
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر فتح مشاركة النظام: $e', error: true);
      }
      return false;
    }
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
  final currentSettings = await repo.settings();
  final hasLogo = (currentSettings['logo'] ?? '').trim().isNotEmpty;
  final needsFreshReceipt = tx.type == OpType.debit || hasLogo;
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

/// شاشة نجاح العملية المنبثقة مع خيارات المشاركة الفورية المباشرة وإمكانية الإغلاق.
Future<void> showTxSuccessSheet(
  BuildContext context,
  WidgetRef ref, {
  required Tx tx,
  Account? account,
}) async {
  final repo = ref.read(repoProvider);
  final acc = account ??
      (tx.accountId == null ? null : await repo.account(tx.accountId!));
  final currencies = await repo.currencies();
  final cur = currencies.firstWhere(
    (c) => c.code == tx.currency,
    orElse: () => kDefaultCurrencies.first,
  );

  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_circle_rounded,
                size: 44,
                color: Colors.green.shade600,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'تم حفظ العملية بنجاح',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${tx.type.label} · ${Fmt.money(tx.amount, cur.decimal)} ${cur.symbol}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryOf(ctx),
              ),
            ),
            if (acc != null) ...[
              const SizedBox(height: 4),
              Text(
                'العميل: ${acc.name}',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(ctx).hintColor,
                ),
              ),
            ],
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            const Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                'مشاركة السند مع العميل:',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      TxShare.sendWhatsAppDirect(
                        context,
                        ref,
                        tx: tx,
                        account: acc,
                      );
                    },
                    icon: const Icon(Icons.chat, size: 20),
                    label: const Text('واتساب'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0288D1),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      TxShare.sendSmsDirect(
                        context,
                        ref,
                        tx: tx,
                        account: acc,
                      );
                    },
                    icon: const Icon(Icons.sms_outlined, size: 20),
                    label: const Text('رسالة SMS'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      TxShare.shareSystem(
                        context,
                        ref,
                        tx: tx,
                        account: acc,
                      );
                    },
                    icon: const Icon(Icons.share_outlined, size: 20),
                    label: const Text('مشاركة عامة (النظام)'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('إغلاق'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
