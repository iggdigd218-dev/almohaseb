// 🔒 واجهات الفترة التجريبية: نافذة الترحيب (مرة واحدة) + الشريط العلوي
// الأنيق للوقت المتبقي + بطاقة انتهاء التجربة مع خيارات التجديد والتواصل.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/cloud_config.dart';
import '../core/license_model.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/sync/cloud_control_service.dart';
import '../data/sync/device_id.dart';
import '../data/sync/subscription_guard.dart';
import 'widgets.dart' show showSnack;

/// رقم التواصل المباشر للتفعيل (واتساب المدير/الدعم).
const String kActivationContact = '+967774190040';

/// نافذة الترحيب بالفترة التجريبية — تظهر مرة واحدة فقط عند أول تفعيل.
Future<void> showTrialWelcomeDialog(BuildContext context) async {
  Sfx.notify();
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFF2563EB)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.workspace_premium,
                  color: Colors.white, size: 40),
            ),
            const SizedBox(height: 16),
            const Text(
              '🎉 تجربتك المجانية بدأت!',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            const Text(
              'استمتع بكافة المزايا كاملة مجاناً لمدة شهر كامل (30 يوماً):\n'
              '☁️ مزامنة سحابية لحظية بين أجهزتك\n'
              '👥 ربط أجهزة الفريق وإدارة الصلاحيات\n'
              '💾 نسخ احتياطي سحابي آمن\n\n'
              'العدّاد يُحتسب بتوقيت الخادم — يظهر الوقت المتبقي '
              'أعلى الشاشة الرئيسية.',
              style: TextStyle(fontSize: 13.5, height: 1.7),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF7C3AED),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ابدأ الاستخدام',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// صياغة الوقت المتبقي: «X يوماً وY ساعة» فوق اليومين، «X ساعة وY دقيقة»
/// دونهما — للاستخدام الموحد في الشريط وقسم تفاصيل الاشتراك.
String formatTrialRemaining(Duration rem) {
  if (rem.inHours >= 48) {
    final d = rem.inDays;
    final h = rem.inHours % 24;
    return h == 0 ? '$d أيام' : '$d أيام و$h ساعة';
  }
  final h = rem.inHours;
  final m = rem.inMinutes % 60;
  if (h == 0) return '$m دقيقة';
  return '$h ساعة و$m دقيقة';
}

/// الشريط الدائم أعلى الشاشة الرئيسية (للمدير فقط): عدّاد تنازلي حي
/// يحسب الفارق بين expires_at ووقت الخادم اللحظي، ويتجدد كل دقيقة.
/// يبقى ظاهراً طوال سريان التجربة — عبر كل الإقلاعات — ولا يختفي إلا
/// عند اشتراك مدفوع (active) أو بعد الانتهاء (تحل محله بطاقة الانتهاء).
class TrialCountdownBanner extends ConsumerStatefulWidget {
  const TrialCountdownBanner({super.key});

  @override
  ConsumerState<TrialCountdownBanner> createState() =>
      _TrialCountdownBannerState();
}

class _TrialCountdownBannerState extends ConsumerState<TrialCountdownBanner> {
  // نبضة عرض محلية كل 30 ثانية: تعيد بناء النص من نفس حالة المزود
  // (التي تسند وقت الخادم لحظياً) دون انتظار دورة المزود الدقيقية.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // (المتطلب) الشريط للمدير فقط — تحصين مزدوج كبقية واجهات المالك.
    final isOwner = (ref.watch(isOwnerProvider).valueOrNull ?? false) ||
        ref.watch(workspaceModeProvider).valueOrNull == 'host';
    if (!isOwner) return const SizedBox.shrink();
    final sub = ref.watch(subscriptionProvider).valueOrNull;
    if (sub == null || sub.status != 'trial' || sub.expiresAtMs <= 0) {
      return const SizedBox.shrink();
    }
    if (sub.expired) {
      // شريط انتهاء مصغر دائم (بدل الاختفاء): تفعيل بنقرة.
      const color = Color(0xFFDC2626);
      return Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.lock_clock, size: 16, color: color),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'انتهت الفترة التجريبية — المزايا السحابية متوقفة',
                style: TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w700, color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => showTrialExpiredSheet(context),
              child: const Text('تفعيل الآن',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: color)),
            ),
          ],
        ),
      );
    }
    final rem = sub.remaining;
    final urgent = rem < const Duration(hours: 3);
    final color = urgent ? const Color(0xFFDC2626) : const Color(0xFF7C3AED);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(urgent ? Icons.hourglass_bottom : Icons.workspace_premium,
              size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              urgent
                  ? '⏳ تنتهي تجربتك خلال ${formatTrialRemaining(rem)} — فعّل اشتراكك الآن'
                  : 'الفترة التجريبية: متبقٍ ${formatTrialRemaining(rem)}',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => showTrialExpiredSheet(context, expired: false),
            child: Text(urgent ? 'تفعيل' : 'ترقية',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: color)),
          ),
        ],
      ),
    );
  }
}

/// (الإعدادات — للمدير) قسم «تفاصيل الاشتراك»: حالة الترخيص، تاريخ
/// الانتهاء، الوقت المتبقي، وزر تجديد/ترقية الاشتراك.
/// (الإعدادات — للمدير) قسم «تفاصيل الاشتراك»: حالة الترخيص، تاريخ
/// الانتهاء، الوقت المتبقي، وزر التحقق من حالة الاشتراك.
class SubscriptionDetailsSection extends ConsumerStatefulWidget {
  const SubscriptionDetailsSection({super.key});

  @override
  ConsumerState<SubscriptionDetailsSection> createState() =>
      _SubscriptionDetailsSectionState();
}

