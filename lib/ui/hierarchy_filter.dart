import 'package:flutter/material.dart';

import '../core/theme.dart';

/// اختيار من المنسدلة الهرمية — يُغلَّف لأن `null` نفسه قيمة صالحة
/// («كل الأقسام») فلا يصلح للتفريق بين الإلغاء والاختيار.
class HierarchyPick {
  const HierarchyPick(this.id);

  /// معرّف القسم/الفئة — `null` يعني «الكل»، و`-1` يعني «عام».
  final int? id;
}

/// خيار واحد في القائمة المنسدلة (قسم أو فئة).
class HierarchyOption {
  const HierarchyOption({
    required this.id,
    required this.label,
    required this.icon,
    required this.tone,
    this.badge,
    this.subtitle,
  });

  final int? id;
  final String label;
  final IconData icon;
  final AppTone tone;
  final String? badge;
  final String? subtitle;
}

/// زر منسدل حديث (Filter Dropdown): يعرض الاختيار الحالي وبجانبه سهم،
/// وبالنقر يفتح نافذة سفلية واحدة تعرض كل الخيارات بأيقوناتها — بديلاً
/// عن السحب الأفقي المرهق يميناً ويساراً.
class HierarchyDropdown extends StatelessWidget {
  const HierarchyDropdown({
    super.key,
    required this.label,
    required this.icon,
    required this.tone,
    required this.onTap,
    this.badge,
    this.active = false,
  });

  final String label;
  final IconData icon;
  final AppTone tone;
  final VoidCallback onTap;
  final String? badge;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = active ? tone.foreground : AppColors.surfaceOf(context);
    final fg = active ? Colors.white : AppColors.textOf(context);
    // (2026-09-24) لا Expanded داخلي: المتصل يمدّدها (Expanded/Flexible) —
    // تمديد داخلي يسبّب «Competing ParentDataWidgets» حين يغلّفها المتصل.
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 48,
          padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 8, 0),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: active
                ? null
                : Border.all(
                    color: dark ? AppColors.dBorder : AppColors.border),
            boxShadow: active ? AppShadows.card(Theme.of(context).colorScheme) : null,
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: active
                      ? Colors.white.withValues(alpha: .22)
                      : tone.background,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon,
                    size: 16, color: active ? Colors.white : tone.foreground),
              ),
              const SizedBox(width: 6),
              // النص مرن بعلامة حذف: المنسدلة تنكمش ولا تفيض على 360px.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ),
              if (badge != null && badge!.isNotEmpty) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: active
                        ? Colors.white.withValues(alpha: .22)
                        : (dark ? AppColors.dSurface2 : AppColors.surface2),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    badge!,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: active ? Colors.white : AppColors.text3Of(context),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: active ? Colors.white : AppColors.text3Of(context),
              ),
            ],
          ),
        ),
      );
  }
}

/// يفتح نافذة سفلية حديثة (انحناء علوي 24px) تعرض كل الخيارات بأيقوناتها
/// ومع بحث فوري عند كثرتها. يُعيد [HierarchyPick] أو `null` عند الإلغاء.
/// إجراء إضافي يظهر أعلى خيارات الورقة (مثل «قسم جديد» و«إدارة»).
class HierarchyAction {
  const HierarchyAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

Future<HierarchyPick?> showHierarchySheet({
  required BuildContext context,
  required String title,
  required List<HierarchyOption> options,
  required int? selectedId,
  IconData titleIcon = Icons.widgets_outlined,
  List<HierarchyAction> actions = const <HierarchyAction>[],
}) {
  return showModalBottomSheet<HierarchyPick>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _HierarchySheet(
      title: title,
      options: options,
      selectedId: selectedId,
      titleIcon: titleIcon,
      actions: actions,
    ),
  );
}

class _HierarchySheet extends StatefulWidget {
  const _HierarchySheet({
    required this.title,
    required this.options,
    required this.selectedId,
    required this.titleIcon,
    required this.actions,
  });

  final String title;
  final List<HierarchyOption> options;
  final int? selectedId;
  final IconData titleIcon;
  final List<HierarchyAction> actions;

  @override
  State<_HierarchySheet> createState() => _HierarchySheetState();
}

class _HierarchySheetState extends State<_HierarchySheet> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<HierarchyOption> get _visible {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return widget.options;
    return widget.options
        .where((o) =>
            o.label.toLowerCase().contains(q) ||
            (o.badge ?? '').toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final items = _visible;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceOf(context),
        borderRadius: AppRadius.sheetTop,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderOf(context),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Row(
                children: [
                  Icon(widget.titleIcon,
                      size: 20, color: AppColors.primaryOf(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(widget.title,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('إغلاق'),
                  ),
                ],
              ),
            ),
            // بحث فوري عند كثرة الخيارات — «قائمة ذكية» بلا تمرير طويل.
            if (widget.options.length > 8) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'ابحث…',
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _search.clear();
                              setState(() {});
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
            ],
            if (widget.actions.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    for (final a in widget.actions)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            a.onTap();
                          },
                          icon: Icon(a.icon, size: 17),
                          label: Text(a.label),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
            ],
            Flexible(
              child: items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('لا نتائج',
                          style:
                              TextStyle(color: AppColors.text2Of(context))),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final o = items[i];
                        final selected = o.id == widget.selectedId;
                        return ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppRadius.card),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 2),
                          leading: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: selected
                                  ? o.tone.foreground
                                  : o.tone.background,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(o.icon,
                                size: 18,
                                color: selected
                                    ? Colors.white
                                    : o.tone.foreground),
                          ),
                          title: Text(o.label,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 14)),
                          subtitle: o.subtitle == null
                              ? null
                              : Text(o.subtitle!,
                                  style: const TextStyle(fontSize: 11.5)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (o.badge != null && o.badge!.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppColors.surface2Of(context),
                                    borderRadius:
                                        BorderRadius.circular(AppRadius.pill),
                                  ),
                                  child: Text(
                                    o.badge!,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.text3Of(context),
                                    ),
                                  ),
                                ),
                              if (selected) ...[
                                const SizedBox(width: 8),
                                Icon(Icons.check_circle,
                                    size: 18,
                                    color: AppColors.primaryOf(context)),
                              ],
                            ],
                          ),
                          onTap: () =>
                              Navigator.pop(context, HierarchyPick(o.id)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// يحوّل قيمة لون مخزّنة (مفتاح نغمة أو HEX) إلى كائن نغمة جاهز للعرض.
AppTone toneOf(String? value) => (value ?? '').startsWith('#')
    ? AppTone.fromHex(value!)
    : AppTone.byKey(value);
