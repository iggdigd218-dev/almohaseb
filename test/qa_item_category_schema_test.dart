// QA — مخطط جدول الفئات على الأجهزة المُرقّاة (إصلاح عاجل 2026-09-24).
//
// العلة: `migrateToV24` (الذي يضيف `section_id`) كان معرّفاً ولا يستدعيه أحد،
// و`migrateToV23` كان يعمل من شبكة الأمان فقط — فقاعدة مُرقّاة لا تمرّ بـ
// onCreate (الجدول موجود أصلاً) تبقى بلا العمودين، وأول إضافة فئة تفشل بـ:
//   DatabaseException(table item_categories has no column named section_id …)
//
// العقد بعد الإصلاح:
//  • الهجرتان تُستدعيان من onUpgrade (from < 23 / from < 24) ورقم المخطط 24.
//  • `ensureFullSchema` (عند كل فتح) يرمّم العمودين ذاتياً بـ ALTER آمن.
//  • الحفظ بـ parent_id/section_id يعمل على قاعدة قديمة بعد الترميم،
//    ويُدرج العملية في sync_queue بلا كسر قيود المزامنة.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// البنية القديمة للجدول كما كانت قبل إضافة parent_id/section_id — أي جهاز
/// مُرقّى من نسخة سابقة يحملها تماماً هكذا.
const _legacyItemCategories = '''
      CREATE TABLE item_categories (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL DEFAULT 'default',
        name         TEXT NOT NULL,
        created_at   TEXT NOT NULL,
        updated_at   TEXT NOT NULL
      )''';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  const backend = 'https://qa-catschema.europe-west1.firebasedatabase.app';

  /// قاعدة بيانات تحاكي جهازاً مُرقّى: كل الجداول حديثة إلا item_categories.
  Future<void> openLegacy({bool heal = true}) async {
    // ناقل سحابي وهمي: بدونه لا تُنشأ صفوف sync_queue أصلاً (3.70 — الحساب
    // الفردي محلي بالكامل)، فلا يمكن التحقق من طابور المزامنة.
    debugDefaultBackendUrlOverride = backend;
    tmp = await Directory.systemTemp.createTemp('nexora_catschema_');
    db = await databaseFactory.openDatabase('${tmp.path}/cat.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    await db.execute('DROP TABLE item_categories');
    await db.execute(_legacyItemCategories);
    if (heal) {
      // ما يحدث فعلياً عند كل فتح للتطبيق (onOpen).
      await AppDatabase.ensureFullSchema(db);
    }
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  }

  Future<List<String>> columns() async {
    final info = await db.rawQuery('PRAGMA table_info(item_categories)');
    return info.map((c) => '${c['name']}').toList();
  }

  tearDown(() async {
    debugDefaultBackendUrlOverride = null;
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('CAT-01 خط الأساس: القاعدة القديمة بلا parent_id ولا section_id',
      () async {
    await openLegacy(heal: false);
    final cols = await columns();
    expect(cols, isNot(contains('parent_id')));
    expect(cols, isNot(contains('section_id')));
  });

  test('CAT-02 إعادة إنتاج العلة: الحفظ بـ section_id يرمي DatabaseException',
      () async {
    await openLegacy(heal: false);
    final now = DateTime.now();
    await expectLater(
      repo.saveItemCategory(ItemCategory(
        name: 'فئة بقسم',
        sectionId: 1,
        createdAt: now,
        updatedAt: now,
      )),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('CAT-03 الترميم عند الفتح يضيف العمودين (parent_id + section_id)',
      () async {
    await openLegacy();
    final cols = await columns();
    expect(cols, contains('parent_id'));
    expect(cols, contains('section_id'));
  });

  test('CAT-04 الترميم idempotent: تكراره بلا خطأ وبلا تكرار أعمدة', () async {
    await openLegacy();
    await AppDatabase.ensureFullSchema(db);
    await AppDatabase.ensureItemCategoryColumns(db);
    final cols = await columns();
    expect(cols.where((c) => c == 'section_id'), hasLength(1));
    expect(cols.where((c) => c == 'parent_id'), hasLength(1));
  });

  test('CAT-05 الهجرتان V23 وV24 تضيفان العمودين صراحةً', () async {
    await openLegacy(heal: false);
    await AppDatabase.migrateToV23(db);
    expect(await columns(), contains('parent_id'));
    await AppDatabase.migrateToV24(db);
    expect(await columns(), contains('section_id'));
  });

  test('CAT-06 حفظ فئة بأب وقسم على قاعدة مُرقّاة: ينجح وتُخزَّن القيم',
      () async {
    await openLegacy();
    final now = DateTime.now();
    final section = await repo.ensureGeneralSection();
    final rootId = await repo.saveItemCategory(ItemCategory(
      name: 'الجذر',
      createdAt: now,
      updatedAt: now,
    ));

    final childId = await repo.saveItemCategory(ItemCategory(
      name: 'فرع',
      parentId: rootId,
      sectionId: section,
      createdAt: now,
      updatedAt: now,
    ));

    final row = await db.query('item_categories',
        where: 'id = ?', whereArgs: [childId], limit: 1);
    expect(row.single['name'], 'فرع');
    expect(row.single['parent_id'], rootId);
    expect(row.single['section_id'], section);

    // سجل العمليات: نوع الكيان itemCategory، والحمولة تحمل الأب والقسم.
    final ops = await db.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: ['itemCategory', '$childId']);
    expect(ops, isNotEmpty, reason: 'يجب أن تُسجَّل العملية في operations');
    expect(ops.first['op_type'], 'create');
    final payload = '${ops.first['payload']}';
    expect(payload, contains('parent_id'));
    expect(payload, contains('section_id'));

    // طابور المزامنة: صف pending لكل عملية (بلا كسر قيود المزامنة).
    final queue = await db.query('sync_queue',
        where: 'operation_id = ?', whereArgs: [ops.first['id']]);
    expect(queue, isNotEmpty, reason: 'يجب أن تُدرج العملية في sync_queue');
    expect(queue.first['status'], 'pending');
  });

  test('CAT-07 قراءة الشجرة والقسم ونقل الفئات عند حذف قسم — بلا استثناء',
      () async {
    await openLegacy();
    final now = DateTime.now();
    final section = await repo.ensureGeneralSection();
    final rootId = await repo.saveItemCategory(
        ItemCategory(name: 'الجذر', createdAt: now, updatedAt: now));
    await repo.saveItemCategory(ItemCategory(
      name: 'فرع',
      parentId: rootId,
      sectionId: section,
      createdAt: now,
      updatedAt: now,
    ));

    final inSection = await repo.itemCategories(sectionId: section);
    expect(inSection.map((c) => c.name), contains('فرع'));

    final tree = await repo.itemCategoryTree();
    expect(tree.map((c) => c.name), contains('الجذر'));

    // حذف قسم: تُعاد فئاته إلى «عام» (يكتب section_id) — كان يفشل قبل الإصلاح.
    await repo.deleteSection(section);
    final cats = await repo.itemCategories();
    expect(cats, isNotEmpty);
  });
}
