// QA — الربط الحتمي بمساحة العمل (3.71.0).
//
// قبل الإصلاح كان «أول صف بلا ترتيب» يسمح لمساحة شخصية ميتة بتظليل
// مساحة المجموعة على جهاز العضو: النقل السحابي ومراقب الطلبات يرتبطان
// بمسار خاطئ فتموت المزامنة بصمت ويضل طلب المغادرة فلا يصل المدير.
// العقود:
//  - الربط الصريح في الإعدادات (sync.workspaceId) يفوز إن كان صفه موجوداً.
//  - بلا ربط صريح: أحدث صف مُدرج يفوز (rowid DESC).
//  - ربط يشير لصف غير موجود لا يخطف الاختيار.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() async {
    debugForceLegacyWorkspaceId = false;
    tmp = await Directory.systemTemp.createTemp('nexora_wsdet_');
    db = await databaseFactory.openDatabase('${tmp.path}/wsdet.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
    // بداية نظيفة: لا صفوف ولا ربط صريح من التهيئة.
    await db.delete('workspaces');
    await repo.setSetting('sync.workspaceId', '');
  });

  tearDown(() async {
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> insertWs(String id) async {
    final now = DateTime.now().toIso8601String();
    await db.insert('workspaces', {
      'id': id,
      'name': id,
      'created_at': now,
      'updated_at': now,
    });
  }

  test('WSDET-01 الربط الصريح يفوز على الصفوف الأقدم', () async {
    await insertWs('WS-PERSONAL1'); // مساحة شخصية ميتة — أُدرجت أولاً.
    await insertWs('WS-GROUPAAA1'); // مساحة المجموعة — الأحدث.
    await repo.setSetting('sync.workspaceId', 'WS-GROUPAAA1');
    expect(await ensureWorkspace(db, repo: repo), 'WS-GROUPAAA1');
  });

  test('WSDET-02 بلا ربط صريح: أحدث صف يفوز (rowid DESC)', () async {
    await insertWs('WS-PERSONAL1');
    await insertWs('WS-GROUPAAA1');
    expect(await ensureWorkspace(db, repo: repo), 'WS-GROUPAAA1');
  });

  test('WSDET-03 ربط يشير لصف غير موجود لا يخطف الاختيار', () async {
    await insertWs('WS-PERSONAL1');
    await insertWs('WS-GROUPAAA1');
    await repo.setSetting('sync.workspaceId', 'WS-GHOST0000');
    expect(await ensureWorkspace(db, repo: repo), 'WS-GROUPAAA1');
  });
}
