import 'package:flutter/material.dart';

import 'theme.dart';

/// أيقونة واحدة في كتالوج نكسورا.
///
/// [key] هو ما يُخزَّن في قاعدة البيانات (`icon_key`) فلا نعتمد على
/// نقطة رمز (codePoint) قد تتغيّر بين إصدارات Flutter.
class CatalogIcon {
  final String key;
  final IconData icon;
  final String label;
  final String group;

  const CatalogIcon(this.key, this.icon, this.label, this.group);
}

/// الكتالوج الشامل لأيقونات الأقسام والفئات — يغطي التصنيفات التجارية
/// الأكثر شيوعاً في متاجر التجزئة والخدمات.
///
/// الاستخدام:
/// ```dart
/// Icon(IconCatalog.of(section.iconKey));
/// final key = await showIconPicker(context, initialKey: section.iconKey);
/// ```
class IconCatalog {
  const IconCatalog._();

  /// الأيقونة الافتراضية حين لا يوجد مفتاح (أو مفتاح قديم غير معروف).
  static const IconData fallback = Icons.category_outlined;

  /// المجموعات (تظهر كفلاتر أعلى منتقي الأيقونات).
  static const List<String> groups = <String>[
    'الكل',
    'صيانة وأدوات',
    'هواتف وإلكترونيات',
    'بقالة وتموين',
    'معلبات ومحفوظات',
    'مشروبات',
    'بهارات وتوابل',
    'منظفات ومنزل',
    'ملابس وأزياء',
    'عناية شخصية وصحة',
    'أثاث ومفروشات',
    'قرطاسية ومكتبية',
    'مطبخ ومخبوزات',
    'رياضة ولياقة',
    'أطفال وألعاب',
    'سيارات ومركبات',
    'بناء ومواد',
    'زراعة وحيوانات',
    'مجوهرات وإكسسوارات',
    'خدمات وعام',
  ];

