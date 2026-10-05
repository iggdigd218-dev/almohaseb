// QA — تدقيق 2026-09-24: نزاهة البيانات بعد الت hardening.
//
// يغطّي سلوكيات جديدة/مصحَّحة:
//   HRD-01 فرادة اسم القسم داخل مساحة العمل (لا عالمياً).
//   HRD-02 الرصيد السالب مرفوض افتراضياً في كل حركات المخزون.
//   HRD-03 الرصيد السالب مسموح بتفعيل الإعداد صراحةً.
//   HRD-04 نقل فئة إلى قسم جديد ⇒ أصنافها تتبعها.
//   HRD-05 قسم الصنف يُصحَّح ليطابق قسم فئته.
//   HRD-06 تنظيف سجل operations في النمط الفردي (يُبقي أحدث عملية لكل كيان).
//   HRD-07 قسم يتيم ⇒ section_id يُفرغ بدل كسر قيد المفتاح الأجنبي.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  const backend = 'https://qa-hardening.europe-west1.firebasedatabase.app';

  setUp(() async {
    debugDefaultBackendUrlOverride = backend;
    tmp = await Directory.systemTemp.createTemp('nexora_hard_');
    db = await databaseFactory.openDatabase('${tmp.path}/hard.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  });

  tearDown(() async {
    debugDefaultBackendUrlOverride = null;
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Item mkItem(String name, {int? categoryId, int? sectionId, double qty = 10}) =>
      Item(
        name: name,
        categoryId: categoryId,
        sectionId: sectionId,
        sku: 'SKU-${name.hashCode.abs()}',
        unit: 'حبة',
        quantity: qty,
        sellPrice: 100,
        buyPrice: 50,
        minQuantity: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  test('HRD-01 فرادة اسم القسم داخل مساحة العمل', () async {
    final now = DateTime.now();
    await repo.saveSection(Section(
        name: 'إلكترونيات', createdAt: now, updatedAt: now));
    await expectLater(
      repo.saveSection(
          Section(name: 'إلكترونيات', createdAt: now, updatedAt: now)),
      throwsStateError,
    );
    // اسم آخر مسموح في المساحة نفسها.
    final id2 = await repo.saveSection(
        Section(name: 'مواد غذائية', createdAt: now, updatedAt: now));
    expect(id2, greaterThan(0));
  });

  test('HRD-02 الرصيد السالب مرفوض افتراضياً (أي حركة)', () async {
    final itemId = await repo.saveItem(mkItem('صنف', qty: 5));
    await expectLater(
      repo.addStockMove(StockMove(
        itemId: itemId,
        quantity: 8,
        kind: StockKind.sale,
        date: DateTime.now(),
        createdAt: DateTime.now(),
      )),
      throwsA(isA<StateError>()),
    );
    // تسوية إلى رصيد سالب مرفوضة أيضاً.
    await expectLater(
      repo.addStockMove(StockMove(
        itemId: itemId,
        quantity: -1,
        kind: StockKind.adjust,
        date: DateTime.now(),
        createdAt: DateTime.now(),
      )),
      throwsA(isA<StateError>()),
    );
  });

  test('HRD-03 الرصيد السالب مسموح بتفعيل الإعداد صراحةً', () async {
    await repo.setSetting('allowNegativeStock', '1');
    final itemId = await repo.saveItem(mkItem('صنف', qty: 5));
    final id = await repo.addStockMove(StockMove(
      itemId: itemId,
      quantity: 8,
      kind: StockKind.sale,
      date: DateTime.now(),
      createdAt: DateTime.now(),
    ));
    expect(id, greaterThan(0));
    final it = await repo.item(itemId);
    expect(it!.quantity, lessThan(0));
  });

  test('HRD-04 نقل الفئة إلى قسم جديد ⇒ أصنافها تتبعها', () async {
    final now = DateTime.now();
    final secA = await repo.saveSection(
        Section(name: 'قسم أ', createdAt: now, updatedAt: now));
    final secB = await repo.saveSection(
        Section(name: 'قسم ب', createdAt: now, updatedAt: now));
    final catId = await repo.saveItemCategory(ItemCategory(
        name: 'فئة', sectionId: secA, createdAt: now, updatedAt: now));
    final itemId = await repo.saveItem(mkItem('صنف', categoryId: catId));

    var it = await repo.item(itemId);
    expect(it!.sectionId, secA, reason: 'الصنف يستمدّ قسمه من فئته');

    await repo.saveItemCategory(ItemCategory(
        id: catId,
        name: 'فئة',
        sectionId: secB,
        createdAt: now,
        updatedAt: now,
    ));
    it = await repo.item(itemId);
    expect(it!.sectionId, secB,
        reason: 'نقل الفئة لقسم جديد يجب أن ينقل أصنافها معها');
  });

  test('HRD-05 قسم الصنف يُصحَّح ليطابق قسم فئته', () async {
    final now = DateTime.now();
    final secA = await repo.saveSection(
        Section(name: 'قسم أ', createdAt: now, updatedAt: now));
    final secB = await repo.saveSection(
        Section(name: 'قسم ب', createdAt: now, updatedAt: now));
    final catId = await repo.saveItemCategory(ItemCategory(
        name: 'فئة', sectionId: secA, createdAt: now, updatedAt: now));
    // صنف بقسم يخالف قسم فئته ⇒ الفئة هي المرجع.
    final itemId =
        await repo.saveItem(mkItem('صنف', categoryId: catId, sectionId: secB));
    final it = await repo.item(itemId);
    expect(it!.sectionId, secA);
  });

  test('HRD-06 تنظيف operations في النمط الفردي يُبقي الأحدث لكل كيان',
      () async {
    await repo.setSetting('account.type', 'individual');
    final old = DateTime.now()
        .subtract(const Duration(days: 200))
        .toIso8601String();
    final recent = DateTime.now().toIso8601String();
    Future<void> op(String id, String entityId, String ts) => db.insert(
          'operations',
          {
            'id': id,
            'device_id': 'd1',
            'workspace_id': 'default',
            'entity_type': 'item',
            'entity_id': entityId,
            'op_type': 'update',
            'version': 1,
            'parent_op_id': '',
            'payload': '{}',
            'device_time': ts,
            'timestamp': ts,
            'synced': 0,
          },
        );

    await op('op-old-1', '1', old);
    await op('op-old-2', '1', old); // قديم لكنه أحدث سجل للكيان 1
    await op('op-old-3', '2', old);
    await op('op-new-1', '2', recent); // الأحدث للكيان 2
    final before = await db.query('operations');
    expect(before.length, 4);

    final deleted = await repo.pruneIndividualOperations();
    // op-old-1 يُحذف (قديم وله أحدث منه)، وop-old-3 كذلك؛
    // op-old-2 و op-new-1 يبقيان (أحدث سجل لكل كيان).
    expect(deleted, 2);
    final after = await db.query('operations', columns: ['id']);
    final ids = after.map((r) => r['id']).toSet();
    expect(ids, {'op-old-2', 'op-new-1'});
  });

  test('HRD-07 قسم يتيم ⇒ section_id يُفرغ بدل كسر القيد', () async {
    final row = <String, Object?>{'name': 'فئة يتيمة', 'section_id': 9999};
    await db.transaction((txn) async {
      await nullDanglingSection(txn, 'item_categories', row);
    });
    expect(row['section_id'], isNull,
        reason: 'مرجع لقسم غير موجود يجب أن يُفرغ (لا أن يُسقط المزامنة)');

    // قسم موجود ⇒ المرجع يُحفظ كما هو.
    final now = DateTime.now();
    final secId = await repo.saveSection(
        Section(name: 'موجود', createdAt: now, updatedAt: now));
    final keep = <String, Object?>{'name': 'فئة', 'section_id': secId};
    await db.transaction((txn) async {
      await nullDanglingSection(txn, 'item_categories', keep);
    });
    expect(keep['section_id'], secId);
  });
}
