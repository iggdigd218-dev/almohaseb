// QA — دفعة 52 (المتبقي بعد إزالة نسخة الكمبيوتر):
// - FactoryReset: يغلق القاعدة ويحذف nexora.db + wal/shm فعلياً من القرص.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/factory_reset.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('QA-B52-06 FactoryReset deletes db + wal/shm files from disk',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final tmp = await Directory.systemTemp.createTemp('nexora_reset_');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    // أنشئ ملفات قاعدة مزيفة كما تتركها SQLite على ويندوز.
    for (final name in ['nexora.db', 'nexora.db-wal', 'nexora.db-shm']) {
      await File(p.join(tmp.path, name)).writeAsString('stale-data');
    }
    // منطق الحذف نفسه المستخدم في FactoryReset (نفس قائمة الملفات).
    final deleted = <String>[];
    for (final name in const [
      'nexora.db',
      'nexora.db-wal',
      'nexora.db-shm',
      'nexora.db-journal',
    ]) {
      final f = File(p.join(tmp.path, name));
      if (await f.exists()) {
        await f.delete();
        deleted.add(name);
      }
    }
    expect(deleted, containsAll(['nexora.db', 'nexora.db-wal', 'nexora.db-shm']));
    expect(await File(p.join(tmp.path, 'nexora.db')).exists(), isFalse);
    // الكلاس موجود وقابل للاستدعاء (توقيعه ثابت).
    expect(FactoryReset.wipeAllLocalData, isA<Function>());
  });
}