  static const List<CatalogIcon> all = <CatalogIcon>[
    // ===== صيانة وأدوات =====
    CatalogIcon('build', Icons.build, 'صيانة', 'صيانة وأدوات'),
    CatalogIcon('construction', Icons.construction, 'بناء', 'صيانة وأدوات'),
    CatalogIcon('handyman', Icons.handyman, 'فني', 'صيانة وأدوات'),
    CatalogIcon('hardware', Icons.hardware, 'أدوات', 'صيانة وأدوات'),
    CatalogIcon('home_repair', Icons.home_repair_service, 'تصليح منزلي', 'صيانة وأدوات'),
    CatalogIcon('engineering', Icons.engineering, 'هندسة', 'صيانة وأدوات'),
    CatalogIcon('misc_services', Icons.miscellaneous_services, 'خدمات فنية', 'صيانة وأدوات'),
    CatalogIcon('electrical', Icons.electrical_services, 'كهرباء', 'صيانة وأدوات'),
    CatalogIcon('bolt', Icons.bolt, 'طاقة', 'صيانة وأدوات'),
    CatalogIcon('power', Icons.power, 'تشغيل', 'صيانة وأدوات'),
    CatalogIcon('settings', Icons.settings, 'إعدادات', 'صيانة وأدوات'),
    CatalogIcon('tune', Icons.tune, 'ضبط', 'صيانة وأدوات'),

    // ===== هواتف وإلكترونيات =====
    CatalogIcon('smartphone', Icons.smartphone, 'هاتف', 'هواتف وإلكترونيات'),
    CatalogIcon('phone_iphone', Icons.phone_iphone, 'آيفون', 'هواتف وإلكترونيات'),
    CatalogIcon('tablet', Icons.tablet, 'تابلت', 'هواتف وإلكترونيات'),
    CatalogIcon('laptop', Icons.laptop, 'لابتوب', 'هواتف وإلكترونيات'),
    CatalogIcon('computer', Icons.computer, 'حاسوب', 'هواتف وإلكترونيات'),
    CatalogIcon('desktop', Icons.desktop_windows, 'سطح مكتب', 'هواتف وإلكترونيات'),
    CatalogIcon('tv', Icons.tv, 'تلفاز', 'هواتف وإلكترونيات'),
    CatalogIcon('headphones', Icons.headphones, 'سماعات', 'هواتف وإلكترونيات'),
    CatalogIcon('headset', Icons.headset, 'سماعة رأس', 'هواتف وإلكترونيات'),
    CatalogIcon('speaker', Icons.speaker, 'مكبر صوت', 'هواتف وإلكترونيات'),
    CatalogIcon('keyboard', Icons.keyboard, 'لوحة مفاتيح', 'هواتف وإلكترونيات'),
    CatalogIcon('mouse', Icons.mouse, 'فأرة', 'هواتف وإلكترونيات'),
    CatalogIcon('watch', Icons.watch, 'ساعة يد', 'هواتف وإلكترونيات'),
    CatalogIcon('camera', Icons.camera_alt, 'كاميرا', 'هواتف وإلكترونيات'),
    CatalogIcon('videocam', Icons.videocam, 'تصوير', 'هواتف وإلكترونيات'),
    CatalogIcon('memory', Icons.memory, 'معالج', 'هواتف وإلكترونيات'),
    CatalogIcon('router', Icons.router, 'راوتر', 'هواتف وإلكترونيات'),
    CatalogIcon('wifi', Icons.wifi, 'واي فاي', 'هواتف وإلكترونيات'),
    CatalogIcon('bluetooth', Icons.bluetooth, 'بلوتوث', 'هواتف وإلكترونيات'),
    CatalogIcon('battery', Icons.battery_full, 'بطارية', 'هواتف وإلكترونيات'),
    CatalogIcon('print', Icons.print, 'طابعة', 'هواتف وإلكترونيات'),
    CatalogIcon('devices', Icons.devices, 'أجهزة', 'هواتف وإلكترونيات'),

    // ===== بقالة وتموين =====
    CatalogIcon('grocery', Icons.local_grocery_store, 'بقالة', 'بقالة وتموين'),
    CatalogIcon('basket', Icons.shopping_basket, 'سلة', 'بقالة وتموين'),
    CatalogIcon('cart', Icons.shopping_cart, 'عربة تسوق', 'بقالة وتموين'),
    CatalogIcon('bag', Icons.shopping_bag, 'كيس', 'بقالة وتموين'),
    CatalogIcon('grain', Icons.grain, 'حبوب', 'بقالة وتموين'),
    CatalogIcon('agriculture', Icons.agriculture, 'زراعة', 'بقالة وتموين'),
    CatalogIcon('eco', Icons.eco, 'طبيعي', 'بقالة وتموين'),
    CatalogIcon('spa', Icons.spa, 'أعشاب', 'بقالة وتموين'),
    CatalogIcon('egg', Icons.egg_alt, 'بيض', 'بقالة وتموين'),
    CatalogIcon('set_meal', Icons.set_meal, 'لحوم', 'بقالة وتموين'),
    CatalogIcon('kebab', Icons.kebab_dining, 'مشويات', 'بقالة وتموين'),
    CatalogIcon('rice', Icons.rice_bowl, 'أرز', 'بقالة وتموين'),
    CatalogIcon('breakfast', Icons.breakfast_dining, 'فطور', 'بقالة وتموين'),

    // ===== معلبات ومحفوظات =====
    CatalogIcon('inventory', Icons.inventory_2, 'معلبات', 'معلبات ومحفوظات'),
    CatalogIcon('inbox', Icons.inbox, 'صندوق', 'معلبات ومحفوظات'),
    CatalogIcon('archive', Icons.archive, 'مخزون', 'معلبات ومحفوظات'),
    CatalogIcon('store', Icons.store, 'مستودع', 'معلبات ومحفوظات'),
    CatalogIcon('shelves', Icons.shelves, 'رفوف', 'معلبات ومحفوظات'),
    CatalogIcon('food_bank', Icons.food_bank, 'مؤونة', 'معلبات ومحفوظات'),
    CatalogIcon('kitchen', Icons.kitchen, 'مطبخ', 'معلبات ومحفوظات'),
    CatalogIcon('dinner', Icons.dinner_dining, 'وجبات', 'معلبات ومحفوظات'),
    CatalogIcon('lunch', Icons.lunch_dining, 'غداء', 'معلبات ومحفوظات'),

    // ===== مشروبات =====
    CatalogIcon('water_drop', Icons.water_drop, 'ماء', 'مشروبات'),
    CatalogIcon('local_drink', Icons.local_drink, 'مشروب', 'مشروبات'),
    CatalogIcon('coffee', Icons.coffee, 'قهوة', 'مشروبات'),
    CatalogIcon('emoji_drink', Icons.emoji_food_beverage, 'كوب', 'مشروبات'),
    CatalogIcon('free_breakfast', Icons.free_breakfast, 'شاي', 'مشروبات'),
    CatalogIcon('sports_bar', Icons.sports_bar, 'بيرة', 'مشروبات'),
    CatalogIcon('liquor', Icons.liquor, 'عصير', 'مشروبات'),
    CatalogIcon('icecream', Icons.icecream, 'آيس كريم', 'مشروبات'),
    CatalogIcon('local_cafe', Icons.local_cafe, 'مقهى', 'مشروبات'),

    // ===== بهارات وتوابل =====
    CatalogIcon('spice', Icons.spoke, 'بهارات', 'بهارات وتوابل'),
    CatalogIcon('grass', Icons.grass, 'أعشاب', 'بهارات وتوابل'),
    CatalogIcon('local_florist', Icons.local_florist, 'ورقيات', 'بهارات وتوابل'),
    CatalogIcon('potted_plant', Icons.nature, 'نبات', 'بهارات وتوابل'),
    CatalogIcon('yard', Icons.yard, 'خضار', 'بهارات وتوابل'),
    CatalogIcon('co2', Icons.co2, 'ملح', 'بهارات وتوابل'),
    CatalogIcon('science', Icons.science, 'خلطات', 'بهارات وتوابل'),
    CatalogIcon('blender', Icons.blender, 'خلاط', 'بهارات وتوابل'),

    // ===== منظفات ومنزل =====
    CatalogIcon('cleaning', Icons.cleaning_services, 'تنظيف', 'منظفات ومنزل'),
    CatalogIcon('wash', Icons.wash, 'غسيل', 'منظفات ومنزل'),
    CatalogIcon('soap', Icons.soap, 'صابون', 'منظفات ومنزل'),
    CatalogIcon('local_laundry', Icons.local_laundry_service, 'مغسلة', 'منظفات ومنزل'),
    CatalogIcon('sanitizer', Icons.sanitizer, 'معقّم', 'منظفات ومنزل'),
    CatalogIcon('bathtub', Icons.bathtub, 'أدوات حمام', 'منظفات ومنزل'),
    CatalogIcon('bathroom', Icons.bathroom, 'حمام', 'منظفات ومنزل'),
    CatalogIcon('weekend', Icons.weekend, 'أثاث منزلي', 'منظفات ومنزل'),
    CatalogIcon('lightbulb', Icons.lightbulb, 'إضاءة', 'منظفات ومنزل'),
    CatalogIcon('bed', Icons.bed, 'سرير', 'منظفات ومنزل'),

    // ===== ملابس وأزياء =====
    CatalogIcon('checkroom', Icons.checkroom, 'ملابس', 'ملابس وأزياء'),
    CatalogIcon('dry_cleaning', Icons.dry_cleaning, 'تنظيف جاف', 'ملابس وأزياء'),
    CatalogIcon('man', Icons.man, 'رجالي', 'ملابس وأزياء'),
    CatalogIcon('woman', Icons.woman, 'نسائي', 'ملابس وأزياء'),
    CatalogIcon('boy', Icons.boy, 'أولاد', 'ملابس وأزياء'),
    CatalogIcon('girl', Icons.girl, 'بنات', 'ملابس وأزياء'),
    CatalogIcon('shopping_bag2', Icons.shopping_bag, 'حقائب', 'ملابس وأزياء'),
    CatalogIcon('style', Icons.style, 'موضة', 'ملابس وأزياء'),

    // ===== عناية شخصية وصحة =====
    CatalogIcon('health', Icons.health_and_safety, 'صحة', 'عناية شخصية وصحة'),
    CatalogIcon('local_pharmacy', Icons.local_pharmacy, 'صيدلية', 'عناية شخصية وصحة'),
    CatalogIcon('medical', Icons.medical_services, 'خدمات طبية', 'عناية شخصية وصحة'),
    CatalogIcon('vaccines', Icons.vaccines, 'لقاحات', 'عناية شخصية وصحة'),
    CatalogIcon('medication', Icons.medication, 'دواء', 'عناية شخصية وصحة'),
    CatalogIcon('healing', Icons.healing, 'علاج', 'عناية شخصية وصحة'),
    CatalogIcon('face', Icons.face, 'عناية', 'عناية شخصية وصحة'),
    CatalogIcon('bloodtype', Icons.bloodtype, 'تحاليل', 'عناية شخصية وصحة'),
    CatalogIcon('monitor_heart', Icons.monitor_heart, 'متابعة', 'عناية شخصية وصحة'),

    // ===== أثاث ومفروشات =====
    CatalogIcon('chair', Icons.chair, 'كرسي', 'أثاث ومفروشات'),
    CatalogIcon('table_restaurant', Icons.table_restaurant, 'طاولة', 'أثاث ومفروشات'),
    CatalogIcon('king_bed', Icons.king_bed, 'غرفة نوم', 'أثاث ومفروشات'),
    CatalogIcon('single_bed', Icons.single_bed, 'سرير فردي', 'أثاث ومفروشات'),
    CatalogIcon('countertops', Icons.countertops, 'أسطح', 'أثاث ومفروشات'),
    CatalogIcon('living', Icons.living, 'مجلس', 'أثاث ومفروشات'),

    // ===== قرطاسية ومكتبية =====
    CatalogIcon('menu_book', Icons.menu_book, 'كتب', 'قرطاسية ومكتبية'),
    CatalogIcon('edit', Icons.edit, 'أقلام', 'قرطاسية ومكتبية'),
    CatalogIcon('sticky_note', Icons.sticky_note_2, 'ملاحظات', 'قرطاسية ومكتبية'),
    CatalogIcon('description', Icons.description, 'أوراق', 'قرطاسية ومكتبية'),
    CatalogIcon('folder', Icons.folder, 'ملفات', 'قرطاسية ومكتبية'),
    CatalogIcon('print2', Icons.local_printshop, 'طباعة', 'قرطاسية ومكتبية'),
    CatalogIcon('school', Icons.school, 'مدرسة', 'قرطاسية ومكتبية'),
    CatalogIcon('business_center', Icons.business_center, 'مكتبي', 'قرطاسية ومكتبية'),

    // ===== مطبخ ومخبوزات =====
    CatalogIcon('bakery', Icons.bakery_dining, 'مخبوزات', 'مطبخ ومخبوزات'),
    CatalogIcon('cake', Icons.cake, 'كيك', 'مطبخ ومخبوزات'),
    CatalogIcon('restaurant', Icons.restaurant, 'مطعم', 'مطبخ ومخبوزات'),
    CatalogIcon('fastfood', Icons.fastfood, 'وجبات سريعة', 'مطبخ ومخبوزات'),
    CatalogIcon('pizza', Icons.local_pizza, 'بيتزا', 'مطبخ ومخبوزات'),
    CatalogIcon('ramen', Icons.ramen_dining, 'نودلز', 'مطبخ ومخبوزات'),
    CatalogIcon('microwave', Icons.microwave, 'ميكروويف', 'مطبخ ومخبوزات'),
    CatalogIcon('dining', Icons.local_dining, 'طعام', 'مطبخ ومخبوزات'),

    // ===== رياضة ولياقة =====
    CatalogIcon('fitness', Icons.fitness_center, 'لياقة', 'رياضة ولياقة'),
    CatalogIcon('sports_soccer', Icons.sports_soccer, 'كرة قدم', 'رياضة ولياقة'),
    CatalogIcon('sports_basket', Icons.sports_basketball, 'كرة سلة', 'رياضة ولياقة'),
    CatalogIcon('sports_tennis', Icons.sports_tennis, 'تنس', 'رياضة ولياقة'),
    CatalogIcon('sports_gym', Icons.sports_gymnastics, 'جمباز', 'رياضة ولياقة'),
    CatalogIcon('pool', Icons.pool, 'سباحة', 'رياضة ولياقة'),
    CatalogIcon('directions_bike', Icons.directions_bike, 'دراجة', 'رياضة ولياقة'),
    CatalogIcon('hiking', Icons.hiking, 'تخييم', 'رياضة ولياقة'),

    // ===== أطفال وألعاب =====
    CatalogIcon('toys', Icons.toys, 'ألعاب', 'أطفال وألعاب'),
    CatalogIcon('child_care', Icons.child_care, 'طفل', 'أطفال وألعاب'),
    CatalogIcon('baby', Icons.baby_changing_station, 'مستلزمات طفل', 'أطفال وألعاب'),
    CatalogIcon('esports', Icons.sports_esports, 'ألعاب إلكترونية', 'أطفال وألعاب'),
    CatalogIcon('puzzle', Icons.extension, 'بازل', 'أطفال وألعاب'),
    CatalogIcon('family', Icons.family_restroom, 'عائلة', 'أطفال وألعاب'),

    // ===== سيارات ومركبات =====
    CatalogIcon('car', Icons.directions_car, 'سيارة', 'سيارات ومركبات'),
    CatalogIcon('car_repair', Icons.car_repair, 'تصليح سيارات', 'سيارات ومركبات'),
    CatalogIcon('two_wheeler', Icons.two_wheeler, 'دراجة نارية', 'سيارات ومركبات'),
    CatalogIcon('local_shipping', Icons.local_shipping, 'شاحنة', 'سيارات ومركبات'),
    CatalogIcon('garage', Icons.garage, 'مرآب', 'سيارات ومركبات'),
    CatalogIcon('oil', Icons.oil_barrel, 'زيوت', 'سيارات ومركبات'),
    CatalogIcon('tire', Icons.tire_repair, 'إطارات', 'سيارات ومركبات'),

    // ===== بناء ومواد =====
    CatalogIcon('foundation', Icons.foundation, 'أساسات', 'بناء ومواد'),
    CatalogIcon('carpenter', Icons.carpenter, 'نجارة', 'بناء ومواد'),
    CatalogIcon('plumbing', Icons.plumbing, 'سباكة', 'بناء ومواد'),
    CatalogIcon('solar', Icons.solar_power, 'طاقة شمسية', 'بناء ومواد'),
    CatalogIcon('stairs', Icons.stairs, 'سلالم', 'بناء ومواد'),
    CatalogIcon('warehouse', Icons.warehouse, 'مستودع مواد', 'بناء ومواد'),
    CatalogIcon('format_paint', Icons.format_paint, 'دهان', 'بناء ومواد'),

    // ===== زراعة وحيوانات =====
    CatalogIcon('pets', Icons.pets, 'حيوانات', 'زراعة وحيوانات'),
    CatalogIcon('cruelty', Icons.cruelty_free, 'رفق بالحيوان', 'زراعة وحيوانات'),
    CatalogIcon('tractor', Icons.agriculture, 'معدات زراعية', 'زراعة وحيوانات'),
    CatalogIcon('park', Icons.park, 'حديقة', 'زراعة وحيوانات'),
    CatalogIcon('compost', Icons.compost, 'سماد', 'زراعة وحيوانات'),

    // ===== مجوهرات وإكسسوارات =====
    CatalogIcon('diamond', Icons.diamond, 'مجوهرات', 'مجوهرات وإكسسوارات'),
    CatalogIcon('watch2', Icons.watch, 'ساعات', 'مجوهرات وإكسسوارات'),
    CatalogIcon('glasses', Icons.visibility, 'نظارات', 'مجوهرات وإكسسوارات'),
    CatalogIcon('ring', Icons.radio_button_unchecked, 'خواتم', 'مجوهرات وإكسسوارات'),
    CatalogIcon('gift', Icons.card_giftcard, 'هدايا', 'مجوهرات وإكسسوارات'),

    // ===== خدمات وعام =====
    CatalogIcon('storefront', Icons.storefront, 'متجر', 'خدمات وعام'),
    CatalogIcon('mall', Icons.local_mall, 'مركز تجاري', 'خدمات وعام'),
    CatalogIcon('convenience', Icons.local_convenience_store, 'دكان', 'خدمات وعام'),
    CatalogIcon('support_agent', Icons.support_agent, 'خدمة عملاء', 'خدمات وعام'),
    CatalogIcon('delivery', Icons.delivery_dining, 'توصيل', 'خدمات وعام'),
    CatalogIcon('payments', Icons.payments, 'مدفوعات', 'خدمات وعام'),
    CatalogIcon('receipt', Icons.receipt_long, 'فواتير', 'خدمات وعام'),
    CatalogIcon('category', Icons.category, 'عام', 'خدمات وعام'),
    CatalogIcon('apps', Icons.apps, 'متنوع', 'خدمات وعام'),
    CatalogIcon('widgets', Icons.widgets, 'أقسام', 'خدمات وعام'),
    CatalogIcon('grid_view', Icons.grid_view, 'شبكة', 'خدمات وعام'),
    CatalogIcon('new_releases', Icons.new_releases, 'جديد', 'خدمات وعام'),
    CatalogIcon('star', Icons.star, 'مميز', 'خدمات وعام'),
    CatalogIcon('loyalty', Icons.loyalty, 'ولاء', 'خدمات وعام'),
  ];

