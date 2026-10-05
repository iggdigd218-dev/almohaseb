import 'package:flutter/material.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../core/words.dart';

/// شارة ملوّنة صغيرة.
class Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  const Pill(this.text, {super.key, this.color = AppColors.teal, this.icon});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4),
            ],
            Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      );
}

/// عرض مبلغ الرصيد مع طبيعته (له/عليه) واللون المناسب.
///
/// الاتفاقية: موجب = «عليه» (مستحق لنا)، سالب = «له» (مستحق منا).
class BalanceText extends StatelessWidget {
  final double value;
  final CurrencyDef currency;
  final bool hidden;
  final double size;
  final bool showNature;

  const BalanceText({
    super.key,
    required this.value,
    required this.currency,
    this.hidden = false,
    this.size = 16,
    this.showNature = true,
  });

  @override
  Widget build(BuildContext context) {
    final zero = value.abs() < 0.005;
    final color = zero
        ? Theme.of(context).hintColor
        : (value > 0 ? AppColors.green : AppColors.red);
    final nature = zero ? 'متساوٍ' : (value > 0 ? 'عليه' : 'له');

    if (hidden) {
      return Text(
        '••••••',
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          Fmt.money(value.abs(), currency.decimal),
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          currency.symbol,
          style: TextStyle(
            fontSize: size * 0.68,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        if (showNature && !zero) ...[
          const SizedBox(width: 6),
          Pill(nature, color: color),
        ],
      ],
    );
  }
}

/// بطاقة إحصائية في لوحة التحكم.
class StatCard extends StatelessWidget {
  final String title;
  final String value;
  final String? sub;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const StatCard({
    super.key,
    required this.title,
    required this.value,
    this.sub,
    required this.icon,
    this.color = AppColors.teal,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, size: 21, color: color),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 11),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ),
                if (sub != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    sub!,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
}

/// حالة فارغة.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 54, color: Theme.of(context).disabledColor),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 15.5, fontWeight: FontWeight.w700),
              ),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 18), action!],
            ],
          ),
        ),
      );
}

/// Two responsive columns with intrinsic height: long Arabic labels and large
/// text never have to fit into a fixed aspect-ratio cell.
class StatCardGrid extends StatelessWidget {
  final List<Widget> children;
  const StatCardGrid({super.key, required this.children});
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth < 280 ? 1 : 2;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final child in children) SizedBox(width: width, child: child),
        ]);
      });
}

/// عنوان قسم مع إجراء اختياري.
class SectionTitle extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  const SectionTitle(this.title, {super.key, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
            if (actionLabel != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child:
                    Text(actionLabel!, style: const TextStyle(fontSize: 12.5)),
              ),
          ],
        ),
      );
}

/// حوار إدخال نصي بسيط (إعادة تسمية، إلخ).
Future<String?> promptDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = '',
  String confirmText = 'موافق',
  String cancelText = 'إلغاء',
}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(labelText: label.isEmpty ? title : label),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(cancelText)),
        FilledButton(
          onPressed: () => Navigator.pop(c, ctrl.text),
          child: Text(confirmText),
        ),
      ],
    ),
  );
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = 'تأكيد',
  bool danger = false,
}) async {
  // لمسة اهتزاز عند فتح الحوار (نقرة خفيفة).
  Sfx.click();
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message, style: const TextStyle(height: 1.6)),
      actions: [
        TextButton(
          onPressed: () {
            Sfx.click();
            Navigator.pop(c, false);
          },
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () {
            if (danger) {
              Sfx.dangerConfirm();
            } else {
              Sfx.pop();
            }
            Navigator.pop(c, true);
          },
          style: danger
              ? FilledButton.styleFrom(backgroundColor: AppColors.red)
              : null,
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return r ?? false;
}

void showSnack(
  BuildContext context,
  String message, {
  bool error = false,
  bool silent = false,
}) {
  // رسائل الخطأ لم تعد شريطاً أحمر صغيراً أسفل الشاشة يختفي خلف النوافذ:
  // تظهر الآن نافذة منبثقة بارزة وسط الشاشة توضح للمستخدم سبب الخطأ.
  if (error) {
    if (!silent) Sfx.error();
    showProminentError(context, message);
    return;
  }
  // ردود فعل صوتية/اهتزازية تلقائية لجميع الرسائل ما لم يُطلب الصمت صراحة.
  if (!silent) {
    if (message.contains('حذف') ||
        message.contains('أرشفة') ||
        message.contains('طرد')) {
      // إجراءات تدميرية: اهتزاز ثقيل تحذيري.
      Sfx.delete();
    } else if (message.contains('⚠️') || message.contains('تحذير')) {
      Sfx.warning();
    } else if (message.contains('✅') ||
        message.contains('نجح') ||
        message.contains('حُفظ') ||
        message.contains('أُضيف') ||
        message.contains('تمت ') ||
        message.contains('اكتمل') ||
        message.startsWith('تم ')) {
      // رسائل النجاح — نغمة خفيفة. المواضع التي تُصدِر أصواتًا مخصّصة (كحفظ
      // العمليات في tx_form) تُمرّر silent: true لتجنب التكرار.
      Sfx.pop();
    } else {
      Sfx.click();
    }
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? AppColors.red : null,
        duration: Duration(seconds: error ? 4 : 3),
      ),
    );
}

