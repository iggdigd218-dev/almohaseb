// شاشة الإعداد الأول (Onboarding): تظهر مرة واحدة فقط عند أول تشغيل
// وقاعدة بيانات فارغة، وتسأل المستخدم عن نمط الاستخدام:
//   1) استخدام شخصي / متجر فردي  → وضع مستقل تماماً بلا أي مزامنة.
//   2) ربط شبكي / متجر متعدد الأجهزة → معالج إنشاء/انضمام مجموعة الموجود.
// بعد اختيار البطاقة يظهر إعداد مصغّر: اسم المتجر + العملة الأساسية.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/accounting.dart';
import '../core/factory_reset.dart';
import '../core/security.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../core/cloud_config.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import '../data/sync/account_workspace.dart';
import '../data/sync/cloud_join.dart';
import '../data/sync/firebase_auth_service.dart';
import '../data/sync/google_auth_service.dart';
import 'account_section.dart' show provisionCloudAfterSignIn;
import 'group_management_screen.dart';
import 'home_shell.dart';
import 'lock_gate.dart';

/// مفتاح علم «أُكمل الإعداد الأول» في جدول الإعدادات.
const kOnboardingDoneKey = 'has_completed_onboarding';

/// هل يجب عرض شاشة الإعداد الأول؟
/// تُعرض فقط إذا: لم يكتمل الإعداد من قبل، والوضع مستقل،
/// وقاعدة البيانات فارغة (لا حسابات إطلاقاً — مستخدم جديد كلياً).
/// أي حالة أخرى (ترقية تطبيق قائم، عضو مجموعة...) تُعلَّم مكتملة تلقائياً
/// حتى لا يُعاد الفحص في كل تشغيل.
Future<bool> shouldShowOnboarding(Repo repo) async {
  final st = await repo.settings();
  if (st[kOnboardingDoneKey] == '1') return false;
  final mode = await repo.workspaceMode();
  if (mode != 'standalone') {
    await repo.setSetting(kOnboardingDoneKey, '1');
    return false;
  }
  final accounts =
      await repo.accounts(includeArchived: true, includeDeleted: true);
  if (accounts.isNotEmpty) {
    await repo.setSetting(kOnboardingDoneKey, '1');
    return false;
  }
  return true;
}

/// يحفظ نتيجة الإعداد المصغّر ويعلّم الإعداد الأول مكتملاً.
/// لا يغيّر workspaceMode — الوضع المستقل هو الافتراضي أصلاً،
/// ومسار «متعدد الأجهزة» يمر عبر معالج المجموعة الذي يضبط الوضع بنفسه.
Future<void> completeOnboarding(
  Repo repo, {
  required String storeName,
  required String currencyCode,
}) async {
  final name = storeName.trim().isEmpty ? 'متجري' : storeName.trim();
  await repo.setSetting('businessName', name);
  await repo.setSetting('defaultCurrency', currencyCode);
  await repo.setSetting(kOnboardingDoneKey, '1');
}

class OnboardingScreen extends ConsumerStatefulWidget {
  final String? initialNotice;
  const OnboardingScreen({super.key, this.initialNotice});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  /// نمط الحساب المختار — يُضبط لحظة فتح نافذة الخيار ('personal'/'network').
  String? _choice;

