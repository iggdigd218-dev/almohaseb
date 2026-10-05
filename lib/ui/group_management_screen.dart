// شاشة موحّدة لإدارة المجموعة (أجهزة + مستخدمون + طرق الربط) — للمدير فقط.
// تظهر مكان شاشة "الأجهزة" للمدراء، وتجمع في مكان واحد:
//  1) زر "ربط جهاز/حساب جديد" يعرض نافذة بكل الطرق (QR، رمز نصي، IP يدوي، كود تعريف للعميل).
//  2) قائمة الأجهزة المرتبطة مع صلاحياتها.
//  3) قائمة المستخدمين والصلاحيات + إعادة تعيين PIN/كلمة المرور.
//  4) النسخ الاحتياطي.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/theme.dart';
import '../core/sfx.dart';
import '../data/providers.dart';
import '../data/sync/account_workspace.dart';
import '../data/sync/cloud_join.dart';
import '../data/sync/firebase_auth_service.dart';
import '../data/sync/google_auth_service.dart';
import 'cloud_sync_section.dart';
import 'devices_screen.dart' show DeviceCard;
import 'trial_ui.dart' show SeatUsageBadge;
import 'widgets.dart';
import '../core/cloud_config.dart';

class GroupManagementScreen extends ConsumerStatefulWidget {
  const GroupManagementScreen({super.key});

  @override
  ConsumerState<GroupManagementScreen> createState() => _State();
}

class _State extends ConsumerState<GroupManagementScreen> {
  // (دفعة 57) قناة SSE حيّة على /joinRequests بدل استطلاع كل 5 ثوانٍ —
  // طلب الاقتران يصل للمدير لحظياً بصفر كمون وبلا ضجيج شبكي دوري.
  JoinRequestWatcher? _joinReqWatcher;