class _SubscriptionDetailsSectionState
    extends ConsumerState<SubscriptionDetailsSection> {
  bool _checking = false;

  String _fmtDate(int ms) {
    if (ms <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}/${two(d.month)}/${two(d.day)}';
  }

  bool _isLifetime(SubscriptionState sub) {
    return sub.status == 'active' &&
        (sub.expiresAtMs <= 0 ||
            sub.expiresAtMs >= DateTime(2090).millisecondsSinceEpoch ||
            sub.planType == 'lifetime');
  }

  Future<void> _checkSubscription() async {
    setState(() => _checking = true);
    Sfx.tap();
    ref.invalidate(subscriptionProvider);
    final sub = await ref.read(subscriptionProvider.future);
    if (!mounted) return;
    setState(() => _checking = false);

    final isLifetime = _isLifetime(sub);
    final expDate = _fmtDate(sub.expiresAtMs);
    final days = (sub.expiresAtMs > sub.serverNowMs
            ? ((sub.expiresAtMs - sub.serverNowMs) / 86400000).ceil()
            : 0)
        .clamp(0, 99999);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.verified_user_outlined, color: AppColors.primary),
            SizedBox(width: 8),
            Text('حالة الاشتراك والترخيص'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isLifetime)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFB45309), Color(0xFFF59E0B)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFF59E0B).withValues(alpha: .3),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.workspace_premium, color: Colors.white, size: 24),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'اشتراك مفعّل مدى الحياة — ترخيص دائم',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 13.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              )
            else if (sub.status == 'active')
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.greenSoftOf(ctx),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.greenOf(ctx).withValues(alpha: .3)),
                ),
                child: Column(
                  children: [
                    Icon(Icons.verified, color: AppColors.greenOf(ctx), size: 32),
                    const SizedBox(height: 6),
                    Text(
                      'متبقي على تجديد الاشتراك: $days يوم\n(ينتهي في: $expDate)',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        height: 1.5,
                        color: AppColors.greenOf(ctx),
                      ),
                    ),
                  ],
                ),
              )
            else if (sub.status == 'trial' && !sub.expired)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C3AED).withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF7C3AED).withValues(alpha: .3)),
                ),
                child: Column(
                  children: [
                    const Icon(Icons.workspace_premium, color: Color(0xFF7C3AED), size: 32),
                    const SizedBox(height: 6),
                    Text(
                      'متبقي من فترتك التجريبية: $days يوم\n(تاريخ الانتهاء: $expDate)',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        height: 1.5,
                        color: Color(0xFF7C3AED),
                      ),
                    ),
                  ],
                ),
              )
            else
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.dangerSoftOf(ctx),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  'انتهت الفترة التجريبية (انتهت في: $expDate)\nجدّد اشتراكك لمتابعة المزامنة.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                    height: 1.5,
                    color: AppColors.dangerOf(ctx),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subAsync = ref.watch(subscriptionProvider);
    final sub = subAsync.valueOrNull;
    if (sub == null || sub.status == 'none') {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.workspace_premium_outlined),
          title: const Text('تفاصيل الاشتراك'),
          subtitle: Text(
            subAsync.isLoading
                ? 'جارٍ تحميل حالة الاشتراك…'
                : 'فعّل المزامنة السحابية أولاً لبدء الفترة التجريبية.',
            style: const TextStyle(fontSize: 11.5, height: 1.5),
          ),
        ),
      );
    }

    final isLifetime = _isLifetime(sub);
    final days = (sub.expiresAtMs > sub.serverNowMs
            ? ((sub.expiresAtMs - sub.serverNowMs) / 86400000).ceil()
            : 0)
        .clamp(0, 99999);
    final expDate = _fmtDate(sub.expiresAtMs);

    final (label, color, icon) = switch ((isLifetime, sub.status, sub.expired)) {
      (true, _, _) => (
          'اشتراك مفعّل مدى الحياة — ترخيص دائم',
          const Color(0xFFD97706),
          Icons.workspace_premium,
        ),
      (_, 'active', _) => (
          'اشتراك مدفوع فعّال (متبقي $days يوم)',
          const Color(0xFF16A34A),
          Icons.verified,
        ),
      (_, 'trial', false) => (
          'فترة تجريبية مجانية (متبقي $days يوم)',
          const Color(0xFF7C3AED),
          Icons.workspace_premium,
        ),
      _ => (
          'انتهت الفترة التجريبية',
          const Color(0xFFDC2626),
          Icons.lock_clock,
        ),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('تفاصيل الاشتراك',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w800)),
                      Text(label,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: color)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (isLifetime)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFB45309), Color(0xFFF59E0B)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.stars_rounded, color: Colors.white, size: 20),
                    SizedBox(width: 8),
                    Text(
                      'اشتراك مفعّل مدى الحياة — ترخيص دائم',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Text('تاريخ الانتهاء',
                        style: TextStyle(
                            fontSize: 12.5, color: AppColors.text2Of(context))),
                    const Spacer(),
                    Text(expDate,
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Text(
                      sub.status == 'active'
                          ? 'متبقي على التجديد'
                          : 'المتبقي من التجربة',
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.text2Of(context)),
                    ),
                    const Spacer(),
                    Text('$days يوم',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: color)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: _checking ? null : _checkSubscription,
                    icon: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync_rounded, size: 18),
                    label: const Text(
                      'التحقق من حالة الاشتراك',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                if (!isLifetime) ...[
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          sub.expired ? const Color(0xFFDC2626) : color,
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () =>
                        showTrialExpiredSheet(context, expired: sub.expired),
                    icon: const Icon(Icons.rocket_launch_outlined, size: 18),
                    label: Text(
                      sub.status == 'active' ? 'إدارة' : 'ترقية',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => showVoucherRedeemDialog(context),
              icon: const Icon(Icons.confirmation_number_outlined, size: 18),
              label: const Text(
                'شحن كود تفعيل (Voucher Key)',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// نافذة «الترقية» السفلية لميزة مقيدة (دفعة 65): تشرح الميزة وتوجّه
/// المستخدم لتسجيل الدخول (لفتح فترة تجريبية) أو تجديد اشتراكه.
Future<void> showFeatureUpgradeSheet(
  BuildContext context, {
  required String featureName,
  required String description,
  required bool expired,
}) {
  Sfx.warning();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.lock_open_outlined,
              size: 48, color: AppColors.primaryOf(ctx)),
          const SizedBox(height: 12),
          Text(featureName,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(description,
              style: const TextStyle(fontSize: 12.5, height: 1.6),
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
            expired
                ? 'انتهت فترتك التجريبية — جدّد اشتراكك لاستعادة هذه الميزة. '
                    'بياناتك المحلية محفوظة كما هي.'
                : 'هذه الميزة للمشتركين. سجّل الدخول بحساب Google لفتحها '
                    'مع فترة تجريبية مجانية — بياناتك تبقى على جهازك.',
            style: TextStyle(
                fontSize: 12.5, height: 1.6, color: AppColors.text2Of(ctx)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              showTrialExpiredSheet(context, expired: expired);
            },
            icon: const Icon(Icons.rocket_launch_outlined, size: 18),
            label: Text(
                expired ? 'تجديد الاشتراك' : 'تفعيل الفترة التجريبية'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('لاحقاً'),
          ),
        ],
      ),
    ),
  );
}

/// (دفعة 65-ب) هل تُوسم مخرجات هذه الميزة بختم التطبيق؟
///
/// القاعدة الجديدة: **لا حظر**. الحساب المقيد — غير المربوط بالسحابة أو
/// منتهية تجربته — يستخدم الميزة كاملة، وتُختم مخرجاتها وحدها:
///   • إشعارات الواتساب: تُرسل فوراً، بالإجمالي لا بالتفصيل، مع ختم.
///   • شعار المتجر: مسموح (الشعارات الجمالية لا تُحجب).
///   • تصدير PDF: متاح، وعليه ختم مائي على كل صفحة.
/// هكذا يبقى المستخدم منتجاً، ويبقى دافع الترقية ظاهراً ولطيفاً.
Future<bool> featureNeedsStamp(WidgetRef ref, Feature feature) async {
  try {
    final sub = await ref.read(subscriptionProvider.future);
    return FeatureAccessGuard.shouldWatermark(sub, feature);
  } catch (_) {
    // تعذّر حسم حالة الاشتراك: لا نختم عقاباً على خطأ عارض.
    return false;
  }
}

/// بطاقة التفعيل/التجديد: تُستخدم بعد الانتهاء (تجديد) وأثناء السريان
/// (ترقية مبكرة) — العنوان والنبرة يتكيفان مع الحالة.
Future<void> showTrialExpiredSheet(BuildContext context,
    {bool expired = true}) async {
  if (expired) {
    Sfx.warning();
  } else {
    Sfx.notify();
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, 20 + MediaQuery.viewInsetsOf(ctx).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(expired ? Icons.lock_clock : Icons.rocket_launch,
              size: 52,
              color: expired
                  ? const Color(0xFFDC2626)
                  : const Color(0xFF7C3AED)),
          const SizedBox(height: 12),
          Text(
            expired ? 'انتهت الفترة التجريبية' : 'ترقية / تجديد الاشتراك',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            expired
                ? 'بياناتك المحلية بأمان ويمكنك مواصلة العمل عليها، لكن المزايا '
                    'السحابية توقفت:\n'
                    '• المزامنة اللحظية بين الأجهزة\n'
                    '• ربط أجهزة جديدة\n'
                    '• النسخ الاحتياطي السحابي\n\n'
                    'فعّل اشتراكك لاستئناف كل شيء فوراً من حيث توقف.'
                : 'فعّل اشتراكك الدائم قبل انتهاء التجربة لتستمر كل المزايا '
                    'السحابية دون أي انقطاع:\n'
                    '• المزامنة اللحظية بين الأجهزة\n'
                    '• ربط أجهزة الفريق\n'
                    '• النسخ الاحتياطي السحابي',
            style: const TextStyle(fontSize: 13, height: 1.7),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF16A34A),
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PurchaseScreen()));
            },
            icon: const Icon(Icons.verified_outlined),
            label: const Text('طلب الترخيص وتفعيل الحساب',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            onPressed: () async {
              final tel = Uri.parse('tel:$kActivationContact');
              try {
                await launchUrl(tel);
              } catch (_) {}
            },
            icon: const Icon(Icons.call_outlined),
            label: const Text('اتصال مباشر'),
          ),
          const SizedBox(height: 8),
          // شاشة الشراء الكاملة: المزايا + إرسال كود التفعيل + تأكيد الشراء.
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PurchaseScreen()));
            },
            icon: const Icon(Icons.workspace_premium),
            label: const Text('شراء التطبيق — عرض كل المزايا',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(expired ? 'متابعة بالعمل المحلي فقط' : 'لاحقاً',
                style: TextStyle(color: AppColors.text3Of(ctx))),
          ),
        ],
      ),
    ),
  );
}


