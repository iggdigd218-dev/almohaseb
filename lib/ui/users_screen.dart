import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/theme.dart';
import '../data/providers.dart';
import '../core/security.dart';
import 'widgets.dart';

/// المستخدمون والصلاحيات — نقل شاشة `users.js`.
class UsersScreen extends ConsumerWidget {
  const UsersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(usersProvider);

    return users.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'تعذّر تحميل المستخدمين',
        message: '$e',
      ),
      // (دفعة 58) سحب للأسفل = تحديث فوري للبيانات.
      data: (list) => RefreshIndicator(
        onRefresh: () async => bump(ref),
        child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 96),
        children: [
          const SectionTitle('الأدوار المتاحة'),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: .85,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: UserRole.values
                .map(
                  (r) => Card(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(r.icon, style: const TextStyle(fontSize: 24)),
                        const SizedBox(height: 4),
                        Text(
                          r.label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 18),
          const SectionTitle('المستخدمون'),
          if (list.isEmpty)
            const EmptyState(
              icon: Icons.people_outline,
              title: 'لا مستخدمون',
              message: 'أضف مستخدمًا وحدّد صلاحياته.',
            )
          else
            for (final u in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: UserCard(user: u),
              ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => openUserForm(context, ref),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('إضافة مستخدم'),
          ),
        ],
        ),
      ),
    );
  }
}

