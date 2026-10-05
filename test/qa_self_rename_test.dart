// اختبار: المستخدم يعيد تسمية جهازه بنفسه بلا صلاحيات، والاسم يثبت.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_rename_');
    db = await databaseFactory.openDatabase('${tmp.path}/qa.db',
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ));
    await AppDatabase.createSchema(db);
    AppDatabase.overrideForTest(db);
    repo = Repo();
    await repo.initSyncInfra(); // يسجل الجهاز ذاتياً.
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
    await tmp.delete(recursive: true);
  });

  test('renameSelfDevice يحدّث devices وsettings معاً', () async {
    await repo.renameSelfDevice('أحمد — فرع الجملة');
    final id = repo.requireDeviceId;
    final d = await db.query('devices', where: 'id = ?', whereArgs: [id]);
    expect(d.single['name'], 'أحمد — فرع الجملة');
    final st = await repo.settings();
    expect(st['sync.deviceName'], 'أحمد — فرع الجملة',
        reason: 'يُحفظ في الإعدادات ليبقى بعد إعادة التسجيل الذاتي');
  });

  test('اسم فارغ يُتجاهل ولا يمسح الاسم القائم', () async {
    await repo.renameSelfDevice('اسمي الأول');
    await repo.renameSelfDevice('   ');
    final id = repo.requireDeviceId;
    final d = await db.query('devices', where: 'id = ?', whereArgs: [id]);
    expect(d.single['name'], 'اسمي الأول');
  });
}