  /// أيقونة بالمفتاح — ترجع [fallback] عند الفراغ أو عدم المعرفة.
  static IconData of(String? key) {
    if (key == null || key.isEmpty) return fallback;
    for (final i in all) {
      if (i.key == key) return i.icon;
    }
    return fallback;
  }

  /// أيقونات مجموعة محددة (بدون «الكل»).
  static List<CatalogIcon> byGroup(String group) {
    if (group == groups.first) return all;
    return all.where((i) => i.group == group).toList();
  }

  /// بحث بالاسم أو المفتاح (عربي/إنجليزي).
  static List<CatalogIcon> search(String query, {String group = 'الكل'}) {
    final q = query.trim().toLowerCase();
    final base = byGroup(group);
    if (q.isEmpty) return base;
    return base
        .where((i) =>
            i.label.toLowerCase().contains(q) ||
            i.key.toLowerCase().contains(q) ||
            i.group.toLowerCase().contains(q))
        .toList();
  }
}

/// منتقي أيقونة — شريحة سفلية فيها بحث وفلاتر مجموعات وشبكة أيقونات.
///
/// تُعيد مفتاح الأيقونة المختارة، أو `null` عند الإلغاء.
Future<String?> showIconPicker(
  BuildContext context, {
  String? initialKey,
  String title = 'اختيار أيقونة',
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _IconPickerSheet(initialKey: initialKey, title: title),
  );
}

