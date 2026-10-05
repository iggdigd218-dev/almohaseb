// (3.70 — المرحلة 5) مسار تسجيل الخروج المؤمَّن:
//
//  • المدير/الوكيل/الحساب الفردي: تحقق أمان الجهاز (بصمة/قفل شاشة عند
//    توفرها) ⇒ تعيين أحد الأعضاء «وكيلاً» عند وجود أعضاء ⇒ خروج.
//    النظام ومزامنة باقي الأجهزة تستمر بشكل طبيعي أثناء الغياب (المحرك
//    لا يتوقف وجلسة السحابة المجهولة تبقى)، وتُستعاد الحساب والصلاحيات
//    فوراً بمجرد إدخال البريد وكلمة المرور.
//  • الموظف/العضو: الخروج الفوري محجوب — الضغط على الزر يتحول إلى طلب
//    موافقة يُرسل إلى المدير أو الوكيل عبر السحابة، ويبقى جهازه يعمل
//    حتى الاعتماد (أو يظهر له الرفض).
//
// كل واجهة تُفتح عبر سياق الملاحة العام بفحص mounted صريح — لا استخدام
// لسياق ميت بعد أي انتظار (use_build_context_synchronously نظيف).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cloud_config.dart';
import '../core/models.dart';
import '../core/security.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import '../data/sync/firebase_auth_service.dart';
import '../data/sync/google_auth_service.dart';
import '../data/sync/logout_requests.dart';
import 'widgets.dart';

/// نقطة الدخول الوحيدة لزر «تسجيل الخروج» في القائمة الجانبية.
Future<void> showSecuredLogout(WidgetRef ref) async {
  final repo = ref.read(repoProvider);
  final st = await repo.settings();
  final individual = (st[Repo.accountModeKey] ?? '') == 'individual';
  final email = (st[Repo.accountEmailKey] ?? '').trim().toLowerCase();
  final me = await repo.currentUser();
  final isOwner = await repo.isWorkspaceOwner();
  final adminSide = individual ||
      isOwner ||
      me?.role == UserRole.admin ||
      me?.role == UserRole.agent;
  if (adminSide) {
    await _adminLogout(ref, repo,
        individual: individual, isOwner: isOwner, me: me, email: email);
  } else {
    await _employeeLogout(ref, repo, email: email, name: me?.name ?? '');
  }
}

Future<void> _adminLogout(
  WidgetRef ref,
  Repo repo, {
  required bool individual,
  required bool isOwner,
  AppUser? me,
  required String email,
}) async {
  // 1) التحقق من أمان الجهاز — البصمة/قفل الشاشة إن توفر.
  if (await Security.biometricsAvailable()) {
    final ok =
        await Security.authenticate(reason: 'تحقق أمني قبل تسجيل الخروج');
    if (!ok) {
      final c0 = rootNavigatorKey.currentContext;
      if (c0 != null && c0.mounted) {
        showSnack(c0, 'أُلغي الخروج — لم ينجح التحقق الأمني', error: true);
      }
      return;
    }
  }
  // 2) اشتراط وكيل: المدير/المالك فقط (الوكيل نفسه لا يحتاج وكيلاً،
  //    والفردي لا أعضاء لديه).
  if (!individual && isOwner && me?.role != UserRole.agent) {
    final users = await repo.users();
    final candidates = users
        .where((u) =>
            u.active &&
            u.email.trim().isNotEmpty &&
            u.email.toLowerCase() != email &&
            u.role != UserRole.admin)
        .toList();
    if (candidates.isNotEmpty) {
      final c1 = rootNavigatorKey.currentContext;
      if (c1 == null || !c1.mounted) return;
      final picked = await _pickDeputy(c1, candidates);
      if (picked == null) return; // تراجع عن الخروج.
      await repo.promoteToDeputy(picked.email);
    } else {
      final c2 = rootNavigatorKey.currentContext;
      if (c2 == null || !c2.mounted) return;
      final go = await confirmDialog(
        c2,
        title: 'لا يوجد أعضاء للوكالة',
        message: 'لا يوجد عضو ببريد مسجَّل لتعيينه وكيلاً.\n'
            'النظام والمزامنة يستمران تلقائياً أثناء غيابك.\n\n'
            'هل تريد متابعة الخروج؟',
        confirmText: 'متابعة الخروج',
        danger: true,
      );
      if (go != true) return;
    }
  }
  // 3) التأكيد النهائي ثم التنفيذ.
  final c3 = rootNavigatorKey.currentContext;
  if (c3 == null || !c3.mounted) return;
  final ok = await confirmDialog(
    c3,
    title: 'تسجيل الخروج',
    message: 'سيستمر النظام ومزامنة باقي الأجهزة بشكل طبيعي أثناء غيابك.\n'
        'تستعيد حسابك وصلاحياتك فوراً بإدخال بريدك وكلمة مرورك.',
    confirmText: 'خروج',
    danger: true,
  );
  if (ok != true) return;
  await _performSignOut(ref, repo);
}