class UserCard extends ConsumerWidget {
  final AppUser user;
  const UserCard({super.key, required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roleColor = switch (user.role) {
      UserRole.admin => AppColors.accentOf(context),
      UserRole.agent => AppColors.greenOf(context),
      UserRole.accountant => AppColors.infoOf(context),
      UserRole.cashier => Colors.orange.shade700,
      UserRole.dataentry => AppColors.violetOf(context),
      UserRole.viewer => AppColors.text3Of(context),
    };

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => openUserForm(context, ref, existing: user),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: roleColor.withValues(alpha: .14),
                child: Text(
                  user.role.icon,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            user.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (user.isMe)
                          Pill('أنا', color: AppColors.greenOf(context)),
                        if (!user.active) ...[
                          const SizedBox(width: 4),
                          Pill('معطّل', color: AppColors.dangerOf(context)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Pill(
                      '${user.role.icon} ${user.role.label}',
                      color: roleColor,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      user.permSummary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.text3Of(context),
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  final repo = ref.read(repoProvider);
                  if (v == 'me' && user.id != null) {
                    // البند ٩: لا يُبدَّل إلى مستخدم محمي إلا بكلمة مروره.
                    if (user.locked) {
                      final ok = await askPassword(context, user);
                      if (!ok) return;
                    }
                    await repo.setCurrentUser(user.id!);
                    bump(ref);
                    ref.invalidate(currentUserProvider);
                    ref.invalidate(deviceRoleProvider);
                    ref.invalidate(canProvider);
                    ref.invalidate(effectivePermissionsProvider);
                    if (context.mounted) {
                      showSnack(context, 'المستخدم الحالي: ${user.name} (${user.role.label})');
                    }
                  } else if (v == 'toggle') {
                    try {
                      await repo.saveUser(user.copyWith(active: !user.active));
                      bump(ref);
                    } catch (e) {
                      if (context.mounted) {
                        showSnack(
                          context,
                          e is StateError ? e.message : 'تعذّر التنفيذ: $e',
                          error: true,
                        );
                      }
                    }
                  } else if (v == 'delete' && user.id != null) {
                    final ok = await confirmDialog(
                      context,
                      title: 'حذف المستخدم',
                      message: 'سيُحذف ${user.name} نهائيًا.',
                      danger: true,
                    );
                    if (ok) {
                      try {
                        await repo.deleteUser(user.id!);
                        bump(ref);
                      } catch (e) {
                        if (context.mounted) {
                          showSnack(
                            context,
                            e is StateError ? e.message : 'تعذّر الحذف: $e',
                            error: true,
                          );
                        }
                      }
                    }
                  }
                },
                itemBuilder: (_) => [
                  if (!user.isMe)
                    PopupMenuItem(
                      value: 'me',
                      child: Row(
                        children: [
                          const Text('تعيين كمستخدم حالي'),
                          if (user.locked) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.lock_outline, size: 15),
                          ],
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: 'toggle',
                    child: Text(user.active ? 'تعطيل' : 'تفعيل'),
                  ),
                  const PopupMenuItem(value: 'delete', child: Text('حذف')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> openUserForm(
  BuildContext context,
  WidgetRef ref, {
  AppUser? existing,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _UserForm(existing: existing),
    );

class _UserForm extends ConsumerStatefulWidget {
  final AppUser? existing;
  const _UserForm({this.existing});

  @override
  ConsumerState<_UserForm> createState() => _UserFormState();
}

class _UserFormState extends ConsumerState<_UserForm> {
  late final TextEditingController _name;
  late final TextEditingController _pin;
  final _password = TextEditingController();
  bool _obscure = true;
  bool _hasPassword = false;
  bool _clearPassword = false;
  late UserRole _role;
  late Map<String, bool> _perms;
  late bool _active;
  bool _saving = false;
  bool _isFirstUser = false;

  @override
  void initState() {
    super.initState();
    final u = widget.existing;
    _name = TextEditingController(text: u?.name ?? '');
    _pin = TextEditingController(text: u?.pin ?? '');
    _hasPassword = (u?.password ?? '').isNotEmpty;
    _role = u?.role ?? UserRole.cashier;
    _perms = Map.of(u?.permissions ?? defaultPerms(_role));
    _active = u?.active ?? true;
    // أول مستخدم على الإطلاق = مدير النظام (بذرة) حتى لا يُقفل النظام.
    if (u == null) {
      final list = ref.read(usersProvider).valueOrNull ?? const [];
      if (list.isEmpty) {
        _isFirstUser = true;
        _role = UserRole.admin;
        _perms = Map.of(defaultPerms(UserRole.admin));
      } else {
        _isFirstUser = false;
        _role = UserRole.cashier;
        _perms = Map.of(defaultPerms(UserRole.cashier));
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: .9,
      expand: false,
      builder: (context, scroll) => Column(
        children: [
          const SizedBox(height: 12),
          Text(
            widget.existing == null ? 'مستخدم جديد' : 'تعديل المستخدم',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 10),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'الاسم *',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<UserRole>(
                  initialValue: _role,
                  decoration: const InputDecoration(
                    labelText: 'الدور',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  // دور «مدير النظام» لا يُمنح من الإعدادات لأي مستخدم —
                  // يظهر فقط لمدير البذرة الحالي؛ الوكيل أعلى دور يُمنح.
                  items: UserRole.values
                      .where((r) =>
                          r != UserRole.admin ||
                          _isFirstUser ||
                          widget.existing?.role == UserRole.admin)
                      .map(
                        (r) => DropdownMenuItem(
                          value: r,
                          child: Text('${r.icon}  ${r.label}'),
                        ),
                      )
                      .toList(),
                  // تغيير الدور يعيد ضبط الصلاحيات لافتراضياته.
                  // أول مستخدم يبقى مديراً (البذرة) ولا يمكن خفض دوره هنا.
                  onChanged: _isFirstUser
                      ? null
                      : (v) => setState(() {
                            _role = v ?? _role;
                            _perms = Map.of(defaultPerms(_role));
                          }),
                ),
                if (_isFirstUser)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.verified_user_outlined,
                          size: 16,
                          color: AppColors.accentOf(context),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'لا يوجد مدير بعد — سيكون هذا المستخدم مدير النظام بكامل الصلاحيات.',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.accentOf(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 14),
                TextField(
                  controller: _pin,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    labelText: 'رمز PIN (اختياري)',
                    prefixIcon: Icon(Icons.password_outlined),
                  ),
                ),
                TextField(
                  controller: _password,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'كلمة مرور التبديل (اختيارية)',
                    helperText: _hasPassword
                        ? 'اتركها فارغة للإبقاء على الكلمة الحالية'
                        : 'تُطلب عند التبديل إلى هذا المستخدم',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                if (_hasPassword)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => setState(() {
                        _clearPassword = true;
                        _password.clear();
                      }),
                      icon: const Icon(Icons.lock_open_outlined, size: 18),
                      label: Text(
                        _clearPassword
                            ? 'ستُزال الحماية عند الحفظ'
                            : 'إزالة كلمة المرور',
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                SwitchListTile(
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                  title: const Text('مفعّل'),
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 8),
                const SectionTitle('الصلاحيات'),
                if (_role == UserRole.admin)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.accentSoftOf(context),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: 18,
                          color: AppColors.accentOf(context),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'مدير النظام يملك جميع الصلاحيات دائمًا.',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.accentOf(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  for (final p in kPerms)
                    CheckboxListTile(
                      value: _perms[p.key] ?? false,
                      onChanged: (v) =>
                          setState(() => _perms[p.key] = v ?? false),
                      title: Text(
                        p.label,
                        style: const TextStyle(fontSize: 13.5),
                      ),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? 'جارٍ الحفظ…' : 'حفظ'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      showSnack(context, 'أدخل اسم المستخدم', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final now = DateTime.now();
      // كلمة جديدة ← تُجزَّأ؛ فارغة ← تبقى القديمة إلا إذا طُلبت الإزالة.
      final typed = _password.text.trim();
      final newHash = _clearPassword
          ? ''
          : (typed.isEmpty
              ? (widget.existing?.password ?? '')
              : Security.hash(typed));

      final u = widget.existing?.copyWith(
            name: _name.text.trim(),
            role: _role,
            pin: _pin.text.trim(),
            password: newHash,
            permissions: _perms,
            active: _active,
            canApplyDiscount: _role == UserRole.admin ||
                _role == UserRole.agent ||
                (_perms['can_discount'] ?? false),
          ) ??
          AppUser(
            name: _name.text.trim(),
            role: _role,
            pin: _pin.text.trim(),
            password: newHash,
            permissions: _perms,
            active: _active,
            canApplyDiscount: _role == UserRole.admin ||
                _role == UserRole.agent ||
                (_perms['can_discount'] ?? false),
            createdAt: now,
            updatedAt: now,
          );
      // نلتقط repo قبل await ونفحص mounted قبل لمس ref بعده —
      // وإلا انفجر «Cannot use ref after the widget was disposed».
      final repo = ref.read(repoProvider);
      await repo.saveUser(u);
      if (!mounted) return;
      bump(ref);
      ref.invalidate(currentUserProvider);
      ref.invalidate(deviceRoleProvider);
      ref.invalidate(canProvider);
      ref.invalidate(effectivePermissionsProvider);
      Navigator.pop(context);
      showSnack(context, 'تم حفظ المستخدم ✅');
    } catch (e) {
      if (!mounted) return;
      showSnack(
        context,
        e is StateError ? e.message : 'تعذّر حفظ المستخدم: $e',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// يطلب كلمة مرور المستخدم قبل التبديل إليه (البند ٩).
Future<bool> askPassword(BuildContext context, AppUser user) async {
  final ctrl = TextEditingController();
  var obscure = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: Text('كلمة مرور ${user.name}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: obscure,
          decoration: InputDecoration(
            labelText: 'كلمة المرور',
            suffixIcon: IconButton(
              icon: Icon(
                obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              onPressed: () => setState(() => obscure = !obscure),
            ),
          ),
          onSubmitted: (_) => Navigator.pop(
            ctx,
            Security.verify(ctrl.text.trim(), user.password),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              Security.verify(ctrl.text.trim(), user.password),
            ),
            child: const Text('تأكيد'),
          ),
        ],
      ),
    ),
  );
  final typedPassword = ctrl.text.trim();
  ctrl.dispose();
  if (ok != true && context.mounted) {
    showSnack(context, 'كلمة المرور غير صحيحة', error: true);
  }
  // ترقية أمنية شفافة: التجزئة القديمة (ملح ثابت) تُعاد كتابتها بالشكل
  // الجديد (ملح عشوائي لكل مستخدم + جولات متعددة) بعد أول تحقق ناجح.
  if (ok == true &&
      context.mounted &&
      Security.needsRehash(user.password) &&
      user.id != null) {
    try {
      final db = await ProviderScope.containerOf(context, listen: false)
          .read(repoProvider)
          .database;
      await db.update('users', {'password': Security.hash(typedPassword)},
          where: 'id = ?', whereArgs: [user.id]);
    } catch (_) {}
  }
  return ok == true;
}