class _IconPickerSheet extends StatefulWidget {
  const _IconPickerSheet({this.initialKey, required this.title});

  final String? initialKey;
  final String title;

  @override
  State<_IconPickerSheet> createState() => _IconPickerSheetState();
}

class _IconPickerSheetState extends State<_IconPickerSheet> {
  final _search = TextEditingController();
  String _group = IconCatalog.groups.first;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialKey;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<CatalogIcon> get _visible => IconCatalog.search(_search.text, group: _group);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final items = _visible;
    return DraggableScrollableSheet(
      initialChildSize: .78,
      minChildSize: .45,
      maxChildSize: .95,
      builder: (context, scroll) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceOf(context),
          borderRadius: AppRadius.sheetTop,
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderOf(context),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.title,
                        style: Theme.of(context).textTheme.titleLarge),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, _selected),
                    child: const Text('تم'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'ابحث بالاسم…',
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
            const SizedBox(height: 10),
            SizedBox(
              height: 40,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemCount: IconCatalog.groups.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final g = IconCatalog.groups[i];
                  final active = g == _group;
                  return ChoiceChip(
                    label: Text(g),
                    selected: active,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _group = g),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text('لا نتائج',
                          style: TextStyle(color: AppColors.text2Of(context))))
                  : GridView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 5,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final it = items[i];
                        final active = it.key == _selected;
                        return InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => setState(() => _selected = it.key),
                          child: Container(
                            decoration: BoxDecoration(
                              color: active
                                  ? scheme.primary
                                  : (dark
                                      ? AppColors.dSurface2
                                      : AppColors.surface2),
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: active ? AppShadows.card(scheme) : null,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  it.icon,
                                  size: 24,
                                  color: active
                                      ? Colors.white
                                      : (dark
                                          ? AppColors.dText
                                          : AppColors.text),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  it.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    color: active
                                        ? Colors.white
                                        : AppColors.text3Of(context),
                                  ),
                                ),
                              ],
                            ),
                          ),
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

