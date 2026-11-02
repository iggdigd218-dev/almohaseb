import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/format.dart';
import 'trial_ui.dart' show ensureFeatureUnlocked;
import '../core/theme.dart';
import '../data/google_drive_service.dart';
import '../data/sync/google_auth_service.dart';
import '../data/providers.dart';
import 'profile_dialog.dart';
import 'widgets.dart';

/// النسخ الاحتياطي والاستعادة وسلة المهملات — نقل شاشة `backup.js`.
class BackupScreen extends ConsumerStatefulWidget {
  /// عند true تُعرض بدون Scaffold خاص بها (لتُضمَّن داخل تبويب).
  final bool embedded;
  const BackupScreen({super.key, this.embedded = false});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _busy = false;
  bool _cloudLoading = true;
  String? _cloudError;
  GoogleAccountInfo? _googleAccount;
  GoogleDriveBackupInfo? _cloudBackup;

  /// بريد الحساب من الجلسة **الموحّدة** (قسم «حساب المؤسسة»).
  /// تسجيل الدخول بـ Google له مدخل واحد في التطبيق؛ شاشة النسخ لا
  /// تملك زر تسجيل، وDrive صلاحية تُمنح بعده لا مدخل تسجيل مستقل.
  String? _accountEmail;

  /// تضمين صور العمليات داخل ملف النسخة (البند ١٣).
  bool _withImages = true;

  // (المعمارية الصامتة) كرت «المزامنة السحابية Firebase» أُزيل بالكامل:
  // النسخ السحابي يعمل تلقائياً وبصمت على الرابط المضمّن ومساحة العمل
  // الحالية — لا حقول رابط/رمز ولا أزرار رفع/سحب يدوية بعد اليوم.

  final GoogleDriveService _drive = GoogleDriveService.instance;

  @override
  void initState() {
    super.initState();
    _loadCloudState();
  }

  Future<void> _loadCloudState() async {
    GoogleAccountInfo? account;
    GoogleDriveBackupInfo? backup;
    String? cloudError;
    try {
      account = await _drive.restoreSession();
      if (account != null) {
        try {
          backup = await _drive.latestBackup();
        } catch (e) {
          cloudError = '$e';
        }
      }
    } catch (e) {
      cloudError = '$e';
    }
    // (توحيد مدخل التسجيل) الجلسة الموحّدة من قسم «حساب المؤسسة» — هي
    // الحكم في إظهار أدوات Drive هنا، لا جلسة Drive نفسها.
    String? accountEmail;
    try {
      final db = await ref.read(repoProvider).database;
      accountEmail = (await GoogleAuthService(db).currentUserFromDb())?.email;
    } catch (_) {
      accountEmail = null;
    }
    if (!mounted) return;
    setState(() {
      _googleAccount = account;
      _cloudBackup = backup;
      _cloudError = cloudError;
      _accountEmail = accountEmail;
      _cloudLoading = false;
    });
  }