bool Function(String text)? debugLaunchActivationWhatsAppOverride;

/// فتح محادثة واتساب على رقم التفعيل — متانة أندرويد 11+:
/// (1) الرابط المباشر whatsapp://send (يتطلب <queries> المصرّح بها)،
/// (2) احتياط wa.me في المتصفح الخارجي، (3) احتياط أخير بالوضع الافتراضي.
Future<bool> launchActivationWhatsApp(String text) async {
  if (debugLaunchActivationWhatsAppOverride != null) {
    return debugLaunchActivationWhatsAppOverride!(text);
  }
  final phone = kActivationContact.replaceAll('+', '');
  final encoded = Uri.encodeComponent(text);
  final direct = Uri.parse('whatsapp://send?phone=$phone&text=$encoded');
  final web = Uri.parse('https://wa.me/$phone?text=$encoded');
  try {
    if (await canLaunchUrl(direct).timeout(const Duration(milliseconds: 500))) {
      if (await launchUrl(direct, mode: LaunchMode.externalApplication).timeout(const Duration(seconds: 1))) {
        return true;
      }
    }
  } catch (_) {}
  try {
    if (await launchUrl(web, mode: LaunchMode.externalApplication).timeout(const Duration(seconds: 1))) {
      return true;
    }
  } catch (_) {}
  try {
    return await launchUrl(web).timeout(const Duration(seconds: 1)); // آخر احتياط: الوضع الافتراضي للمنصة.
  } catch (_) {
    return false;
  }
}

