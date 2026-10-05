// QA — (2026-09-22) شجرة فئات الأصناف + نموذج الفئة
//  TREE : فئة رئيسية ← فئات فرعية (parent_id) مع استعلام جذور/أبناء.
//  MODEL: ItemCategory يحمل parentId والأبناء، ويُدار بلا فقدان بيانات.
//  DEL  : حذف فئة رئيسية يُرقّي أبناءها للجذر بدل محوهم.
//  SYNC : تعديل الفئة يُسجَّل عبر SyncRecorder بـ EntityKind.itemCategory.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Repo repo;
  setUp(() async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    await AppDatabase.migrateToV23(db);
    await AppDatabase.migrateToV24(db); // عمود parent_id + فهرسه
    // القاعدة في الذاكرة تُشارَك بين الاختبارات في العملية نفسها — نبدأ
    // كل اختبار من صفحة بيضاء لئلا تتسرب بيانات اختبار إلى آخر.
    await db.delete('item_categories');
    await db.delete('items');
    await db.delete('operations');
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  });

  ItemCategory cat(String name, {int? parentId}) => ItemCategory(
        name: name,
        parentId: parentId,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  test('TREE-01 عمود parent_id موجود ومُفهرس بعد الترقية', () async {
    final db = await repo.database;
    final cols = await db.rawQuery('PRAGMA table_info(item_categories)');
    final names = cols.map((c) => '${c['name']}').toSet();
    expect(names.contains('parent_id'), isTrue);
    final idx = await db.rawQuery("PRAGMA index_list('item_categories')");
    expect(
      idx.map((r) => '${r['name']}').toSet().contains('idx_item_cat_parent'),
      isTrue,
    );
  });

  test('TREE-02 الشجرة: جذور وأبناء، والجذر بلا أب', () async {
    final rootId = await repo.saveItemCategory(cat('مواد غذائية'));
    final subId = await repo.saveItemCategory(cat('ألبان', parentId: rootId));
    await repo.saveItemCategory(cat('معلبات', parentId: rootId));
    await repo.saveItemCategory(cat('أجهزة')); // جذر ثانٍ

    final roots = await repo.itemCategories(rootsOnly: true);
    expect(roots.map((c) => c.name).toList(), contains('مواد غذائية'));
    expect(roots.any((c) => c.name == 'ألبان'), isFalse,
        reason: 'الابن ليس جذراً');

    final children = await repo.itemCategories(parentId: rootId);
    expect(children.map((c) => c.name).toSet(), {'ألبان', 'معلبات'});
    expect(children.first.parentId, rootId);

    final tree = await repo.itemCategoryTree();
    final food = tree.firstWhere((c) => c.id == rootId);
    expect(food.children.length, 2, reason: 'الأبناء مُجمَّعون في الشجرة');
    expect(tree.any((c) => c.name == 'ألبان'), isFalse);
    expect(subId, isNotNull);
  });

  test('TREE-03 الفئة القديمة بلا أب تُعدّ جذراً (لا فقدان بيانات)', () async {
    final id = await repo.saveItemCategory(cat('قديمة'));
    final all = await repo.itemCategories();
    final c = all.firstWhere((e) => e.id == id);
    expect(c.parentId, isNull);
    expect(c.isRoot, isTrue);
    expect((await repo.itemCategories(rootsOnly: true)).length,
        all.length,
        reason: 'كل الفئات القديمة جذور');
  });

  test('TREE-04 منع الدوران: الفئة لا تكون أباً لنفسها ولا لفرعها', () async {
    final a = await repo.saveItemCategory(cat('أ'));
    final b = await repo.saveItemCategory(cat('ب', parentId: a));

    final all = await repo.itemCategories();
    final catA = all.firstWhere((c) => c.id == a);
    expect(
      () => repo.saveItemCategory(catA.copyWith(parentId: a)),
      throwsA(isA<StateError>()),
      reason: 'الفئة لا تكون أباً لنفسها',
    );
    expect(
      () => repo.saveItemCategory(catA.copyWith(parentId: b)),
      throwsA(isA<StateError>()),
      reason: 'الأب لا يصبح فرعاً لابنه',
    );
  });

  test('TREE-05 حذف فئة رئيسية يُرقّي أبناءها للجذر', () async {
    final rootId = await repo.saveItemCategory(cat('رئيسية'));
    final subId = await repo.saveItemCategory(cat('فرعية', parentId: rootId));
    await repo.deleteItemCategory(rootId);

    final sub = (await repo.itemCategories()).firstWhere((c) => c.id == subId);
    expect(sub.parentId, isNull, reason: 'الابن بقي ولم يُمحَ (صار جذراً)');
    expect(await repo.itemCategories(rootsOnly: true), isNotEmpty);
  });

  test('TREE-06 تعديل الفئة يُسجَّل للمزامنة بـ EntityKind.itemCategory',
      () async {
    final id = await repo.saveItemCategory(cat('فئة للمزامنة'));
    final db = await repo.database;
    final ops = await db.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: ['itemCategory', '$id']);
    expect(ops, isNotEmpty, reason: 'عملية إنشاء مسجلة عبر SyncRecorder');

    await repo.saveItemCategory(
      (await repo.itemCategories())
          .firstWhere((c) => c.id == id)
          .copyWith(name: 'فئة معدّلة'),
    );
    final after = await db.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: ['itemCategory', '$id']);
    expect(after.length, greaterThan(ops.length),
        reason: 'عملية تعديل ثانية مسجلة');
  });

  test('TREE-07 النموذج: parentId يكتمل في toMap/fromMap', () {
    final now = DateTime.now();
    final c = ItemCategory(
        id: 5, name: 'ابن', parentId: 2, createdAt: now, updatedAt: now);
    final map = c.toMap();
    expect(map['parent_id'], 2);
    final back = ItemCategory.fromMap(map);
    expect(back.parentId, 2);
    expect(back.name, 'ابن');
    // clearParentId يعيدها جذراً
    expect(c.copyWith(clearParentId: true).parentId, isNull);
  });

  // ════════════════════════════════════════════════════════════════════════
  // (2026-09-22) الأقسام: قسم ← فئة ← صنف
  // ════════════════════════════════════════════════════════════════════════

  Section sec(String name) => Section(
        name: name,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  ItemCategory catOf(String name, {int? sectionId}) => ItemCategory(
        name: name,
        sectionId: sectionId,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  test('SECT-01 إنشاء الأقسام وفلترة الفئات بها', () async {
    final electronics = await repo.saveSection(sec('إلكترونيات'));
    final food = await repo.saveSection(sec('مواد غذائية'));
    final c1 = await repo.saveItemCategory(catOf('هواتف', sectionId: electronics));
    await repo.saveItemCategory(catOf('تمور', sectionId: food));
    await repo.saveItemCategory(catOf('متنوع')); // بلا قسم ⇒ «عام»

    final all = await repo.sections();
    expect(all.map((e) => e.name).toSet(),
        {'إلكترونيات', 'مواد غذائية'},
        reason: 'قسم «عام» لا يُنشأ تلقائياً بل عند الحاجة');

    expect(await repo.itemCategories(sectionId: electronics),
        everyElement((c) => c.sectionId == electronics || c.sectionId == null),
        reason: 'الفئات بلا قسم تظهر ضمن أي قسم «كعام»');
    expect(
      (await repo.itemCategories(sectionId: electronics))
          .map((c) => c.name)
          .toSet(),
      contains('هواتف'),
    );
    final general = await repo.itemCategories(sectionId: kGeneralSectionId);
    expect(general.any((c) => c.id == c1), isFalse,
        reason: 'الفئة المقيّدة بقسم لا تظهر في «عام»');
  });

  test('SECT-02 حذف قسم يحذف كافة فئاته التابعة تلقائياً', () async {
    final id = await repo.saveSection(sec('قسم مؤقت'));
    final catId = await repo.saveItemCategory(catOf('فئة تتبع القسم', sectionId: id));
    await repo.deleteSection(id);

    final cats = await repo.itemCategories();
    expect(cats.any((e) => e.id == catId), isFalse,
        reason: 'الفئة التابعة للقسم حُذفت تلقائياً');
    expect((await repo.sections()).any((s) => s.id == id), isFalse);
  });

  test('SECT-03 الصنف يرث قسم فئته تلقائياً', () async {
    final sId = await repo.saveSection(sec('ملابس'));
    final cId = await repo.saveItemCategory(catOf('قمصان', sectionId: sId));
    final now = DateTime.now();
    final itemId = await repo.saveItem(Item(
      name: 'قميص قطني',
      categoryId: cId,
      category: 'قمصان',
      buyPrice: 100,
      sellPrice: 150,
      quantity: 5,
      createdAt: now,
      updatedAt: now,
    ));
    final items = await repo.items();
    final saved = items.firstWhere((i) => i.id == itemId);
    expect(saved.sectionId, sId,
        reason: 'القسم مستمد من الفئة بلا تدخل المستخدم');
  });

  test('SECT-04 حركات الأقسام مسجلة في طابور المزامنة', () async {
    final id = await repo.saveSection(sec('خدمات'));
    final db = await repo.database;
    final ops = await db.query('operations',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: ['section', '$id']);
    expect(ops, isNotEmpty,
        reason: 'إنشاء القسم مسجل بـ EntityKind.section للمزامنة');
  });

  test('SECT-05 كيان من إصدار أحدث لا يُكتب في جدول خاطئ', () async {
    // النوع غير المعروف يعود unknown، والتطبيق يتجاهله (لا يسقط على tx).
    expect(EntityKind.from('section').name, 'section');
    expect(EntityKind.from('كيان_مستقبلي'), EntityKind.unknown,
        reason: 'أمان الإصدارات المختلطة');
  });

  test('SECT-06 إعادة إنشاء قسم تم حذفه سابقاً بنفس الاسم تنجح وتنشطه دون خطأ تكرار', () async {
    // 1. إنشاء قسم «الكترونيات»
    final id1 = await repo.saveSection(sec('الكترونيات'));
    final initialList = await repo.sections();
    expect(initialList.any((s) => s.name == 'الكترونيات'), isTrue);

    // 2. حذف القسم (حذف ناعم)
    await repo.deleteSection(id1);
    final afterDelete = await repo.sections();
    expect(afterDelete.any((s) => s.name == 'الكترونيات'), isFalse);

    // 3. محاولة إعادة إنشاء قسم جديد بنفس الاسم «الكترونيات» يجب ألا ترمي خطأ تكرار
    final id2 = await repo.saveSection(sec('الكترونيات'));
    expect(id2 > 0, isTrue);
    final finalSections = await repo.sections();
    expect(finalSections.any((s) => s.name == 'الكترونيات'), isTrue);
    expect(finalSections.where((s) => s.name == 'الكترونيات').length, 1);
  });
}