Future<AppUser?> _pickDeputy(BuildContext ctx, List<AppUser> candidates) {
  return showDialog<AppUser>(
    context: ctx,
    builder: (dctx) => AlertDialog(
      title: const Text('تعيين وكيل قبل الخروج'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'اختر العضو الذي سيدير العمليات ويعتمد طلبات الخروج أثناء غيابك:',
              style: TextStyle(fontSize: 12.5, height: 1.6),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final u in candidates)
                    ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.radio_button_unchecked,
                        size: 20,
                      ),
                      title: Text(u.name.isEmpty ? u.email : u.name,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(u.email,
                          style: const TextStyle(fontSize: 11)),
                      onTap: () =>
                          Navigator.of(dctx).pop(u), // اختيار = تأكيد
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(),
          child: const Text('إلغاء الخروج'),
        ),
      ],
    ),
  );
}

Future<void> _performSignOut(WidgetRef ref, Repo repo) async {
  try {
    final db = await repo.database;
    try {
      await GoogleAuthService(db).signOut();
    } catch (_) {}
    await FirebaseAuthRest.clearSession(repo);
    // جلسة مجهولة صامتة بديلة — المزامنة المحلية والسحابية تستمر
    // دون انقطاع أثناء غياب المدير (لا توقف للمحرك ولا لمسار الطابور).
    await FirebaseAuthRest.initSilentAuth(repo);
    ref.invalidate(googleLinkedProvider);
    ref.invalidate(settingsProvider);
    ref.invalidate(drawerPhotoProvider);
    ref.read(refreshProvider.notifier).state++;
    final c = rootNavigatorKey.currentContext;
    if (c != null && c.mounted) {
      showSnack(c, 'تم تسجيل الخروج — النظام والمزامنة مستمران؛ '
          'عودتك فورية ببريدك وكلمة مرورك');
    }
  } catch (e) {
    final c = rootNavigatorKey.currentContext;
    if (c != null && c.mounted) {
      showSnack(c, 'تعذّر تسجيل الخروج: $e', error: true);
    }
  }
}

// ==================== مسار الموظف: طلب موافقة ====================

Future<void> _employeeLogout(
  WidgetRef ref,
  Repo repo, {
  required String email,
  required String name,
}) async {
  final st = await repo.settings();
  final url = effectiveBackendUrl(st['cloudBackendUrl']);
  if (url.isEmpty || email.isEmpty) {
    final c0 = rootNavigatorKey.currentContext;
    if (c0 == null || !c0.mounted) return;
    final ok = await confirmDialog(
      c0,
      title: 'تسجيل الخروج',
      message: 'لا توجد سحابة أو بريد لإرسال طلب الموافقة — '
          'سيُنفَّذ الخروج مباشرة على هذا الجهاز.',
      confirmText: 'خروج',
      danger: true,
    );
    if (ok != true) return;
    await _performSignOut(ref, repo);
    return;
  }
  String reqId;
  try {
    reqId = await LogoutRequests.create(
      repo,
      backendUrl: url,
      workspaceId: repo.requireWorkspaceId,
      email: email,
      name: name,
    );
  } catch (e) {
    final c1 = rootNavigatorKey.currentContext;
    if (c1 != null && c1.mounted) showSnack(c1, 'تعذّر إرسال طلب الخروج: $e', error: true);
    return;
  }
  final c2 = rootNavigatorKey.currentContext;
  if (c2 == null || !c2.mounted) return;
  await showDialog<void>(
    context: c2,
    barrierDismissible: false,
    builder: (dctx) => _PendingLogoutDialog(
      backendUrl: url,
      workspaceId: repo.requireWorkspaceId,
      requestId: reqId,
      onApproved: () async {
        if (dctx.mounted) Navigator.of(dctx).pop();
        await _performSignOut(ref, repo);
      },
    ),
  );
}

class _PendingLogoutDialog extends StatefulWidget {
  final String backendUrl;
  final String workspaceId;
  final String requestId;
  final Future<void> Function() onApproved;
  const _PendingLogoutDialog({
    required this.backendUrl,
    required this.workspaceId,
    required this.requestId,
    required this.onApproved,
  });

  @override
  State<_PendingLogoutDialog> createState() => _PendingLogoutDialogState();
}