// ==================== شاشة شراء التطبيق (الخطة الفردية) ====================

/// صف ميزة في شاشة الشراء.
class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;
  const _FeatureRow(this.icon, this.title, this.desc);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: const Color(0xFF7C3AED).withValues(alpha: .10),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: const Color(0xFF7C3AED)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800)),
                  Text(desc,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: AppColors.text2Of(context))),
                ],
              ),
            ),
          ],
        ),
      );
}

/// شاشة «طلب الترخيص وتفعيل الحساب»: جمع بيانات المنشأة والمشترك (إلزامية)
/// + [إرسال طلب الترخيص] عبر واتساب برسالة مجهزة مع معرف الجهاز وكود الترخيص
/// + [تأكيد عملية الشراء] بفحص التفعيل السحابي فوراً دون مسح بيانات.
class PurchaseScreen extends ConsumerStatefulWidget {
  /// اسم الميزة التي قادت المستخدم هنا (للعنوان التسويقي) — اختياري.
  final String? lockedFeature;
  final String? initialDeviceId;
  final String? initialLicenseKey;

  const PurchaseScreen({
    super.key,
    this.lockedFeature,
    this.initialDeviceId,
    this.initialLicenseKey,
  });

  @override
  ConsumerState<PurchaseScreen> createState() => _PurchaseScreenState();
}