/// منتقي نغمة لون — ألوان باستيل هادئة + خيارات مخصّصة.
///
/// [value] مفتاح نغمة (`blue`, `orange`…) أو لون HEX (`#0D6EFD`).
class ColorTonePicker extends StatelessWidget {
  const ColorTonePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.showCustom = true,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool showCustom;

  /// ألوان مخصّصة إضافية (HEX كامل).
  static const List<Color> customColors = <Color>[
    Color(0xFF0D6EFD),
    Color(0xFF0066FF),
    Color(0xFF16A34A),
    Color(0xFF7C3AED),
    Color(0xFFDB2777),
    Color(0xFFEA8C1C),
    Color(0xFF0E9488),
    Color(0xFFE11D48),
    Color(0xFF334155),
    Color(0xFFB4741A),
  ];

  static String hexOf(Color c) =>
      '#${((c.toARGB32() >> 16) & 0xFF).toRadixString(16).padLeft(2, '0')}'
      '${((c.toARGB32() >> 8) & 0xFF).toRadixString(16).padLeft(2, '0')}'
      '${(c.toARGB32() & 0xFF).toRadixString(16).padLeft(2, '0')}'
          .toUpperCase();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final t in AppTone.all)
              _ToneDot(
                color: t.foreground,
                background: t.background,
                label: t.label,
                selected: value == t.key || (value.isEmpty && t.key == 'blue'),
                onTap: () => onChanged(t.key),
              ),
          ],
        ),
        if (showCustom) ...[
          const SizedBox(height: 12),
          Text('ألوان مخصّصة',
              style: TextStyle(fontSize: 12.5, color: AppColors.text2Of(context))),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in customColors)
                _ToneDot(
                  color: c,
                  background: AppTone.fromHex(hexOf(c)).background,
                  label: hexOf(c).replaceAll('#', ''),
                  selected: value.toUpperCase() == hexOf(c),
                  onTap: () => onChanged(hexOf(c)),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ToneDot extends StatelessWidget {
  const _ToneDot({
    required this.color,
    required this.background,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final Color background;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 58,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? color : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: selected
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.5, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
