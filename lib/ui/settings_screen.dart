import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_version.dart';
import '../core/db_init.dart' show isDesktop;
import '../core/factory_reset.dart';
import '../core/models.dart';
import '../core/security.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import '../data/sync/auto_backup.dart';
import '../data/sync/cloud_join.dart';
import '../data/sync/device_id.dart';
import '../data/sync/firebase_auth_service.dart';
import '../data/sync/google_auth_service.dart';
import '../data/sync/workspace_service.dart';
import 'onboarding_screen.dart';
import '../services/floating_pos_service.dart';
import 'splash.dart' show SplashScreen;
import 'trial_ui.dart' show SubscriptionDetailsSection;
import 'update_section.dart';
import 'account_section.dart';
import 'appearance_screen.dart';
import 'join_approval_flow.dart' show startJoinApprovalFlow;
import 'package:url_launcher/url_launcher.dart';
import 'logout_flow.dart' show showLogoutRequestsSheet;
import 'group_management_screen.dart';
import 'support_chat_screen.dart';
import 'widgets.dart';
import '../core/cloud_config.dart';
import '../core/platform_info.dart';

/// الإعدادات — نقل مفاتيح `settings.js` كاملة، مع حفظ صريح بزر واحد.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

/// مفاتيح المؤسسة القابلة للتحرير النصي، بالترتيب المعروض.
const _orgFields = <(String, String, IconData, TextInputType?, int)>[
  ('businessName', 'اسم المؤسسة', Icons.business_outlined, null, 1),
  ('businessNameEn', 'الاسم بالإنجليزية', Icons.translate, null, 1),
  ('address', 'العنوان', Icons.location_on_outlined, null, 2),
  ('phone', 'الهاتف', Icons.phone_outlined, TextInputType.phone, 1),
  ('whatsapp', 'واتساب', Icons.chat_outlined, TextInputType.phone, 1),
  (
    'email',
    'البريد الإلكتروني',
    Icons.email_outlined,
    TextInputType.emailAddress,
    1,
  ),
  (
    'managerName',
    'اسم المسؤول (يظهر على السندات)',
    Icons.badge_outlined,
    null,
    1,
  ),
  ('voucherFooter', 'تذييل السند', Icons.notes_outlined, null, 2),
  (
    'defaultVoucherNotes',
    'ملاحظات وشروط افتراضية في السند',
    Icons.rule_outlined,
    null,
    2,
  ),
];

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _ctrls = <String, TextEditingController>{};
  bool _dirty = false;
  bool _saving = false;
  bool _loaded = false;
  bool _bioSupported = false;
  String _bioLabel = '…';

  @override
  void initState() {
    super.initState();
    _checkBiometrics();
  }

  /// نسخة احتياطية محلية لجهاز العضو — تُكتب في مستندات التطبيق فقط.
  Future<void> _createLocalBackup(BuildContext context) async {
    try {
      final repo = ref.read(repoProvider);
      final payload = await repo.exportForLocalBackup(withImages: true);
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final f = File('${dir.path}/nexora-local-backup-$ts.nexora');
      await f.writeAsString(jsonEncode(payload));
      if (context.mounted) {
        showSnack(context, '✅ حُفظت نسخة محلية: ${f.path.split('/').last}');
      }
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر إنشاء النسخة: $e', error: true);
      }
    }
  }

  /// (استرداد طارئ — 1) المالك الحالي يعيد الإدارة للمالك السابق طواعية
  /// بنقرة واحدة — يعمل حتى لو كانت أزرار الإدارة الأخرى لا تظهر.
  Future<void> _handbackOwnership(BuildContext context, String prevName) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.assignment_return_outlined,
            color: Color(0xFFB45309), size: 40),
        title: const Text('إرجاع الإدارة للمالك السابق'),
        content: Text(
          'ستعود ملكية مساحة العمل فوراً إلى «$prevName» ويصله إشعار: '
          '«لقد تم استلام صلاحية المدير وعادت إليك».\n\n'
          'سيتحول جهازك إلى عضو بدور «عرض فقط» (يمكن للمدير تغييره '
          'لاحقاً).\n\nهل تريد المتابعة؟',
          style: const TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB45309)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إرجاع الإدارة'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final name =
          await ref.read(repoProvider).handbackOwnershipToPreviousOwner();
      try {
        await ref.read(syncEngineProvider).forceSyncNow();
      } catch (_) {}
      bump(ref);
      Sfx.success();
      if (context.mounted) {
        showSnack(context,
            '✅ أُرجعت الإدارة إلى «$name» — وصله الإشعار وأنت الآن عضو.');
      }
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر الإرجاع: $e', error: true);
      }
    }
  }

  /// (استرداد طارئ — 2) منشئ المساحة يسترد الملكية سيادياً: تحقق سحابي
  /// من creator.json ثم استعادة فورية + بث لكل الأجهزة وتحديث roster.
  Future<void> _creatorRecover(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.workspace_premium,
            color: Color(0xFF7C3AED), size: 40),
        title: const Text('استرداد ملكية مساحة العمل'),
        content: const Text(
          'أنت منشئ هذه المساحة — سجلك محفوظ في السحابة بشكل دائم.\n\n'
          'سيتم التحقق من سجل المنشئ سحابياً ثم تستعيد الملكية فوراً: '
          'تصبح أنت المدير، ويتحول المالك الحالي إلى عضو، ويُبثّ التغيير '
          'لكل الأجهزة.\n\nهل تريد الاسترداد الآن؟',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF7C3AED)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('استرداد الملكية'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      try {
        await ref.read(repoProvider).creatorRecoverOwnership();
      } catch (_) {
        await ref.read(repoProvider).restoreManagerOwnership();
      }
      try {
        await ref.read(syncEngineProvider).forceSyncNow();
      } catch (_) {}
      bump(ref);
      Sfx.success();
      if (context.mounted) {
        showSnack(context, '✅ استُردت ملكية مساحة العمل — أنت المدير من جديد.');
      }
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر الاسترداد: $e', error: true);
      }
    }
  }

  /// (صمام أمان) المدير السابق يسترجع الإدارة خلال 24 ساعة من تسليم
  /// متعثر — تأكيد صريح ثم استعادة محلية + بث سيادي لكل الأجهزة.
  Future<void> _reclaimOwnership(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.settings_backup_restore_rounded,
            color: Color(0xFFB45309), size: 40),
        title: const Text('استرجاع إدارة المجموعة'),
        content: const Text(
          'ستستعيد ملكية المجموعة وتصبح المدير من جديد، ويتحول الجهاز '
          'الذي سلّمته الإدارة إلى عضو.\n\n'
          'استخدم هذا فقط إذا تعذّر تفعيل الإدارة على الجهاز الجديد.\n\n'
          'هل تريد المتابعة؟',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB45309)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('استرجاع الإدارة'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(repoProvider).reclaimOwnership();
      try {
        await ref.read(syncEngineProvider).forceSyncNow();
      } catch (_) {}
      bump(ref);
      Sfx.success();
      if (context.mounted) {
        showSnack(context, '✅ استُرجعت الإدارة — أنت المدير من جديد.');
      }
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر الاسترجاع: $e', error: true);
      }
    }
  }

  /// (دفعة 58 — متطلب 11) العضو يطلب مغادرة المجموعة: تأكيد ثم إرسال
  /// الطلب للسحابة — المدير يوافق فيُطرد الجهاز نظيفاً (شاهدة إبطال تصل
  /// عبر SSE فيعيد الجهاز نفسه مستقلاً تلقائياً).
  Future<void> _requestLeaveGroup(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.logout, color: Colors.orange, size: 40),
        title: const Text('طلب مغادرة المجموعة'),
        content: const Text(
          'سيُرسل طلبك إلى مدير المجموعة. بعد موافقته تُحذف بيانات '
          'المجموعة من جهازك نهائياً ويعود جهازك مستقلاً.\n\nهل أنت متأكد؟',
          style: TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إرسال الطلب'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final repo = ref.read(repoProvider);
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) {
        if (context.mounted) {
          showSnack(context, 'لا يوجد اتصال سحابي مهيأ على هذا الجهاز.',
              error: true);
        }
        return;
      }
      // (3.71.0 — طلب لا يضل) المساحة الحتمية نفسها التي يرتبط بها محرك
      // المزامنة: الطلب كان يُكتب لمساحة شخصية ميتة فلا يراه المدير أبداً.
      // والمدير لا يرسل طلب مغادرة لنفسه — معلّق إلى الأبد بلا مُعتمِد.
      if (await repo.isWorkspaceOwner()) {
        if (context.mounted) {
          showSnack(context,
              'أنت مدير المجموعة — لا يوجد مدير أعلى ليوافق على مغادرتك. '
              'استخدم «تسليم الإدارة» أو «حل المجموعة» من إدارة المجموعة.');
        }
        return;
      }
      final db = await repo.database;
      final ws = await ensureWorkspace(db, repo: repo);
      final ourId = await ensureDeviceId(repo);
      await CloudJoin.requestLeave(repo, backendUrl: url, workspaceId: ws);
      Sfx.success();
      if (!context.mounted) return;

      // فتح نافذة انتظار موافقة المدير والمراقبة اللحظية للقرار
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) => _LeavePendingDialog(
          backendUrl: url,
          workspaceId: ws,
          deviceId: ourId,
          repo: repo,
          ref: ref,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر إرسال الطلب: $e', error: true);
      }
    }
  }

  Future<void> _checkBiometrics() async {
    final ok = await Security.biometricsAvailable();
    final label = await Security.availableLabel();
    if (mounted) {
      setState(() {
        _bioSupported = ok;
        _bioLabel = label;
      });
    }
  }

  /// نملأ الحقول مرة واحدة فقط حتى لا يُمحى ما يكتبه المستخدم عند التحديث.
  void _hydrate(Map<String, String> st) {
    if (_loaded) return;
    for (final f in _orgFields) {
      _ctrls[f.$1] = TextEditingController(text: st[f.$1] ?? '');
    }
    _ctrls['labelOweUs'] = TextEditingController(
      text: st['labelOweUs'] ?? 'عليه',
    );
    _ctrls['labelOweThem'] = TextEditingController(
      text: st['labelOweThem'] ?? 'له',
    );
    for (final c in _ctrls.values) {
      c.addListener(() {
        if (!_dirty && mounted) setState(() => _dirty = true);
      });
    }
    _loaded = true;
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _saveAll() async {
    setState(() => _saving = true);
    try {
      final repo = ref.read(repoProvider);
      for (final e in _ctrls.entries) {
        await repo.setSyncedSetting(e.key, e.value.text.trim());
      }
      final stAfter = await repo.settings();
      final url = effectiveBackendUrl(stAfter['cloudBackendUrl']);
      if (url.isNotEmpty) {
        unawaited(AutoBackupService.silentWorkspaceBackup(repo, force: true));
      }
      await repo.logActivity('حفظ الإعدادات', 'settings', '');
      bump(ref);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      showSnack(context, 'تم حفظ الإعدادات ✅');
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'تعذّر حفظ الإعدادات: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final currencies = ref.watch(currenciesProvider).valueOrNull ?? [];

    return settings.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('جارٍ تحميل الإعدادات…'),
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
                title: 'تعذّر تحميل الإعدادات',
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
      ),
      data: (st) {
        _hydrate(st);
        // جهاز العضو داخل مجموعة لا يعدّل بيانات المؤسسة — المجموعة حساب
        // واحد وبياناتها بيد المدير فقط، لذا نخفي القسم بالكامل.
        final wsMode =
            ref.watch(workspaceModeProvider).valueOrNull ?? 'standalone';
        final wsOwner = ref.watch(isOwnerProvider).valueOrNull ?? true;
        final canEditOrg = wsMode == 'standalone' || wsOwner;
        // (دفعة 58 — متطلب 8) الإعدادات الحساسة (المزامنة/قاعدة البيانات)
        // للمالك أو من دوره «مدير» فقط — تُخفى تماماً عن بقية الأدوار.
        final userRole = ref.watch(deviceRoleProvider).valueOrNull?.role;
        // (دفعة 65) نوع الحساب: فردي أم مؤسسة. توافق خلفي — من لا يملك
        // المفتاح (مستخدم سابق) يُستنتج نوعه من نمط مساحة العمل بدل أن
        // يُخفى عنه قسم المجموعة الذي يستخدمه فعلاً.
        final storedType = (st['account.type'] ?? '').toString().trim();
        final hasEmailLinked =
            (st['account.email'] ?? '').toString().trim().isNotEmpty ||
                (ref.watch(googleLinkedProvider).valueOrNull ?? false);
        final accountType = hasEmailLinked
            ? 'enterprise'
            : (storedType.isNotEmpty
                ? storedType
                : (wsMode == 'standalone' ? 'individual' : 'enterprise'));
        final isIndividual = accountType != 'enterprise';
        // (3.70.0 — إعادة التصميم) تبويبات وبطاقات نقر مستقلة مصنّفة —
        // بلا قوائم منسدلة متداخلة (ExpansionTile) إطلاقاً.
        return DefaultTabController(
          length: 4,
          child: Stack(
            children: [
              Column(
                children: [
                  Material(
                    color: AppColors.surfaceOf(context),
                    child: SafeArea(
                      bottom: false,
                      child: TabBar(
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        labelColor: AppColors.primaryOf(context),
                        unselectedLabelColor: AppColors.text2Of(context),
                        indicatorColor: AppColors.primaryOf(context),
                        dividerColor: AppColors.borderOf(context),
                        labelStyle: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 12.5),
                        unselectedLabelStyle: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12.5),
                        tabs: const [
                          Tab(
                              icon: Icon(Icons.palette_outlined, size: 19),
                              text: 'المظهر'),
                          Tab(
                              icon: Icon(Icons.receipt_long_outlined, size: 19),
                              text: 'الفواتير والبيع'),
                          Tab(
                              icon: Icon(Icons.security_outlined, size: 19),
                              text: 'الأمان'),
                          Tab(
                              icon: Icon(Icons.hub_outlined, size: 19),
                              text: 'النظام والمزامنة'),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        // [بطاقة المظهر]
                        _tabPage([
                          Card(
                            child: ListTile(
                              leading: const Icon(Icons.palette_outlined),
                              title: const Text('المظهر والأصوات'),
                              subtitle: const Text(
                                  'حجم الخط، الأصوات والاهتزاز والتنبيهات'),
                              trailing: const Icon(Icons.chevron_left),
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const AppearanceScreen()),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                        ]),
                        // [بطاقة الفواتير ونقطة البيع]
                        _tabPage([
                          _Collapsible(
                            title: 'العملة والترقيم',
                            icon: Icons.currency_exchange,
                            color: AppColors.primary2,
                            children: [
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.currency_exchange),
                                title: const Text('العملة الافتراضية'),
                                subtitle: Text(st['defaultCurrency'] ?? 'YER'),
                                trailing: const Icon(Icons.chevron_left),
                                onTap: () async {
                                  final v = await showModalBottomSheet<String>(
                                    context: context,
                                    builder: (_) => SafeArea(
                                      child: ListView(
                                        shrinkWrap: true,
                                        children: [
                                          for (final c in currencies)
                                            ListTile(
                                              title: Text(
                                                  '${c.symbol}  ${c.name}'),
                                              onTap: () => Navigator.pop(
                                                  context, c.code),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                  if (v != null) {
                                    await ref
                                        .read(repoProvider)
                                        .setSetting('defaultCurrency', v);
                                    bump(ref);
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          _Collapsible(
                            title: 'المبيعات والسندات',
                            icon: Icons.receipt_long_outlined,
                            color: const Color(0xFF0EA5E9),
                            initiallyExpanded: true,
                            children: [
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.swap_horiz),
                                title: const Text('نوع العملية الافتراضي'),
                                subtitle: const Text(
                                  'يُختار تلقائياً عند فتح شاشة إضافة عملية',
                                ),
                                trailing: DropdownButton<String>(
                                  value: st['defaultOp'] ?? 'inflow',
                                  underline: const SizedBox.shrink(),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'inflow',
                                      child: Text('قبض (مبيعة/دفعة)'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'debit',
                                      child: Text('عليه (دين آجل)'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'outflow',
                                      child: Text('صرف'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'credit',
                                      child: Text('له (دائن)'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'revenue',
                                      child: Text('إيراد'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'expense',
                                      child: Text('مصروف'),
                                    ),
                                  ],
                                  onChanged: (v) async {
                                    if (v == null) return;
                                    await ref
                                        .read(repoProvider)
                                        .setSetting('defaultOp', v);
                                    bump(ref);
                                  },
                                ),
                              ),
                              const Divider(height: 1),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                secondary:
                                    const Icon(Icons.inventory_2_outlined),
                                title: const Text('تنبيه انخفاض المخزون'),
                                subtitle: const Text(
                                  'تحذير عند بيع صنف وصل لحد إعادة الطلب',
                                ),
                                value: (st['warnLowStock'] ?? '1') == '1',
                                onChanged: (v) async {
                                  await ref.read(repoProvider).setSetting(
                                      'warnLowStock', v ? '1' : '0');
                                  bump(ref);
                                },
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                secondary:
                                    const Icon(Icons.trending_down_rounded),
                                title: const Text(
                                    'السماح بالبيع عند نفاد الرصيد الدفتري'),
                                subtitle: const Text(
                                  'تفعيل: يسمح ببيع صنف نفد رصيده (حركة سالبة مع '
                                  'تنبيه). تعطيل: نقطة البيع تمنع الإضافة عند النفاد.',
                                ),
                                value: (st['allowNegativeStock'] ?? '0') == '1',
                                onChanged: (v) async {
                                  await ref.read(repoProvider).setSetting(
                                      'allowNegativeStock', v ? '1' : '0');
                                  bump(ref);
                                },
                              ),
                              // القفل التاريخي للتدقيق: منع غير المدير من تعديل/حذف
                              // سجلات مالية أقدم من المدة المحددة (0 = معطل).
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.lock_clock_outlined),
                                title:
                                    const Text('قفل السجلات المالية القديمة'),
                                subtitle: Text(
                                  (int.tryParse(st['auditLockDays'] ?? '0') ??
                                              0) <=
                                          0
                                      ? 'معطل — كل السجلات قابلة للتعديل حسب الصلاحيات'
                                      : 'السجلات الأقدم من ${st['auditLockDays']} يوماً '
                                          'مقفلة ضد التعديل والحذف لغير المدير',
                                ),
                                trailing: const Icon(Icons.chevron_left),
                                onTap: () async {
                                  final v = await showQuickAmountPad(
                                    context,
                                    title: 'مدة القفل بالأيام (0 = تعطيل)',
                                    initial: double.tryParse(
                                        st['auditLockDays'] ?? '0'),
                                    hint: 'مثال: 30',
                                  );
                                  if (v == null) return;
                                  await ref.read(repoProvider).setSetting(
                                      'auditLockDays',
                                      '${v.toInt().clamp(0, 3650)}');
                                  bump(ref);
                                },
                              ),
                            ],
                          ),
                        ]),
                        // [بطاقة الأمان والنسخ الاحتياطي وإعادة الضبط]
                        _tabPage([
                          _Collapsible(
                            title: 'الأمان والخصوصية',
                            icon: Icons.lock_outline,
                            color: const Color(0xFFE11D48),
                            children: [
                                SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                secondary: const Icon(Icons.fingerprint),
                                title: const Text('فتح التطبيق بالبصمة'),
                                subtitle: Text(
                                  _bioSupported
                                      ? 'الوسائل المتاحة: $_bioLabel'
                                      : 'غير متاحة — فعّل بصمة في إعدادات الجهاز',
                                ),
                                value: _bioSupported &&
                                    (st['biometric'] ?? '0') == '1',
                                onChanged: !_bioSupported
                                    ? null
                                    : (v) async {
                                        if (v) {
                                          final ok =
                                              await Security.authenticate(
                                            reason: 'أكّد بصمتك لتفعيل القفل',
                                          );
                                          if (!ok) {
                                            if (context.mounted) {
                                              showSnack(
                                                  context, 'لم يتم التحقق');
                                            }
                                            return;
                                          }
                                        }
                                        await ref.read(repoProvider).setSetting(
                                            'biometric', v ? '1' : '0');
                                        bump(ref);
                                      },
                              ),
                              const Divider(height: 1),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                secondary:
                                    const Icon(Icons.lock_clock_outlined),
                                title: const Text('القفل عند العودة للتطبيق'),
                                subtitle:
                                    const Text('يُطلب التحقق بعد كل تصغير'),
                                value: (st['autoLock'] ?? '0') == '1',
                                onChanged: (st['biometric'] ?? '0') != '1'
                                    ? null
                                    : (v) async {
                                        await ref.read(repoProvider).setSetting(
                                            'autoLock', v ? '1' : '0');
                                        bump(ref);
                                      },
                              ),
                            ],
                          ),
                          // (3.70 — المرحلة 3) النسخ الاحتياطي التلقائي المجدول:
                          // [كل ساعتين / يومياً في وقت محدد] + لقطة محلية + Drive مجاني.
                          if (canEditOrg || isIndividual) ...[
                            const SizedBox(height: 18),
                            const _AutoBackupSection(),
                          ],
                          if (!canEditOrg) ...[
                            _Collapsible(
                              title: 'نسخة احتياطية محلية',
                              icon: Icons.save_outlined,
                              color: AppColors.primary2,
                              children: [
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.backup_outlined),
                                  title: const Text(
                                      'إنشاء نسخة احتياطية محلية الآن'),
                                  subtitle: const Text(
                                    'تُحفظ داخل مجلد التطبيق على هذا الجهاز فقط، '
                                    'ولا يمكن استخدامها خارج مجموعتك.',
                                    style:
                                        TextStyle(fontSize: 11.5, height: 1.5),
                                  ),
                                  trailing: const Icon(Icons.chevron_left),
                                  onTap: () => _createLocalBackup(context),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 18),
                          // دمج وظائف الحذف والتعيين تحت اسم "إعادة الضبط والحذف"
                          _Collapsible(
                            title: 'إعادة الضبط والحذف',
                            icon: Icons.warning_amber_rounded,
                            color: const Color(0xFFDC2626),
                            initiallyExpanded: false,
                            children: [
                              if (isIndividual && wsMode == 'standalone')
                                const _DeleteAccountTile(),
                              if (canEditOrg) ...[
                                _GroupWipeTile(),
                                const SizedBox(height: 8),
                                const _DissolveGroupTile(),
                              ],
                              if (isDesktop) ...[
                                const SizedBox(height: 8),
                                const _FactoryResetTile(),
                              ],
                            ],
                          ),
                          const SizedBox(height: 18),
                        ]),
                        // [بطاقة إدارة النظام والمزامنة]
                        _tabPage([
                          // (استرداد طارئ — 1) «إرجاع الإدارة للمالك السابق»: بطاقة
                          // بارزة أعلى الإعدادات على جهاز المالك الحالي (المستلم في
                          // تسليم سابق) — مقصودة خارج أقسام الإدارة حتى تظهر حتى لو
                          // تعطلت واجهات الإدارة على الأجهزة القديمة (أندرويد 7).
                          if (ref.watch(handbackTargetProvider).valueOrNull
                              case final String prevName) ...[
                            Card(
                              color: const Color(0xFFB45309)
                                  .withValues(alpha: .08),
                              child: ListTile(
                                leading: const Icon(
                                    Icons.assignment_return_outlined,
                                    color: Color(0xFFB45309)),
                                title: const Text(
                                  'إرجاع إدارة مساحة العمل للمالك السابق',
                                  style: TextStyle(fontWeight: FontWeight.w800),
                                ),
                                subtitle: Text(
                                  'أنت المدير الحالي بعد تسليم سابق. بنقرة واحدة '
                                  'تعود الإدارة إلى «$prevName» ويصله إشعار فوري.',
                                  style: const TextStyle(
                                      fontSize: 11.5, height: 1.5),
                                ),
                                trailing: const Icon(Icons.chevron_left),
                                onTap: () =>
                                    _handbackOwnership(context, prevName),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          // مسار الترقية من الوضع المستقل: تفعيل المزامنة وربط أجهزة —
                          // يفتح معالج إنشاء المجموعة (يصبح هذا الجهاز مضيفاً) دون أي
                          // فقدان للبيانات المحلية القائمة.
                          // (قانون 2026-09-19) إنشاء المجموعات لحساب المؤسسة فقط —
                          // إعدادات الفردي محصورة ولا يظهر له هذا المسار إطلاقاً.
                          if (wsMode == 'standalone' && !isIndividual) ...[
                            const SizedBox(height: 18),
                            _Collapsible(
                              title: 'المزامنة وربط الأجهزة',
                              icon: Icons.hub_outlined,
                              color: const Color(0xFF7C3AED),
                              children: [
                                Card(
                                  child: ListTile(
                                    leading: const Icon(Icons.sync_alt_rounded,
                                        color: Color(0xFF7C3AED)),
                                    title: const Text(
                                        'تفعيل المزامنة وربط أجهزة أخرى'),
                                    subtitle: const Text(
                                      'حوّل هذا الجهاز إلى مضيف مجموعة واربط أجهزة '
                                      'الكاشير والمحاسبين — كل بياناتك الحالية تبقى '
                                      'كما هي وتُزامَن للأجهزة الجديدة.',
                                      style: TextStyle(
                                          fontSize: 11.5, height: 1.5),
                                    ),
                                    trailing: const Icon(Icons.chevron_left),
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const GroupManagementScreen(),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          // (الزر العائم) أندرويد فقط: فقاعة الاستعلام والبيع
                          // السريع فوق التطبيقات الأخرى + بلاطة الستارة.
                          if (PlatformInfo.isAndroid) ...[
                            const SizedBox(height: 18),
                            const _Collapsible(
                              title: 'الزر العائم للبيع السريع',
                              icon: Icons.picture_in_picture_alt_rounded,
                              color: AppColors.primary,
                              children: [_FloatingPosSection()],
                            ),
                          ],
                          // (حساب Google) هوية المؤسسة الدائمة — للمدير/المستقل فقط.
                          // (قانون 2026-09-19) إعدادات المؤسسة لا تظهر للفردي.
                          if ((wsOwner || wsMode == 'standalone') &&
                              !isIndividual) ...[
                            const SizedBox(height: 18),
                            const _Collapsible(
                              title: 'حساب المؤسسة (Google)',
                              icon: Icons.account_circle_outlined,
                              color: Color(0xFF059669),
                              children: [AccountSection()],
                            ),
                          ],
                          // (الاشتراك) تفاصيل الاشتراك: للمدير فقط — حالة الترخيص
                          // وتاريخ الانتهاء والوقت المتبقي وزر التجديد/الترقية.
                          // (قانون 2026-09-19) إعدادات المؤسسة لا تظهر للفردي.
                          if ((wsOwner || wsMode == 'standalone') &&
                              !isIndividual) ...[
                            const SizedBox(height: 18),
                            const _Collapsible(
                              title: 'تفاصيل الاشتراك',
                              icon: Icons.workspace_premium_outlined,
                              color: Color(0xFF7C3AED),
                              children: [SubscriptionDetailsSection()],
                            ),
                          ],
                          // (إدارة الموظفين) طلبات خروج الموظفين — للمدير والوكيل
                          if (wsMode != 'standalone' &&
                              (canEditOrg || userRole == UserRole.agent)) ...[
                            const SizedBox(height: 18),
                            _Collapsible(
                              title: 'إدارة الموظفين',
                              icon: Icons.badge_outlined,
                              color: const Color(0xFF0284C7),
                              children: [
                                Card(
                                  child: ListTile(
                                    leading: const Icon(
                                      Icons.fact_check_outlined,
                                      color: Color(0xFF0284C7),
                                    ),
                                    title: const Text('طلبات خروج الموظفين'),
                                    subtitle: const Text(
                                      'مراجعة والموافقة على طلبات تسجيل خروج أو مغادرة أعضاء المجموعة.',
                                      style: TextStyle(
                                          fontSize: 11.5, height: 1.5),
                                    ),
                                    trailing: const Icon(Icons.chevron_left),
                                    onTap: () =>
                                        showLogoutRequestsSheet(ref),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          // (الدعم والمساعدة) خدمة العملاء والدردشة المباشرة
                          const SizedBox(height: 18),
                          _Collapsible(
                            title: 'الدعم والمساعدة',
                            icon: Icons.support_agent_rounded,
                            color: const Color(0xFF16A34A),
                            children: [
                              Card(
                                color: AppColors.primarySoftOf(context),
                                child: ListTile(
                                  leading: Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: AppColors.primaryOf(context),
                                      borderRadius: BorderRadius.circular(11),
                                    ),
                                    child: const Icon(
                                      Icons.chat_bubble_outline_rounded,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                  ),
                                  title: const Text(
                                    'الدعم الفني والدردشة المباشرة',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                    ),
                                  ),
                                  subtitle: const Text(
                                    'محادثة مباشرة ومشفرة مع إدارة النظام داخل التطبيق (نص ورموز).',
                                    style: TextStyle(
                                        fontSize: 11.5, height: 1.5),
                                  ),
                                  trailing: const Icon(Icons.chevron_left_rounded),
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const SupportChatScreen(),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: 8),
                              Card(
                                color: const Color(0xFFE7F7EE),
                                child: ListTile(
                                  leading: Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF25D366),
                                      borderRadius: BorderRadius.circular(11),
                                    ),
                                    child: const Icon(
                                      Icons.support_agent_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                  title: const Text(
                                    'خدمة العملاء (واتساب)',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                      color: Color(0xFF128C4B),
                                    ),
                                  ),
                                  subtitle: const Text(
                                    'تواصل مباشر مع فريق الدعم الفني لأي مساعدة أو استفسار.',
                                    style: TextStyle(
                                        fontSize: 11.5,
                                        height: 1.5,
                                        color: Color(0xFF128C4B)),
                                  ),
                                  trailing: const Icon(
                                    Icons.open_in_new_rounded,
                                    color: Color(0xFF128C4B),
                                  ),
                                  onTap: () async {
                                    final uri = Uri.parse(
                                      'https://wa.me/967774190040?text=${Uri.encodeComponent('السلام عليكم، أحتاج الدعم الفني لتطبيق مدير الحسابات.')}',
                                    );
                                    final ok = await canLaunchUrl(uri);
                                    if (ok) {
                                      await launchUrl(
                                        uri,
                                        mode: LaunchMode.externalApplication,
                                      );
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                          // (قانون 2026-09-19) شريط «الترقية إلى مؤسسة» أُزيل:
                          // إعدادات الفردي محصورة — لا مسارات مؤسسة فيها.
                          // (دفعة 65) الحساب الفردي: خيار «الانضمام إلى مؤسسة قائمة»
                          // يبقى متاحاً ومستقلاً لمن يرغب بالعمل تحت إدارة متجر آخر.
                          if (isIndividual && !hasEmailLinked && wsMode != 'member') ...[
                            const SizedBox(height: 18),
                            _Collapsible(
                              title: 'الانضمام إلى مؤسسة قائمة',
                              icon: Icons.group_add_outlined,
                              color: const Color(0xFF7C3AED),
                              children: [
                                Card(
                                  child: ListTile(
                                    leading: const Icon(
                                        Icons.group_add_outlined,
                                        color: Color(0xFF7C3AED)),
                                    title: const Text(
                                        'الانضمام إلى مجموعة عبر السحابة'),
                                    subtitle: const Text(
                                      'امسح رمز QR أو أدخل رمز الدعوة — يُفعَّل بعد '
                                      'موافقة المدير.',
                                      style: TextStyle(
                                          fontSize: 11.5, height: 1.5),
                                    ),
                                    trailing: const Icon(Icons.chevron_left),
                                    onTap: () =>
                                        startJoinApprovalFlow(context, ref),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (!canEditOrg) ...[
                            // (دفعة 58 — متطلب 11) «طلب مغادرة المجموعة»: يرسل طلباً
                            // للمدير عبر السحابة، وبعد موافقته يُفَكّ ارتباط هذا الجهاز
                            // نظيفاً ويعود مستقلاً.
                            const SizedBox(height: 18),
                            _Collapsible(
                              title: 'مغادرة المجموعة',
                              icon: Icons.logout,
                              color: const Color(0xFFEA580C),
                              children: [
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.logout,
                                      color: Color(0xFFEA580C)),
                                  title: const Text('طلب مغادرة المجموعة'),
                                  subtitle: const Text(
                                    'يُرسل طلبك إلى المدير، وبعد موافقته يُفصل جهازك '
                                    'عن المجموعة وتُحذف بياناتها من جهازك ويعود مستقلاً.',
                                    style:
                                        TextStyle(fontSize: 11.5, height: 1.5),
                                  ),
                                  trailing: const Icon(Icons.chevron_left),
                                  onTap: () => _requestLeaveGroup(context),
                                ),
                              ],
                            ),
                            // (استرداد طارئ — 2) الاسترداد السيادي للمنشئ: هذا
                            // الجهاز أنشأ المساحة لكنه ليس المالك حالياً — خيار
                            // أمان دائم لاسترداد الملكية دون تدخل يدوي في Firebase.
                            if (ref
                                    .watch(creatorRecoveryProvider)
                                    .valueOrNull ==
                                true) ...[
                              const SizedBox(height: 18),
                              _Collapsible(
                                title: 'استرداد ملكية مساحة العمل',
                                icon: Icons.workspace_premium_outlined,
                                color: const Color(0xFF7C3AED),
                                children: [
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(Icons.workspace_premium,
                                        color: Color(0xFF7C3AED)),
                                    title:
                                        const Text('استرداد ملكية مساحة العمل'),
                                    subtitle: const Text(
                                      'أنت منشئ هذه المساحة. إن فقدت الإدارة لأي '
                                      'سبب يمكنك استردادها فوراً — يُحدَّث السجل '
                                      'السحابي وتُبثّ الاستعادة لكل الأجهزة.',
                                      style: TextStyle(
                                          fontSize: 11.5, height: 1.5),
                                    ),
                                    trailing: const Icon(Icons.chevron_left),
                                    onTap: () => _creatorRecover(context),
                                  ),
                                ],
                              ),
                            ],
                            // (صمام أمان) استرجاع الإدارة: يظهر للمدير السابق فقط
                            // خلال 24 ساعة من التسليم — ينقذ الموقف إذا تعثر تفعيل
                            // الإدارة على الجهاز المستلم (جهاز قديم/أندرويد 7).
                            if (ref
                                    .watch(reclaimOwnershipProvider)
                                    .valueOrNull ==
                                true) ...[
                              const SizedBox(height: 18),
                              _Collapsible(
                                title: 'استرجاع الإدارة (صمام الأمان)',
                                icon: Icons.settings_backup_restore_rounded,
                                color: const Color(0xFFB45309),
                                children: [
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(
                                        Icons.admin_panel_settings_outlined,
                                        color: Color(0xFFB45309)),
                                    title: const Text('استرجاع إدارة المجموعة'),
                                    subtitle: const Text(
                                      'سلّمت الإدارة مؤخراً ولم تُفعَّل على الجهاز '
                                      'الجديد؟ يمكنك استعادتها من هنا خلال 24 ساعة '
                                      'من التسليم — تُبثّ الاستعادة لكل الأجهزة.',
                                      style: TextStyle(
                                          fontSize: 11.5, height: 1.5),
                                    ),
                                    trailing: const Icon(Icons.chevron_left),
                                    onTap: () => _reclaimOwnership(context),
                                  ),
                                ],
                              ),
                            ],
                          ],
                          const UpdateSection(),
                          const SizedBox(height: 18),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  Text(
                                    'مدير الحسابات',
                                    style:
                                        Theme.of(context).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '$appVersionLabel — تطبيق أصلي بالكامل',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.text3Of(context),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'موجب (+) = مستحق لنا «عليه»  ·  سالب (−) = مستحق منا «له»',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      height: 1.6,
                                      color: AppColors.text3Of(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ]),

                      ],
                    ),
                  ),
                ],
              ),
              // شريط حفظ عائم يظهر فور أي تعديل غير محفوظ.
              if (_dirty)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(16),
                    color: AppColors.primaryOf(context),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: _saving ? null : _saveAll,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.save_outlined,
                                color: Colors.white),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'لديك تعديلات غير محفوظة',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              _saving ? 'جارٍ الحفظ…' : 'حفظ الآن',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// (3.70.0) صفحة تبويب: بطاقات مستقلة دائمة الظهور — وإن حجبت
  /// البطاقات حسب نوع الحساب/الدور تظهر حالة فارغة مهذبة.
  Widget _tabPage(List<Widget> children) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
      children: children.isEmpty
          ? [
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: EmptyState(
                  icon: Icons.tune_rounded,
                  title: 'لا خيارات متاحة هنا',
                  message: 'هذا القسم غير متاح لنوع حسابك أو دورك الحالي.',
                ),
              ),
            ]
          : children,
    );
  }
}

/// قسم إعدادات قابل للطيّ برمز يميّزه — يقابل «الطي في أيقونات حسب النوع».
/// (3.70.0 — إعادة التصميم) بطاقة قسم مستقلة: أيقونة ملونة + عنوان +
/// وصف سطر واحد + المحتوى **دائم الظهور** — لا ExpansionTile ولا قوائم
/// منسدلة متداخلة إطلاقاً. (الاسم التاريخي محفوظ لتقليل اللمسات.)
class _Collapsible extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color? color;
  final List<Widget> children;
  final bool initiallyExpanded; // لم تعد ذات أثر — البطاقات مفتوحة دائماً
  const _Collapsible({
    required this.title,
    required this.icon,
    this.color,
    required this.children,
    this.initiallyExpanded = false,
  });

  /// وصف سطر واحد لكل بطاقة — تصنيف واضح بلا حشو.
  static const Map<String, String> _subs = {
    'بيانات المؤسسة': 'اسم النشاط وبيانات المنشأة والعنوان',
    'العملة والترقيم': 'العملة الافتراضية لكل العمليات والفواتير',
    'المبيعات والسندات': 'خيارات الفواتير والبيع والسندات والتنبيهات',
    'الأمان والخصوصية': 'قفل الشاشة والبصمة وحماية التطبيق',
    'إعادة الضبط والحذف': 'حذف الحساب أو تهيئة المجموعة وإعادة الضبط',
    'المزامنة وربط الأجهزة': 'حوّل الجهاز إلى مضيف مجموعة واربط الأجهزة',
    'حساب المؤسسة (Google)': 'الهوية الدائمة للمنشأة وربط حساب Google',
    'تفاصيل الاشتراك': 'حالة الترخيص والمقاعد وتاريخ الانتهاء',
    'الانضمام إلى مؤسسة قائمة': 'انضم عبر QR أو رمز دعوة بموافقة المدير',
    'إدارة الموظفين': 'مراجعة طلبات خروج ومغادرة أعضاء المجموعة',
    'الدعم والمساعدة': 'التواصل المباشر مع الدعم الفني وخدمة العملاء',
    'نسخة احتياطية محلية': 'نسخة داخل مجلد التطبيق على هذا الجهاز فقط',
    'مغادرة المجموعة': 'طلب مغادرة بموافقة المدير وفك ارتباط نظيف',
    'استرداد ملكية مساحة العمل': 'استرجاع ملكية منشأتك فوراً وبثّها للأجهزة',
    'استرجاع الإدارة (صمام الأمان)': 'استعادة الإدارة خلال 24 ساعة من التسليم',
    'النسخ الاحتياطي التلقائي': 'جدولة النسخ (كل ساعتين/يومياً) ووجهة Drive',
  };

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.primaryOf(context);
    final sub = _subs[title];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        // (2026-09-24) هوية حديثة: ظل ناعم خفيف بدل الحدود السميكة.
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.card(Theme.of(context).colorScheme),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
            child: Row(
              children: [
                // أيقونة دائرية ملوّنة داخل الكرت المجمّع.
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: c.withValues(alpha: .12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: c, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 15),
                      ),
                      if (sub != null)
                        Text(
                          sub,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.4,
                            color: AppColors.text3Of(context),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
            child: Column(
              // (2026-09-24) كل سطر يحمل أيقونة دائرية ملوّنة متناسقة.
              children: [for (final w in children) _decorate(w, c)],
            ),
          ),
        ],
      ),
    );
  }

  /// يغلّف أيقونة السطر بدائرة ملوّنة ناعمة (نصوص نظيفة ومتباعدة).
  Widget _decorate(Widget child, Color c) {
    if (child is SwitchListTile) {
      final sec = child.secondary;
      if (sec is Icon) {
        final col = sec.color ?? c;
        return SwitchListTile(
          key: child.key,
          contentPadding: EdgeInsets.zero,
          secondary: _RoundIcon(icon: sec.icon!, color: col),
          title: child.title,
          subtitle: child.subtitle,
          value: child.value,
          onChanged: child.onChanged,
        );
      }
      return child;
    }
    if (child is ListTile) {
      final lead = child.leading;
      if (lead is Icon) {
        final col = lead.color ?? c;
        return ListTile(
          key: child.key,
          contentPadding: EdgeInsets.zero,
          leading: _RoundIcon(icon: lead.icon!, color: col),
          title: child.title,
          subtitle: child.subtitle,
          trailing: child.trailing,
          onTap: child.onTap,
          onLongPress: child.onLongPress,
          enabled: child.enabled,
        );
      }
    }
    return child;
  }
}

/// أيقونة دائرية ملوّنة بخلفية باستيل ناعمة — عنصر الهوية في القوائم.
class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 19),
      );
}

/// خيار «تهيئة المجموعة من الصفر» — جهاز المدير فقط:
/// حذف كامل لبيانات التطبيق والأعضاء (دون المساس بالإعدادات والصلاحيات)،
/// ينفَّذ بعد مصادقة النظام (بصمة/رمز قفل الشاشة)، ويُقفل شهراً بعد التنفيذ.
class _GroupWipeTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_GroupWipeTile> createState() => _GroupWipeTileState();
}

class _GroupWipeTileState extends ConsumerState<_GroupWipeTile> {
  DateTime? _lockedUntil;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadLock();
  }

  Future<void> _loadLock() async {
    final at = await ref.read(repoProvider).groupWipeAvailableAt();
    if (mounted) setState(() => _lockedUntil = at);
  }

  Future<void> _wipe() async {
    // 1) تأكيد نصي واضح.
    final sure = await confirmDialog(
      context,
      title: '⚠️ تهيئة المجموعة من الصفر',
      message: 'سيُحذف كل شيء نهائياً من جهازك ومن أجهزة كل الأعضاء:\n'
          'الحسابات، العمليات، السندات، الأصناف، المخزون، الدردشة، '
          'سلة المهملات، سجل النشاط والإشعارات.\n\n'
          'تبقى المجموعة قائمة: الأجهزة المقترنة والمستخدمون والصلاحيات '
          'والإعدادات لا تُمس.\n\n'
          'بعد التنفيذ يُقفل هذا الخيار لمدة شهر كامل. لا يمكن التراجع!',
      confirmText: 'متابعة',
      danger: true,
    );
    if (!sure || !mounted) return;
    // 2) مصادقة النظام: بصمة أو رمز قفل الشاشة — إلزامية للتنفيذ.
    final authed = await Security.authenticate(
      reason: 'أكّد هويتك لتهيئة المجموعة وحذف كل البيانات',
    );
    if (!authed) {
      if (mounted) {
        showSnack(context, 'لم تكتمل المصادقة — أُلغيت التهيئة', error: true);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      // ══ (2026-09-22 — قانون فك الارتباط الشامل) ══
      // التهيئة من الصفر تعني انفصال كل عضو رسمياً: يمحى من السجل
      // وعضوية المستخدم وفهرس الأجهزة، وتُلغى كل دعوة وطلب انضمام —
      // لا عضو يبقى معلقاً في السحابة بعد التهيئة.
      try {
        final st0 = await ref.read(repoProvider).settings();
        final url0 = effectiveBackendUrl(st0['cloudBackendUrl']);
        if (url0.isNotEmpty) {
          final ws0 = await ref.read(repoProvider).activeWorkspaceId();
          await CloudJoin.purgeAllMembers(
            ref.read(repoProvider),
            backendUrl: url0,
            workspaceId: ws0,
          );
        }
      } catch (_) {}
      await ref.read(repoProvider).wipeGroupData();
      // دفع فوري لعمليات الحذف نحو الأعضاء.
      try {
        ref.read(syncEngineProvider).notifyNewOperation();
      } catch (_) {}
      bump(ref);
      await _loadLock();
      if (mounted) {
        showSnack(context, 'تمت التهيئة — بدأت المجموعة من الصفر 🧹');
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lockedUntil != null;
    final lockLabel = locked
        ? 'مقفل حتى ${_lockedUntil!.toIso8601String().substring(0, 10)} — '
            'يُتاح مرة واحدة كل شهر'
        : 'يتطلب بصمة أو رمز قفل الشاشة للتنفيذ';
    return Card(
      child: ListTile(
        enabled: !locked && !_busy,
        leading: _busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                locked ? Icons.lock_clock : Icons.delete_forever,
                color: locked ? AppColors.text3Of(context) : Colors.red,
              ),
        title: Text(
          'حذف كامل البيانات وتهيئة المجموعة من الصفر',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w800,
            color: locked ? AppColors.text3Of(context) : Colors.red,
          ),
        ),
        subtitle: Text(
          'يفرغ دفاتر جهازك وأجهزة الأعضاء دون المساس بالإعدادات '
          'والصلاحيات.\n$lockLabel',
          style: const TextStyle(fontSize: 11.5, height: 1.5),
        ),
        onTap: locked || _busy ? null : _wipe,
      ),
    );
  }
}

// ═══════════ (دفعة 52) إعادة ضبط المصنع — نسخة الكمبيوتر ═══════════

/// زر بارز أحمر يحذف ملف قاعدة البيانات المحلية نفسه من القرص
/// (nexora.db + wal/shm) بعد إغلاق الاتصال، ثم يعيد التطبيق إلى شاشة
/// الترحيب — الحل الجذري للبيانات القديمة العالقة على ويندوز.
class _FactoryResetTile extends ConsumerStatefulWidget {
  const _FactoryResetTile();

  @override
  ConsumerState<_FactoryResetTile> createState() => _FactoryResetTileState();
}

class _FactoryResetTileState extends ConsumerState<_FactoryResetTile> {
  bool _busy = false;

  Future<void> _reset() async {
    // 1) تأكيد صريح بالنص المطلوب.
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ إعادة ضبط المصنع'),
        content: const Text(
          'هل أنت متأكد من رغبتك في تصفير البرنامج وحذف قاعدة البيانات '
          'المحلية؟\n\nسيُحذف ملف قاعدة البيانات نهائياً من هذا الكمبيوتر '
          '(الحسابات، العمليات، الأصناف، الإعدادات، بيانات الاقتران) '
          'ويبدأ التطبيق من شاشة الترحيب كأنه مثبت للتو.\n\n'
          'هذا الإجراء لا يمكن التراجع عنه.',
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
            child: const Text('تصفير وحذف نهائي'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    final engine = ref.read(syncEngineProvider);
    try {
      // 2) أوقف محرك المزامنة أولاً (يستخدم القاعدة).
      try {
        engine.stop();
      } catch (_) {}
      // 3) أغلق القاعدة واحذف ملفاتها + الوسائط.
      await FactoryReset.wipeAllLocalData();
      Sfx.success();
      if (!mounted) return;
      // 4) عودة نظيفة لشاشة البداية: القاعدة الجديدة تُنشأ تلقائياً
      //    عند أول فتح، وشاشة الترحيب تظهر لغياب has_completed_onboarding.
      final repo = ref.read(repoProvider);
      try {
        await repo.initSyncInfra().timeout(const Duration(seconds: 8));
      } catch (_) {}
      try {
        await engine.start();
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SplashScreen()),
        (_) => false,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, 'تعذّر التصفير: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.red.withValues(alpha: .05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.red.withValues(alpha: .35)),
      ),
      child: ListTile(
        enabled: !_busy,
        leading: _busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.restart_alt, color: Colors.red),
        title: const Text(
          'مسح كافة البيانات وإعادة ضبط المصنع (نسخة الكمبيوتر)',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w800,
            color: Colors.red,
          ),
        ),
        subtitle: const Text(
          'يحذف ملف قاعدة البيانات المحلية نهائياً من هذا الجهاز ويعيد '
          'البرنامج إلى شاشة الترحيب — يُستخدم عند تعذّر تنظيف البيانات '
          'القديمة يدوياً.',
          style: TextStyle(fontSize: 11.5, height: 1.5),
        ),
        onTap: _busy ? null : _reset,
      ),
    );
  }
}

// ═══════════ (دفعة 55) حل المجموعة وإلغاء كل الارتباطات — للمدير ═══════════

/// يبث شواهد طرد لكل الأجهزة المرتبطة (تُقصى لحظياً وتعود مستقلة)،
/// يحذف عقدة المجموعة من السحابة، ثم يفكك المجموعة محلياً:
/// دفاتر المدير تبقى، الأجهزة/الأعضاء/الدردشات تُحذف، والوضع يعود
/// مستقلاً — جاهزاً لإنشاء مجموعة جديدة وإعادة ربط الأجهزة.
class _DissolveGroupTile extends ConsumerStatefulWidget {
  const _DissolveGroupTile();

  @override
  ConsumerState<_DissolveGroupTile> createState() => _DissolveGroupTileState();
}

class _DissolveGroupTileState extends ConsumerState<_DissolveGroupTile> {
  bool _busy = false;

  Future<void> _dissolve() async {
    final repo = ref.read(repoProvider);
    final engine = ref.read(syncEngineProvider);
    // عدد الأجهزة المرتبطة (غير جهازنا) لعرضه في التأكيد.
    var peerCount = 0;
    try {
      final st = await repo.settings();
      final ourId = st['sync.deviceId'] ?? '';
      final devs = await repo.devices();
      peerCount = devs.where((d) => '${d['id']}' != ourId).length;
    } catch (_) {}
    if (!mounted) return;
    // 1) تأكيد صريح.
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ حذف المجموعة نهائياً'),
        content: Text(
          'سيتم حل المجموعة بالكامل:\n\n'
          '• إلغاء ارتباط كل الأجهزة المرتبطة '
          '${peerCount > 0 ? '($peerCount جهاز) ' : ''}فوراً — كل عضو '
          'يعود إلى حسابه الفردي المستقل وبياناته المحلية تبقى له.\n'
          '• حذف بيانات المجموعة من السحابة (السجل، العمليات، الدعوات).\n'
          '• حذف الأعضاء والدردشات من جهازك.\n\n'
          'دفاترك (الحسابات والعمليات والأصناف) تبقى سليمة على جهازك، '
          'ويمكنك إنشاء مجموعة جديدة وإعادة ربط الأجهزة في أي وقت.\n\n'
          'هذا الإجراء لا يمكن التراجع عنه.',
          style: const TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حل المجموعة نهائياً'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    // 2) مصادقة النظام (بصمة/قفل شاشة) — إجراء مدمّر على مستوى المجموعة.
    final authed = await Security.authenticate(
      reason: 'أكّد هويتك لحل المجموعة وإلغاء ارتباط كل الأجهزة',
    );
    if (!authed) {
      if (mounted) {
        showSnack(context, 'لم تكتمل المصادقة — أُلغي الحل', error: true);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      var broadcast = 0;
      // 3) البث السحابي: شاهدة طرد لكل جهاز + تفكيك عقدة المجموعة.
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isNotEmpty) {
        try {
          broadcast = await CloudJoin.dissolveGroup(repo, backendUrl: url);
        } catch (_) {
          // شبكة غائبة: الشواهد لم تُبث — الأعضاء سيُقصون عند أول
          // فشل مصافحة roster (العقدة ستُحذف حين تتوفر الشبكة).
        }
      }
      // إشعار أقران الشبكة المحلية أيضاً (إن وجدوا).
      try {
        await engine.broadcastRosterChange();
      } catch (_) {}
      // 4) التفكيك المحلي على جهاز المدير.
      engine.stop();
      await repo.dissolveGroupLocally();
      await engine.start();
      Sfx.success();
      bump(ref);
      if (mounted) {
        setState(() => _busy = false);
        showSnack(
          context,
          '✅ حُلّت المجموعة — أُلغي ارتباط '
          '${broadcast > 0 ? '$broadcast جهاز' : 'كل الأجهزة'} وعاد جهازك '
          'مستقلاً. يمكنك إنشاء مجموعة جديدة الآن.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, 'تعذّر حل المجموعة: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.red.withValues(alpha: .05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.red.withValues(alpha: .35)),
      ),
      child: ListTile(
        enabled: !_busy,
        leading: _busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.group_off, color: Colors.red),
        title: const Text(
          'حذف المجموعة وإلغاء كل الارتباطات',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w800,
            color: Colors.red,
          ),
        ),
        subtitle: const Text(
          'يفك ارتباط جميع الأجهزة فوراً (تعود مستقلة وتُمسح بيانات '
          'المجموعة منها)، يحذف المجموعة من السحابة، ويعيد جهازك مستقلاً '
          'مع الاحتفاظ بدفاترك — لإعادة الربط من الصفر.',
          style: TextStyle(fontSize: 11.5, height: 1.5),
        ),
        onTap: _busy ? null : _dissolve,
      ),
    );
  }
}

// ═══════════ (قانون 2026-09-19) حذف الحساب الفردي نهائياً ═══════════

/// زر حذف الحساب الفردي: يحذف كل شيء محلياً ومن قاعدة البيانات السحابية
/// — ويستثني فقط بصمة الجهاز (device_index) والاشتراك المدفوع
/// (subscription) كما ينص القانون حرفياً.
class _DeleteAccountTile extends ConsumerStatefulWidget {
  const _DeleteAccountTile();

  @override
  ConsumerState<_DeleteAccountTile> createState() => _DeleteAccountTileState();
}

class _DeleteAccountTileState extends ConsumerState<_DeleteAccountTile> {
  bool _busy = false;

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ حذف الحساب نهائياً'),
        content: const Text(
          'سيُحذف كل شيء يخص حسابك:\n\n'
          '• كل البيانات المحلية: الحسابات، العمليات، السندات، الأصناف، '
          'الإعدادات، الدردشات.\n'
          '• كل بياناتك من قاعدة البيانات السحابية: المساحة، النسخ، '
          'السجل، الدعوات.\n\n'
          'يُستثنى من الحذف: بصمة الجهاز والاشتراك المدفوع فقط.\n\n'
          'بعدها يعود التطبيق لشاشة الترحيب كأنه مثبت للتو.\n'
          'هذا الإجراء لا يمكن التراجع عنه.',
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
            child: const Text('حذف كل شيء نهائياً'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final authed = await Security.authenticate(
      reason: 'أكّد هويتك لحذف الحساب وكل بياناته نهائياً',
    );
    if (!authed) {
      if (mounted) {
        showSnack(context, 'لم تكتمل المصادقة — أُلغي الحذف', error: true);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final repo = ref.read(repoProvider);
    final engine = ref.read(syncEngineProvider);
    try {
      try {
        engine.stop();
      } catch (_) {}
      // 1) السحابة: كل عقد المساحة تُحذف عدا الاشتراك المدفوع، وبصمة
      //    الجهاز (device_index العامة) لا تُمس إطلاقاً.
      try {
        final st = await repo.settings();
        final url = effectiveBackendUrl(st['cloudBackendUrl']);
        final db = await repo.database;
        // (3.71.0) مساحة حتمية — الحذف السحابي لا يصيب مساحة بالاختيار العشوائي.
        final ws = await ensureWorkspace(db, repo: repo);
        if (url.isNotEmpty) {
          await CloudJoin.deleteIndividualWorkspace(repo,
              backendUrl: url, workspaceId: ws);
          // فهرس Google يُحذف أيضاً — الحساب المحذوف لا يُسترجع.
          await CloudJoin.forgetIndex(repo, backendUrl: url);
        }
        // فك ربط Google إن وُجد (أفضل جهد — الجدول يُمحى محلياً على أي حال).
        try {
          await GoogleAuthService(db).signOut();
        } catch (_) {}
      } catch (_) {}
      // 2) المحلي: مسح كامل (ملف القاعدة + الوسائط + ملفات الاقتران).
      await FactoryReset.wipeAllLocalData();
      Sfx.success();
      if (!mounted) return;
      // 3) إقلاع نظيف → شاشة الترحيب (كأنه تثبيت جديد).
      try {
        await repo.initSyncInfra().timeout(const Duration(seconds: 8));
      } catch (_) {}
      try {
        await engine.start();
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const SplashScreen()),
        (_) => false,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, 'تعذّر حذف الحساب: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.red.withValues(alpha: .05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.red.withValues(alpha: .35)),
      ),
      child: ListTile(
        enabled: !_busy,
        leading: _busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.person_remove_alt_1_outlined, color: Colors.red),
        title: const Text('حذف الحساب نهائياً',
            style: TextStyle(fontWeight: FontWeight.w800, color: Colors.red)),
        subtitle: const Text(
          'يحذف كل بياناتك محلياً ومن قاعدة البيانات — عدا بصمة الجهاز '
          'والاشتراك المدفوع.',
          style: TextStyle(fontSize: 11.5, height: 1.5),
        ),
        trailing: const Icon(Icons.chevron_left),
        onTap: _busy ? null : _delete,
      ),
    );
  }
}

// ==================== (3.70) النسخ الاحتياطي التلقائي ====================

/// جدولة [كل ساعتين / يومياً في وقت محدد] + لقطة SQLite محلية باسم
/// backup_{store_id}_{timestamp}.db + وجهة Google Drive مجانية ودائمة
/// للجميع (لا تُحجب بانتهاء التجربة — السحابة الخاصة وحدها المقيدة).
class _AutoBackupSection extends StatelessWidget {
  const _AutoBackupSection();

  @override
  Widget build(BuildContext context) => const _Collapsible(
        title: 'النسخ الاحتياطي التلقائي',
        icon: Icons.autorenew_rounded,
        color: AppColors.primary2,
        children: [_AutoBackupControls()],
      );
}

class _AutoBackupControls extends ConsumerStatefulWidget {
  const _AutoBackupControls();

  @override
  ConsumerState<_AutoBackupControls> createState() =>
      _AutoBackupControlsState();
}

class _AutoBackupControlsState extends ConsumerState<_AutoBackupControls> {
  String _mode = 'off';
  final _timeCtl = TextEditingController(text: '02:00');
  bool _drive = true;
  bool _busy = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timeCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final st = await ref.read(repoProvider).settings();
    if (!mounted) return;
    setState(() {
      _mode = st[AutoBackupService.kModeKey] ?? 'off';
      _timeCtl.text = st[AutoBackupService.kTimeKey] ?? '02:00';
      _drive = (st[AutoBackupService.kDriveKey] ?? '1') == '1';
      _loaded = true;
    });
  }

  Future<void> _set(String key, String value) =>
      ref.read(repoProvider).setSetting(key, value);

  Future<void> _runNow() async {
    setState(() => _busy = true);
    try {
      await AutoBackupService.runScheduled(ref.read(repoProvider));
      if (mounted) showSnack(context, 'أُنشئت نسخة احتياطية تلقائية');
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر النسخ: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox(height: 40);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _mode,
          decoration:
              const InputDecoration(labelText: 'الجدولة', isDense: true),
          items: const [
            DropdownMenuItem(value: 'off', child: Text('إيقاف')),
            DropdownMenuItem(value: 'every2h', child: Text('كل ساعتين')),
            DropdownMenuItem(value: 'daily', child: Text('يومياً في وقت محدد')),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _mode = v);
            _set(AutoBackupService.kModeKey, v);
          },
        ),
        if (_mode == 'daily') ...[
          const SizedBox(height: 10),
          TextField(
            controller: _timeCtl,
            decoration: const InputDecoration(
              labelText: 'الوقت يومياً (HH:MM — 24 ساعة)',
              isDense: true,
            ),
            keyboardType: TextInputType.datetime,
            onSubmitted: (v) => _set(AutoBackupService.kTimeKey, v.trim()),
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Google Drive — مجاني ودائم',
              style: TextStyle(fontSize: 13)),
          subtitle: const Text(
            'يتطلب تسجيل دخول Google. لا يتأثر بانتهاء التجربة.',
            style: TextStyle(fontSize: 11),
          ),
          value: _drive,
          onChanged: (v) {
            setState(() => _drive = v);
            _set(AutoBackupService.kDriveKey, v ? '1' : '0');
          },
        ),
        const SizedBox(height: 4),
        FilledButton.icon(
          onPressed: _busy ? null : _runNow,
          icon: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.backup_rounded, size: 17),
          label: const Text('نسخ الآن'),
        ),
        const SizedBox(height: 6),
        const Text(
          'تُحفظ اللقطة المحلية باسم backup_{store_id}_{timestamp}.db — '
          'والنسخ إلى السحابة الخاصة متاح أثناء التجربة أو الاشتراك فقط.',
          style: TextStyle(fontSize: 10.5, height: 1.5),
        ),
      ],
    );
  }
}

/// (أندرويد فقط) مفتاح تشغيل الزر العائم للاستعلام والبيع السريع.
///
/// الحالة تُحفظ في SharedPreferences **محلياً على هذا الجهاز فقط** — لا تُزامن
/// مع بقية الأجهزة لأنها صلاحية نظام تخصّ الجهاز نفسه.
class _FloatingPosSection extends StatefulWidget {
  const _FloatingPosSection();

  @override
  State<_FloatingPosSection> createState() => _FloatingPosSectionState();
}

class _FloatingPosSectionState extends State<_FloatingPosSection> {
  bool? _enabled;
  bool _permission = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await FloatingPosService.isEnabled();
    final perm = await FloatingPosService.instance.hasPermission();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _permission = perm;
    });
  }

  Future<void> _setOn(bool value) async {
    setState(() => _busy = true);
    if (value) {
      var perm = await FloatingPosService.instance.hasPermission();
      if (!perm) perm = await FloatingPosService.instance.requestPermission();
      if (!perm) {
        if (mounted) {
          setState(() {
            _busy = false;
            _permission = false;
            _enabled = false;
          });
          showSnack(
            context,
            'يجب منح صلاحية «الظهور فوق التطبيقات الأخرى» من شاشة أندرويد.',
            error: true,
          );
        }
        await FloatingPosService.setEnabled(false);
        return;
      }
      final ok = await FloatingPosService.instance.show();
      if (!ok) {
        if (mounted) {
          setState(() {
            _busy = false;
            _enabled = false;
          });
          showSnack(context, 'تعذّر تشغيل الزر العائم.', error: true);
        }
        await FloatingPosService.setEnabled(false);
        return;
      }
      await FloatingPosService.setEnabled(true);
      if (mounted) {
        showSnack(context, 'تم تشغيل الزر العائم ⚡');
      }
    } else {
      await FloatingPosService.instance.hide();
      await FloatingPosService.setEnabled(false);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _enabled = value;
      if (value) _permission = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_enabled == null) {
      return const SizedBox(
        height: 48,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.picture_in_picture_alt_rounded,
                  color: AppColors.primary),
              title: const Text(
                'تفعيل الزر العائم للبيع السريع فوق التطبيقات',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                _permission
                    ? 'الفقاعة تبقى ظاهرة فوق أي تطبيق للاستعلام الفوري والبيع.'
                    : 'صلاحية «الظهور فوق التطبيقات» غير ممنوحة حالياً.',
                style: TextStyle(
                  fontSize: 11,
                  color: _permission ? Colors.black54 : const Color(0xFFB91C1C),
                ),
              ),
              value: _enabled!,
              onChanged: _busy ? null : _setOn,
            ),
            if (!_permission) ...[
              const SizedBox(height: 4),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                ),
                onPressed: _busy
                    ? null
                    : () async {
                        final granted = await FloatingPosService
                            .instance
                            .requestPermission();
                        if (!mounted) return;
                        setState(() => _permission = granted);
                        if (granted) {
                          await FloatingPosService.instance.show();
                          await FloatingPosService.setEnabled(true);
                          if (mounted) {
                            setState(() => _enabled = true);
                          }
                        }
                      },
                icon: const Icon(Icons.security_rounded, size: 16),
                label: const Text('منح صلاحية الظهور'),
              ),
            ],
            const SizedBox(height: 6),
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 15, color: AppColors.primary),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'يمكنك أيضاً تفعيل واستخدام الميزة مباشرة من لوحة '
                    'الإعدادات السريعة (الستارة) أعلى هاتفك عبر بلاطة '
                    '«استعلام نكسورا».',
                    style: TextStyle(fontSize: 10.5, height: 1.6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

/// نافذة انتظار موافقة مدير المجموعة على طلب المغادرة
class _LeavePendingDialog extends StatefulWidget {
  final String backendUrl;
  final String workspaceId;
  final String deviceId;
  final Repo repo;
  final WidgetRef ref;

  const _LeavePendingDialog({
    required this.backendUrl,
    required this.workspaceId,
    required this.deviceId,
    required this.repo,
    required this.ref,
  });

  @override
  State<_LeavePendingDialog> createState() => _LeavePendingDialogState();
}

class _LeavePendingDialogState extends State<_LeavePendingDialog> {
  Timer? _pollTimer;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_leaving || !mounted) return;
      try {
        final approved = await CloudJoin.checkLeaveOrEvicted(
          backendUrl: widget.backendUrl,
          workspaceId: widget.workspaceId,
          deviceId: widget.deviceId,
        );
        if (approved && mounted) {
          _leaving = true;
          _pollTimer?.cancel();
          Navigator.of(context, rootNavigator: true).pop();
          await widget.repo.resetToStandaloneAfterExpulsion();
          await FirebaseAuthRest.clearSession(widget.repo);
          try {
            final db = await widget.repo.database;
            await GoogleAuthService(db).signOut();
          } catch (_) {}
          widget.ref.invalidate(repoProvider);
          rootNavigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const OnboardingScreen()),
            (route) => false,
          );
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.hourglass_top_rounded, color: Colors.orange, size: 40),
      title: const Text('بانتظار موافقة مدير المجموعة'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text(
            'تم إرسال طلب المغادرة إلى مدير المجموعة.\n'
            'فور موافقة المدير، سيتم فك ارتباط الجهاز تلقائياً، '
            'وحذف بيانات المجموعة، والعودة إلى شاشة البداية لاختيار نوع الحساب.',
            textAlign: TextAlign.center,
            style: TextStyle(height: 1.5, fontSize: 13),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            _pollTimer?.cancel();
            try {
              await CloudJoin.deleteJoinRequest(
                backendUrl: widget.backendUrl,
                workspaceId: widget.workspaceId,
                deviceId: widget.deviceId,
              );
            } catch (_) {}
            if (context.mounted) {
              Navigator.of(context).pop();
              showSnack(context, 'تم إلغاء طلب المغادرة.');
            }
          },
          child: const Text('إلغاء الطلب'),
        ),
      ],
    );
  }
}