class _PurchaseScreenState extends ConsumerState<PurchaseScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _clientNameCtrl;
  late final TextEditingController _storeNameCtrl;
  late final TextEditingController _phoneCtrl;

  String _deviceId = '';
  String _licenseKey = '';
  bool _verifying = false;
  bool _submitted = false;
  bool _loadingDev = true;

  @override
  void initState() {
    super.initState();
    final user = ref.read(currentUserProvider).valueOrNull;
    final devName = ref.read(ownDeviceNameProvider).valueOrNull?.trim() ?? '';
    final st = ref.read(settingsProvider).valueOrNull ?? const {};

    _clientNameCtrl = TextEditingController(
      text: devName.isNotEmpty
          ? devName
          : (user?.name ?? (st['account.name'] ?? '')).trim(),
    );
    _storeNameCtrl = TextEditingController(
      text: (st['businessName'] ?? '').trim(),
    );
    _phoneCtrl = TextEditingController(
      text: (st['phone'] ?? st['whatsapp'] ?? '').trim(),
    );

    if (widget.initialDeviceId != null && widget.initialDeviceId!.isNotEmpty) {
      _deviceId = widget.initialDeviceId!;
      _licenseKey = widget.initialLicenseKey ?? generateLicenseKey(_deviceId);
      _loadingDev = false;
    } else {
      _initIds();
    }
  }

  Future<void> _initIds() async {
    try {
      final repo = ref.read(repoProvider);
      final id = await ensureDeviceId(repo);
      final key = generateLicenseKey(id);
      if (mounted) {
        setState(() {
          _deviceId = id;
          _licenseKey = key;
          _loadingDev = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingDev = false);
    }
  }

  @override
  void dispose() {
    _clientNameCtrl.dispose();
    _storeNameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  /// إرسال طلب الترخيص: التحقق الصارم من الحقول الإجبارية (الاسم، المنشأة، الهاتف)
  /// ومنع المتابعة أو إرسال المعرف بدون ملئها، مع إظهار أخطاء واضحة باللون الأحمر.
  Future<void> _sendActivationRequest() async {
    setState(() => _submitted = true);
    Sfx.click();

    if (!_formKey.currentState!.validate()) {
      Sfx.warning();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('يرجى إدخال اسم المنشأة والمستخدم ورقم الهاتف للمتابعة'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }

    final clientName = _clientNameCtrl.text.trim();
    final storeName = _storeNameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();

    try {
      final repo = ref.read(repoProvider);
      // حفظ بيانات المشترك محلياً في الإعدادات
      await repo.setSetting('businessName', storeName);
      await repo.setSetting('phone', phone);
      await repo.setSetting('whatsapp', phone);
      if (clientName.isNotEmpty) {
        await repo.renameSelfDevice(clientName);
      }
      bump(ref);

      final devId =
          _deviceId.isNotEmpty ? _deviceId : await ensureDeviceId(repo);
      final licenseKey = _licenseKey.isNotEmpty
          ? _licenseKey
          : generateLicenseKey(devId);
      final raw = await hardwareFingerprintRaw() ?? 'fallback:$devId';
      final fp = SubscriptionGuard.fingerprintHash(raw);

      // تسجيل الطلب سحابياً إن وُجد اتصال
      try {
        final st = await repo.settings();
        final url = effectiveBackendUrl(st['cloudBackendUrl']);
        final ws = await SubscriptionGuard.workspaceIdFor(repo);
        if (url.isNotEmpty && ws.isNotEmpty) {
          await SubscriptionGuard.registerLicenseRequest(
            repo,
            backendUrl: url,
            workspaceId: ws,
            clientName: clientName,
            storeName: storeName,
            phone: phone,
            deviceId: devId,
            licenseKey: licenseKey,
          );
        }
      } catch (_) {}

      final msg =
          'مرحباً، أود طلب ترخيص وتفعيل اشتراك تطبيق مدير الحسابات (Nexora):\n'
          '🏢 اسم المنشأة: $storeName\n'
          '👤 اسم العميل / المسؤول: $clientName\n'
          '📱 رقم الهاتف: $phone\n'
          '🔑 معرف الجهاز (Device ID): $devId\n'
          '⚡ كود الترخيص: $licenseKey\n'
          'بصمة التفعيل: $fp';

      final ok = await launchActivationWhatsApp(msg);
      if (!ok) throw Exception('wa-launch-failed');
    } catch (_) {
      if (mounted) {
        showSnack(context, 'تعذّر فتح واتساب — تأكد من تثبيته.', error: true);
      }
    }
  }

  /// التحقق من التفعيل السحابي: فحص قسري لعقدة الاشتراك — إن قلبها
  /// المشغّل إلى active تسري الترقية فوراً على هذا الجهاز.
  Future<void> _confirmPurchase() async {
    setState(() => _verifying = true);
    Sfx.click();
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      // (تفعيل الفردي بنقرة) لا نشترط ضبط المزامنة يدوياً: المستخدم
      // الفردي يتحقق عبر الرابط الرسمي المضمّن برمجياً مباشرة.
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) {
        if (mounted) {
          showSnack(context,
              'فعّل المزامنة السحابية أولاً من الإعدادات ليكتمل التحقق.',
              error: true);
        }
        return;
      }
      // (إصلاح 2026-09-23) التحقق يقرأ عقدة المساحة المرتبطة فعلاً لا أول
      // صف: عضو مجموعة كان يتحقق من اشتراكه الشخصي فيبدو التفعيل كأنه
      // لم يصل («لم يُرصد تفعيل بعد») والمدير فعّله على مساحة المجموعة.
      final ws = await SubscriptionGuard.workspaceIdFor(repo);
      SubscriptionGuard.debugReset(); // تجاوز الكاش — قراءة حقيقية الآن.
      final sub = await SubscriptionGuard.check(repo,
          backendUrl: url, workspaceId: ws, force: true);
      if (!mounted) return;
      if (sub.isSubscribed) {
        Sfx.success();
        bump(ref);
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.verified,
                color: Color(0xFF16A34A), size: 44),
            title: const Text('🎉 تم تفعيل اشتراكك بنجاح'),
            content: const Text(
              'كل المزايا فُتحت فوراً على هذا الجهاز — دون مسح بيانات '
              'أو إعادة تثبيت. شكراً لثقتك!',
              style: TextStyle(height: 1.6),
              textAlign: TextAlign.center,
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ابدأ الاستخدام'),
              ),
            ],
          ),
        );
        if (mounted) Navigator.of(context).maybePop();
      } else {
        Sfx.warning();
        showSnack(
            context,
            'لم يُرصد تفعيل بعد. أرسل كود التفعيل عبر واتساب وسيُفعَّل '
            'اشتراكك خلال دقائق، ثم اضغط هنا مجدداً.',
            error: true);
      }
    } catch (_) {
      if (mounted) {
        showSnack(context, 'تعذّر التحقق — تأكد من اتصال الإنترنت.',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('طلب الترخيص وتفعيل الحساب')),
      body: Form(
        key: _formKey,
        autovalidateMode: _submitted
            ? AutovalidateMode.onUserInteraction
            : AutovalidateMode.disabled,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFF2563EB)],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  const Icon(Icons.workspace_premium,
                      color: Colors.white, size: 44),
                  const SizedBox(height: 8),
                  Text(
                    widget.lockedFeature == null
                        ? 'طلب ترخيص وتفعيل الاشتراك'
                        : '«${widget.lockedFeature}» ميزة مدفوعة',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'أدخل بيانات المنشأة والمسؤول لإصدار رخصة التشغيل وتفعيل كافة القدرات فوراً.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // كرت البيانات الإجبارية
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: AppColors.primary.withValues(alpha: .25),
                  width: 1.2,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.badge_outlined,
                              size: 18, color: AppColors.primary),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'بيانات المشترك والمنشأة (إلزامية)',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w800),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDC2626)
                                .withValues(alpha: .10),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'مطلوب *',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFDC2626),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'يرجى ملء الحقول التالية لمتابعة طلب الترخيص وإرسال معرف الجهاز:',
                      style: TextStyle(
                          fontSize: 11.5, color: AppColors.text2Of(context)),
                    ),
                    const SizedBox(height: 14),

                    // 1. اسم العميل / المسؤول
                    TextFormField(
                      controller: _clientNameCtrl,
                      decoration: InputDecoration(
                        labelText: 'اسم العميل / المسؤول *',
                        hintText: 'مثال: محمد عبدالله',
                        prefixIcon: const Icon(Icons.person_outline, size: 20),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.field),
                        ),
                        isDense: true,
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'يرجى إدخال اسم المنشأة والمستخدم ورقم الهاتف للمتابعة';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),

                    // 2. اسم المنشأة / المحل
                    TextFormField(
                      controller: _storeNameCtrl,
                      decoration: InputDecoration(
                        labelText: 'اسم المنشأة / المحل *',
                        hintText: 'مثال: سوبرماركت النور',
                        prefixIcon:
                            const Icon(Icons.storefront_outlined, size: 20),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.field),
                        ),
                        isDense: true,
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'يرجى إدخال اسم المنشأة والمستخدم ورقم الهاتف للمتابعة';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),

                    // 3. رقم الهاتف / الواتساب
                    TextFormField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: 'رقم الهاتف / الواتساب *',
                        hintText: 'مثال: 771234567 أو +967771234567',
                        prefixIcon: const Icon(Icons.phone_outlined, size: 20),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.field),
                        ),
                        isDense: true,
                      ),
                      validator: (val) {
                        final text = val?.trim() ?? '';
                        if (text.isEmpty) {
                          return 'يرجى إدخال اسم المنشأة والمستخدم ورقم الهاتف للمتابعة';
                        }
                        final digits =
                            text.replaceAll(RegExp(r'[^0-9]'), '');
                        if (digits.length < 7 || digits.length > 15) {
                          return 'يرجى إدخال رقم هاتف صحيح للمتابعة';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // بطاقة معرف الجهاز وكود الترخيص
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.bgOf(context),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: AppColors.borderOf(context),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.devices,
                          size: 16, color: AppColors.primary),
                      const SizedBox(width: 6),
                      const Text('معرف الجهاز (Device ID):',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      if (_deviceId.isNotEmpty)
                        IconButton(
                          tooltip: 'نسخ معرف الجهاز',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 26, minHeight: 26),
                          icon: const Icon(Icons.copy, size: 14),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _deviceId));
                            showSnack(context, 'نُسخ معرف الجهاز ✓');
                          },
                        ),
                    ],
                  ),
                  Text(
                    _loadingDev
                        ? 'جارٍ قراءة معرف الجهاز…'
                        : (_deviceId.isNotEmpty
                            ? _deviceId
                            : 'تعذّر تحديد المعرف'),
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.key,
                          size: 16, color: Color(0xFF7C3AED)),
                      const SizedBox(width: 6),
                      const Text('كود الترخيص:',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      if (_licenseKey.isNotEmpty)
                        IconButton(
                          tooltip: 'نسخ كود الترخيص',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 26, minHeight: 26),
                          icon: const Icon(Icons.copy, size: 14),
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: _licenseKey));
                            showSnack(context, 'نُسخ كود الترخيص ✓');
                          },
                        ),
                    ],
                  ),
                  Text(
                    _licenseKey.isNotEmpty ? _licenseKey : 'NX-PENDING',
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // زر إرسال طلب الترخيص ومعرف الجهاز (واتساب)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF16A34A),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.button),
                ),
              ),
              onPressed: _sendActivationRequest,
              icon: const Icon(Icons.send_rounded),
              label: const Text('إرسال طلب الترخيص ومعرف الجهاز (واتساب)',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
            ),
            const SizedBox(height: 10),

            // زر تأكيد عملية الشراء والتحقق من التفعيل
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.button),
                ),
              ),
              onPressed: _verifying ? null : _confirmPurchase,
              icon: _verifying
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2))
                  : const Icon(Icons.verified_outlined),
              label: Text(
                  _verifying
                      ? 'جارٍ التحقق من التفعيل…'
                      : 'اضغط هنا لتأكيد عملية الشراء والتحقق من التفعيل',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'بعد إرسال الطلب واعتماده من المدير يُفعَّل اشتراكك سحابياً — '
                'اضغط زر التأكيد ليسري فوراً دون مسح بيانات.',
                style:
                    TextStyle(fontSize: 11, color: AppColors.text3Of(context)),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 18),

            // بطاقة شحن كود التفعيل الذاتي (Voucher Key)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF7C3AED).withValues(alpha: .06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: const Color(0xFF7C3AED).withValues(alpha: .25),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.confirmation_number_outlined,
                          color: Color(0xFF7C3AED), size: 20),
                      SizedBox(width: 8),
                      Text(
                        'شحن كود الترخيص (تفعيل ذاتي فوري)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF7C3AED),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'إذا حصلت على كود تفعيل مسبق الدفع (Voucher)، اشحنه هنا لتفعيل حسابك فورياً دون انتظار.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.text2Of(context),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => showVoucherRedeemDialog(context),
                    icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                    label: const Text(
                      'إدخال كود الشحن والتفعيل',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Divider(height: 1),
            const SizedBox(height: 16),

            const Text('✨ المزايا المفتوحة بالاشتراك:',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const _FeatureRow(Icons.category_outlined, 'التصنيفات',
                'إنشاء واستخدام تصنيفات الحسابات والأصناف بلا حدود.'),
            const _FeatureRow(Icons.notifications_active_outlined,
                'الإشعارات والرسائل التلقائية',
                'رسائل الرصيد للعملاء وتنبيهات تلقائية ذكية.'),
            const _FeatureRow(Icons.cloud_upload_outlined,
                'النسخ الاحتياطي السحابي',
                'نسخة يومية آمنة ومزامنة بياناتك عبر السحابة.'),
            const _FeatureRow(Icons.settings_backup_restore_outlined,
                'نقاط الاسترجاع',
                'استرجاع بياناتك لأي نقطة محددة أو دمج قواعد البيانات.'),
            const _FeatureRow(Icons.manage_search_outlined,
                'البحث الشامل المتقدم',
                'بحث فوري عميق في الحسابات والعمليات والتصنيفات.'),
            const _FeatureRow(Icons.devices_other_outlined,
                'تعدد الأجهزة (باقة المؤسسات)',
                'فريق كامل بأدوار وصلاحيات ومزامنة لحظية وسجل تدقيق.'),
          ],
        ),
      ),
    );
  }
}

