import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_version.dart';
import '../core/security.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import '../data/sync/auto_backup.dart';
import 'trial_ui.dart' show SubscriptionDetailsSection;
import 'update_section.dart';
import 'appearance_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import 'support_chat_screen.dart';
import 'widgets.dart';
import '../core/cloud_config.dart';

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
        // إعدادات منسدلة عمودية أنيقة (أيقونات منسدلة) بدون تبويبات جانبية
        return Stack(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 90),
              children: [
                // 1. المظهر والأصوات
                _Collapsible(
                  title: 'المظهر والأصوات',
                  icon: Icons.palette_outlined,
                  color: const Color(0xFF8B5CF6),
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('المظهر والأصوات'),
                      subtitle: const Text('حجم الخط، الوضع الليلي، الأصوات والاهتزاز'),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const AppearanceScreen()),
                      ),
                    ),
                  ],
                ),

                // 2. العملة والترقيم
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
                                    title: Text('${c.symbol}  ${c.name}'),
                                    onTap: () => Navigator.pop(context, c.code),
                                  ),
                              ],
                            ),
                          ),
                        );
                        if (v != null) {
                          await ref.read(repoProvider).setSetting('defaultCurrency', v);
                          bump(ref);
                        }
                      },
                    ),
                  ],
                ),

                // 3. خيارات العمليات والسندات
                _Collapsible(
                  title: 'خيارات العمليات والسندات',
                  icon: Icons.receipt_long_outlined,
                  color: const Color(0xFF0EA5E9),
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.swap_horiz),
                      title: const Text('نوع العملية الافتراضي'),
                      subtitle: const Text('يُختار تلقائياً عند فتح شاشة إضافة عملية'),
                      trailing: DropdownButton<String>(
                        value: st['defaultOp'] ?? 'inflow',
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 'inflow', child: Text('قبض (دفعة)')),
                          DropdownMenuItem(value: 'debit', child: Text('عليه (دين آجل)')),
                          DropdownMenuItem(value: 'outflow', child: Text('صرف')),
                          DropdownMenuItem(value: 'credit', child: Text('له (دائن)')),
                          DropdownMenuItem(value: 'revenue', child: Text('إيراد')),
                          DropdownMenuItem(value: 'expense', child: Text('مصروف')),
                        ],
                        onChanged: (v) async {
                          if (v == null) return;
                          await ref.read(repoProvider).setSetting('defaultOp', v);
                          bump(ref);
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.lock_clock_outlined),
                      title: const Text('قفل السجلات المالية القديمة'),
                      subtitle: Text(
                        (int.tryParse(st['auditLockDays'] ?? '0') ?? 0) <= 0
                            ? 'معطل — كل السجلات قابلة للتعديل حسب الصلاحيات'
                            : 'السجلات الأقدم من ${st['auditLockDays']} يوماً مقفلة ضد التعديل والحذف',
                      ),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () async {
                        final v = await showQuickAmountPad(
                          context,
                          title: 'مدة القفل بالأيام (0 = تعطيل)',
                          initial: double.tryParse(st['auditLockDays'] ?? '0'),
                          hint: 'مثال: 30',
                        );
                        if (v == null) return;
                        await ref.read(repoProvider).setSetting('auditLockDays', '${v.toInt().clamp(0, 3650)}');
                        bump(ref);
                      },
                    ),
                  ],
                ),

                // 4. الأمان والخصوصية
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
                      value: _bioSupported && (st['biometric'] ?? '0') == '1',
                      onChanged: !_bioSupported
                          ? null
                          : (v) async {
                              if (v) {
                                final ok = await Security.authenticate(reason: 'أكّد بصمتك لتفعيل القفل');
                                if (!ok) {
                                  if (context.mounted) showSnack(context, 'لم يتم التحقق');
                                  return;
                                }
                              }
                              await ref.read(repoProvider).setSetting('biometric', v ? '1' : '0');
                              bump(ref);
                            },
                    ),
                    const Divider(height: 1),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.lock_clock_outlined),
                      title: const Text('القفل عند العودة للتطبيق'),
                      subtitle: const Text('يُطلب التحقق بعد كل تصغير'),
                      value: (st['autoLock'] ?? '0') == '1',
                      onChanged: (st['biometric'] ?? '0') != '1'
                          ? null
                          : (v) async {
                              await ref.read(repoProvider).setSetting('autoLock', v ? '1' : '0');
                              bump(ref);
                            },
                    ),
                  ],
                ),

                // 5. النسخ الاحتياطي التلقائي أو المحلي
                if (canEditOrg || isIndividual) ...[
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
                        title: const Text('إنشاء نسخة احتياطية محلية الآن'),
                        subtitle: const Text(
                          'تُحفظ داخل مجلد التطبيق على هذا الجهاز فقط',
                          style: TextStyle(fontSize: 11.5),
                        ),
                        trailing: const Icon(Icons.chevron_left),
                        onTap: () => _createLocalBackup(context),
                      ),
                    ],
                  ),
                ],

                // 6. تفاصيل الاشتراك
                if (wsOwner || wsMode == 'standalone') ...[
                  const _Collapsible(
                    title: 'تفاصيل الاشتراك',
                    icon: Icons.workspace_premium_outlined,
                    color: Color(0xFF7C3AED),
                    children: [SubscriptionDetailsSection()],
                  ),
                ],

                // 7. الدعم والمساعدة
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
                          child: const Icon(Icons.chat_bubble_outline_rounded, color: Colors.white, size: 20),
                        ),
                        title: const Text('الدعم الفني والدردشة المباشرة', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                        subtitle: const Text('محادثة مباشرة ومشفرة مع إدارة النظام داخل التطبيق.', style: TextStyle(fontSize: 11.5)),
                        trailing: const Icon(Icons.chevron_left_rounded),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const SupportChatScreen()),
                        ),
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
                          child: const Icon(Icons.support_agent_rounded, color: Colors.white, size: 22),
                        ),
                        title: const Text(
                          'خدمة العملاء (واتساب)',
                          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: Color(0xFF128C4B)),
                        ),
                        subtitle: const Text(
                          'تواصل مباشر مع فريق الدعم الفني لأي مساعدة أو استفسار.',
                          style: TextStyle(fontSize: 11.5, color: Color(0xFF128C4B)),
                        ),
                        trailing: const Icon(Icons.open_in_new_rounded, color: Color(0xFF128C4B)),
                        onTap: () async {
                          final uri = Uri.parse('https://wa.me/967774190040?text=${Uri.encodeComponent('السلام عليكم، أحتاج الدعم الفني لتطبيق مدير الحسابات.')}');
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri, mode: LaunchMode.externalApplication);
                          }
                        },
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),
                const UpdateSection(),
                const SizedBox(height: 18),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Text('مدير الحسابات', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text('$appVersionLabel — تطبيق أصلي بالكامل', style: TextStyle(fontSize: 12, color: AppColors.text3Of(context))),
                      ],
                    ),
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
          );
        },
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
  final bool initiallyExpanded;
  const _Collapsible({
    required this.title,
    required this.icon,
    this.color,
    required this.children,
    this.initiallyExpanded = false,
  });

  /// وصف سطر واحد لكل بطاقة.
  static const Map<String, String> _subs = {
    'المظهر والأصوات': 'حجم الخط، الوضع الليلي، والأصوات والاهتزاز',
    'العملة والترقيم': 'العملة الافتراضية لكل العمليات والسندات',
    'المبيعات والسندات': 'نوع العملية الافتراضي وقفل السجلات المالية',
    'الأمان والخصوصية': 'قفل الشاشة والبصمة وحماية التطبيق',
    'تفاصيل الاشتراك': 'حالة الترخيص والمقاعد وتاريخ الانتهاء',
    'النسخ الاحتياطي التلقائي': 'جدولة النسخ (كل ساعتين/يومياً) ووجهة Drive',
    'نسخة احتياطية محلية': 'نسخة داخل مجلد التطبيق على هذا الجهاز فقط',
    'الدعم والمساعدة': 'التواصل المباشر مع الدعم الفني وخدمة العملاء',
  };

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.primaryOf(context);
    final sub = _subs[title];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.card(Theme.of(context).colorScheme),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: c.withValues(alpha: .12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: c, size: 22),
          ),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5),
          ),
          subtitle: sub != null
              ? Text(
                  sub,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: AppColors.text3Of(context),
                  ),
                )
              : null,
          trailing: Icon(Icons.keyboard_arrow_down_rounded, color: c, size: 24),
          children: [
            Column(
              children: [for (final w in children) _decorate(w, c)],
            ),
          ],
        ),
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