  /// (إصلاح 2026-09-18 — طلبات لا تزال تظهر بعد الموافقة)
  /// أجهزة تمت الموافقة عليها في هذه الجلسة — لا تُعرض مرة أخرى حتى لو
  /// بقيت عقدتها approved في السحابة لمدة 10 دقائق.
  final Set<String> _recentlyApproved = {};
  DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _startJoinRequestWatcher();
    _checkJoinRequests();
    _reconcileRoster();
  }

  /// (2026-09-22) مواءمة جدول الأجهزة المحلي مع السجل السحابي عند فتح
  /// الشاشة: الأشباح (صفوف مقترنة بلا عضوية سحابية) تُوسم مفصولاً فلا
  /// تُعرض أجهزةً مرتبطة ولا تُربك عدّ المقاعد. صامتة تماماً عند الفشل.
  Future<void> _reconcileRoster() async {
    try {
      final repo = ref.read(repoProvider);
      if (!await repo.isWorkspaceOwner()) return;
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) return;
      final ws = await repo.activeWorkspaceId();
      final fixed =
          await CloudJoin.reconcileRosterWithLocal(repo,
              backendUrl: url, workspaceId: ws);
      if (fixed > 0 && mounted) bump(ref);
    } catch (_) {}
  }

  Future<void> _startJoinRequestWatcher() async {
    try {
      final repo = ref.read(repoProvider);
      if (!await repo.isWorkspaceOwner()) return;
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty || !mounted) return;
      final ws = await repo.activeWorkspaceId();
      _joinReqWatcher = JoinRequestWatcher(
        backendUrl: url,
        workspaceId: ws,
        onRequestsChanged: () {
          if (mounted) _checkJoinRequests();
        },
      )..start();
    } catch (_) {}
  }

  @override
  void dispose() {
    _joinReqWatcher?.stop();
    super.dispose();
  }

  bool _joinSheetOpen = false;

  Future<void> _checkJoinRequests() async {
    if (!mounted || _joinSheetOpen) return;
    // منع الاستدعاء المتكرر السريع (debounce 2 ثانية)
    final now = DateTime.now();
    if (now.difference(_lastCheck).inSeconds < 2) return;
    _lastCheck = now;
    try {
      final repo = ref.read(repoProvider);
      if (!await repo.isWorkspaceOwner()) return;
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) return;
      final ws = await repo.activeWorkspaceId();
      final db = await repo.database;
      var reqs = await CloudJoin.fetchJoinRequests(repo,
          backendUrl: url, workspaceId: ws);
      // فلتر إضافي: لا تعرض ما وافقنا عليه للتو في هذه الجلسة
      reqs = reqs.where((r) {
        final id = '${r['deviceId'] ?? ''}';
        return !_recentlyApproved.contains(id);
      }).toList();
      if (reqs.isEmpty || !mounted) return;
      _joinSheetOpen = true;
      final firstId = '${reqs.first['deviceId'] ?? ''}';
      await showJoinApprovalSheet(context, ref, reqs.first,
          backendUrl: url, workspaceId: ws);
      // بعد إغلاق النافذة: إن تمت الموافقة، سجّل الجهاز كمُعالج
      // حتى لا يظهر مرة أخرى حتى لو بقيت عقدة approved في السحابة
      if (firstId.isNotEmpty) {
        // تحقق هل الجهاز أصبح مقترناً فعلاً؟
        final dev = await db.query('devices',
            where: 'id = ? AND is_paired = 1', whereArgs: [firstId], limit: 1);
        if (dev.isNotEmpty) {
          _recentlyApproved.add(firstId);
          // (إصلاح حرج 2026-09-18 — سباق الموافقة/الاختفاء) الحذف الفوري
          // للطلب هنا كان سباقاً قاتلاً: العضو قد يكون بين رؤية approved
          // وسحب اللقطة بضع ثوانٍ، فيصادف استطلاعه عقدة محذوفة ويرمي
          // «انتهى طلب الانضمام أو حُذف من المدير» رغم الموافقة.
          // مسؤولية الحذف الآن: (1) جهاز العضو كآخر خطوة في
          // completeApprovedJoin بعد نجاح الحفظ في SQLite، (2) التقليم
          // الدوري pruneStaleJoinRequests بعد مهلة 10 دقائق.
        }
      }
      _joinSheetOpen = false;
      if (mounted) bump(ref);
      // إن كانت هناك طلبات أخرى معلقة، اعرض التالي بعد مهلة قصيرة
      if (mounted) {
        final remaining = await CloudJoin.fetchJoinRequests(repo,
            backendUrl: url, workspaceId: ws);
        final filtered = remaining.where((r) {
          final id = '${r['deviceId'] ?? ''}';
          return !_recentlyApproved.contains(id);
        }).toList();
        if (filtered.isNotEmpty) {
          await Future<void>.delayed(const Duration(seconds: 1));
          if (mounted) _checkJoinRequests();
        }
      }
    } catch (_) {
      _joinSheetOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // حارس صلاحيات: المدير فقط.
    final isOwnerAsync = ref.watch(isOwnerProvider);
    return isOwnerAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('إدارة المجموعة')),
        body: EmptyState(
          icon: Icons.error_outline,
          title: 'خطأ',
          message: '$e',
        ),
      ),
      data: (isOwner) {
        if (!isOwner) {
          return Scaffold(
            appBar: AppBar(title: const Text('إدارة المجموعة')),
            body: const EmptyState(
              icon: Icons.block,
              title: 'غير مصرّح',
              message:
                  'هذه الشاشة للمدير (مالك المجموعة) فقط.\nاطلب من المدير منحك صلاحية إدارة المستخدمين.',
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('أجهزة وأعضاء المجموعة'),
            actions: [
              // (باقة المؤسسات) عدّاد المقاعد الدائم أمام المدير.
              const Center(child: SeatUsageBadge()),
              const SizedBox(width: 8),
              // (دفعة 56) تنظيف كل الأجهزة المطرودة دفعة واحدة.
              IconButton(
                tooltip: 'تنظيف الأجهزة المطرودة',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () => _purgeAllExpelled(context),
              ),
              IconButton(
                tooltip: 'إضافة جهاز جديد',
                icon: const Icon(Icons.add_link),
                // (3.70.0) بوابة الأمان: حساب Google موثق شرط للربط.
                onPressed: () async {
                  if (await _ensureGoogleLinked(context) && context.mounted) {
                    _showPairHub(context);
                  }
                },
              ),
            ],
          ),
          body: const _DevicesTab(),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () async {
              if (await _ensureGoogleLinked(context) && context.mounted) {
                _showPairHub(context);
              }
            },
            icon: const Icon(Icons.qr_code_2),
            label: const Text('ربط جهاز جديد'),
          ),
        );
      },
    );
  }

  /// (دفعة 56) «تنظيف الأجهزة المطرودة»: حذف نهائي لكل البطاقات
  /// المطرودة دفعة واحدة — محلياً وسحابياً.
  Future<void> _purgeAllExpelled(BuildContext context) async {
    Sfx.click();
    final repo = ref.read(repoProvider);
    final engine = ref.read(syncEngineProvider);
    List<String> ids;
    try {
      ids = await repo.expelledDeviceIds();
    } catch (e) {
      if (context.mounted) showSnack(context, 'تعذّر: $e', error: true);
      return;
    }
    if (!context.mounted) return;
    if (ids.isEmpty) {
      showSnack(context, 'لا توجد أجهزة مطرودة في السجل.');
      return;
    }
    final ok = await confirmDialog(
      context,
      title: 'تنظيف الأجهزة المطرودة',
      message: 'سيُحذف ${ids.length} جهاز مطرود نهائياً من السجل '
          'ومن السحابة. لا يمكن التراجع.',
      confirmText: 'حذف الكل نهائياً',
      danger: true,
    );
    if (ok != true) return;
    var done = 0;
    for (final id in ids) {
      try {
        await engine.purgeDeviceRecordEverywhere(id);
        done++;
      } catch (_) {}
    }
    Sfx.success();
    if (context.mounted) {
      bump(ref);
      showSnack(context, '✅ حُذف $done من ${ids.length} جهاز مطرود نهائياً.');
    }
  }

  /// (3.70.0 — بوابة الأمان) حظر توليد رموز الدعوة (QR/PIN) أو إضافة
  /// أجهزة إلا إذا كان حساب Google موثقاً في جدول google_auth — مع مسار
  /// تسجيل فوري من داخل البوابة نفسها.
  Future<bool> _ensureGoogleLinked(BuildContext context) async {
    try {
      final db = await ref.read(repoProvider).database;
      final r = await db.query('google_auth', where: 'id = 1', limit: 1);
      if (r.isNotEmpty && '${r.first['google_id'] ?? ''}'.trim().isNotEmpty) {
        return true;
      }
    } catch (_) {}
    if (!context.mounted) return false;
    final signIn = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('بوابة الأمان — حساب Google مطلوب'),
        content: const Text(
          'لحماية مجموعتك، إنشاء رموز الدعوة (QR/PIN) وربط الأجهزة متاح '
          'فقط بعد توثيق حساب Google للمنشأة.\n\n'
          'سجّل الدخول بحساب Google الآن للمتابعة.',
          style: TextStyle(height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.login_rounded, size: 18),
            label: const Text('تسجيل الدخول بـ Google'),
          ),
        ],
      ),
    );
    if (signIn != true || !context.mounted) return false;
    try {
      final repo = ref.read(repoProvider);
      final db = await repo.database;
      final res = await GoogleAuthService(db).signIn();
      final gu = res.user;
      if (gu == null) {
        if (context.mounted) {
          showSnack(context, res.error ?? 'تعذّر تسجيل الدخول', error: true);
        }
        return false;
      }
      // البريد الإلكتروني هو هوية المدير الوحيدة؛ الأعضاء لا يدخلون
      // بالبريد، بل عبر QR/PIN. استخدم نفس مسار الربط المركزي هنا أيضاً.
      final tok = gu.idToken ?? '';
      FirebaseAccount? account;
      if (tok.isNotEmpty) {
        account = await FirebaseAuthRest.signInWithGoogleIdToken(tok);
      }
      account ??= FirebaseAccount(
        uid: gu.id,
        email: gu.email,
        displayName: gu.displayName ?? '',
      );
      final st = await repo.settings();
      final backendUrl = effectiveBackendUrl(st['cloudBackendUrl']);
      final outcome = await AccountWorkspace.linkAccountOnly(
        repo,
        backendUrl: backendUrl,
        account: account,
      );
      if (outcome == AccountLinkOutcome.failed ||
          outcome == AccountLinkOutcome.memberUntouched) {
        if (context.mounted) {
          showSnack(context, 'تعذّر اعتماد حساب المدير لهذه المنشأة', error: true);
        }
        return false;
      }
      if (context.mounted) bump(ref);
      return true;
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'تعذّر توثيق الحساب: $e', error: true);
      }
      return false;
    }
  }

  void _showPairHub(BuildContext context) {
    Sfx.click();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _PairHubSheet(),
    );
  }
}