// ==================== ودجة القفل 🔒 للمزايا المدفوعة ====================

/// تغلّف أي قسم/بلاطة ميزة مدفوعة: مفتوحة = تُعرض كما هي؛ مقفلة = تبقى
/// ظاهرة بتدرج رمادي ومؤشر 🔒، والضغط يعرض رسالة تعريفية ثم شاشة الشراء.
class FeatureGate extends ConsumerWidget {
  /// مفتاح الميزة في featureUnlockedProvider.
  final String featureKey;

  /// اسم الميزة للعرض في الرسالة التعريفية.
  final String featureName;

  /// وصف تسويقي قصير يظهر في الرسالة التعريفية.
  final String description;
  final Widget child;

  const FeatureGate({
    super.key,
    required this.featureKey,
    required this.featureName,
    required this.description,
    required this.child,
  });

  static Future<void> showLockedNotice(
    BuildContext context, {
    required String featureName,
    required String description,
  }) async {
    Sfx.warning();
    final buy = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.lock_outline,
            color: Color(0xFF7C3AED), size: 42),
        title: Text('«$featureName» ميزة مدفوعة'),
        content: Text('$description\n\nفعّل اشتراكك لفتحها فوراً — '
            'بياناتك الحالية تبقى كما هي دون أي مسح.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('لاحقاً'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF7C3AED)),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.workspace_premium, size: 18),
            label: const Text('شراء التطبيق'),
          ),
        ],
      ),
    );
    if (buy == true && context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PurchaseScreen(lockedFeature: featureName)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked =
        ref.watch(featureUnlockedProvider(featureKey)).valueOrNull ?? true;
    if (unlocked) return child;
    // مقفلة: تظل ظاهرة (تشويق) بتدرج رمادي + قفل، والضغط يفتح التعريف.
    return Stack(
      children: [
        // امتصاص كل النقرات الداخلية ثم تحويلها لرسالة التعريف.
        AbsorbPointer(
          child: Opacity(
            opacity: 0.45,
            child: ColorFiltered(
              colorFilter: const ColorFilter.matrix(<double>[
                0.2126, 0.7152, 0.0722, 0, 0, //
                0.2126, 0.7152, 0.0722, 0, 0,
                0.2126, 0.7152, 0.0722, 0, 0,
                0, 0, 0, 1, 0,
              ]),
              child: child,
            ),
          ),
        ),
        Positioned.fill(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => showLockedNotice(context,
                  featureName: featureName, description: description),
              child: Align(
                alignment: Alignment.topLeft,
                child: Container(
                  margin: const EdgeInsets.all(8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C3AED),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock, size: 12, color: Colors.white),
                      SizedBox(width: 4),
                      Text('مدفوعة',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// (باقة المؤسسات) شارة عدّاد المقاعد: «الأجهزة 3/5» — تظهر للمدير في
/// شاشة إدارة المجموعة وتفاصيل الاشتراك.
class SeatUsageBadge extends ConsumerWidget {
  const SeatUsageBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(seatUsageProvider).valueOrNull;
    if (usage == null) return const SizedBox.shrink();
    final (connected, maxSeats) = usage;
    final full = connected >= maxSeats;
    final color = full ? const Color(0xFFDC2626) : const Color(0xFF0EA5E9);
    return Tooltip(
      message: full
          ? 'استُنفدت مقاعد الباقة — رقِّ الاشتراك لإضافة أجهزة'
          : 'الأجهزة المتصلة من أصل الحد الأقصى للباقة',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: .35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(full ? Icons.event_busy : Icons.devices, size: 13,
                color: color),
            const SizedBox(width: 5),
            Text('الأجهزة $connected/$maxSeats',
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w800, color: color)),
          ],
        ),
      ),
    );
  }
}

/// بوابة نقرة لميزة مدفوعة: true = مفتوحة فامضِ؛ false = عُرضت رسالة
/// التعريف (مع زر شاشة الشراء) وعلى المستدعي التوقف.
Future<bool> ensureFeatureUnlocked(
  BuildContext context,
  WidgetRef ref, {
  required String featureKey,
  required String featureName,
  required String description,
}) async {
  bool ok = true;
  try {
    ok = await ref.read(featureUnlockedProvider(featureKey).future);
  } catch (_) {}
  if (ok) return true;
  if (context.mounted) {
    await FeatureGate.showLockedNotice(context,
        featureName: featureName, description: description);
  }
  return false;
}

/// حوار شحن وتفعيل كود الترخيص الذاتي (Voucher Key).
Future<void> showVoucherRedeemDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  bool submitting = false;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.confirmation_number_outlined, color: Color(0xFF7C3AED)),
            SizedBox(width: 8),
            Text('شحن كود الترخيص'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'أدخل كود الشحن مسبق الدفع (Voucher) لتمديد وتفعيل حسابك تلقائياً وبشكل فوري:',
              style: TextStyle(fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'كود الشحن والتفعيل',
                hintText: 'VCH-XXXX-XXXX-XXXX',
                prefixIcon: const Icon(Icons.vpn_key_outlined),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: submitting ? null : () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF7C3AED),
            ),
            onPressed: submitting
                ? null
                : () async {
                    final code = ctrl.text.trim();
                    if (code.isEmpty) return;
                    setState(() => submitting = true);
                    try {
                      final container = ProviderScope.containerOf(context);
                      final repo = container.read(repoProvider);
                      final st = await repo.settings();
                      final backendUrl = effectiveBackendUrl((st['cloudBackendUrl'] ?? '').toString());
                      if (backendUrl.isEmpty) {
                        throw StateError('يرجى تفعيل المزامنة السحابية أولاً');
                      }
                      final wsId = await SubscriptionGuard.workspaceIdFor(repo);
                      final voucher = await CloudControlService.instance.redeemVoucherKey(
                        repo,
                        backendUrl: backendUrl,
                        workspaceId: wsId,
                        rawVoucherCode: code,
                      );
                      if (context.mounted) {
                        Navigator.pop(ctx);
                        Sfx.success();
                        container.read(refreshProvider.notifier).state++;
                        await showDialog<void>(
                          context: context,
                          builder: (c) => AlertDialog(
                            icon: const Icon(Icons.verified, color: Color(0xFF16A34A), size: 48),
                            title: const Text('🎉 تم التفعيل بنجاح!'),
                            content: Text(
                              'تم شحن الحساب بنجاح لمدة ${voucher.durationLabel}.\nكافة المزايا مفعلة الآن.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(height: 1.6),
                            ),
                            actions: [
                              FilledButton(
                                onPressed: () => Navigator.pop(c),
                                child: const Text('رائع'),
                              ),
                            ],
                          ),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        showSnack(context, '$e', error: true);
                        setState(() => submitting = false);
                      }
                    }
                  },
            child: submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('تفعيل وشحن'),
          ),
        ],
      ),
    ),
  );
}

