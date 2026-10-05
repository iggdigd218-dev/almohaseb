// قسم «حساب المؤسسة (Google)» في الإعدادات — الهوية الدائمة للمؤسسة.
//
// للمدير/المستقل فقط: يعرض الحساب المربوط (البريد الإلكتروني) أو زر
// تسجيل الدخول. الربط يجعل مساحة العمل والترخيص يتبعان الحساب —
// فيستعيد المستخدم كل شيء على أي هاتف بمجرد تسجيل الدخول.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/repository.dart';
import '../data/sync/firebase_auth_service.dart';
import '../data/sync/cloud_join.dart';
import '../data/sync/subscription_guard.dart';
import 'profile_dialog.dart';

class AccountSection extends ConsumerStatefulWidget {
  const AccountSection({super.key});

  @override
  ConsumerState<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends ConsumerState<AccountSection> {
  String _email = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(repoProvider);
    final email = await FirebaseAuthRest.savedEmail(repo);
    if (!mounted) return;
    setState(() {
      _email = email;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final linked = _email.isNotEmpty;
    return Card(
      child: ListTile(
        leading: Icon(
          linked ? Icons.verified_user_outlined : Icons.account_circle_outlined,
          color: linked ? const Color(0xFF059669) : const Color(0xFF0284C7),
        ),
        title: Text(linked ? 'حساب Google المرتبط' : 'حساب Google والمنشأة'),
        subtitle: Text(
          linked
              ? '$_email\nتتم إدارة الحساب والمزامنة وربط الأعضاء من أيقونة الحساب أعلى القائمة الجانبية.'
              : 'لتسجيل الدخول بحساب Google أو الانضمام لمجموعة، انقر على أيقونة الحساب أعلى القائمة الجانبية.',
          style: const TextStyle(fontSize: 11.5, height: 1.5),
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.open_in_new_rounded, size: 18),
        onTap: () async {
          await showAccountProfileDialog(context, ref);
          if (mounted) await _load();
        },
      ),
    );
  }
}


/// (قانون 2026-09-19) تهيئة سحابية بعد تسجيل Google — مشتركة بين قسم
/// الحساب في الإعدادات وشاشة الترحيب حتى يسجّل المسارَان سواءً تماماً.
Future<void> provisionCloudAfterSignIn(
    Repo repo, WidgetRef ref, String url) async {
  if (url.isEmpty) return;
  try {
    final ws = await repo.activeWorkspaceId();
    await CloudJoin.ensureOwnerMembership(repo,
        backendUrl: url, workspaceId: ws);
    await SubscriptionGuard.ensureTrialStarted(repo,
        backendUrl: url, workspaceId: ws);
    ref.invalidate(subscriptionProvider);
  } catch (_) {
    // خلفية صامتة.
  }
  // ══ (2026-09-22) الجلب التلقائي الكامل بعد تسجيل جوجل ══
  // فور اكتمال الدخول: تُعاد تهيئة محرك المزامنة بالجلسة الجديدة وتُجلب
  // كل بيانات الجهاز والمؤسسة مباشرة (دفع الطابور + سحب سحابي كامل) —
  // لا انتظار للدورة الدورية ولا استرجاع بصمة مجهول بعد اليوم.
  try {
    final engine = ref.read(syncEngineProvider);
    engine.stop();
    await engine.start();
    ref.invalidate(workspaceModeProvider);
    unawaited(engine.forceSyncNow());
  } catch (_) {
    // خلفية صامتة — الدورة الدورية تكمل لاحقاً.
  }
}