// ═══════════════════════════ تبويب الأجهزة ════════════════════════════
class _DevicesTab extends ConsumerStatefulWidget {
  const _DevicesTab();
  @override
  ConsumerState<_DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends ConsumerState<_DevicesTab> {
  Future<void> _editDevicePermissions(
    BuildContext context,
    WidgetRef ref,
    Map<String, Object?> device,
  ) async {
    final users = ref.read(usersProvider).valueOrNull ?? const <AppUser>[];
    final uid = device['user_id'] as int?;
    AppUser? current;
    if (uid != null) {
      try {
        current = users.firstWhere((u) => u.id == uid);
      } catch (_) {
        current = null;
      }
    }
    var role = current?.role ?? UserRole.viewer;
    var perms = <String>{
      ...kPerms
          .where((p) => (current?.permissions[p.key] ?? false))
          .map((p) => p.key)
    };
    // نلتقط المراجع قبل فتح النافذة: الشاشة الخلفية يُعاد بناؤها مع كل
    // نشاط مزامنة، وإن أُتلفت أثناء فتح النافذة يصبح ref غير صالح
    // («Cannot use ref after the widget was disposed») فيفشل الحفظ.
    final repo = ref.read(repoProvider);
    final engine = ref.read(syncEngineProvider);

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          void setRole(UserRole r) {
            setDlg(() {
              role = r;
              perms = defaultPerms(r)
                  .entries
                  .where((e) => e.value)
                  .map((e) => e.key)
                  .toSet();
            });
          }

          // دور المدير لا يُمنح لأي عضو — الوكيل أعلى دور متاح، يقوم
          // بعمل المدير أثناء غيابه ويملك كل الصلاحيات افتراضياً.
          final isAgent = role == UserRole.agent;
          return AlertDialog(
            title: Text('صلاحيات: ${device['name'] ?? 'الجهاز'}'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('الدور',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      // «مدير النظام» محذوف من الخيارات: لا يُمنح لأي عضو.
                      for (final r in UserRole.values)
                        if (r != UserRole.admin)
                          ChoiceChip(
                            label: Text('${r.icon} ${r.label}'),
                            selected: role == r,
                            onSelected: (_) => setRole(r),
                          ),
                    ],
                  ),
                  if (isAgent)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '🛡️ الوكيل يقوم بعمل المدير أثناء غيابه — يملك كل '
                        'الصلاحيات، ويمكنك تعديلها بدقة أدناه.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: AppColors.infoOf(ctx),
                        ),
                      ),
                    ),
                  const SizedBox(height: 14),
                  const Text('الصلاحيات التفصيلية',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  for (final p in kPerms)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: perms.contains(p.key),
                      title: Text(p.label),
                      onChanged: (v) => setDlg(() {
                        if (v == true) {
                          perms.add(p.key);
                        } else {
                          perms.remove(p.key);
                        }
                      }),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    // repo/engine مُلتقطان قبل فتح النافذة — لا نلمس ref
                    // هنا إطلاقاً: قد تكون الشاشة الخلفية أُتلفت وأُعيد
                    // بناؤها أثناء بقاء النافذة مفتوحة.
                    await repo.setDevicePermissions(
                        device['id'] as String, role, perms);
                    // فرض فوري: نبثّ إشعارًا لكل الأقران ليسحب الجهاز المعني
                    // صلاحياته الجديدة خلال ثوانٍ (<10 ثوانٍ) دون انتظار الدورية.
                    await engine.broadcastRosterChange();
                    if (ctx.mounted) Navigator.pop(ctx);
                    Sfx.success();
                  } catch (e) {
                    Sfx.error();
                    if (ctx.mounted) {
                      showSnack(ctx, 'تعذّر حفظ الصلاحيات: $e', error: true);
                    }
                  }
                },
                child: const Text('حفظ الصلاحيات'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devicesAsync = ref.watch(devicesProvider);
    final usersAsync = ref.watch(usersProvider);

    return devicesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          EmptyState(icon: Icons.error_outline, title: 'خطأ', message: '$e'),
      data: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.devices_other,
            title: 'لا توجد أجهزة',
            message:
                'اضغط زر + في الأعلى لربط أول جهاز عبر QR أو الرمز أو IP يدوي.',
          );
        }
        // مراجع مُلتقطة مرة واحدة: كل الاستدعاءات أدناه تحدث بعد await
        // (نوافذ تأكيد/إدخال) وقد تُتلف الشاشة أثناءها — استعمال ref
        // بعد الإتلاف يرمي «Cannot use ref after the widget was disposed».
        final repo = ref.read(repoProvider);
        final engine = ref.read(syncEngineProvider);
        void safeBump() {
          if (mounted) bump(ref);
        }

        final hostRow =
            list.where((r) => ((r['is_owner'] ?? 0) as int) == 1).toList();
        final hostId =
            hostRow.isNotEmpty ? hostRow.first['id'] as String : null;
        final myDevId = repo.deviceId;
        final initialOwn = list
                .where((r) => myDevId != null && r['id'] == myDevId)
                .firstOrNull ??
            (hostRow.isNotEmpty ? hostRow.first : null);

        return Builder(
          builder: (ctx) {
            final own = initialOwn;
            final ownId = (own?['id'] as String?) ?? myDevId ?? hostId;
            final amITheOwner =
                own != null && ((own['is_owner'] ?? 0) as int) == 1;
            final memberDevices = list
                .where((d) =>
                    d['id'] != ownId && ((d['is_owner'] ?? 0) as int) != 1)
                .toList();

            return RefreshIndicator(
              onRefresh: () async => bump(ref),
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                children: [
                  // بطاقة جهاز المدير الحالي
                  Card(
                    elevation: 1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.35),
                        width: 1.5,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.admin_panel_settings,
                              color: Theme.of(context).colorScheme.primary,
                              size: 26,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    final name =
                                        (own?['name'] as String?)?.isNotEmpty == true
                                            ? own!['name'] as String
                                            : 'جهاز المدير الأساسي';
                                    final badge = Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.amber.shade700,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Text(
                                        'المالك 👑',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    );
                                    // على الشاشات الضيقة لا نضع اسم الجهاز
                                    // وشارة المالك في صف واحد حتى لا يحدث
                                    // RenderFlex overflow في عرض 360 بكسل.
                                    if (constraints.maxWidth < 250) {
                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          badge,
                                        ],
                                      );
                                    }
                                    return Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        badge,
                                      ],
                                    );
                                  },
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'هذا الجهاز (الجهاز الرئيسي لإدارة المنشأة والمجموعة)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'أجهزة الأعضاء المرتبطة (${memberDevices.length})',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (memberDevices.isEmpty)
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: Theme.of(context)
                              .dividerColor
                              .withValues(alpha: 0.2),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 28),
                        child: Column(
                          children: [
                            Icon(Icons.devices_other,
                                size: 44, color: Colors.grey.shade400),
                            const SizedBox(height: 10),
                            const Text(
                              'لا توجد أجهزة أعضاء مرتبطة بعد',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'اضغط على زر "إضافة جهاز جديد" أدناه لربط أجهزة الموظفين والكاشير عبر رمز QR أو PIN',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    for (final d in memberDevices)
                      DeviceCard(
                        data: d,
                        users: (usersAsync.valueOrNull ?? const <AppUser>[])
                            .cast<AppUser>(),
                        isSelf: d['id'] == ownId,
                        isOwnerDevice: d['id'] == hostId,
                        amITheOwner: amITheOwner,
                        onAssign: (uid) async {
                          await repo.assignDeviceUser(d['id'] as String, uid);
                          await engine.broadcastRosterChange();
                          safeBump();
                        },
                        // (دفعة 51) تعديل الدور مباشرة من البطاقة: يضبط دور
                        // مستخدم الجهاز وصلاحياته الافتراضية ويبثّها فوراً.
                        onRoleChanged: amITheOwner
                            ? (role) async {
                                await repo.setDevicePermissions(
                                  d['id'] as String,
                                  role,
                                  defaultPerms(role)
                                      .entries
                                      .where((e) => e.value)
                                      .map((e) => e.key)
                                      .toSet(),
                                );
                                await engine.broadcastRosterChange();
                                Sfx.success();
                                safeBump();
                              }
                            : null,
                        onPermissions: () async {
                          await _editDevicePermissions(context, ref, d);
                          safeBump();
                        },
                        // (دفعة 56) حذف نهائي من السجل لبطاقة مطرودة/محظورة.
                        onPurge: () async {
                          final ok = await confirmDialog(
                            context,
                            title: 'حذف نهائي من السجل',
                            message:
                                'سيُمحى سجل "${d['name']}" نهائياً من قائمة '
                                'الأجهزة هنا ومن السحابة (roster + شواهد الطرد). '
                                'لا يمكن التراجع — إعادة ربط الجهاز لاحقاً تتم '
                                'بدعوة جديدة كأي جهاز جديد.',
                            confirmText: 'حذف نهائي',
                            danger: true,
                          );
                          if (ok != true) return;
                          try {
                            await engine
                                .purgeDeviceRecordEverywhere(d['id'] as String);
                            Sfx.success();
                            safeBump();
                          } catch (e) {
                            Sfx.error();
                            if (context.mounted) {
                              showSnack(context, 'تعذّر الحذف: $e',
                                  error: true);
                            }
                          }
                        },
                        onRename: () async {
                          final name = await promptDialog(
                            context,
                            title: 'إعادة تسمية الجهاز',
                            initial: (d['name'] ?? '') as String,
                            label: 'اسم الجهاز',
                          );
                          if (name == null || name.trim().isEmpty) return;
                          await repo.renameDevice(
                              d['id'] as String, name.trim());
                          safeBump();
                        },
                        onRevoke: () async {
                          final ok = await confirmDialog(
                            context,
                            title: 'حظر الجهاز',
                            message:
                                'سيُمنع "${d['name']}" من المزامنة حتى إعادة السماح.',
                            confirmText: 'حظر',
                            danger: true,
                          );
                          if (ok == true) {
                            await repo.revokeDevice(d['id'] as String);
                            // (دفعة 54) الحظر أيضاً يبث شاهدة الطرد: الجهاز
                            // المحظور يُقصى لحظياً ويعود لوضع مستقل.
                            await engine.broadcastEviction(d['id'] as String);
                            try {
                              await engine.broadcastRosterChange();
                            } catch (_) {}
                            safeBump();
                          }
                        },
                        onRestore: () async {
                          await repo.restoreDevice(d['id'] as String);
                          // (دفعة 54) حذف شاهدة الطرد وإلا أقصى الجهازُ
                          // المستعاد نفسَه عند فحصه القادم.
                          await engine
                              .clearEvictionBroadcast(d['id'] as String);
                          try {
                            await engine.broadcastRosterChange();
                          } catch (_) {}
                          safeBump();
                        },
                        onExpel: () async {
                          final ok = await confirmDialog(
                            context,
                            title: 'طرد الجهاز',
                            message:
                                'سيُطرد "${d['name']}" من المجموعة ويمسح بياناته عند أول اتصال.',
                            confirmText: 'طرد',
                            danger: true,
                          );
                          if (ok == true) {
                            await repo.expelDevice(d['id'] as String);
                            // (دفعة 54) بروتوكول الطرد النشط: شاهدة صريحة في
                            // /evictions + حذف عقدته من /roster — تصل
                            // المستهدف لحظياً عبر قناته المخصصة.
                            await engine.broadcastEviction(d['id'] as String,
                                reason: 'expelled_by_manager');
                            // بث تغيير السجل لبقية الأجهزة (LAN + roster).
                            try {
                              await engine.broadcastRosterChange();
                            } catch (_) {}
                            safeBump();
                          }
                        },
                        onTransferOwner: () async {
                          // (صمام أمان) فحص جاهزية المستلم قبل التسليم —
                          // جهاز قديم/غائب يُنبَّه عنه قبل نقل الملكية.
                          final warnings = await repo
                              .transferReadinessCheck(d['id'] as String);
                          if (!context.mounted) return;
                          final warnBlock = warnings.isEmpty
                              ? ''
                              : '⚠️ تحذيرات الجاهزية:\n'
                                  '${warnings.map((w) => '• $w').join('\n')}\n\n';
                          final ok = await confirmDialog(
                            context,
                            title: 'تسليم الإدارة',
                            message: '$warnBlock'
                                'سيصبح "${d['name']}" هو المدير وتصبح أنت عضوًا.',
                            confirmText: 'تسليم',
                            danger: true,
                          );
                          if (ok == true) {
                            try {
                              await repo.transferOwnership(d['id'] as String);
                              safeBump();
                              if (context.mounted) {
                                showSnack(context, '✅ تم تسليم الإدارة.');
                                Navigator.of(context)
                                    .popUntil((r) => r.isFirst);
                              }
                            } catch (e) {
                              if (context.mounted) {
                                showSnack(context, 'تعذّر: $e', error: true);
                              }
                            }
                          }
                        },
                        onResetSecret: () async {
                          final ok = await confirmDialog(
                            context,
                            title: 'إعادة تعيين مفتاح الجهاز',
                            message: 'سيفقد الجهاز الاتصال حتى يعيد الاقتران.',
                            confirmText: 'إعادة التعيين',
                            danger: true,
                          );
                          if (ok == true) {
                            final s =
                                await repo.resetDeviceSecret(d['id'] as String);
                            safeBump();
                            if (context.mounted) {
                              showDialog(
                                context: context,
                                builder: (c) => AlertDialog(
                                  title: const Text('المفتاح الجديد'),
                                  content: SelectableText(
                                    s,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(c),
                                      child: const Text('تم'),
                                    ),
                                  ],
                                ),
                              );
                            }
                          }
                        },
                        onCloudLink: () => showCloudInviteDialog(context, ref),
                      ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ═══════════════════════════ نافذة الربط الموحدة ════════════════════════════
class _PairHubSheet extends ConsumerStatefulWidget {
  const _PairHubSheet();
  @override
  ConsumerState<_PairHubSheet> createState() => _PairHubSheetState();
}

class _PairHubSheetState extends ConsumerState<_PairHubSheet> {
  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: .7,
      minChildSize: .5,
      maxChildSize: .95,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'ربط جهاز أو حساب جديد',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            const Text(
              'اختر طريقة الربط المناسبة. ستنضم الأجهزة الجديدة إلى هذه المجموعة وتستلم نسخة من البيانات.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.black54,
                fontSize: 12,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 20),
            // (دفعة 58) الاقتران سحابي حصرياً — أزيلت طرق LAN (QR بعنوان IP،
            // الإدخال اليدوي IP+منفذ، كود التفعيل المحلي) نهائياً.
            _HubTile(
              icon: Icons.cloud_sync_outlined,
              color: const Color(0xFF0EA5E9),
              title: 'ربط عضو عبر السحابة',
              subtitle:
                  'يُنشئ دعوة سحابية (QR + رمز PIN صالح 15 دقيقة) — يمسحها العضو أو يُدخل الرمز، وبعد موافقتك تُستبدل بياناته بنسخة المجموعة.',
              onTap: () {
                final rootContext =
                    Navigator.of(context, rootNavigator: true).context;
                Navigator.pop(context);
                Sfx.click();
                showCloudInviteDialog(rootContext, ref);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _HubTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _HubTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Colors.black54,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_left, color: Colors.black38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════ موافقة المدير على طلبات الانضمام (دفعة 51) ═══════════════

/// نافذة «طلب انضمام جهاز جديد»: اسم الجهاز + بصمته + اختيار الدور،
/// وزرا «قبول وتفعيل» / «رفض». تُستدعى تلقائياً عند رصد طلب معلّق.
/// (إصلاح حرج 2026-09-18 — النوافذ المتعددة) قفل عام واحد لنوافذ
/// الموافقة: مراقبان مستقلان (قناة HomeShell العامة + قناة هذه الشاشة)
/// كان كل منهما يفتح نافذته الخاصة لنفس الطلب، فتتكدس نوافذ موافقة
/// مكررة فوق بعضها ويتضاعف القبول. القفل فحص-وإسناد متزامن عند مدخل
/// الدالة نفسها — بلا فجوة سباق، وأي مراقب ثانٍ يعود فوراً بصمت.
final Set<String> _activeJoinDialogKeys = <String>{};

Future<void> showJoinApprovalSheet(
  BuildContext context,
  WidgetRef ref,
  Map<String, Object?> request, {
  required String backendUrl,
  String? workspaceId,
}) async {
  final dialogKey = '${request['kind'] ?? 'join'}:${request['deviceId'] ?? ''}';
  if (!_activeJoinDialogKeys.add(dialogKey)) {
    return; // نافذة مفتوحة بالفعل لنفس الطلب — لا تكرار
  }
  try {
    // (دفعة 58 — متطلب 11) طلب مغادرة عضو يمر من نفس القناة بوسم kind=leave
    // — له حوار خاص (موافقة = طرد نظيف، رفض = بقاء العضو).
    if ('${request['kind'] ?? ''}' == 'leave') {
      return showLeaveApprovalDialog(context, ref, request,
          backendUrl: backendUrl);
    }
    final repo = ref.read(repoProvider);
    final engine = ref.read(syncEngineProvider);
    final ws = (workspaceId != null && workspaceId.trim().isNotEmpty)
        ? workspaceId.trim()
        : repo.requireWorkspaceId;
    final deviceId = '${request['deviceId'] ?? ''}';
    final deviceName = '${request['deviceName'] ?? 'جهاز جديد'}';
    final fp = '${request['fingerprint'] ?? ''}';
    final platform = '${request['platform'] ?? ''}';
    var role = UserRole.cashier;
    // (دفعة 65) قفل الموافقة: يمنع النقر المتكرر ويُظهر تقدماً واضحاً.
    var approving = false;
    Sfx.notify();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                18, 18, 18, 18 + MediaQuery.viewInsetsOf(ctx).bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0EA5E9).withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.devices_other,
                          color: Color(0xFF0EA5E9)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('طلب انضمام جهاز جديد',
                              style: TextStyle(
                                  fontSize: 15.5, fontWeight: FontWeight.w800)),
                          Text(
                            deviceName,
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  // (دفعة 56) وسم منصة نظيف بدل القيمة الخام.
                  'الجهاز: ${switch (platform) {
                    'android' => 'Android',
                    'ios' => 'iPhone',
                    'windows' => 'Windows',
                    'linux' => 'Linux',
                    'macos' => 'Mac',
                    _ => 'جهاز',
                  }}${fp.isEmpty ? '' : '  ·  بصمة العتاد: $fp'}',
                  style:
                      TextStyle(fontSize: 11.5, color: AppColors.text3Of(ctx)),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<UserRole>(
                  initialValue: role,
                  decoration: const InputDecoration(
                    labelText: 'الدور والصلاحيات',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final r in UserRole.values)
                      if (r != UserRole.admin)
                        DropdownMenuItem(
                            value: r, child: Text('${r.icon} ${r.label}')),
                  ],
                  onChanged: (v) =>
                      setSheet(() => role = v ?? UserRole.cashier),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red),
                        icon: const Icon(Icons.close),
                        label: const Text('رفض'),
                        onPressed: () async {
                          try {
                            await CloudJoin.rejectJoinRequest(repo,
                                backendUrl: backendUrl,
                                deviceId: deviceId,
                                workspaceId: ws);
                          } catch (_) {}
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        icon: approving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.check_circle_outline),
                        label:
                            Text(approving ? 'جارٍ التفعيل…' : 'قبول وتفعيل'),
                        // (دفعة 65) الزر كان بلا قفل وبلا مؤشر: الموافقة
                        // سلسلة كتابات سحابية متتابعة، فبدا ميتاً فينقره
                        // المدير مراراً فتتضاعف الموافقات. الآن: قفل +
                        // مؤشر تقدم + مهلة قصوى + رسالة خطأ واضحة.
                        onPressed: approving
                            ? null
                            : () async {
                                setSheet(() => approving = true);
                                try {
                                  await CloudJoin.approveJoinRequest(repo,
                                          backendUrl: backendUrl,
                                          deviceId: deviceId,
                                          deviceName: deviceName,
                                          roleCode: role.code,
                                          workspaceId: ws)
                                      .timeout(kCloudOpTimeout);
                                  await engine.broadcastRosterChange();
                                  Sfx.pair();
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  return;
                                } on TimeoutException catch (_) {
                                  if (ctx.mounted) {
                                    showSnack(
                                        ctx,
                                        'انتهت مهلة الاتصال '
                                        '(${kCloudOpTimeout.inSeconds} ثانية) — '
                                        'تحقّق من الشبكة ثم أعد المحاولة.',
                                        error: true);
                                  }
                                } catch (e) {
                                  if (ctx.mounted) {
                                    showSnack(ctx, 'تعذّر القبول: $e',
                                        error: true);
                                  }
                                }
                                if (ctx.mounted) {
                                  setSheet(() => approving = false);
                                }
                              },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  } finally {
    _activeJoinDialogKeys.remove(dialogKey);
  }
}

/// (دفعة 58 — متطلب 11) حوار موافقة المدير على طلب مغادرة عضو:
/// الموافقة تنفّذ فك ارتباط نظيفاً كاملاً (طرد محلي + بث شاهدة سحابية
/// فيمسح جهاز العضو بيانات المجموعة ويعود مستقلاً)، والرفض يبقيه عضواً.
Future<void> showLeaveApprovalDialog(
  BuildContext context,
  WidgetRef ref,
  Map<String, Object?> request, {
  required String backendUrl,
}) async {
  final repo = ref.read(repoProvider);
  final engine = ref.read(syncEngineProvider);
  final deviceId = '${request['deviceId'] ?? ''}';
  final deviceName = '${request['deviceName'] ?? 'جهاز عضو'}';
  Sfx.notify();
  final approve = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.logout, color: Colors.orange, size: 40),
      title: const Text('طلب مغادرة المجموعة'),
      content: Text(
        'الجهاز «$deviceName» يطلب مغادرة المجموعة.\n\n'
        'الموافقة تفكّ ارتباطه نظيفاً: تُحذف بيانات المجموعة من جهازه '
        'ويعود مستقلاً، وتختفي عملياته المعلقة من متابعة المزامنة.',
        style: const TextStyle(height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('رفض — يبقى عضواً'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.orange),
          onPressed: () => Navigator.pop(ctx, true),
          icon: const Icon(Icons.check),
          label: const Text('الموافقة على المغادرة'),
        ),
      ],
    ),
  );
  final ws = await repo.activeWorkspaceId();

  if (approve != true) {
    try {
      await CloudJoin.rejectJoinRequest(repo,
          backendUrl: backendUrl, deviceId: deviceId, workspaceId: ws);
    } catch (_) {}
    return;
  }

  // 1) أولاً: اعتماد الطلب في السحابة ليلتقطه جهاز العضو فوراً
  try {
    await CloudJoin.approveLeaveRequest(
      backendUrl: backendUrl,
      workspaceId: ws,
      deviceId: deviceId,
    );
  } catch (_) {}

  // 2) بث شاهدة الإبطال
  try {
    await engine.broadcastEviction(deviceId, reason: 'leave_approved');
  } catch (_) {}

  // 3) إبادة وحذف سجل الجهاز نهائياً من السحابة (roster + devices + device_index)
  try {
    await CloudJoin.expelMemberCompletely(
      repo,
      backendUrl: backendUrl,
      deviceId: deviceId,
      workspaceId: ws,
    );
    await CloudJoin.purgeDeviceRecordFromCloud(
      backendUrl: backendUrl,
      deviceId: deviceId,
      workspaceId: ws,
    );
  } catch (_) {}

  // 4) حذف الجهاز نهائياً ومحلياً من قاعدة بيانات المدير
  try {
    await repo.expelDevice(deviceId);
    await repo.purgeDeviceRecord(deviceId);
  } catch (_) {}

  // 5) بث تحديث السجل وتحديث الشاشة فوراً
  try {
    await engine.broadcastRosterChange();
  } catch (_) {}

  if (context.mounted) {
    bump(ref);
    showSnack(context, '✅ تمت الموافقة على المغادرة وحذف العضو نهائياً من المجموعة.');
  }

  // 6) تنظيف الطلب بعد 15 ثانية لضمان التقاط العضو للاعتماد
  Future.delayed(const Duration(seconds: 15), () async {
    try {
      await CloudJoin.deleteJoinRequest(
          backendUrl: backendUrl, workspaceId: ws, deviceId: deviceId);
    } catch (_) {}
  });
}