/// يترجم نصوص الأخطاء التقنية إلى شرح عربي مفهوم للمستخدم.
String friendlyErrorText(String raw) {
  final r = raw
      .replaceAll('Exception:', '')
      .replaceAll('StateError:', '')
      .replaceAll('Bad state:', '')
      .trim();
  final low = r.toLowerCase();

  // تعارض القيود الفريدة
  if (low.contains('unique constraint failed') ||
      low.contains('unique constraint violation') ||
      low.contains('code 2067')) {
    return 'تعذر الحفظ لوجود سجل مسبق مسجل بنفس القيمة (الاسم أو المعرّف مستخدم بالفعل في النظام).\n\n(تفاصيل تقنية: $r)';
  }
  // تعارض العلاقات والربط
  if (low.contains('foreign key constraint failed') ||
      low.contains('foreign key violation') ||
      low.contains('code 787')) {
    return 'تعذر الحذف أو التعديل لارتباط هذا السجل بعمليات أو فواتير أخرى داخل قاعدة البيانات.\n\n(تفاصيل تقنية: $r)';
  }
  // الحقول الإلزامية
  if (low.contains('not null constraint failed') ||
      low.contains('not null constraint') ||
      low.contains('code 1299')) {
    return 'تعذر إتمام العملية لوجود بيانات أساسية مطلوبة تركت فارغة.\n\n(تفاصيل تقنية: $r)';
  }
  // قفل قاعدة البيانات
  if (low.contains('database is locked') ||
      low.contains('database_locked') ||
      low.contains('database table is locked') ||
      low.contains('database busy') ||
      low.contains('code 5')) {
    return 'قاعدة البيانات مشغولة حالياً بعملية مزامنة أو حفظ أخرى، يرجى الانتظار ثوانٍ والمحاولة مجدداً.';
  }

  if (low.contains('awaiting-offline-peers')) {
    return 'بعض أجهزة المجموعة غير متصلة الآن — ستصلها التغييرات تلقائياً فور اتصالها.';
  }
  if (low.contains('socketexception') ||
      low.contains('connection refused') ||
      low.contains('connection timed out') ||
      low.contains('network is unreachable') ||
      low.contains('timeoutexception') ||
      low.contains('failed host lookup') ||
      low.contains('network error') ||
      low.contains('clientexception')) {
    return 'فشل الاتصال بخادم المزامنة؛ يرجى التحقق من اتصال الإنترنت والمحاولة لاحقاً.\n\n(تفاصيل تقنية: $r)';
  }
  if (low.contains('user-not-authorized') || low.contains('not-authorized')) {
    return 'ليست لديك صلاحية لتنفيذ هذا الإجراء.\nاطلب من المدير منحك الصلاحية المناسبة من شاشة إدارة المجموعة.';
  }
  if (low.contains('workspace-mismatch')) {
    return 'هذا الجهاز يتبع مجموعة مختلفة — لا يمكن المزامنة بين مجموعتين مختلفتين.';
  }
  if (low.contains('expelled')) {
    return 'تم إخراج هذا الجهاز من المجموعة من قِبل المدير.';
  }
  if (low.contains('token') && (low.contains('expired') || low.contains('invalid'))) {
    return 'رمز الاقتران غير صالح أو انتهت مدته.\nاطلب من المدير توليد رمز جديد وأعد المحاولة خلال 5 دقائق.';
  }
  if (low.contains('permission') && low.contains('denied')) {
    return 'رفض النظام منح الإذن المطلوب.\nفعّل الإذن من إعدادات النظام ثم أعد المحاولة.';
  }
  return r;
}

