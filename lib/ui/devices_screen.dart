import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/sfx.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import 'cloud_sync_section.dart';
import 'trial_ui.dart' show SeatUsageBadge;
import 'widgets.dart';

/// شاشة إدارة الأجهزة المرتبطة: عرض/ربط/إلغاء/تحديد الصلاحيات.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  Future<void> _assign(int? userId, String deviceId) async {
    if (userId == null) return;
    try {
      await ref.read(repoProvider).assignDeviceToUser(deviceId, userId);
      bump(ref);
      if (mounted) showSnack(context, 'تم تعيين المستخدم للجهاز ✅');
    } catch (e) {
      if (mounted) showSnack(context, 'تعذّر التعيين: $e', error: true);
    }
  }

  Future<void> _rename(String deviceId, String current) async {
    // التقط المرجع قبل النافذة: الشاشة قد تُتلف أثناء فتحها
    // فيصبح ref غير صالح («Cannot use ref after disposed»).
    final repo = ref.read(repoProvider);
    final ctl = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('إعادة تسمية الجهاز'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'اسم الجهاز'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (ok == true && ctl.text.trim().isNotEmpty) {
      await repo.renameDevice(deviceId, ctl.text);
      if (mounted) bump(ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devicesAsync = ref.watch(devicesProvider);
    final usersAsync = ref.watch(usersProvider);

    // (دفعة 58) سحب للأسفل = تحديث فوري للبيانات.
    return RefreshIndicator(
      onRefresh: () async => bump(ref),
      child: ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 96),
      children: [
        Card(
          color: AppColors.primarySoftOf(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Icon(Icons.devices, size: 22),
                    const SizedBox(width: 8),
                    const Text(
                      'إدارة الأجهزة المرتبطة',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    FilledButton.icon(
                      // (دفعة 58) الربط سحابي فقط — دعوة عبر Firebase.
                      onPressed: () => showCloudInviteDialog(context, ref),
                      icon: const Icon(Icons.cloud_outlined),
                      label: const Text('ربط جهاز جديد عبر السحابة'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'بصفتك مديراً يمكنك ربط أجهزة أخرى بهذه المساحة وتحديد صلاحيات كل جهاز (عبر تعيين مستخدم له). إلغاء الاقتران يمنع الجهاز من المزامنة فوراً.',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // (باقة المؤسسات) عدّاد المقاعد الدائم: المتصلة/الحد الأقصى.
        const Row(
          children: [
            Expanded(child: SectionTitle('الأجهزة')),
            SeatUsageBadge(),
            SizedBox(width: 14),
          ],
        ),
        devicesAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline,
            title: 'تعذّر تحميل الأجهزة',
            message: '$e',
          ),
          data: (list) {
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.devices_other,
                title: 'لا توجد أجهزة مرتبطة',
                message: 'اضغط "ربط جهاز جديد" لإضافة أول جهاز.',
              );
            }
            // مرجع مُلتقط قبل النوافذ: استعمال ref بعد await قد يصادف
            // شاشة أُتلفت («Cannot use ref after disposed»).
            final repo = ref.read(repoProvider);
            return FutureBuilder<Map<String, Object?>?>(
              future: repo.ownDeviceRow(),
              builder: (ctx, snap) {
                final own = snap.data;
                final ownId = own?['id'] as String?;
                final amITheOwner =
                    own != null && ((own['is_owner'] ?? 0) as int) == 1;
                final hostRow = list
                    .where((r) => ((r['is_owner'] ?? 0) as int) == 1)
                    .toList();
                final hostId =
                    hostRow.isNotEmpty ? hostRow.first['id'] as String : null;
                return Column(
                  children: [
                    for (final d in list)
                      DeviceCard(
                        data: d,
                        users: (usersAsync.valueOrNull ?? const <AppUser>[])
                            .cast<AppUser>(),
                        isSelf: d['id'] == ownId,
                        isOwnerDevice: d['id'] == hostId,
                        amITheOwner: amITheOwner,
                        onAssign: (uid) => _assign(uid, d['id'] as String),
                        // (دفعة 56) تغيير الدور من البطاقة مباشرة —
                        // حفظ فوري محلياً + بث للسحابة + تحديث الواجهة.
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
                                try {
                                  await ref
                                      .read(syncEngineProvider)
                                      .broadcastRosterChange();
                                } catch (_) {}
                                Sfx.success();
                                bump(ref);
                              }
                            : null,
                        onRename: () => _rename(
                          d['id'] as String,
                          (d['name'] ?? '') as String,
                        ),
                        onRevoke: () async {
                          final ok = await confirmDialog(
                            context,
                            title: 'حظر الجهاز مؤقتاً',
                            message:
                                'سيتم منع "${d['name']}" من المزامنة حتى تُعيد السماح له. البيانات لن تُمسح ويمكن إعادة السماح في أي وقت.',
                            confirmText: 'حظر',
                            danger: true,
                          );
                          if (ok == true) {
                            await ref
                                .read(repoProvider)
                                .revokeDevice(d['id'] as String);
                            // (دفعة 54) بث شاهدة الطرد النشطة للمستهدف.
                            try {
                              await ref
                                  .read(syncEngineProvider)
                                  .broadcastEviction(d['id'] as String);
                            } catch (_) {}
                            bump(ref);
                          }
                        },
                        onRestore: () async {
                          await ref
                              .read(repoProvider)
                              .restoreDevice(d['id'] as String);
                          // (دفعة 54) حذف شاهدة الطرد عند إعادة السماح.
                          try {
                            await ref
                                .read(syncEngineProvider)
                                .clearEvictionBroadcast(d['id'] as String);
                          } catch (_) {}
                          bump(ref);
                        },
                        onExpel: () async {
                          final ok = await confirmDialog(
                            context,
                            title: 'طرد الجهاز من المجموعة',
                            message:
                                'سيتم طرد "${d['name']}" من المجموعة. عند أول اتصال للجهاز، ستُحذف جميع بيانات المجموعة منه ويعود إلى الوضع المستقل بحساب مدير جديد.\n\nلا يمكن التراجع عن ذلك إلا بإعادة ربط الجهاز من جديد.',
                            confirmText: 'تأكيد الطرد',
                            danger: true,
                          );
                          if (ok == true) {
                            await ref
                                .read(repoProvider)
                                .expelDevice(d['id'] as String);
                            // (دفعة 54) بث شاهدة الطرد النشطة: تصل المستهدف
                            // لحظياً عبر SSE فيبطل جلسته ويعود مستقلاً.
                            try {
                              await ref
                                  .read(syncEngineProvider)
                                  .broadcastEviction(d['id'] as String,
                                      reason: 'expelled_by_manager');
                            } catch (_) {}
                            bump(ref);
                            if (context.mounted) {
                              showSnack(
                                context,
                                '✅ تم طرد الجهاز وبثّ الإبطال — سيُقصى لحظياً.',
                              );
                            }
                          }
                        },
                        // (دفعة 56) حذف نهائي من السجل — بطاقة مطرودة فقط.
                        onPurge: () async {
                          final ok = await confirmDialog(
                            context,
                            title: 'حذف نهائي من السجل',
                            message:
                                'سيُمحى سجل "${d['name']}" نهائياً محلياً '
                                'وسحابياً. لا يمكن التراجع.',
                            confirmText: 'حذف نهائي',
                            danger: true,
                          );
                          if (ok != true) return;
                          try {
                            await ref
                                .read(syncEngineProvider)
                                .purgeDeviceRecordEverywhere(d['id'] as String);
                            Sfx.success();
                            bump(ref);
                          } catch (e) {
                            if (context.mounted) {
                              showSnack(context, 'تعذّر الحذف: $e',
                                  error: true);
                            }
                          }
                        },
                        onTransferOwner: () async {
                          final targetName = d['name'] as String? ?? 'الجهاز';
                          // (صمام أمان) فحص جاهزية الجهاز المستلم قبل
                          // التسليم — تحذيرات واضحة، والقرار للمدير.
                          final warnings = await repo
                              .transferReadinessCheck(d['id'] as String);
                          if (!context.mounted) return;
                          final warnBlock = warnings.isEmpty
                              ? ''
                              : '⚠️ تحذيرات الجاهزية:\n'
                                  '${warnings.map((w) => '• $w').join('\n')}\n\n';
                          final ok = await confirmDialog(
                            context,
                            title: 'تسليم الإدارة لهذا الجهاز',
                            message: '$warnBlock'
                                'سيتم نقل ملكية المجموعة إلى "$targetName".\n'
                                'سيصبح هو المدير الوحيد، وستصبح أنت عضوًا عاديًا بدور "عرض فقط" (يمكنك اختيار دور مختلف من القائمة لاحقاً).\n\n'
                                'لا يمكن التراجع عن هذا إلا إذا قام المالك الجديد بتسليمك الإدارة مرة أخرى.\n\n'
                                'هل تريد المتابعة؟',
                            confirmText: 'تأكيد تسليم الإدارة',
                            danger: true,
                          );
                          if (ok == true) {
                            try {
                              await repo.transferOwnership(
                                d['id'] as String,
                                newUserRoleForMe: 'viewer',
                              );
                              if (mounted) bump(ref);
                              if (context.mounted) {
                                showSnack(
                                  context,
                                  '✅ تم تسليم الإدارة. أنت الآن عضو بدور "عرض فقط".',
                                );
                                Navigator.of(context)
                                    .popUntil((r) => r.isFirst);
                              }
                            } catch (e) {
                              if (context.mounted) {
                                showSnack(
                                  context,
                                  'تعذّر تسليم الإدارة: $e',
                                  error: true,
                                );
                              }
                            }
                          }
                        },
                        onResetSecret: () async {
                          final targetName = d['name'] as String? ?? 'الجهاز';
                          final ok = await confirmDialog(
                            context,
                            title: 'إعادة تعيين رمز/مفتاح الجهاز',
                            message:
                                'سيتم توليد مفتاح مصادقة جديد لجهاز "$targetName" وسيفقد الجهاز إمكانية المزامنة فوراً إلى أن يعيد المستخدم إدخال الرمز الجديد.\n\n'
                                'استخدم هذا الإجراء إذا اشتبهت بتسريب البيانات أو أردت التحكم عن بُعد.',
                            confirmText: 'إعادة التعيين',
                            danger: true,
                          );
                          if (ok == true) {
                            try {
                              final secret = await ref
                                  .read(repoProvider)
                                  .resetDeviceSecret(d['id'] as String);
                              bump(ref);
                              if (context.mounted) {
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('تمت إعادة التعيين'),
                                    content: SelectableText(
                                      'المفتاح الجديد للجهاز "$targetName":\n\n$secret\n\n'
                                      'على المستخدم إعادة الاقتران أو إدخال المفتاح في إعدادات جهازه.',
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text('حسنًا'),
                                      ),
                                    ],
                                  ),
                                );
                              }
                            } catch (e) {
                              if (context.mounted) {
                                showSnack(context, 'تعذّر: $e', error: true);
                              }
                            }
                          }
                        },
                        onCloudLink: () =>
                            showCloudInviteDialog(context, ref),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ],
      ),
    );
  }
}

class DeviceCard extends StatelessWidget {
  final Map<String, Object?> data;
  final List<AppUser> users;
  final Future<void> Function(int? userId) onAssign;
  final VoidCallback onRename;
  final VoidCallback onRevoke;
  final VoidCallback onRestore;
  final VoidCallback onExpel;
  final VoidCallback onTransferOwner;
  final VoidCallback onResetSecret;
  final VoidCallback? onPermissions;
  final VoidCallback? onCloudLink;

  /// (دفعة 56) «حذف نهائي من السجل» — للبطاقات المطرودة/المحظورة فقط.
  final VoidCallback? onPurge;

  /// (دفعة 51) تعديل الدور مباشرة من البطاقة دون فتح نافذة الصلاحيات.
  final Future<void> Function(UserRole role)? onRoleChanged;
  final bool isSelf;
  final bool isOwnerDevice;
  final bool amITheOwner;
  const DeviceCard({super.key, 
    required this.data,
    required this.users,
    required this.onAssign,
    required this.onRename,
    required this.onRevoke,
    required this.onRestore,
    required this.onExpel,
    required this.onTransferOwner,
    required this.onResetSecret,
    this.onPermissions,
    this.onCloudLink,
    this.onPurge,
    this.onRoleChanged,
    required this.isSelf,
    required this.isOwnerDevice,
    required this.amITheOwner,
  });

  @override
  Widget build(BuildContext context) {
    // اسم العرض الموحد بلقب الدور: «المدير (اسم الجهاز)» وهكذا.
    final name = roleDisplayName(
      roleCode: (data['user_role'] as String?) ?? '',
      isOwner: ((data['is_owner'] as int?) ?? 0) == 1,
      deviceName: (data['name'] ?? 'جهاز') as String,
    );
    final platform = (data['platform'] ?? '') as String;
    final expelled = ((data['expelled_at'] ?? '') as String).isNotEmpty;
    final revoked =
        ((data['revoked_at'] ?? '') as String).isNotEmpty && !expelled;
    final inactive = expelled || revoked;
    final lastSeen = (data['last_seen_at'] ?? '') as String;
    final userName = data['user_name'] as String?;
    final userRole = data['user_role'] as String?;
    final currentUserId = data['user_id'] as int?;

    // تحديد الأجهزة الخاملة لأكثر من شهر (للتنبيه البصري).
    final lastSeenDt = DateTime.tryParse(lastSeen);
    final staleForMonth = lastSeenDt != null &&
        DateTime.now().difference(lastSeenDt) > const Duration(days: 30);
    // (دفعة 56) مؤشر الاتصال السحابي: ظهور خلال آخر 3 دقائق = متصل.
    final cloudOnline = lastSeenDt != null &&
        DateTime.now().difference(lastSeenDt) < const Duration(minutes: 3);
    // دور الجهاز الفعلي (شارة ملونة عالية التباين).
    final role = isOwnerDevice
        ? UserRole.admin
        : (userRole == null || userRole.isEmpty
            ? null
            : UserRole.fromCode(userRole));

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_iconFor(platform), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  // (دفعة 56) شارة الدور الديناميكية — تعكس الدور الممنوح
                  // فعلياً بلون مميز عالي التباين لكل دور.
                  if (role != null) ...[
                    Flexible(child: _RoleBadge(role: role)),
                    const SizedBox(width: 6),
                  ],
                  if (expelled)
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.shade900.withValues(alpha: .15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'مطرود',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.red,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    )
                  else if (revoked)
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'محظور',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.deepOrange,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    )
                  else if (staleForMonth)
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'خامل ⚠️',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.redAccent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: (cloudOnline || isSelf ? Colors.green : Colors.blueGrey)
                              .withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          // (دفعة 56) مؤشر الحالة السحابية بدل «نشط» العامة.
                          cloudOnline || isSelf ? 'متصل سحابياً ☁️' : 'غير متصل',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: cloudOnline || isSelf
                                ? Colors.green
                                : Colors.blueGrey,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  // (دفعة 56) وسم منصة نظيف (Android/Windows...) بدل
                  // عرض «المنصة: lan» وعناوين IP الخام البائدة.
                  _smallLabel('الجهاز', _platformTag(platform)),
                  _smallLabel('المستخدم', userName ?? 'غير معيّن'),
                  // مقتطف بصمة الجهاز (المعرّف مشتق من بصمة العتاد).
                  _smallLabel(
                    'البصمة',
                    (data['id'] as String? ?? '').length > 10
                        ? (data['id'] as String).substring(0, 10)
                        : (data['id'] as String? ?? '—'),
                  ),
                  if (lastSeen.isNotEmpty)
                    _smallLabel(
                      'آخر ظهور',
                      DateTime.tryParse(lastSeen) == null
                          ? lastSeen
                          : Fmt.relative(DateTime.parse(lastSeen)),
                    ),
                  // (دفعة 58 — متطلب 9) وقت آخر مزامنة ناجحة لكل عضو —
                  // يراها المدير على بطاقة الجهاز مباشرة.
                  if ('${data['last_sync_at'] ?? ''}'.isNotEmpty)
                    _smallLabel(
                      'آخر مزامنة ☁️',
                      DateTime.tryParse('${data['last_sync_at']}') == null
                          ? '${data['last_sync_at']}'
                          : Fmt.relative(
                              DateTime.parse('${data['last_sync_at']}')),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  // (دفعة 58 — متطلب 17) أُزيلت منسدلة الدور من ظاهر
                  // البطاقة نهائياً — تعديل الدور حصراً من حوار «إدارة
                  // صلاحيات الجهاز» عبر قائمة النقاط الثلاث.
                    Expanded(
                      child: DropdownButtonFormField<int?>(
                        isExpanded: true,
                        initialValue: (currentUserId != null &&
                                users.any((u) =>
                                    u.id == currentUserId &&
                                    u.role != UserRole.admin &&
                                    !u.isMe))
                            ? currentUserId
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'الصلاحيات (المستخدم المرتبط)',
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text(
                              '— بدون صلاحيات —',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          ...users
                              .where((u) => u.role != UserRole.admin && !u.isMe)
                              .map(
                            (u) => DropdownMenuItem<int?>(
                              value: u.id,
                              child: Text(
                                '${u.name} (${u.role.label})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: inactive ? null : onAssign,
                      ),
                    ),
                  const SizedBox(width: 6),
                  // كل إجراءات الجهاز مجمّعة في قائمة ثلاث نقاط واحدة
                  // بدل صف الأيقونات الصغيرة المبعثرة.
                  _buildActionsMenu(
                    context,
                    expelled: expelled,
                    revoked: revoked,
                    inactive: inactive,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// قائمة ثلاث نقاط تجمع كل إجراءات الجهاز في مكان واحد مرتب:
  /// صلاحيات/تسمية/حظر-سماح/إعادة رمز/تسليم إدارة/طرد + ربط العضو عبر السحابة.
  Widget _buildActionsMenu(
    BuildContext context, {
    required bool expelled,
    required bool revoked,
    required bool inactive,
  }) {
    final items = <PopupMenuEntry<String>>[];

    void add(String value, IconData icon, Color color, String label,
        {bool enabled = true}) {
      items.add(PopupMenuItem<String>(
        value: value,
        enabled: enabled,
        child: Row(
          children: [
            Icon(icon, size: 18, color: enabled ? color : Colors.grey),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ));
    }

    if (!expelled && !isSelf && amITheOwner && onPermissions != null) {
      add('perms', Icons.verified_user_outlined, Colors.teal,
          'إدارة صلاحيات الجهاز',
          enabled: !inactive);
    }
    if (!isSelf) {
      add('rename', Icons.edit_outlined, Colors.blueGrey, 'إعادة التسمية',
          enabled: !inactive);
    }
    if (!expelled) {
      if (revoked) {
        add('restore', Icons.verified_user_outlined, Colors.green,
            'إعادة السماح (إلغاء الحظر)',
            enabled: !isSelf);
      } else {
        add('revoke', Icons.block, Colors.orange, 'حظر مؤقت',
            enabled: !isSelf);
      }
    }
    // (دفعة 58 — متطلب 19) «ربط العضو عبر السحابة» يظهر فقط عندما يكون
    // الجهاز موقوفاً/غير مرتبط — جهاز نشط مرتبط فعلاً لا يحتاج إعادة ربط.
    if (!expelled && !isSelf && amITheOwner && onCloudLink != null && revoked) {
      add('cloudlink', Icons.cloud_sync_outlined, const Color(0xFF0EA5E9),
          'ربط العضو عبر السحابة');
    }
    if (!expelled && !isSelf && amITheOwner) {
      add('resetsecret', Icons.lock_reset, Colors.blueAccent,
          'إعادة تعيين رمز الجهاز');
    }
    // (قانون 2026-09-19) «تسليم الإدارة» أُزيل نهائياً: مدير واحد فقط
    // داخل المجموعة ولا يظهر أي خيار لتعيين مدير.
    if (!expelled && !isSelf && !isOwnerDevice) {
      add('expel', Icons.person_remove, Colors.red, 'طرد من المجموعة');
    }
    // (المدير يمسح ما يشاء) «حذف نهائي من السجل» متاح لكل جهاز عدا
    // جهازك أنت (لا تنتحر) وجهاز مالك المساحة (الهوية الثابتة) — بلا شرط
    // «مطرود»: الأجهزة الوهمية (DEV-*) والقديمة لم تكن قابلة للمسح قبلاً.
    if (!isSelf && !isOwnerDevice && amITheOwner && onPurge != null) {
      if (items.isNotEmpty) items.add(const PopupMenuDivider());
      add('purge', Icons.delete_forever, Colors.red.shade700,
          'حذف نهائي من السجل');
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      tooltip: 'إجراءات الجهاز',
      icon: const Icon(Icons.more_vert, size: 22),
      itemBuilder: (_) => items,
      onSelected: (v) {
        switch (v) {
          case 'perms':
            onPermissions?.call();
          case 'rename':
            onRename();
          case 'restore':
            onRestore();
          case 'revoke':
            onRevoke();
          case 'cloudlink':
            onCloudLink?.call();
          case 'resetsecret':
            onResetSecret();
          case 'expel':
            onExpel();
          case 'purge':
            onPurge?.call();
        }
      },
    );
  }

  IconData _iconFor(String p) => switch (p) {
        'android' => Icons.phone_android,
        'ios' => Icons.phone_iphone,
        'windows' => Icons.laptop_windows,
        'linux' || 'macos' => Icons.computer,
        _ => Icons.devices,
      };

  /// (دفعة 56) وسم منصة نظيف — لا «lan» ولا قيم خام.
  String _platformTag(String p) => switch (p) {
        'android' => 'Android',
        'ios' => 'iPhone',
        'windows' => 'Windows',
        'linux' => 'Linux',
        'macos' => 'Mac',
        _ => 'جهاز',
      };

  Widget _smallLabel(String k, String v) => RichText(
        text: TextSpan(
          style:
              const TextStyle(fontSize: 11, color: Colors.black54, height: 1.4),
          children: [
            TextSpan(
              text: '$k: ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: v),
          ],
        ),
      );
}

/// (دفعة 56) شارة الدور الديناميكية عالية التباين:
/// مدير ذهبية، وكيل بنفسجية داكنة، كاشير زمردية، محاسب زرقاء،
/// مدخل بيانات بنفسجية، عرض فقط رمادية.
class _RoleBadge extends StatelessWidget {
  final UserRole role;
  const _RoleBadge({required this.role});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (role) {
      UserRole.admin => (const Color(0xFFF59E0B), Colors.white), // ذهبي
      UserRole.agent => (const Color(0xFF7C3AED), Colors.white), // وكيل
      UserRole.accountant => (const Color(0xFF10B981), Colors.white), // محاسب
      UserRole.cashier => (const Color(0xFFF97316), Colors.white), // كاشير
      UserRole.dataentry => (const Color(0xFFA855F7), Colors.white), // إدخال
      UserRole.viewer => (const Color(0xFF6B7280), Colors.white), // عرض
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: bg.withValues(alpha: .35),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        '${role.icon} ${role.label}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          color: fg,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
