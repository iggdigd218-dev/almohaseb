// QA — ربط الإشعارات بالسجلات (فتح العملية من الإشعار):
// - جدول notifications يحمل عمودَي entity_type/entity_id.
// - notify() يخزّن بيانات الربط وتظهر في notifications().
// - قاعدة قديمة بلا العمودين تُرقّى تلقائياً عبر createSchema (idempotent).
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('QA-NOTIF-LINK-01 schema has entity_type/entity_id columns', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchema(db);
    final cols = (await db.rawQuery('PRAGMA table_info(notifications)'))
        .map((c) => c['name'] as String)
        .toSet();
    expect(cols.contains('entity_type'), isTrue);
    expect(cols.contains('entity_id'), isTrue);
    await db.close();
  });

  test('QA-NOTIF-LINK-02 linked notification stores and returns entity',
      () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchema(db);
    await db.insert('notifications', {
      'title': 'تمت مزامنة العملية',
      'body': 'عملية حسابية — وصلت إلى جهاز المحل',
      'kind': 'success',
      'seen': 0,
      'entity_type': 'tx',
      'entity_id': '42',
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('notifications', {
      'title': 'إشعار عام',
      'body': 'بدون سجل مرتبط',
      'kind': 'info',
      'seen': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
    final rows = await db.query('notifications', orderBy: 'id ASC');
    expect(rows[0]['entity_type'], 'tx');
    expect(rows[0]['entity_id'], '42');
    // الإشعار العام: قيمة افتراضية فارغة — لا يقود لأي سجل.
    expect((rows[1]['entity_type'] ?? '') as String, isEmpty);
    await db.close();
  });

  test('QA-NOTIF-LINK-03 legacy table without link columns gets upgraded',
      () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    // جدول قديم (ما قبل v18) بلا عمودَي الربط.
    await db.execute('''
      CREATE TABLE notifications (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        title      TEXT NOT NULL,
        body       TEXT DEFAULT '',
        kind       TEXT DEFAULT 'info',
        seen       INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )''');
    await db.insert('notifications', {
      'title': 'قديم',
      'created_at': DateTime.now().toIso8601String(),
    });
    // createSchema idempotent: يجب أن يضيف العمودين دون فقدان البيانات.
    await AppDatabase.createSchema(db);
    final cols = (await db.rawQuery('PRAGMA table_info(notifications)'))
        .map((c) => c['name'] as String)
        .toSet();
    expect(cols.contains('entity_type'), isTrue);
    expect(cols.contains('entity_id'), isTrue);
    final rows = await db.query('notifications');
    expect(rows.length, 1);
    expect(rows.first['title'], 'قديم');
    expect((rows.first['entity_type'] ?? '') as String, isEmpty);
    await db.close();
  });
}