/// شاشة حظر وتجميد الحساب عن بعد (Remote Kill Switch / Freeze Barrier).
class FrozenAccountBarrier extends StatelessWidget {
  const FrozenAccountBarrier({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  color: const Color(0xFFDC2626).withValues(alpha: .12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.lock_rounded, size: 50, color: Color(0xFFDC2626)),
              ),
              const SizedBox(height: 22),
              const Text(
                'تم تعليق الحساب مؤقتاً',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFFDC2626),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'تم إيقاف صلاحيات الوصول لهذا التطبيق عن بُعد بواسطة إدارة النظام.\nيرجى مراجعة الإدارة لتسوية الحساب واستئناف الخدمة.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.6, color: Color(0xFF4B5563)),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF16A34A),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () => launchActivationWhatsApp('السلام عليكم، تم تعليق حساب المنشأة في التطبيق، نرجو المساعدة.'),
                icon: const Icon(Icons.chat_outlined),
                label: const Text('تواصل مع الإدارة (واتساب)', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () async {
                  final tel = Uri.parse('tel:$kActivationContact');
                  try {
                    await launchUrl(tel);
                  } catch (_) {}
                },
                icon: const Icon(Icons.phone),
                label: const Text('اتصال مباشر بالإدارة'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// شاشة التحديث الإجباري عن بعد (Force Update Barrier).
class ForceUpdateBarrier extends StatelessWidget {
  const ForceUpdateBarrier({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB).withValues(alpha: .12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.system_update_rounded, size: 50, color: Color(0xFF2563EB)),
              ),
              const SizedBox(height: 22),
              const Text(
                'تحديث إجباري مطلوب',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF2563EB),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'أصبح إصدار التطبيق المثبت قديماً ولم يعد متوافقاً مع المنظومة السحابية.\nيرجى تنزيل الإصدار الأحدث لمتابعة العمل بأمان.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.6, color: Color(0xFF4B5563)),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () async {
                  final uri = Uri.parse('https://github.com/iggdigd218-dev/Nexora/releases/tag/latest');
                  try {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  } catch (_) {}
                },
                icon: const Icon(Icons.download_rounded),
                label: const Text('تنزيل التحديث الآن', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// شاشة وضع الصيانة السحابي المؤقت (Maintenance Mode Barrier).
class MaintenanceModeBarrier extends ConsumerStatefulWidget {
  const MaintenanceModeBarrier({super.key});

  @override
  ConsumerState<MaintenanceModeBarrier> createState() =>
      _MaintenanceModeBarrierState();
}

class _MaintenanceModeBarrierState
    extends ConsumerState<MaintenanceModeBarrier> {
  bool _checking = false;

  Future<void> _recheck() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final repo = ref.read(repoProvider);
      await CloudControlService.instance.checkControlCenter(repo);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable:
          CloudControlService.instance.maintenanceMessageNotifier,
      builder: (ctx, msg, _) {
        final displayMsg = msg.trim().isNotEmpty
            ? msg.trim()
            : 'الخوادم السحابية قيد الصيانة المؤقتة لتحديث الخدمات وترقية قواعد البيانات.\nنعتذر عن الإزعاج المؤقت، يرجى المحاولة بعد قليل.';

        return Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD97706).withValues(alpha: .12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.construction_rounded,
                        size: 50, color: Color(0xFFD97706)),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'النظام قيد الصيانة المؤقتة',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFFD97706),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    displayMsg,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 14, height: 1.6, color: Color(0xFF4B5563)),
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFD97706),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _checking ? null : _recheck,
                    icon: _checking
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.refresh_rounded),
                    label: Text(
                      _checking ? 'جارِ التحقق...' : 'إعادة الفحص الآن',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () => launchActivationWhatsApp(
                        'السلام عليكم، بخصوص وضع صيانة النظام المؤقت.'),
                    icon: const Icon(Icons.chat_outlined),
                    label: const Text('تواصل مع الدعم الفني'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// نافذة التنبيهات السحابية الحية (In-App Cloud Alerts Sheet).
Future<void> showCloudAlertsSheet(BuildContext context, WidgetRef ref) async {
  final alerts = CloudControlService.instance.cloudAlertsNotifier.value;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.notifications_active_rounded,
                    color: Color(0xFF7C3AED)),
                const SizedBox(width: 8),
                const Text(
                  'التنبيهات والإشعارات السحابية',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (alerts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(
                  child: Text('لا توجد تنبيهات جديدة في الوقت الحالي'),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.55,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: alerts.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final a = alerts[i];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      leading: CircleAvatar(
                        backgroundColor:
                            a.isRead ? Colors.grey.shade200 : const Color(0xFFEDE9FE),
                        child: Icon(
                          Icons.campaign_rounded,
                          color: a.isRead
                              ? Colors.grey
                              : const Color(0xFF7C3AED),
                          size: 20,
                        ),
                      ),
                      title: Text(
                        a.title,
                        style: TextStyle(
                          fontWeight:
                              a.isRead ? FontWeight.w600 : FontWeight.w800,
                          fontSize: 13.5,
                        ),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          a.body,
                          style: const TextStyle(fontSize: 12, height: 1.4),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