/// نافذة خطأ بارزة وسط الشاشة (بدل الشريط الأحمر الصغير أسفل الشاشة
/// الذي كان يختفي خلف النوافذ): أيقونة تحذير كبيرة + سبب الخطأ موضحاً
/// بلغة مفهومة + زر إغلاق واضح.
void showProminentError(
  BuildContext context,
  String message, {
  String title = 'حدث خطأ',
}) {
  final friendly = friendlyErrorText(message);
  showDialog<void>(
    context: context,
    barrierDismissible: true,
    useRootNavigator: true, // فوق كل النوافذ المفتوحة.
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.red.withValues(alpha: .1),
                border: Border.all(color: Colors.red.shade400, width: 4),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.priority_high_rounded,
                  size: 34, color: Colors.red.shade600),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 17,
                color: Colors.red.shade700,
              ),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                child: Text(
                  friendly,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13.5, height: 1.7),
                ),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade600,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('حسناً، فهمت',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// عرض المبلغ بالحروف العربية تحت حقول إدخال المبالغ.
///
/// يتتبّع حقل النص ويعرض تفقيطًا مباشرًا للقيمة (مثال: 450000 ← «أربعمائة
/// وخمسون ألف»). يختفي تلقائيًا عندما يكون الحقل فارغًا أو القيمة صفرًا.
/// لا يحفظ أي بيانات ولا يؤثر على المنطق — عرض مساعد فقط.
class AmountWords extends StatefulWidget {
  final TextEditingController controller;

  /// عدد الكسور العشرية المتوقعة (0 للريال اليمني مثلًا).
  final int decimals;
  const AmountWords({super.key, required this.controller, this.decimals = 0});

  @override
  State<AmountWords> createState() => _AmountWordsState();
}

class _AmountWordsState extends State<AmountWords> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final v = Fmt.parseAmount(widget.controller.text);
    if (v == null || v == 0) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 12, top: 6, end: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.spellcheck_rounded,
              size: 15, color: AppColors.primaryOf(context)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              numberToWords(v),
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                fontWeight: FontWeight.w700,
                color: dark ? AppColors.dText2 : AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// لوحة إدخال رقمية سريعة (حوار سفلي): حقل رقمي بفواصل آلاف حية + أزرار
/// «+00» و«+000» لتسريع إدخال المبالغ والكميات الكبيرة بلا نقرات متكررة.
Future<double?> showQuickAmountPad(
  BuildContext context, {
  required String title,
  double? initial,
  String? hint,
}) {
  final ctl = TextEditingController(
    text: initial == null || initial == 0
        ? ''
        : (initial == initial.roundToDouble()
            ? Fmt.money(initial)
            : '$initial'),
  );
  return showModalBottomSheet<double>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      void appendZeros(String zeros) {
        final raw = ThousandsFormatter.strip(ctl.text);
        if (raw.isEmpty || raw == '0') return;
        final v = double.tryParse(raw);
        if (v == null) return;
        final next = '$raw$zeros';
        ctl.value = const ThousandsFormatter().formatEditUpdate(
          ctl.value,
          TextEditingValue(text: next),
        );
        Sfx.click();
      }

      void submit() {
        final v = Fmt.parseAmount(ThousandsFormatter.strip(ctl.text));
        Navigator.pop(ctx, v);
      }

      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
          left: 16,
          right: 16,
          top: 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            TextField(
              controller: ctl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: const [ThousandsFormatter()],
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              decoration: InputDecoration(hintText: hint, isDense: true),
              onSubmitted: (_) => submit(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => appendZeros('00'),
                    child: const Text('+00',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => appendZeros('000'),
                    child: const Text('+000',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: submit,
                    icon: const Icon(Icons.check),
                    label: const Text('تم'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      );
    },
  );
}
