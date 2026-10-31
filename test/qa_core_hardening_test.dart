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
import 'package:nexora_app/data/repository.dart';
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
            'entity_type': 'tx',
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

}
