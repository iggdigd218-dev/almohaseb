// QA — الهوية البصرية الجديدة (2026-09-24): الثيم، كتالوج الأيقونات،
// النغمات، أعمدة الهوية في المخطط (icon_key/color_hex/image_path)،
// وأيقونة ويندوز.
//
// العقد بعد التنفيذ:
//  • اللون الأساسي أزرق ملكي (#0D6EFD) والخلفية رمادي ثلجي (#F4F6F9)،
//    وزوايا البطاقات والحقول موحّدة عند 16px.
//  • الكتالوج: مفاتيح فريدة، وبحث عربي/إنجليزي، وبديل آمن للمفتاح الفارغ.
//  • المخطط v25: أعمدة الهوية تُضاف للقواعد القديمة تلقائياً (ALTER آمن).
//  • أيقونة ويندوز: ملف app_icon.ico بكل المقاسات + تثبيت في main.cpp.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/icon_catalog.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// بنية قديمة لجدول sections (قبل أعمدة الهوية) — جهاز مُرقّى يحملها هكذا.
const _legacySections = '''
      CREATE TABLE sections (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        name        TEXT NOT NULL,
        icon        TEXT DEFAULT '',
        sort_order  INTEGER NOT NULL DEFAULT 0,
        deleted_at  TEXT DEFAULT '',
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL
      )''';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  const backend = 'https://qa-branding.europe-west1.firebasedatabase.app';

  Future<void> openLegacy({bool heal = true}) async {
    debugDefaultBackendUrlOverride = backend;
    tmp = await Directory.systemTemp.createTemp('nexora_branding_');
    db = await databaseFactory.openDatabase('${tmp.path}/brand.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    await db.execute('DROP TABLE sections');
    await db.execute(_legacySections);
    if (heal) {
      await AppDatabase.ensureFullSchema(db);
    }
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  }

  Future<List<String>> columns(String table) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    return info.map((c) => '${c['name']}').toList();
  }

  tearDown(() async {
    debugDefaultBackendUrlOverride = null;
    try {
      await db.close();
    } catch (_) {}
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  // ===================== الثيم =====================
  test('BRD-01 الثيم: أزرق ملكي + رمادي ثلجي + زوايا 16px', () {
    expect(AppColors.primary, const Color(0xFF0D6EFD));
    expect(AppColors.primary2, const Color(0xFF0066FF));
    expect(AppColors.bg, const Color(0xFFF4F6F9));
    expect(AppColors.surface, const Color(0xFFFFFFFF));
    // الأخضر الزمردي للأسعار وحالة التوفر.
    expect(AppColors.green, const Color(0xFF16A34A));
    // توحيد الانحناء.
    expect(AppRadius.card, 16);
    expect(AppRadius.field, 16);
    expect(AppRadius.sheet, 24);
    // رقم المخطط يواكب الهجرة الجديدة.
    expect(AppDatabase.schemaVersion, greaterThanOrEqualTo(25));
  });

  test('BRD-02 ThemeData: البطاقات بلا حدود سميكة وبظل ناعم 16px', () {
    final theme = AppTheme.light();
    final card = theme.cardTheme;
    final shape = card.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius.resolve(TextDirection.rtl).topLeft.x, 16);
    expect(card.elevation, greaterThan(0));
    // لا حدّ سميك: الحواف شفافة (الظل هو الفاصل البصري).
    expect(shape.side, BorderSide.none);
    // الحقول والبطاقات بنفس الانحناء.
    final input = theme.inputDecorationTheme.border! as OutlineInputBorder;
    expect(input.borderRadius.resolve(TextDirection.rtl).topLeft.x, 16);
  });

  // ===================== الكتالوج =====================
  test('ICON-01 الكتالوج: مفاتيح فريدة ومجموعات تغطي التصنيفات', () {
    final keys = IconCatalog.all.map((i) => i.key).toList();
    expect(keys.toSet().length, keys.length);
    expect(keys.length, greaterThanOrEqualTo(120));
    for (final g in [
      'صيانة وأدوات',
      'هواتف وإلكترونيات',
      'بقالة وتموين',
      'معلبات ومحفوظات',
      'مشروبات',
      'بهارات وتوابل',
      'منظفات ومنزل',
      'ملابس وأزياء',
      'عناية شخصية وصحة',
    ]) {
      expect(IconCatalog.byGroup(g).isNotEmpty, isTrue, reason: g);
    }
    // كل أيقونة تنتمي لمجموعة معلومة.
    for (final i in IconCatalog.all) {
      expect(IconCatalog.groups, contains(i.group), reason: i.key);
    }
  });

  test('ICON-02 البحث: بالعربية وبالمفتاح الإنجليزي', () {
    expect(IconCatalog.search('هاتف').isNotEmpty, isTrue);
    expect(IconCatalog.search('phone').any((i) => i.key == 'smartphone'),
        isTrue);
    expect(IconCatalog.search('').length, IconCatalog.all.length);
    // فلترة المجموعة تُطبَّق مع البحث.
    final inDrinks = IconCatalog.search('', group: 'مشروبات');
    expect(inDrinks.every((i) => i.group == 'مشروبات'), isTrue);
    // بديل آمن عند الفراغ أو مفتاح مجهول.
    expect(IconCatalog.of(''), IconCatalog.fallback);
    expect(IconCatalog.of(null), IconCatalog.fallback);
    expect(IconCatalog.of('غير_موجود'), IconCatalog.fallback);
    expect(IconCatalog.of('smartphone'), Icons.smartphone);
  });

  // ===================== النغمات =====================
  test('TONE-01 النغمات: باستيل جاهزة + لون مخصص من HEX', () {
    expect(AppTone.byKey('orange').foreground, const Color(0xFFEA8C1C));
    expect(AppTone.byKey('violet').foreground, const Color(0xFF7C3AED));
    expect(AppTone.byKey('مجهول').key, 'blue'); // بديل افتراضي
    // خلفية الباستيل أفتح بكثير من لون النغمة.
    for (final t in AppTone.all) {
      expect(t.background.computeLuminance(),
          greaterThan(t.foreground.computeLuminance()));
    }
    final custom = AppTone.fromHex('#123456');
    expect(custom.key, 'custom');
    expect(custom.foreground, const Color(0xFF123456));
    expect(custom.background.computeLuminance(),
        greaterThan(custom.foreground.computeLuminance()));
    // نص HEX غير صالح ⇒ النغمة الافتراضية.
    expect(AppTone.fromHex('').key, 'blue');
    expect(AppTone.fromHex('xyz').key, 'blue');
  });

  // ===================== المخطط =====================
  test('BRD-03 القاعدة القديمة تُرَمَّم بأعمدة الهوية عند الفتح', () async {
    await openLegacy(heal: false);
    final before = await columns('sections');
    expect(before, isNot(contains('icon_key')));

    await AppDatabase.ensureFullSchema(db);
    await AppDatabase.migrateToV25(db);

    final after = await columns('sections');
    for (final c in ['icon_key', 'color_hex', 'image_path']) {
      expect(after, contains(c));
    }
    final catCols = await columns('item_categories');
    for (final c in ['icon_key', 'color_hex', 'image_path']) {
      expect(catCols, contains(c));
    }
  });

  test('BRD-04 الترميم idempotent: تكراره بلا خطأ ولا تكرار أعمدة', () async {
    await openLegacy();
    await AppDatabase.migrateToV25(db);
    await AppDatabase.ensureSectionColumns(db);
    final cols = await columns('sections');
    expect(cols.where((c) => c == 'icon_key').length, 1);
  });

  test('BRD-05 حفظ وقراءة هوية القسم (أيقونة + لون + صورة)', () async {
    await openLegacy();
    final now = DateTime.now();
    final id = await repo.saveSection(Section(
      name: 'إلكترونيات',
      iconKey: 'smartphone',
      colorHex: '#0D6EFD',
      imagePath: '/tmp/sec.png',
      createdAt: now,
      updatedAt: now,
    ));
    final rows = await db.query('sections', where: 'id = ?', whereArgs: [id]);
    expect(rows.first['icon_key'], 'smartphone');
    expect(rows.first['color_hex'], '#0D6EFD');
    expect(rows.first['image_path'], '/tmp/sec.png');

    final loaded = (await repo.sections()).firstWhere((s) => s.id == id);
    expect(loaded.iconKey, 'smartphone');
    expect(loaded.colorHex, '#0D6EFD');
    expect(loaded.effectiveIcon, 'smartphone');
  });

  test('BRD-06 حفظ وقراءة هوية الفئة (أيقونة + لون)', () async {
    await openLegacy();
    final now = DateTime.now();
    final id = await repo.saveItemCategory(ItemCategory(
      name: 'موبايلات',
      iconKey: 'phone_iphone',
      colorHex: 'violet',
      createdAt: now,
      updatedAt: now,
    ));
    final rows =
        await db.query('item_categories', where: 'id = ?', whereArgs: [id]);
    expect(rows.first['icon_key'], 'phone_iphone');
    expect(rows.first['color_hex'], 'violet');

    final loaded =
        (await repo.itemCategories()).firstWhere((c) => c.id == id);
    expect(loaded.iconKey, 'phone_iphone');
    expect(loaded.colorHex, 'violet');
  });

  test('BRD-07 النموذج: copyWith يحافظ على الهوية ويتيح تحديثها', () {
    final now = DateTime.now();
    final s = Section(
      name: 'بقالة',
      iconKey: 'grocery',
      colorHex: 'green',
      createdAt: now,
      updatedAt: now,
    );
    expect(s.copyWith().iconKey, 'grocery');
    expect(s.copyWith(colorHex: 'pink').colorHex, 'pink');
    // القسم القديم (رمز تعبيري بلا مفتاح) يعمل عبر effectiveIcon.
    final legacy = Section(name: 'قديم', icon: '🛒', createdAt: now, updatedAt: now);
    expect(legacy.iconKey, '');
    expect(legacy.effectiveIcon, '🛒');
    expect(legacy.toMap()['icon_key'], '');
  });

  // ===================== أيقونة ويندوز =====================
  test('WIN-01 ملف الأيقونة موجود بكل المقاسات القياسية', () {
    final ico = File('assets/icons/app_icon.ico');
    expect(ico.existsSync(), isTrue);
    final bytes = ico.readAsBytesSync();
    // ترويسة ICON: 0,0 then type 1 then count.
    expect(bytes[0], 0);
    expect(bytes[1], 0);
    expect(bytes[2], 1);
    final count = bytes[4] | (bytes[5] << 8);
    expect(count, greaterThanOrEqualTo(6));
    // كل المقاسات القياسية موجودة في دليل الأيقونة.
    final sizes = <int>[];
    for (var i = 0; i < count; i++) {
      final off = 6 + i * 16;
      final w = bytes[off] == 0 ? 256 : bytes[off];
      sizes.add(w);
    }
    for (final s in [16, 32, 48, 64, 128, 256]) {
      expect(sizes, contains(s), reason: 'مقاس $s ناقص');
    }
  });

  test('WIN-02 منصة ويندوز تشير إلى الأيقونة وتثبّتها في شريط المهام', () {
    final ico = File('windows/runner/resources/app_icon.ico');
    expect(ico.existsSync(), isTrue);
    expect(ico.readAsBytesSync().length,
        File('assets/icons/app_icon.ico').readAsBytesSync().length);

    final rc = File('windows/runner/Runner.rc').readAsStringSync();
    expect(rc, contains('IDI_APP_ICON'));
    expect(rc, contains('app_icon.ico'));

    final main = File('windows/runner/main.cpp').readAsStringSync();
    expect(main, contains('#include "resource.h"'));
    expect(main, contains('WM_SETICON'));
    expect(main, contains('IDI_APP_ICON'));

    // سكربت الهوية يضمن بقاء الأيقونة بعد إعادة توليد المنصة في CI.
    final ps1 = File('scripts/apply_windows_branding.ps1').readAsStringSync();
    expect(ps1, contains('app_icon.ico'));
    expect(ps1, contains('WM_SETICON'));
  });
}