  Future<File> _createBackupFile() async {
    final data =
        await ref.read(repoProvider).exportAll(withImages: _withImages);
    final json = const JsonEncoder.withIndent('  ').convert(data);
    final dir = await getTemporaryDirectory();
    final stamp =
        DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
    final file = File('${dir.path}/nexora-backup-$stamp.nexora');
    await file.writeAsString(json, flush: true);
    return file;
  }

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      final file = await _createBackupFile();
      await Share.shareXFiles([
        XFile(file.path),
      ], subject: 'نسخة احتياطية — إدارة البيانات');
      if (mounted) {
        final raw = await file.readAsString();
        final map = jsonDecode(raw) as Map;
        final n = (map['images'] as Map?)?.length ?? 0;
        if (!mounted) return;
        showSnack(
          context,
          n > 0
              ? 'تم إنشاء النسخة ✅ (تتضمّن $n صورة)'
              : 'تم إنشاء النسخة الاحتياطية ✅',
        );
        await ref.read(repoProvider).notify(
              title: 'تم إنشاء نسخة احتياطية',
              body: n > 0 ? 'ملف النسخة يتضمّن $n صورة' : 'اكتمل تصدير بياناتك بنجاح',
              kind: 'success',
            );
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر إنشاء النسخة: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<int> _importJson(String raw) async {
    final cleaned = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
    final decoded = jsonDecode(cleaned);
    if (decoded is! Map) throw const FormatException('ملف غير صالح');
    final map = Map<String, Object?>.from(decoded);
    final count = await ref.read(repoProvider).importAll(map);
    await _resyncGroupAfterRestore();
    bump(ref);
    return count;
  }

  /// بعد استعادة المدير: تُجدول كل البيانات المستعادة كعمليات مزامنة
  /// فتصل رأساً إلى بقية أجهزة المجموعة (لا شيء يحدث خارج المجموعة).
  Future<void> _resyncGroupAfterRestore() async {
    try {
      final queued = await ref.read(repoProvider).resyncAllToGroup();
      if (queued > 0) {
        ref.read(syncEngineProvider).notifyNewOperation();
        if (mounted) {
          showSnack(context,
              'جارٍ مزامنة النسخة المستعادة إلى أجهزة المجموعة ($queued سجلًا) 🔄');
        }
      }
    } catch (_) {
      // المزامنة اللاحقة الدورية ستلتقط ما تبقى.
    }
  }

  Future<String> _readPickedFile(PlatformFile picked) async {
    // بعض مزوّدي Android يعيدون bytes أو readStream فقط بدل path محلي.
    final bytes = picked.bytes;
    if (bytes != null) return utf8.decode(bytes);
    final stream = picked.readStream;
    if (stream != null) {
      final all = <int>[];
      await for (final chunk in stream) {
        all.addAll(chunk);
      }
      return utf8.decode(all);
    }
    final path = picked.path;
    if (path == null) {
      throw const FormatException(
        'لم يعُد مزوّد الملفات محتوى قابلًا للقراءة.',
      );
    }
    return File(path).readAsString();
  }

  Future<void> _restore() async {
    final ok = await confirmDialog(
      context,
      title: '⚠️ استعادة نسخة احتياطية',
      message:
          'سيتم استبدال كل البيانات الحالية بمحتوى الملف. لا يمكن التراجع.\n\n'
          'يقبل التطبيق ملفات مدير الحسابات (‎.nexora‎) وملفات JSON من مدير الملفات '
          'ومزوّدي التخزين السحابي. الاستعادة ذرّية: إذا كان أي صف أو مرجع '
          'غير صالح فستظهر رسالة خطأ ولن تُطبّق استعادة جزئية.\n\nهل تريد المتابعة؟',
      confirmText: 'استعادة',
      danger: true,
    );
    if (!ok) return;

    setState(() => _busy = true);
    try {
      // withData مهم لأن بعض مزوّدي Android يعيدون content URI بلا path محلي.
      final res = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (res == null) return;
      final raw = await _readPickedFile(res.files.single);
      final n = await _importJson(raw);
      if (mounted) showSnack(context, 'تمت الاستعادة ✅ ($n سجلًا)');
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّرت الاستعادة: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<GoogleAccountInfo?> _ensureGoogleAccount({bool promptSignIn = false}) async {
    var account = _googleAccount ?? await _drive.restoreSession();
    if (account == null && promptSignIn) {
      try {
        account = await _drive.signIn();
      } catch (e) {
        if (mounted) showSnack(context, '$e', error: true);
        return null;
      }
    }
    if (account != null) {
      GoogleDriveBackupInfo? backup;
      String? cloudError;
      try {
        backup = await _drive.latestBackup();
      } catch (e) {
        cloudError = '$e';
      }
      if (mounted) {
        setState(() {
          _googleAccount = account;
          _cloudBackup = backup;
          _cloudError = cloudError;
        });
      }
    }
    return account;
  }

  Future<void> _uploadToGoogle() async {
    setState(() => _busy = true);
    try {
      final account = await _ensureGoogleAccount(promptSignIn: true);
      if (account == null) {
        if (mounted) {
          showSnack(context, 'يرجى تسجيل الدخول بحساب Google أولاً', error: true);
        }
        return;
      }
      final file = await _createBackupFile();
      final backup = await _drive.uploadLatest(file);
      if (mounted) {
        setState(() {
          _cloudBackup = backup;
          _cloudError = null;
        });
        showSnack(context, 'تم حفظ النسخة الاحتياطية في Google Drive بنجاح ✅');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر رفع النسخة: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromGoogle() async {
    setState(() => _busy = true);
    try {
      final account = await _ensureGoogleAccount(promptSignIn: true);
      if (account == null) {
        if (mounted) {
          showSnack(context, 'يرجى تسجيل الدخول بحساب Google أولاً', error: true);
        }
        return;
      }
      final backups = await _drive.listBackups();
      if (!mounted) return;
      if (backups.isEmpty) {
        showSnack(context, 'لا توجد نسخ احتياطية في حساب Google Drive');
        return;
      }

      // عرض نافذة النسخ الاحتياطية المتاحة مرتبة تنازلياً حسب الوقت
      final selected = await showModalBottomSheet<GoogleDriveBackupInfo>(
        context: context,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_download_outlined, color: AppColors.primary2),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'النسخ الاحتياطية المتاحة على Google Drive',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: backups.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 60),
                  itemBuilder: (ctx, i) {
                    final b = backups[i];
                    final dateStr = b.modifiedTime != null
                        ? Fmt.dateTime(b.modifiedTime!)
                        : 'تاريخ غير محدد';
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: i == 0
                            ? Colors.green.shade50
                            : Theme.of(ctx).colorScheme.surfaceContainerHighest,
                        child: Icon(
                          i == 0 ? Icons.star_rounded : Icons.history,
                          color: i == 0 ? Colors.green.shade700 : Theme.of(ctx).hintColor,
                          size: 20,
                        ),
                      ),
                      title: Text(
                        dateStr,
                        style: TextStyle(
                          fontWeight: i == 0 ? FontWeight.bold : FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        '${b.name}${b.sizeLabel.isNotEmpty ? ' · ${b.sizeLabel}' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: const Icon(Icons.restore_outlined),
                      onTap: () => Navigator.pop(ctx, b),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );

      if (selected == null || !mounted) return;

      final ok = await confirmDialog(
        context,
        title: 'تأكيد الاستعادة',
        message: 'سيتم استعادة النسخة بتاريخ:\n'
            '${selected.modifiedTime != null ? Fmt.dateTime(selected.modifiedTime!) : selected.name}\n\n'
            'هل تريد المتابعة واستبدال البيانات المحلية؟',
        confirmText: 'استعادة الآن',
        danger: true,
      );
      if (!ok || !mounted) return;

      setState(() => _busy = true);
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/nexora-drive-${DateTime.now().millisecondsSinceEpoch}.nexora',
      );
      if (selected.id.isNotEmpty) {
        await _drive.downloadBackupById(selected.id, file);
      } else {
        await _drive.downloadLatestTo(file);
      }
      final n = await _importJson(await file.readAsString());
      if (mounted) {
        showSnack(context, 'تمت استعادة النسخة بنجاح ✅ ($n سجلًا)');
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, 'تعذّرت الاستعادة من Google: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// يفتح نافذة الحساب الموحدة (المدخل الوحيد لتسجيل الدخول بـ Google في التطبيق).
  Future<void> _openAccountSection() async {
    await showAccountProfileDialog(context, ref);
    if (mounted) await _loadCloudState();
  }

  Future<void> _shareToDriveDirectly() async {
    setState(() => _busy = true);
    try {
      final file = await _createBackupFile();
      await Share.shareXFiles([
        XFile(file.path),
      ], subject: 'نسخة احتياطية سحابية — Google Drive');
      if (mounted) {
        showSnack(
          context,
          'تم تجهيز النسخة لمشاركتها وحفظها في Google Drive ☁️',
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر تصدير النسخة: ', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wsMode = ref.watch(workspaceModeProvider).valueOrNull ?? 'standalone';
    if (wsMode == 'member') {
      return Scaffold(
        appBar: AppBar(title: const Text('النسخ الاحتياطي وإدارة البيانات')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: EmptyState(
              icon: Icons.shield_outlined,
              title: 'النسخ والاستيراد مقيد',
              message:
                  'أجهزة الأعضاء مقيدة ضد تصدير واستيراد البيانات الخارجية.\nيتم نسخ ومزامنة بيانات المنشأة مركزياً من خلال جهاز المدير.',
            ),
          ),
        ),
      );
    }
    final counts = ref.watch(countsProvider).valueOrNull ?? {};
    final trash = ref.watch(trashProvider);
    final wsOwner = ref.watch(isOwnerProvider).valueOrNull ?? true;
    final cloudAllowed = wsMode == 'standalone' || (wsMode != 'member' && wsOwner);
    // الاستعادة داخل المجموعة حكر على جهاز المدير — وتُزامن رأساً للأجهزة.
    final restoreAllowed = wsMode == 'standalone' || (wsMode != 'member' && wsOwner);

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 96),
      children: [
        const SectionTitle('حالة البيانات'),
        StatCardGrid(
          children: [
            StatCard(
              title: 'الحسابات',
              value: '${counts['accounts'] ?? 0}',
              icon: Icons.people_alt_outlined,
              color: AppColors.primaryOf(context),
            ),
            StatCard(
              title: 'العمليات',
              value: '${counts['transactions'] ?? 0}',
              icon: Icons.receipt_long_outlined,
              color: AppColors.infoOf(context),
            ),
            StatCard(
              title: 'السندات',
              value: '${counts['vouchers'] ?? 0}',
              icon: Icons.receipt_outlined,
              color: AppColors.violetOf(context),
            ),
            StatCard(
              title: 'سلة المهملات',
              value: '${counts['trash'] ?? 0}',
              icon: Icons.delete_outline,
              color: AppColors.accentOf(context),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const SectionTitle('النسخ الاحتياطي المحلي'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  secondary: const Icon(Icons.image_outlined),
                  title: const Text(
                    'تضمين صور العمليات',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: const Text(
                    'تضمين صور السندات والإيصالات والشعار داخل ملف النسخة',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  value: _withImages,
                  onChanged: (v) => setState(() => _withImages = v),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _backup,
                        icon: const Icon(Icons.backup_outlined),
                        label: const Text('إنشاء نسخة'),
                      ),
                    ),
                    if (restoreAllowed) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : () async { if (await ensureFeatureUnlocked(context, ref, featureKey: 'restore', featureName: 'نقاط الاسترجاع', description: 'استرجع بياناتك من أي نسخة احتياطية أو ادمج قواعد البيانات بأمان.')) await _restore(); },
                          icon: const Icon(Icons.restore_outlined),
                          label: const Text('استعادة'),
                        ),
                      ),
                    ],
                  ],
                ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
        if (cloudAllowed) ...[
        const SizedBox(height: 20),
        const SectionTitle('النسخ السحابي عبر Google Drive'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_cloudLoading)
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    title: Text('جارٍ التحقق من حساب Google…'),
                  )
                else if (_googleAccount == null && _accountEmail == null) ...[
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.cloud_queue_outlined, size: 28),
                    title: Text('ربط حساب Google Drive'),
                    subtitle: Text('لحفظ واستعادة النسخ الاحتياطية سحابياً بأمان'),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : () => _ensureGoogleAccount(promptSignIn: true),
                      icon: const Icon(Icons.login),
                      label: const Text('تسجيل الدخول بحساب Google'),
                    ),
                  ),
                ] else ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      child: Text(
                        ((_googleAccount?.email ?? _accountEmail ?? 'G').isEmpty
                                ? 'G'
                                : (_googleAccount?.email ?? _accountEmail!)[0])
                            .toUpperCase(),
                      ),
                    ),
                    title: Text(
                      _googleAccount?.displayName?.isNotEmpty == true
                          ? _googleAccount!.displayName!
                          : 'حساب Google',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(_googleAccount?.email ?? _accountEmail ?? ''),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(
                      Icons.cloud_done_outlined,
                      color: AppColors.primaryOf(context),
                    ),
                    title: Text(
                      _cloudBackup == null
                          ? 'جاهز لحفظ النسخة الاحتياطية'
                          : 'آخر نسخة: ${Fmt.dateTime(_cloudBackup!.modifiedTime ?? DateTime.now())}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    subtitle: _cloudBackup?.sizeLabel.isNotEmpty == true
                        ? Text(_cloudBackup!.sizeLabel)
                        : null,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _busy ? null : () async { if (await ensureFeatureUnlocked(context, ref, featureKey: 'cloud_backup', featureName: 'النسخ السحابي عبر Google Drive', description: 'نسخة احتياطية خاصة داخل Google Drive تُحدَّث بضغطة واحدة.')) await _uploadToGoogle(); },
                          icon: const Icon(Icons.cloud_upload_outlined),
                          label: const Text('حفظ نسخة الآن'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : () async { if (await ensureFeatureUnlocked(context, ref, featureKey: 'restore', featureName: 'الاستعادة من Google Drive', description: 'استرجع نسختك المحفوظة في Google Drive متى احتجتها.')) await _restoreFromGoogle(); },
                          icon: const Icon(Icons.cloud_download_outlined),
                          label: const Text('استعادة من Drive'),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_cloudError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _cloudError!,
                    style: TextStyle(
                      color: AppColors.dangerOf(context),
                      fontSize: 11.5,
                    ),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 10),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
        ],
        const SizedBox(height: 20),
        SectionTitle(
          'سلة المهملات',
          actionLabel: 'تفريغ',
          onAction: () async {
            final ok = await confirmDialog(
              context,
              title: 'تفريغ سلة المهملات',
              message: 'سيُحذف كل ما بداخلها نهائيًا.',
              danger: true,
            );
            if (ok) {
              await ref.read(repoProvider).emptyTrash();
              bump(ref);
            }
          },
        ),
        trash.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('$e'),
          data: (items) {
            if (items.isEmpty) {
              return const EmptyState(
                icon: Icons.delete_outline,
                title: 'السلة فارغة',
                message: 'كل ما تحذفه يُحفظ هنا مؤقتًا ويمكن استرجاعه.',
              );
            }
            return Column(
              children: items.map((t) {
                final created = DateTime.tryParse(
                  (t['created_at'] ?? '') as String? ?? '',
                );
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(
                      Icons.restore_from_trash_outlined,
                      color: AppColors.accentOf(context),
                    ),
                    title: Text(
                      '${t['label'] ?? t['store']}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      created == null ? '' : Fmt.dateTime(created),
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    trailing: TextButton(
                      onPressed: () async {
                        await ref
                            .read(repoProvider)
                            .restoreFromTrash(t['id'] as int);
                        bump(ref);
                        if (context.mounted) {
                          showSnack(context, 'تم الاسترجاع ✅');
                        }
                      },
                      child: const Text('استرجاع'),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}

/// سجل النشاط — نقل شاشة `activity.js`.
class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acts = ref.watch(activityProvider);

    return acts.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'تعذّر تحميل السجل',
        message: '$e',
      ),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(
            icon: Icons.history,
            title: 'لا نشاط بعد',
            message: 'كل إضافة أو تعديل أو حذف سيظهر هنا.',
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 96),
          children: [
            SectionTitle(
              'آخر التغييرات',
              actionLabel: 'مسح السجل',
              onAction: () async {
                final ok = await confirmDialog(
                  context,
                  title: 'مسح سجل النشاط',
                  message: 'سيُمسح السجل بالكامل.',
                  danger: true,
                );
                if (ok) {
                  await ref.read(repoProvider).clearActivity();
                  bump(ref);
                }
              },
            ),
            for (final a in items)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  // نقرة على أي سطر تعرض نافذة تفاصيل كاملة للنشاط.
                  onTap: () => showActivityDetails(context, ref, a),
                  child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: AppColors.primaryOf(context),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${a['text']}',
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${a['user_name'] ?? ''}',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.text3Of(context),
                            ),
                          ),
                          Text(
                            Fmt.relative(
                              DateTime.tryParse(
                                    (a['created_at'] ?? '') as String,
                                  ) ??
                                  DateTime.now(),
                            ),
                            style: TextStyle(
                              fontSize: 10.5,
                              color: AppColors.text3Of(context),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 6),
                      Icon(Icons.chevron_left,
                          size: 18, color: AppColors.text3Of(context)),
                    ],
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

/// نافذة تفاصيل نشاط واحد: النص الكامل، النوع، المنفّذ، الوقت الدقيق،
/// وبيانات السجل المرتبط إن كان ما يزال موجوداً.
Future<void> showActivityDetails(
  BuildContext context,
  WidgetRef ref,
  Map<String, Object?> a,
) async {
  final refType = '${a['ref_type'] ?? ''}';
  final refId = '${a['ref_id'] ?? ''}';
  final created = DateTime.tryParse('${a['created_at'] ?? ''}');

  // اسم الجدول المرتبط بكل نوع مرجع في سجل النشاط.
  final table = switch (refType) {
    'account' => 'accounts',
    'tx' => 'transactions',
    'voucher' => 'vouchers',
    'user' => 'users',
    _ => null,
  };
  final typeLabel = switch (refType) {
    'account' => 'حساب',
    'tx' => 'عملية حسابية',
    'voucher' => 'سند',
    'user' => 'مستخدم',
    'stock' => 'حركة مخزون',
    'trash' => 'سلة المهملات',
    _ => refType.isEmpty ? '—' : refType,
  };

  // جلب السجل المرتبط (إن وُجد) لعرض أبرز حقوله.
  Map<String, Object?>? linked;
  if (table != null && refId.isNotEmpty) {
    try {
      final db = await ref.read(repoProvider).database;
      final rows = await db.query(table,
          where: 'id = ?', whereArgs: [refId], limit: 1);
      if (rows.isNotEmpty) linked = rows.first;
    } catch (_) {}
  }

  // أبرز الحقول المفهومة للعرض (بالعربية) حسب نوع السجل.
  final details = <(String, String)>[];
  void add(String label, Object? v) {
    final s = '$v'.trim();
    if (s.isNotEmpty && s != 'null') details.add((label, s));
  }

  if (linked != null) {
    add('الاسم', linked['name']);
    add('الرقم', linked['number']);
    add('البيان', linked['note'] ?? linked['description']);
    add('المبلغ', linked['amount']);
    add('العملة', linked['currency']);
    add('الكمية', linked['quantity']);
    add('الحالة', switch ('${linked['status']}') {
      'approved' => 'معتمد',
      'draft' => 'مسودة',
      'cancelled' => 'ملغى',
      _ => '',
    });
    final deleted = '${linked['deleted_at'] ?? ''}';
    if (deleted.isNotEmpty) details.add(('⚠️', 'هذا السجل محذوف حالياً'));
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.history, color: AppColors.primaryOf(ctx)),
      title: const Text('تفاصيل النشاط', style: TextStyle(fontSize: 17)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // النص الكامل للنشاط.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface2Of(ctx),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${a['text']}',
                style:
                    const TextStyle(fontWeight: FontWeight.w700, height: 1.6),
              ),
            ),
            const SizedBox(height: 12),
            _DetailRow(label: 'النوع', value: typeLabel),
            if (refId.isNotEmpty) _DetailRow(label: 'المعرّف', value: refId),
            _DetailRow(label: 'المنفّذ', value: '${a['user_name'] ?? '—'}'),
            if (created != null)
              _DetailRow(label: 'الوقت', value: Fmt.dateTime(created)),
            if (details.isNotEmpty) ...[
              const Divider(height: 20),
              Text('بيانات السجل المرتبط',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text2Of(ctx),
                  )),
              const SizedBox(height: 6),
              for (final d in details) _DetailRow(label: d.$1, value: d.$2),
            ] else if (table != null) ...[
              const SizedBox(height: 8),
              Text(
                'السجل المرتبط لم يعد موجوداً (حُذف أو استُبدل).',
                style: TextStyle(
                    fontSize: 12, color: AppColors.text3Of(ctx)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('إغلاق'),
        ),
      ],
    ),
  );
}

/// سطر تفاصيل (تسمية: قيمة) داخل نافذة تفاصيل النشاط.
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12.5, color: AppColors.text3Of(context))),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
}