class _PendingLogoutDialogState extends State<_PendingLogoutDialog> {
  Timer? _timer;
  String _status = 'pending';
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_done) return;
    try {
      final s = await LogoutRequests.statusOf(
        backendUrl: widget.backendUrl,
        workspaceId: widget.workspaceId,
        id: widget.requestId,
      );
      if (!mounted || _done || s.isEmpty || s == _status) return;
      if (s == 'approved') {
        _done = true;
        _timer?.cancel();
        await widget.onApproved();
      } else if (s == 'rejected') {
        _done = true;
        _timer?.cancel();
        setState(() => _status = s);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rejected = _status == 'rejected';
    return AlertDialog(
      title: Text(rejected ? 'رُفض طلب الخروج' : 'طلب الخروج مرسل'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rejected)
            const Text(
              'رفض المدير أو الوكيل طلبك — جهازك يستمر بالعمل كالمعتاد.',
              style: TextStyle(fontSize: 13, height: 1.7),
            )
          else ...[
            const Text(
              'تم إرسال طلب الموافقة إلى المدير أو الوكيل.\n'
              'جهازك يستمر بالعمل حتى الاعتماد.',
              style: TextStyle(fontSize: 13, height: 1.7),
            ),
            const SizedBox(height: 14),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(rejected ? 'حسناً' : 'إغلاق (الطلب يبقى معلقاً)'),
        ),
      ],
    );
  }
}

// ==================== اعتماد الطلبات (مدير/وكيل) ====================

/// ورقة اعتماد/رفض طلبات خروج الموظفين — للمدير والوكيل.
Future<void> showLogoutRequestsSheet(WidgetRef ref) async {
  final c0 = rootNavigatorKey.currentContext;
  if (c0 == null || !c0.mounted) return;
  final repo = ref.read(repoProvider);
  final st = await repo.settings();
  final url = effectiveBackendUrl(st['cloudBackendUrl']);
  final c1 = rootNavigatorKey.currentContext;
  if (c1 == null || !c1.mounted) return;
  if (url.isEmpty) {
    showSnack(c1, 'لا توجد سحابة مرتبطة — لا طلبات خروج', error: true);
    return;
  }
  await showModalBottomSheet<void>(
    context: c1,
    isScrollControlled: true,
    builder: (_) => _LogoutRequestsSheet(
      backendUrl: url,
      workspaceId: repo.requireWorkspaceId,
    ),
  );
}

class _LogoutRequestsSheet extends StatefulWidget {
  final String backendUrl;
  final String workspaceId;
  const _LogoutRequestsSheet({
    required this.backendUrl,
    required this.workspaceId,
  });

  @override
  State<_LogoutRequestsSheet> createState() => _LogoutRequestsSheetState();
}

class _LogoutRequestsSheetState extends State<_LogoutRequestsSheet> {
  late Future<List<LogoutRequestInfo>> _load;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load = LogoutRequests.listPending(
        backendUrl: widget.backendUrl, workspaceId: widget.workspaceId);
  }

  Future<List<LogoutRequestInfo>> _reload() {
    return LogoutRequests.listPending(
        backendUrl: widget.backendUrl, workspaceId: widget.workspaceId);
  }

  Future<void> _resolve(LogoutRequestInfo r, bool approve) async {
    // الالتقاط قبل الانتظار — لا BuildContext بعد أي فجوة async.
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await LogoutRequests.resolve(
        backendUrl: widget.backendUrl,
        workspaceId: widget.workspaceId,
        id: r.id,
        approve: approve,
      );
      messenger.showSnackBar(SnackBar(
          content: Text(approve
              ? 'تم اعتماد خروج ${r.email}'
              : 'رُفض طلب ${r.email}')));
      if (!mounted) return;
      setState(() {
        _load = _reload();
      });
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('تعذّر الحسم: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'طلبات خروج الموظفين',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            FutureBuilder<List<LogoutRequestInfo>>(
              future: _load,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('تعذّر جلب الطلبات: ${snap.error}',
                        style: const TextStyle(fontSize: 12.5)),
                  );
                }
                final list = snap.data ?? const [];
                if (list.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('لا توجد طلبات معلقة.',
                        style: TextStyle(fontSize: 13)),
                  );
                }
                return Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final r in list)
                        ListTile(
                          leading: const Icon(Icons.logout_rounded),
                          title: Text(r.name.isEmpty ? r.email : r.name,
                              style: const TextStyle(fontSize: 13.5)),
                          subtitle: Text(r.email,
                              style: const TextStyle(fontSize: 11)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FilledButton(
                                onPressed:
                                    _busy ? null : () => _resolve(r, true),
                                child: const Text('اعتماد'),
                              ),
                              const SizedBox(width: 6),
                              TextButton(
                                onPressed:
                                    _busy ? null : () => _resolve(r, false),
                                child: const Text('رفض'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