  String _name = 'متجري';
  String _currency = 'YER';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialNotice != null && widget.initialNotice!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (dctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 24),
                SizedBox(width: 8),
                Text('تنبيه إنهاء الارتباط', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Text(widget.initialNotice!),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dctx).pop(),
                child: const Text('حسناً فهمت'),
              ),
            ],
          ),
        );
      });
    }
  }

  /// الانتقال إلى الشاشة الرئيسية (وإلى معالج المجموعة عند الاختيار الشبكي).
  Future<void> _finishAndNavigate() async {
    if (!mounted) return;
    final nav = Navigator.of(context);
    final goNetwork = _choice == 'network';
    nav.pushReplacement(
      MaterialPageRoute(builder: (_) => const LockGate(child: HomeShell())),
    );
    if (goNetwork) {
      // معالج المجموعة الموجود (إنشاء عبر QR/سحابة أو انضمام بالمسح).
      nav.push(
        MaterialPageRoute(builder: (_) => const GroupManagementScreen()),
      );
    }
  }

  /// المتابعة بدون حساب Google — عمل محلي كامل (المحلية أولاً).
  Future<void> _startLocal() async {
    if (_busy || _choice == null) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      await completeOnboarding(
        repo,
        storeName: _name,
        currencyCode: _currency,
      );
      final isIndiv = _choice == 'personal';
      await repo.setSetting(
          'account.type', isIndiv ? 'individual' : 'enterprise');
      await repo.restoreManagerOwnership(syncToCloud: false);
      await repo.checkAndAutoPromoteManager();
      await repo.ensureSelfPermissionRow(roleCode: 'admin');
      bump(ref);
      await _finishAndNavigate();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// البدء الفوري كمدير أساسي للمجموعة محلياً وبلا أي انتظار للشبكة (المحلية أولاً).
  Future<void> _startNetworkManagerDirect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      await completeOnboarding(
        repo,
        storeName: _name,
        currencyCode: _currency,
      );
      await repo.setSetting('account.type', 'enterprise');
      await repo.restoreManagerOwnership(syncToCloud: false);
      await repo.checkAndAutoPromoteManager();
      await repo.ensureSelfPermissionRow(roleCode: 'admin');
      bump(ref);
      if (!mounted) return;
      await _finishAndNavigate();
    } catch (_) {
      if (mounted) await _finishAndNavigate();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// إكمال الإعداد ثم ربط حساب Google بدخول صريح ومرئي للمستخدم.
  Future<void> _startWithGoogle() async {
    if (_busy || _choice == null) return;
    setState(() => _busy = true);
    try {
      await _signInWithGoogle();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// (حساب Google) تسجيل الدخول الفوري والاعتماد كمدير أساسي محلياً واسترجاع مساحة العمل السحابية.
  Future<void> _signInWithGoogle() async {
    Sfx.click();
    final repo = ref.read(repoProvider);
    final db = await repo.database;
    if (!mounted) return;
    final auth = GoogleAuthService(db);

    String statusText = 'جاري فتح نافذة اختيار حساب Google...';
    StateSetter? updateDialog;
    bool dialogOpen = true;
    bool userCancelled = false;

    // نافذة تقدم صريحة ومرنة لا تحبس المستخدم أبداً
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dctx) => PopScope(
        canPop: true,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            dialogOpen = false;
            userCancelled = true;
          }
        },
        child: StatefulBuilder(
          builder: (ctx, setDialogState) {
            updateDialog = setDialogState;
            return Center(
              child: Card(
                elevation: 12,
                margin: const EdgeInsets.symmetric(horizontal: 24),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                  side: BorderSide(
                    color: Theme.of(context).primaryColor.withValues(alpha: 0.2),
                  ),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 44,
                        height: 44,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        statusText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14.5,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: () {
                          userCancelled = true;
                          dialogOpen = false;
                          Navigator.of(ctx).pop();
                        },
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: const Text('إلغاء والمتابعة محلياً'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    try {
      // طلب حساب Google بمهلة مرنة
      final r = await auth.signIn().timeout(
        const Duration(seconds: 40),
        onTimeout: () => const GoogleAuthResult.fail(
            'انتهت مهلة استجابة Google — تأكد من الاتصال وأعد المحاولة.'),
      );

      if (userCancelled || !mounted) return;

      final gu = r.user;
      if (gu == null) {
        if (dialogOpen && mounted) {
          dialogOpen = false;
          Navigator.of(context, rootNavigator: true).pop();
        }
        Sfx.error();
        if (mounted) {
          if (r.error == 'تم إلغاء تسجيل الدخول') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'تم إلغاء تسجيل الدخول عبر Google — يمكنك المحاولة مجدداً أو المتابعة محلياً'),
              ),
            );
          } else {
            await showDialog<void>(
              context: context,
              builder: (errCtx) => AlertDialog(
                title: const Row(
                  children: [
                    Icon(Icons.error_outline_rounded, color: Colors.redAccent),
                    SizedBox(width: 8),
                    Text('تعذّر تسجيل الدخول'),
                  ],
                ),
                content: Text(r.error ??
                    'حدث خطأ أثناء الاتصال بحساب Google. يمكنك البدء محلياً ثم ربط الحساب لاحقاً.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(errCtx).pop(),
                    child: const Text('حسناً'),
                  ),
                ],
              ),
            );
          }
        }
        return;
      }

      // تحديث حالة النافذة بعد التقاط الحساب فوراً
      statusText =
          'تم التحقق من الحساب: ${gu.email}\nجاري تهيئة مساحة العمل والاشتراك...';
      updateDialog?.call(() {});

      FirebaseAccount? account;
      final tok = gu.idToken ?? '';
      if (tok.isNotEmpty) {
        try {
          account = await FirebaseAuthRest.signInWithGoogleIdToken(tok)
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
      account ??= FirebaseAccount(
        uid: gu.id,
        email: gu.email,
        displayName: gu.displayName ?? '',
      );

      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);

      // نحفظ الاسم والعملة كقيم مبدئية قبل الفحص السحابي، فإذا وُجدت مساحة سابقة
      // مرتبطة بهذا البريد على السحابة تستبدلها بيانات المنشأة المسترجعة بالكامل!
      await completeOnboarding(repo,
          storeName: _name, currencyCode: _currency);
      // عند التسجيل بواسطة البريد الإلكتروني يُعتمد المستخدم كمنشئ/مالك حساب منشأة
      await repo.setSetting('account.type', 'enterprise');

      AccountLinkOutcome outcome = AccountLinkOutcome.migrated;
      if (url.isNotEmpty) {
        try {
          outcome = await AccountWorkspace.linkAccountOnly(
            repo,
            backendUrl: url,
            account: account,
          ).timeout(const Duration(seconds: 25));
        } catch (_) {
          outcome = AccountLinkOutcome.migrated;
        }
      }

      await repo.setSetting('account.type', 'enterprise');
      await FirebaseAuthRest.saveSession(repo, account);
      if (account.email.trim().isNotEmpty) {
        await repo.setSetting('account.email', account.email.trim());
        await repo.setSetting('email', account.email.trim());
      }
      await repo.restoreManagerOwnership();
      await repo.checkAndAutoPromoteManager();
      await repo.ensureSelfPermissionRow(roleCode: 'admin');

      if (outcome == AccountLinkOutcome.switched) {
        // استُرجعت مساحة سابقة قائمة — ندخل مباشرة إلى الرئيسية دون فتح معالج إنشاء مجموعة جديدة
        _choice = 'personal';
        statusText =
            '✅ تم استرجاع مساحة عمل منشأتك وبياناتها بنجاح!\nجاري الدخول كمدير أساسي...';
      } else {
        statusText =
            '✅ تم اعتماد جهازك كمدير أساسي للمنشأة!\nجاري فتح التطبيق...';
      }
      updateDialog?.call(() {});

      if (url.isNotEmpty) {
        unawaited(provisionCloudAfterSignIn(repo, ref, url));
      }

      await Future.delayed(const Duration(milliseconds: 500));
      if (dialogOpen && mounted) {
        dialogOpen = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
      bump(ref);
      await _finishAndNavigate();
    } catch (e) {
      if (dialogOpen && mounted) {
        dialogOpen = false;
        try {
          Navigator.of(context, rootNavigator: true).pop();
        } catch (_) {}
      }
      if (mounted) {
        await _startNetworkManagerDirect();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 720;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 28, 22, 28),
              children: [
                // ---------- الترويسة ----------
                // (2026-09-24) علامة الهوية: العربة نفسها في أيقونة التطبيق.
                Icon(Icons.shopping_cart_rounded,
                    size: 58, color: AppColors.primaryOf(context)),
                const SizedBox(height: 14),
                Text(
                  'مرحباً بك في سجل الحسابات',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'اختر نمط الاستخدام الأنسب لعملك للبدء في ثوانٍ',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14.5,
                    color: AppColors.text2Of(context),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 26),
                // ---------- بطاقتا الاختيار ----------
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _personalCard()),
                      const SizedBox(width: 14),
                      Expanded(child: _networkCard()),
                    ],
                  )
                else ...[
                  _personalCard(),
                  const SizedBox(height: 14),
                  _networkCard(),
                ],
                const SizedBox(height: 16),
                const SizedBox(height: 4),
                // (طلب 2026-09-19) حذف كامل من الجهاز والسحابة — من نفس
                // الصفحة، وبعده لا استرجاع للبيانات ولا لموقع المجموعة.
                Center(
                  child: TextButton.icon(
                    onPressed: _busy ? null : _purgeEverything,
                    icon: const Icon(Icons.delete_forever_outlined,
                        size: 17, color: Colors.red),
                    label: const Text(
                      'حذف كامل من الجهاز والسحابة',
                      style: TextStyle(
                          fontSize: 12.5,
                          color: Colors.red,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // (قانون 2026-09-19) الإعداد يتم داخل نافذة الخيار نفسها —
                // هنا مؤشر انشغال فقط ريثما يكتمل الحفظ أو تسجيل Google.
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _personalCard() => _ModeCard(
        selected: _choice == 'personal',
        icon: Icons.person_outline_rounded,
        bigIcon: Icons.storefront_rounded,
        color: const Color(0xFF16A34A),
        title: 'استخدام شخصي / متجر فردي',
        badge: 'سريع وبسيط',
        description: 'كل بياناتك على هذا الجهاز فقط — بلا مزامنة ولا شبكات. '
            'مثالي للمتجر الواحد ودفتر الديون الشخصي.',
        onTap: () => _openModeWindow('personal'),
      );

  Widget _networkCard() => _ModeCard(
        selected: _choice == 'network',
        icon: Icons.devices_rounded,
        bigIcon: Icons.hub_rounded,
        color: const Color(0xFF0EA5E9),
        title: 'ربط شبكي / متجر متعدد الأجهزة',
        badge: 'مزامنة وتعاون',
        description: 'اربط أكثر من جهاز على نفس الحسابات: مدير وكاشير '
            'ومدخل بيانات — مزامنة فورية تلقائية بين الجميع.',
        onTap: () => _openModeWindow('network'),
      );

  /// (طلب 2026-09-19) «حذف كامل من كل مكان»: الجهاز + السحابة — لا يبقى
  /// ما يُسترجع: لا البيانات ولا موقع الجهاز في مجموعته (تُحذف بصمة
  /// device_index وفهرس Google وقيود العضوية). الاشتراك المدفوع وحده
  /// يبقى أصلاً مالياً.
  Future<void> _purgeEverything() async {
    if (_busy) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ حذف كامل من الجهاز والسحابة'),
        content: const Text(
          'سيُحذف كل شيء نهائياً ومن كل مكان:\n\n'
          '• كل البيانات المحلية على هذا الجهاز.\n'
          '• كل بياناتك من السحابة (المساحة، النسخ، السجل).\n'
          '• موقع جهازك في مجموعته (إن كان عضواً) وبصمة الجهاز وفهرس '
          'حساب Google.\n\n'
          'بعد هذا الحذف لا يمكن استرجاع بياناتك ولا موقعك في المجموعة '
          'أبداً. يُستثنى الاشتراك المدفوع فقط.\n\n'
          'هل أنت متأكد تماماً؟',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف كل شيء من كل مكان'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final authed = await Security.authenticate(
      reason: 'أكّد هويتك للحذف الكامل من الجهاز والسحابة',
    );
    if (!authed) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('لم تكتمل المصادقة — أُلغي الحذف')));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repoProvider);
      final engine = ref.read(syncEngineProvider);
      try {
        engine.stop();
      } catch (_) {}
      // 1) السحابة: قيود الجهاز تُ مسح من كل مكان (عضواً كان أو مالكاً).
      try {
        final st = await repo.settings();
        final url = effectiveBackendUrl(st['cloudBackendUrl']);
        if (url.isNotEmpty) {
          await CloudJoin.purgeDeviceEverywhere(repo, backendUrl: url);
        }
        final db = await repo.database;
        try {
          await GoogleAuthService(db).signOut();
        } catch (_) {}
      } catch (_) {}
      // 2) الجهاز: مسح كامل (القاعدة + الوسائط + ملفات الاقتران).
      await FactoryReset.wipeAllLocalData();
      Sfx.success();
      // 3) إقلاع نظيف وبقاء في شاشة الترحيب — نظيفاً تماماً.
      try {
        await repo.initSyncInfra().timeout(const Duration(seconds: 8));
      } catch (_) {}
      try {
        await engine.start();
      } catch (_) {}
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('✅ تم الحذف الكامل — الجهاز والسحابة نظيفان'),
          backgroundColor: Color(0xFF16A34A)));
      setState(() => _choice = null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تعذّر الحذف الكامل: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// (قانون 2026-09-19) الضغط على بطاقة النوع يفتح **نافذة جديدة** خاصة
  /// بالخيار — بلا أي قائمة منسدلة — فيها وصف كامل لنوع الحساب ثم الإعداد
  /// السريع (الاسم + العملة بشرائح اختيار) وزرّا Google / المتابعة محلياً.
  Future<void> _openModeWindow(String mode) async {
    if (_busy) return;
    Sfx.click();
    setState(() => _choice = mode);
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _ModeWindow(
        mode: mode,
        initialName: _name,
        initialCurrency: _currency,
        onGoogle: (name, currency) async {
          _name = name;
          _currency = currency;
          Navigator.of(ctx).pop();
          await _startWithGoogle();
        },
        onSkip: (name, currency) async {
          _name = name;
          _currency = currency;
          Navigator.of(ctx).pop();
          await _startLocal();
        },
      ),
    );
  }
}

/// بطاقة اختيار نمط الاستخدام: حدود عالية التباين وحالة اختيار واضحة.
class _ModeCard extends StatefulWidget {
  final bool selected;
  final IconData icon;
  final IconData bigIcon;
  final Color color;
  final String title;
  final String badge;
  final String description;
  final VoidCallback onTap;
  const _ModeCard({
    required this.selected,
    required this.icon,
    required this.bigIcon,
    required this.color,
    required this.title,
    required this.badge,
    required this.description,
    required this.onTap,
  });

  @override
  State<_ModeCard> createState() => _ModeCardState();
}

class _ModeCardState extends State<_ModeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    final c = widget.color;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
        decoration: BoxDecoration(
          color: sel
              ? c.withValues(alpha: .08)
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: sel ? c : Theme.of(context).dividerColor,
            width: sel ? 2.4 : 1.4,
          ),
          boxShadow: (_hover || sel)
              ? [
                  BoxShadow(
                    color: c.withValues(alpha: .18),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(widget.bigIcon, color: c, size: 28),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: c.withValues(alpha: .35)),
                        ),
                        child: Text(
                          widget.badge,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: c,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Icon(widget.icon, size: 18, color: c),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (sel)
                        Icon(Icons.check_circle_rounded, color: c, size: 22),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.description,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.55,
                      color: AppColors.text2Of(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// (قانون 2026-09-19) نافذة خيار نوع الحساب: وصف موسّع للنوع + إعداد
/// سريع (اسم النشاط + العملة بشرائح اختيار — بلا قوائم منسدلة) + زرّا
/// «ربط بحساب Google» و«المتابعة بدون حساب».
class _ModeWindow extends StatefulWidget {
  final String mode; // 'personal' | 'network'
  final String initialName;
  final String initialCurrency;
  final Future<void> Function(String name, String currency) onGoogle;
  final Future<void> Function(String name, String currency) onSkip;
  const _ModeWindow({
    required this.mode,
    required this.initialName,
    required this.initialCurrency,
    required this.onGoogle,
    required this.onSkip,
  });

  @override
  State<_ModeWindow> createState() => _ModeWindowState();
}

class _ModeWindowState extends State<_ModeWindow> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.initialName);
  late String _currency = widget.initialCurrency;
  bool _busy = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit(Future<void> Function(String, String) action) {
    if (_busy) return;
    setState(() => _busy = true);
    final name =
        _nameCtrl.text.trim().isEmpty ? 'متجري' : _nameCtrl.text.trim();
    action(name, _currency);
  }

  @override
  Widget build(BuildContext context) {
    final personal = widget.mode == 'personal';
    final color = personal ? const Color(0xFF16A34A) : const Color(0xFF0EA5E9);
    final title = personal ? 'حساب فردي' : 'حساب مؤسسة';
    final icon = personal ? Icons.storefront_rounded : Icons.hub_rounded;
    final lead = personal
        ? 'مناسب للمتجر الواحد ودفتر الديون الشخصي — كل بياناتك على هذا '
            'الجهاز، وإعداداتك محصورة وبسيطة.'
        : 'مناسب للمنشآت متعددة الأجهزة والفروع — مزامنة سحابية فورية '
            'وإعدادات مؤسسة كاملة.';
    final bullets = personal
        ? const [
            '• بياناتك محلية على هذا الجهاز — سرعة وبساطة بلا تعقيد.',
            '• لا يمكن إنشاء مجموعات من الحساب الفردي إطلاقاً.',
            '• يمكنك الانضمام لاحقاً إلى مؤسسة قائمة عبر رمز دعوة المدير.',
            '• زر «حذف الحساب» في الإعدادات يمسح كل بياناتك نهائياً '
                '(عدا بصمة الجهاز والاشتراك المدفوع).',
          ]
        : const [
            '• أنشئ مجموعتك وكن مديرها الوحيد — لا مدير ثانياً أبداً.',
            '• اربط أجهزة الكاشير والمحاسبين بدعوات QR أو رمز من 6 أرقام.',
            '• مزامنة فورية للعمليات والأرصدة بين كل الأجهزة.',
            '• إعدادات المؤسسة الكاملة: الأجهزة، الصلاحيات، الاشتراك، '
                'والنسخ السحابي.',
            '• هوية Google دائمة: مؤسستك تعود كاملة على أي جهاز بتسجيل واحد.',
          ];
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(icon, color: color, size: 30),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    tooltip: 'إغلاق',
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(lead,
                  style: TextStyle(
                      fontSize: 13.5,
                      height: 1.6,
                      color: AppColors.text2Of(context))),
              const SizedBox(height: 10),
              for (final b in bullets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(b,
                      style: const TextStyle(fontSize: 12.5, height: 1.55)),
                ),
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 14),
              TextField(
                controller: _nameCtrl,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'اسم المتجر / النشاط',
                  prefixIcon: Icon(Icons.store_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              const Text('العملة الأساسية',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in kDefaultCurrencies)
                    ChoiceChip(
                      label: Text('${c.symbol} ${c.code}'),
                      selected: _currency == c.code,
                      onSelected: (_) => setState(() => _currency = c.code),
                    ),
                ],
              ),
              if (!personal) ...[
                const SizedBox(height: 12),
                Text(
                  'بعد الإكمال سيفتح معالج المجموعة: أنشئ مجموعتك من هذا '
                  'الجهاز أو اربط أجهزة فريقك.',
                  style: TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      color: AppColors.text3Of(context)),
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _submit(widget.onGoogle),
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.account_circle_outlined),
                  label: const Text('ربط بحساب Google والمتابعة',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _submit(widget.onSkip),
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: const Text('المتابعة بدون حساب (محلياً)',
                      style: TextStyle(fontSize: 14)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
