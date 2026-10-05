// بوابة الأقسام وشريط الفئات في نقطة البيع (2026-09-24).
//
// البنية الهرمية الجديدة:
//   المستوى 1 — **بوابة الأقسام**: شاشة المبيعات تفتح على الأقسام فقط.
//   المستوى 2 — **الأصناف والفئات**: شريط فئات علوي (6 كحد أقصى والباقي في
//                منسدلة أنيقة) + زرّا تنقل سريع بين الأقسام المجاورة.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/icon_catalog.dart';
import '../core/models.dart';
import '../core/theme.dart';
import 'hierarchy_filter.dart' show toneOf;

/// بلاطة قسم في البوابة — مربع منحني بلون باستيل خاص بالقسم.
class _SectionTile extends StatelessWidget {
  const _SectionTile({
    required this.label,
    required this.icon,
    required this.tone,
    required this.subtitle,
    this.count,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final AppTone tone;
  final String subtitle;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: tone.background,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceOf(context),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: tone.foreground, size: 22),
                  ),
                  const Spacer(),
                  if (count != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceOf(context),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: tone.foreground,
                        ),
                      ),
                    ),
                ],
              ),
              const Spacer(),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textOf(context),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: AppColors.text3Of(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// بوابة الأقسام (المستوى 1) — تعرض الأقسام فقط، وبنقرة واحدة ندخل الأصناف.
class PosSectionsGate extends ConsumerWidget {
  const PosSectionsGate({
    super.key,
    required this.sections,
    required this.roots,
    required this.items,
    required this.onOpen,
  });

  final List<Section> sections;
  final List<ItemCategory> roots;

  /// كل الأصناف (لحساب عدد الأصناف في كل قسم).
  final List<Item> items;

  /// يُستدعى باختيار القسم: `null` = كل الأقسام، `-1` = عام.
  final void Function(int? sectionId) onOpen;

  int _countOf(int? sectionId) => items.where((i) {
        if (sectionId == null) return true;
        final sid = i.sectionId ?? _sectionOfCategory(i.categoryId);
        return sectionId == kGeneralSectionId ? sid == null : sid == sectionId;
      }).length;

  int? _sectionOfCategory(int? catId) {
    if (catId == null) return null;
    for (final c in roots) {
      if (c.id == catId) return c.sectionId;
      for (final child in c.children) {
        if (child.id == catId) return child.sectionId ?? c.sectionId;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = MediaQuery.sizeOf(context).width;
    final cross = w >= 1000 ? 4 : (w >= 600 ? 3 : 2);
    final allCount = _countOf(null);
    final generalCount = _countOf(kGeneralSectionId);

    return GridView.count(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 96),
      crossAxisCount: cross,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.08,
      children: [
        _SectionTile(
          label: 'كل الأقسام',
          icon: IconCatalog.of('apps'),
          tone: AppTone.blue,
          subtitle: 'كل الأصناف في مكان واحد',
          count: allCount,
          onTap: () => onOpen(null),
        ),
        if (generalCount > 0)
          _SectionTile(
            label: 'عام',
            icon: IconCatalog.of('category'),
            tone: AppTone.sand,
            subtitle: 'أصناف بلا قسم',
            count: generalCount,
            onTap: () => onOpen(kGeneralSectionId),
          ),
        for (final s in sections)
          _SectionTile(
            label: s.name,
            icon: IconCatalog.of(s.effectiveIcon),
            tone: toneOf(s.colorHex.isNotEmpty ? s.colorHex : ''),
            subtitle: '${roots.where((c) => c.sectionId == s.id).length} فئة',
            count: _countOf(s.id),
            onTap: () => onOpen(s.id),
          ),
      ],
    );
  }
}

/// شريط القسم النشط: اسم القسم + تنقّل سريع للقسم المجاور + رجوع للبوابة.
class PosSectionBar extends StatelessWidget {
  const PosSectionBar({
    super.key,
    required this.title,
    required this.onBackToGate,
    required this.onPrev,
    required this.onNext,
  });

  final String title;
  final VoidCallback onBackToGate;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Row(
        children: [
          // رجوع إلى بوابة الأقسام.
          _NavChip(
            icon: Icons.grid_view_rounded,
            tooltip: 'كل الأقسام',
            onTap: onBackToGate,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w800,
                color: AppColors.textOf(context),
              ),
            ),
          ),
          // تنقّل سريع: القسم السابق / التالي بلا رجوع للبوابة.
          _NavChip(
            icon: Icons.keyboard_arrow_right_rounded,
            tooltip: 'القسم السابق',
            enabled: onPrev != null,
            onTap: onPrev ?? () {},
          ),
          const SizedBox(width: 6),
          _NavChip(
            icon: Icons.keyboard_arrow_left_rounded,
            tooltip: 'القسم التالي',
            enabled: onNext != null,
            onTap: onNext ?? () {},
          ),
        ],
      ),
    );
  }
}

class _NavChip extends StatelessWidget {
  const _NavChip({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = enabled
        ? AppColors.primaryOf(context)
        : AppColors.text3Of(context).withValues(alpha: .4);
    return SizedBox(
      width: 36,
      height: 36,
      child: Material(
        color: c.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          iconSize: 20,
          onPressed: enabled ? onTap : null,
          icon: Icon(icon, color: c),
        ),
      ),
    );
  }
}

