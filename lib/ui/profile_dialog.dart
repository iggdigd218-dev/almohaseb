// نافذة الحساب الشخصي، تسجيل الدخول بـ Google، ربط الأعضاء، والمنشأة الموحّدة.
//
// تفتح عند النقر على ترويسة الحساب الزرقاء أعلى القائمة الجانبية (المنطقة الوحيدة
// الموحدة لتسجيل الدخول وربط الأعضاء وإدارة الهوية والمنشأة).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../core/cloud_config.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../data/repository.dart';
import '../data/sync/account_workspace.dart';
import '../data/sync/cloud_join.dart';
import '../data/sync/firebase_auth_service.dart';
import '../data/sync/google_auth_service.dart';
import '../data/sync/workspace_service.dart';
import 'account_section.dart';
import 'join_approval_flow.dart';
import 'logout_flow.dart';
import 'qr_pair_scanner.dart';
import 'widgets.dart';

Future<void> showAccountProfileDialog(BuildContext context, WidgetRef ref) async {
  Sfx.click();
  await showDialog<void>(
    context: context,
    builder: (ctx) => const _ProfileDialog(),
  );
}

class _ProfileDialog extends ConsumerStatefulWidget {
  const _ProfileDialog();

  @override
  ConsumerState<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends ConsumerState<_ProfileDialog> {
  late final TextEditingController _userNameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _bizNameCtrl;
  late final TextEditingController _bizActivityCtrl;
  late final TextEditingController _addressCtrl;
  final TextEditingController _joinPinCtrl = TextEditingController();

  bool _saving = false;
  bool _logoBusy = false;
  bool _googleBusy = false;
  bool _joinBusy = false;
  bool _showJoinInput = false;
  String _linkedEmail = '';

  @override
  void initState() {
    super.initState();
    final user = ref.read(currentUserProvider).valueOrNull;
    final devName = ref.read(ownDeviceNameProvider).valueOrNull?.trim() ?? '';
    final st = ref.read(settingsProvider).valueOrNull ?? const {};

    _userNameCtrl = TextEditingController(
      text: devName.isNotEmpty ? devName : (user?.name ?? ''),
    );
    _emailCtrl = TextEditingController(
      text: (st['account.email'] ?? '').trim(),
    );
    _phoneCtrl = TextEditingController(
      text: (st['phone'] ?? st['whatsapp'] ?? '').trim(),
    );
    _bizNameCtrl = TextEditingController(
      text: (st['businessName'] ?? '').trim(),
    );
    _bizActivityCtrl = TextEditingController(
      text: (st['businessActivity'] ?? '').trim(),
    );
    _addressCtrl = TextEditingController(
      text: (st['address'] ?? '').trim(),
    );
    _loadGoogleState();
  }

  Future<void> _loadGoogleState() async {
    try {
      final repo = ref.read(repoProvider);
      final em = await FirebaseAuthRest.savedEmail(repo);
      if (em.isNotEmpty) {
        if (mounted) setState(() => _linkedEmail = em);
        return;
      }
      final db = await repo.database;
      final gu = await GoogleAuthService(db).currentUserFromDb();
      if (gu != null && gu.email.isNotEmpty && mounted) {
        setState(() => _linkedEmail = gu.email);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _userNameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _bizNameCtrl.dispose();
    _bizActivityCtrl.dispose();
    _addressCtrl.dispose();
    _joinPinCtrl.dispose();
    super.dispose();
  }

  Future<void> _signInWithGoogle() async {
    if (_googleBusy) return;
    final repo = ref.read(repoProvider);
    if (await repo.workspaceMode() == 'member') {
      if (mounted) {
        showSnack(
          context,
          'هذا الجهاز مرتبط كعضو في منشأة قائمة — لا يُسمح بتسجيل حساب Google أثناء الارتباط.',
          error: true,
        );
      }
      return;
    }
    setState(() => _googleBusy = true);
    Sfx.click();
    try {
      final db = await repo.database;
      final r = await GoogleAuthService(db).signIn();
      final gu = r.user;
      if (gu == null) {
        Sfx.error();
        if (mounted) {
          showSnack(context, r.error ?? 'تعذّر تسجيل الدخول بـ Google',
              error: true);
        }
        return;
      }

      FirebaseAccount? account;
      final tok = gu.idToken ?? '';
      if (tok.isNotEmpty) {
        try {
          account = await FirebaseAuthRest.signInWithGoogleIdToken(tok)
              .timeout(const Duration(seconds: 6), onTimeout: () => null);
        } catch (_) {
          account = null;
        }
      }
      account ??= FirebaseAccount(
        uid: gu.id,
        email: gu.email,
        displayName: gu.displayName ?? '',
      );

      if ((gu.photoUrl ?? '').isNotEmpty) {
        await repo.setSetting('account.photoPath', gu.photoUrl!);
      }
      await repo.setSetting(Repo.accountEmailKey, gu.email);
      await repo.setSetting('email', gu.email);
      await repo.setSetting('account.type', 'enterprise');

      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      final outcome = await AccountWorkspace.linkAccountOnly(
        repo,
        backendUrl: url,
        account: account,
      ).timeout(
        const Duration(seconds: 25),
        onTimeout: () => AccountLinkOutcome.migrated,
      );

      final activeWsId = await ensureWorkspace(db, repo: repo);
      await linkWorkspaceToGoogle(
        db,
        workspaceId: activeWsId,
        googleId: gu.id,
        email: gu.email,
        name: gu.displayName ?? '',
      );

      // ضمان ترقية مالك الجهاز فوراً إلى مدير النظام بصلاحيات كاملة
      final curMode = await repo.workspaceMode();
      if (curMode != 'member') {
        await repo.checkAndAutoPromoteManager();
        await repo.ensureSelfPermissionRow(roleCode: 'admin');
        unawaited(repo.restoreManagerOwnership());
      }

      // تحديث حقول النافذة بالبيانات المسترجعة من المساحة السحابية
      final refreshedSt = await repo.settings();
      if ((refreshedSt['businessName'] ?? '').trim().isNotEmpty) {
        _bizNameCtrl.text = refreshedSt['businessName']!.trim();
      }
      if ((refreshedSt['businessActivity'] ?? '').trim().isNotEmpty) {
        _bizActivityCtrl.text = refreshedSt['businessActivity']!.trim();
      }
      if ((refreshedSt['phone'] ?? refreshedSt['whatsapp'] ?? '').trim().isNotEmpty) {
        _phoneCtrl.text =
            (refreshedSt['phone'] ?? refreshedSt['whatsapp'] ?? '').trim();
      }
      if ((refreshedSt['address'] ?? '').trim().isNotEmpty) {
        _addressCtrl.text = refreshedSt['address']!.trim();
      }
      if ((refreshedSt['account.name'] ?? '').trim().isNotEmpty &&
          _userNameCtrl.text.trim().isEmpty) {
        _userNameCtrl.text = refreshedSt['account.name']!.trim();
      } else if ((gu.displayName ?? '').trim().isNotEmpty &&
          _userNameCtrl.text.trim().isEmpty) {
        _userNameCtrl.text = gu.displayName!.trim();
        await repo.renameSelfDevice(gu.displayName!.trim());
      }
      _emailCtrl.text = gu.email;

      ref.invalidate(googleLinkedProvider);
      ref.invalidate(drawerPhotoProvider);
      ref.invalidate(settingsProvider);
      ref.invalidate(currentUserProvider);
      ref.invalidate(isOwnerProvider);
      ref.invalidate(workspaceModeProvider);
      bump(ref);

      if (!mounted) return;
      setState(() => _linkedEmail = gu.email);
      Sfx.success();

      switch (outcome) {
        case AccountLinkOutcome.switched:
          showSnack(context,
              '✅ تم استرداد مساحة عملك المرتبطة بحساب Google وتفعيل المزامنة');
          break;
        case AccountLinkOutcome.memberUntouched:
          showSnack(context, '✅ تم ربط حساب Google مع الحفاظ على عضوية مجموعتك');
          break;
        default:
          showSnack(context,
              '✅ تم تسجيل الدخول بـ Google وتفعيل المزامنة السحابية والمجموعة');
          break;
      }

      unawaited(provisionCloudAfterSignIn(repo, ref, url));
    } catch (e, st) {
      debugPrint('Unified Google Sign-In error: $e\n$st');
      Sfx.error();
      if (mounted) {
        showSnack(context, 'تعذّر إتمام تسجيل الدخول: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  Future<void> _submitMemberJoin({PairingData? qrData}) async {
    if (_joinBusy) return;
    final repo = ref.read(repoProvider);
    final devName = _userNameCtrl.text.trim().isNotEmpty
        ? _userNameCtrl.text.trim()
        : 'جهاز عضو';

    String tokenOrPin = _joinPinCtrl.text.trim();
    String targetWs = '';
    final st = await repo.settings();
    String backendUrl = effectiveBackendUrl(st['cloudBackendUrl']);

    if (qrData != null) {
      tokenOrPin = qrData.tok.trim();
      targetWs = qrData.ws.trim();
      if (qrData.cloudUrl.trim().isNotEmpty) {
        backendUrl = qrData.cloudUrl.trim();
      }
    }

    if (tokenOrPin.isEmpty) {
      if (mounted) {
        showSnack(context, 'أدخل رمز الدعوة (6 أرقام) أو امسح باركود QR أولاً',
            error: true);
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded,
            color: Colors.orange, size: 40),
        title: const Text('تحذير: الانضمام لمنشأة قائمة'),
        content: const Text(
          'سيتم حذف جميع بياناتك المحلية والسحابية السابقة نهائياً (الحسابات، السندات، الأصناف، المحادثات، والنسخ السحابية الخاصة بك) ولن يتم استرجاع أي بيانات سابقة.\n\n'
          'إذا كان هذا الجهاز مرتبطاً بمؤسسة سابقة فسيتم عزله عنها تلقائياً، وستدخل المنشأة الجديدة نظيفاً تماماً ببيانات المنشأة المرتبط بها فقط.\n\n'
          'هل توافق على المتابعة؟',
          style: TextStyle(height: 1.7),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('أوافق — حذف بياناتي والانضمام'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _joinBusy = true);
    Sfx.click();
    try {
      if (targetWs.isEmpty || targetWs == 'default') {
        final foundWs = await CloudJoin.findWorkspaceByInvite(
          backendUrl: backendUrl,
          tokenOrPin: tokenOrPin,
        );
        if (foundWs != null && foundWs.isNotEmpty) {
          targetWs = foundWs;
        }
      }
      if (targetWs.isEmpty) targetWs = 'default';

      await CloudJoin.purgeAndIsolateJoiningMember(
        repo,
        backendUrl: backendUrl,
        targetWorkspaceId: targetWs,
      );

      await CloudJoin.requestJoin(
        repo,
        backendUrl: backendUrl,
        tokenOrPin: tokenOrPin,
        deviceName: devName,
        workspaceId: targetWs,
      );
      final savedWs = (await repo.settings())['pendingJoin.ws'] ?? targetWs;
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.pop(); // إغلاق نافذة الحساب قبل فتح شاشة انتظار موافقة المدير
      await nav.push(
        MaterialPageRoute<void>(
          builder: (_) => JoinApprovalScreen(
            prefillUrl: backendUrl,
            prefillWs: savedWs,
            prefillToken: tokenOrPin,
            startWaiting: true,
          ),
        ),
      );
      ref.invalidate(workspaceModeProvider);
      ref.invalidate(isOwnerProvider);
      ref.invalidate(currentUserProvider);
      bump(ref);
    } on CloudJoinException catch (e) {
      Sfx.error();
      if (mounted) showSnack(context, e.message, error: true);
    } catch (e) {
      Sfx.error();
      if (mounted) showSnack(context, 'تعذّر إرسال طلب الانضمام: $e', error: true);
    } finally {
      if (mounted) setState(() => _joinBusy = false);
    }
  }

  Future<void> _scanQrToJoin() async {
    final data = await scanQrPair(context);
    if (data == null || !mounted) return;
    if (!data.isCloud || data.tok.trim().isEmpty) {
      showSnack(context, 'رمز QR غير صالح — تأكد أنه رمز دعوة سحابية.',
          error: true);
      return;
    }
    await _submitMemberJoin(qrData: data);
  }

  Future<void> _pickAndSetLogo() async {
    final isOwner = await ref.read(repoProvider).isWorkspaceOwner();
    if (!isOwner) {
      if (mounted) {
        showSnack(context, 'تعديل الشعار متاح لمالك المنشأة فقط', error: true);
      }
      return;
    }
    setState(() => _logoBusy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 80,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final b64 = base64Encode(bytes);
      if (b64.length > 400000) {
        if (mounted) {
          showSnack(context, 'الصورة أكبر من اللازم — اختر صورة أصغر',
              error: true);
        }
        return;
      }
      final repo = ref.read(repoProvider);
      await repo.setSyncedSetting('org.icon.b64', b64);
      ref.invalidate(drawerPhotoProvider);
      bump(ref);
      Sfx.pop();
      if (mounted) {
        showSnack(context, '✅ تم تحديث الشعار بنجاح');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر رفع الشعار: $e', error: true);
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  Future<void> _removeLogo() async {
    final isOwner = await ref.read(repoProvider).isWorkspaceOwner();
    if (!isOwner) return;
    setState(() => _logoBusy = true);
    try {
      final repo = ref.read(repoProvider);
      await repo.setSyncedSetting('org.icon.b64', '');
      ref.invalidate(drawerPhotoProvider);
      bump(ref);
      Sfx.pop();
      if (mounted) showSnack(context, 'تم حذف الشعار');
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر حذف الشعار: $e', error: true);
    } finally {
      if (mounted) setState(() => _logoBusy = false);
    }
  }

  Future<void> _saveProfile() async {
    final repo = ref.read(repoProvider);
    final isOwner = await repo.isWorkspaceOwner();

    setState(() => _saving = true);
    Sfx.tap();
    try {
      final newName = _userNameCtrl.text.trim();
      if (newName.isNotEmpty) {
        await repo.renameSelfDevice(newName);
        try {
          await ref.read(syncEngineProvider).broadcastRosterChange();
        } catch (_) {}
      }

      if (isOwner) {
        final emailVal = _emailCtrl.text.trim();
        final phoneVal = _phoneCtrl.text.trim();
        final st = await repo.settings();
        final url = effectiveBackendUrl(st['cloudBackendUrl']);
        final wsId = repo.requireWorkspaceId;

        if (url.isNotEmpty) {
          if (emailVal.isNotEmpty) {
            final existingEmailWs = await AccountWorkspace.lookupByEmail(
              backendUrl: url,
              email: emailVal,
            );
            if (existingEmailWs.isNotEmpty && existingEmailWs != wsId) {
              if (mounted) {
                setState(() => _saving = false);
                showSnack(
                  context,
                  'هذا البريد الإلكتروني مرتبط بمساحة منشأة أخرى على السحابة ولا يمكن تكراره.',
                  error: true,
                );
              }
              return;
            }
          }
          if (phoneVal.isNotEmpty) {
            final existingPhoneWs = await AccountWorkspace.lookupByPhone(
              backendUrl: url,
              phone: phoneVal,
            );
            if (existingPhoneWs.isNotEmpty && existingPhoneWs != wsId) {
              if (mounted) {
                setState(() => _saving = false);
                showSnack(
                  context,
                  'رقم الهاتف هذا مرتبط بمساحة منشأة أخرى على السحابة ولا يمكن تكراره.',
                  error: true,
                );
              }
              return;
            }
          }
        }

        if (emailVal.isNotEmpty) {
          await repo.setSetting('account.email', emailVal);
          await repo.setSetting('email', emailVal);
        }
        await repo.setSyncedSetting('phone', phoneVal);
        await repo.setSyncedSetting('whatsapp', phoneVal);
        await repo.setSyncedSetting('businessName', _bizNameCtrl.text.trim());
        await repo.setSyncedSetting(
            'businessActivity', _bizActivityCtrl.text.trim());
        await repo.setSyncedSetting('address', _addressCtrl.text.trim());
        if (emailVal.isNotEmpty) {
          await repo.checkAndAutoPromoteManager();
        }
        if (url.isNotEmpty) {
          unawaited(AccountWorkspace.syncWorkspaceMetaToCloud(
            repo,
            backendUrl: url,
          ));
        }
      }

      bump(ref);
      Sfx.success();
      if (mounted) {
        Navigator.pop(context);
        showSnack(context, 'تم حفظ التعديلات بنجاح ✅');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'تعذّر حفظ التعديلات: $e', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = ref.watch(drawerPhotoProvider).valueOrNull ?? '';
    final wsMode = ref.watch(workspaceModeProvider).valueOrNull ?? 'standalone';
    final isOwnerAsync = ref.watch(isOwnerProvider).valueOrNull;
    final isOwner = (wsMode == 'member') ? false : (isOwnerAsync ?? true);
    final googleLinked =
        (ref.watch(googleLinkedProvider).valueOrNull ?? false) ||
            _linkedEmail.isNotEmpty;
    final st = ref.watch(settingsProvider).valueOrNull ?? const {};
    final isIndividual = (st[Repo.accountModeKey] ?? '') == 'individual';
    final canDirectLogout = isOwner || isIndividual;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    const fallback = Icon(Icons.person, color: Colors.white, size: 34);
    final Widget face = photo.startsWith('http')
        ? Image.network(
            photo,
            width: 72,
            height: 72,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback,
          )
        : (photo.isNotEmpty
            ? Image.file(
                File(photo),
                width: 72,
                height: 72,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback,
              )
            : fallback);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.account_circle_outlined,
                color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'الملف الشخصي والمنشأة',
              style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          maxWidth: 480,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ══════════ 1) بطاقة حساب Google الموحّدة (لغير الأعضاء فقط) ══════════
              if (wsMode != 'member')
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: googleLinked
                      ? (isDark
                          ? const Color(0xFF064E3B).withValues(alpha: .45)
                          : const Color(0xFFECFDF5))
                      : (isDark
                          ? const Color(0xFF1E293B)
                          : const Color(0xFFF0F9FF)),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: googleLinked
                        ? const Color(0xFF10B981).withValues(alpha: .5)
                        : const Color(0xFF0284C7).withValues(alpha: .35),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          googleLinked
                              ? Icons.verified_user_rounded
                              : Icons.cloud_sync_rounded,
                          color: googleLinked
                              ? const Color(0xFF059669)
                              : const Color(0xFF0284C7),
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                googleLinked
                                    ? 'متصل بحساب Google (المزامنة السحابية مفعّلة)'
                                    : 'تسجيل الدخول بحساب Google',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                googleLinked
                                    ? (_linkedEmail.isNotEmpty
                                        ? _linkedEmail
                                        : _emailCtrl.text)
                                    : 'سجّل الدخول لتفعيل المزامنة السحابية الفورية، إدارة المجموعة، واسترجاع بياناتك بأمان.',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.text2Of(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (!googleLinked)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: _googleBusy ? null : _signInWithGoogle,
                        icon: _googleBusy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.login_rounded, size: 18),
                        label: Text(
                          _googleBusy
                              ? 'جارٍ الاتصال بحساب Google…'
                              : 'تسجيل الدخول بحساب Google',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      )
                    else
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: _googleBusy ? null : _signInWithGoogle,
                        icon: _googleBusy
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sync_rounded, size: 17),
                        label: const Text(
                          'تبديل حساب Google أو تحديث الربط السحابي',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      ),
                  ],
                ),
              ),

              // ══════════ 2) ربط هذا الجهاز كعضو في مجموعة (مخفي عند التسجيل بالبريد) ══════════
              if (wsMode != 'member' && !googleLinked) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1E293B).withValues(alpha: .6)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () =>
                            setState(() => _showJoinInput = !_showJoinInput),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 4, horizontal: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.group_add_rounded,
                                  color: Color(0xFF7C3AED), size: 20),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'ربط هذا الجهاز كعضو في مجموعة (رمز أو QR)',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                              Icon(
                                _showJoinInput
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_showJoinInput) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'أدخل رمز الدعوة المكون من 6 أرقام من جهاز المدير أو امسح باركود QR:',
                          style: TextStyle(fontSize: 11.5),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _joinPinCtrl,
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                maxLength: 12,
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                      RegExp(r'[0-9A-Za-z\-]')),
                                ],
                                decoration: InputDecoration(
                                  hintText: 'رمز 6 أرقام',
                                  counterText: '',
                                  isDense: true,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filledTonal(
                              tooltip: 'مسح باركود QR',
                              onPressed: _joinBusy ? null : _scanQrToJoin,
                              icon: const Icon(Icons.qr_code_scanner_rounded),
                            ),
                            const SizedBox(width: 6),
                            FilledButton(
                              onPressed: _joinBusy
                                  ? null
                                  : () => _submitMemberJoin(),
                              child: _joinBusy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('انضمام'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ] else ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C3AED).withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF7C3AED).withValues(alpha: .35),
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.groups_rounded,
                          color: Color(0xFF7C3AED), size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'هذا الجهاز مرتبط كعضو فعّال في مجموعة المنشأة ويزامن لحظياً.',
                          style: TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 14),
              // ══════════ 3) الشعار والأيقونة وبيانات المنشأة ══════════
              Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: .28),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ClipOval(child: face),
                    ),
                    if (_logoBusy)
                      const Positioned.fill(
                        child: Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              if (isOwner)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: _logoBusy ? null : _pickAndSetLogo,
                      icon: const Icon(Icons.photo_camera_outlined, size: 17),
                      label:
                          Text(photo.isNotEmpty ? 'تغيير الشعار' : 'رفع الشعار'),
                    ),
                    if (photo.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _logoBusy ? null : _removeLogo,
                        icon: const Icon(Icons.delete_outline,
                            size: 17, color: Colors.red),
                        label: const Text('حذف',
                            style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ],
                )
              else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    'بيانات وشعار المنشأة تُدار من جهاز مدير النظام',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 10),
              // الحقول
              _field(
                controller: _userNameCtrl,
                label: 'اسم المستخدم / هذا الجهاز',
                icon: Icons.person_outline,
                enabled: true,
              ),
              if (isOwner) ...[
                const SizedBox(height: 10),
                _field(
                  controller: _emailCtrl,
                  label: 'البريد الإلكتروني',
                  icon: Icons.email_outlined,
                  keyboard: TextInputType.emailAddress,
                  enabled: true,
                ),
              ],
              const SizedBox(height: 10),
              _field(
                controller: _phoneCtrl,
                label: 'رقم الهاتف / واتساب',
                icon: Icons.phone_outlined,
                keyboard: TextInputType.phone,
                enabled: isOwner,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _bizNameCtrl,
                label: 'اسم المنشأة / المتجر',
                icon: Icons.business_outlined,
                enabled: isOwner,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _bizActivityCtrl,
                label: 'نشاط المنشأة',
                icon: Icons.storefront_outlined,
                enabled: isOwner,
              ),
              const SizedBox(height: 10),
              _field(
                controller: _addressCtrl,
                label: 'العنوان الجغرافي',
                icon: Icons.location_on_outlined,
                maxLines: 2,
                enabled: isOwner,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: AppColors.dangerOf(context),
          ),
          onPressed: () {
            Navigator.pop(context);
            showSecuredLogout(ref);
          },
          icon: Icon(
            canDirectLogout ? Icons.logout_rounded : Icons.exit_to_app_rounded,
            size: 18,
          ),
          label: Text(
            canDirectLogout ? 'تسجيل الخروج' : 'طلب الخروج',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _saveProfile,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.check, size: 18),
          label: const Text('حفظ التعديلات',
              style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboard,
    int maxLines = 1,
    bool enabled = true,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboard,
      maxLines: maxLines,
      enabled: enabled,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        isDense: true,
        filled: !enabled,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
        ),
      ),
    );
  }
}