/// شريط الفئات (المستوى 2): صف واحد بحد أقصى 6 خانات، والباقي في منسدلة.
///
/// عند اختيار فئة من المنسدلة **تلتف القائمة فوراً** لتصبح صفاً واحداً
/// يبرز الفئة المختارة: [الكل] [المختارة] [المزيد ▾].
class PosCategoryStrip extends StatelessWidget {
  const PosCategoryStrip({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onPick,
  });

  /// فئات القسم النشط (بلا فروع) مرتّبة كما تظهر للمستخدم.
  final List<ItemCategory> categories;

  final int? selectedId;

  /// يُستدعى باختيار فئة (`null` = كل الفئات).
  final void Function(int? categoryId) onPick;

  static const int _maxVisible = 5; // + «الكل» = 6 خانات كحد أقصى

  @override
  Widget build(BuildContext context) {
    final selected = categories
        .cast<ItemCategory?>()
        .firstWhere((c) => c?.id == selectedId, orElse: () => null);

    // عند وجود فئة مختارة: [الكل] [المختارة] [المزيد] — صف واحد مركّز.
    final visible = <ItemCategory>[];
    if (selected != null) {
      visible.add(selected);
    } else {
      visible.addAll(categories.take(_maxVisible));
    }
    final hasMore = categories.length > (selected != null ? 1 : _maxVisible);

    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsetsDirectional.fromSTEB(12, 2, 12, 2),
        children: [
          _CatChip(
            label: 'الكل',
            icon: Icons.widgets_outlined,
            tone: AppTone.blue,
            active: selectedId == null,
            onTap: () => onPick(null),
          ),
          for (final c in visible)
            _CatChip(
              label: c.name,
              icon: IconCatalog.of(c.iconKey),
              tone: toneOf(c.colorHex.isNotEmpty ? c.colorHex : ''),
              active: c.id == selectedId,
              onTap: () => onPick(c.id),
            ),
          if (hasMore)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: _MoreChip(
                count: categories.length,
                onTap: () => _openSheet(context),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openSheet(BuildContext context) async {
    final pick = await showModalBottomSheet<int?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CategoriesSheet(
        categories: categories,
        selectedId: selectedId,
      ),
    );
    // القيمة null هنا تعني «الكل» (اختيار صريح من الورقة).
    onPick(pick);
  }
}

class _CategoriesSheet extends StatefulWidget {
  const _CategoriesSheet({
    required this.categories,
    required this.selectedId,
  });

  final List<ItemCategory> categories;
  final int? selectedId;

  @override
  State<_CategoriesSheet> createState() => _CategoriesSheetState();
}

class _CategoriesSheetState extends State<_CategoriesSheet> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim();
    final list = q.isEmpty
        ? widget.categories
        : widget.categories
            .where((c) => c.name.contains(q) || c.name.toLowerCase().contains(q))
            .toList();

    return DraggableScrollableSheet(
      initialChildSize: .55,
      minChildSize: .3,
      maxChildSize: .85,
      builder: (ctx, scroll) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          borderRadius: AppRadius.sheetTop,
        ),
        child: Column(
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
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Row(
                children: [
                  Icon(Icons.category_outlined,
                      color: AppColors.primaryOf(context)),
                  const SizedBox(width: 8),
                  const Text(
                    'اختر الفئة',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
            if (widget.categories.length > 8)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _q,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'بحث…',
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.field),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: list.length + 1,
                itemBuilder: (ctx, i) {
                  if (i == 0) {
                    return _CatRow(
                      label: 'كل الفئات',
                      icon: Icons.widgets_outlined,
                      tone: AppTone.blue,
                      active: widget.selectedId == null,
                      onTap: () => Navigator.pop(context, null),
                    );
                  }
                  final c = list[i - 1];
                  return _CatRow(
                    label: c.name,
                    icon: IconCatalog.of(c.iconKey),
                    tone: toneOf(c.colorHex.isNotEmpty ? c.colorHex : ''),
                    active: c.id == widget.selectedId,
                    onTap: () => Navigator.pop(context, c.id),
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

class _CatRow extends StatelessWidget {
  const _CatRow({
    required this.label,
    required this.icon,
    required this.tone,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final AppTone tone;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: tone.background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: tone.foreground, size: 20),
      ),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      trailing: active
          ? Icon(Icons.check_circle_rounded, color: AppColors.primaryOf(context))
          : null,
    );
  }
}

class _CatChip extends StatelessWidget {
  const _CatChip({
    required this.label,
    required this.icon,
    required this.tone,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final AppTone tone;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: Material(
        color: active ? tone.foreground : AppColors.surfaceOf(context),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 7, 12, 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 16,
                    color: active ? Colors.white : tone.foreground),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: active
                        ? Colors.white
                        : AppColors.textOf(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MoreChip extends StatelessWidget {
  const _MoreChip({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primaryOf(context).withValues(alpha: .12),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 7, 12, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.expand_more_rounded,
                  size: 16, color: AppColors.primaryOf(context)),
              const SizedBox(width: 4),
              Text(
                'المزيد ($count)',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryOf(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
