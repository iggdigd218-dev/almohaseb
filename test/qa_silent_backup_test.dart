// QA — النسخ السحابي الصامت + عزل المساحة بعد الطرد (المعمارية الصامتة).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/data/sync/auto_backup.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  final now = DateTime(2026, 9, 12);

  setUp(() async {
    debugForceLegacyWorkspaceId = false;
    // بيئة الاختبار معزولة عن الإنتاج — رابط زائف عبر التجاوز الاختباري.
    debugDefaultBackendUrlOverride = 'https://qa-silent.example.com';
    tmp = await Directory.systemTemp.createTemp('nexora_silent_');
    db = await databaseFactory.openDatabase('${tmp.path}/silent.db',
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

  test('SILENT-01 أول تثبيت: مساحة فريدة WS- لا default', () async {
    final ws = repo.requireWorkspaceId;
    expect(ws, isNot('default'));
    expect(RegExp(r'^WS-[A-HJ-KM-NP-Z2-9]{8}$').hasMatch(ws), isTrue,
        reason: 'المعرف يجب أن يكون WS-XXXXXXXX: $ws');
  });

  test('SILENT-02 النسخة الصامتة تُرفع لمسار المساحة وتحدّث الطابع', () async {
    // (2026-09-22) النسخ السحابي عبر حساب جوجل فقط — بريد مربوط.
    await repo.setSetting('account.email', 'boss@nexora.test');
    await repo.saveAccount(Account(
      name: 'عميل صامت',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    final ws = repo.requireWorkspaceId;
    final puts = <String, Object?>{};
    final client = MockClient((req) async {
      if (req.method == 'PUT') {
        puts[req.url.path] = jsonDecode(req.body);
        return http.Response.bytes(utf8.encode(req.body), 200);
      }
      return http.Response.bytes(utf8.encode('null'), 200);
    });
    expect(await AutoBackupService.silentBackupDue(repo), isTrue);
    final ok = await http.runWithClient(
        () => AutoBackupService.silentWorkspaceBackup(repo), () => client);
    expect(ok, isTrue);
    // الرفع تم على مسار المساحة المعزولة.
    final backupPath = puts.keys.firstWhere(
        (p) => p.contains('/workspaces/$ws/backup.json'),
        orElse: () => '');
    expect(backupPath, isNotEmpty,
        reason: 'المسارات المرفوعة: ${puts.keys}');
    final rec = puts[backupPath] as Map;
    expect((rec['payload'] as Map)['data'], isA<Map>());
    // الاستحقاق انطفأ بعد النجاح.
    expect(await AutoBackupService.silentBackupDue(repo), isFalse);
  });

  test('SILENT-03 بعد الطرد: مساحة جديدة معزولة تختلف عن القديمة', () async {
    final before = repo.requireWorkspaceId;
    await repo.resetToStandaloneAfterExpulsion();
    final after = repo.requireWorkspaceId;
    expect(after, isNot(before));
    expect(after, isNot('default'));
    expect(RegExp(r'^WS-[A-HJ-KM-NP-Z2-9]{8}$').hasMatch(after), isTrue);
    // القاعدة تحمل المساحة الجديدة وحدها.
    final rows = await db.query('workspaces');
    expect(rows.length, 1);
    expect(rows.first['id'], after);
  });

  test('SILENT-04 (2026-09-22) بوابة جوجل: لا نسخة سحابية بلا بريد، '
      'وجهاز العضو لا ينسخ إطلاقاً', () async {
    final puts = <String>[];
    final client = MockClient((req) async {
      if (req.method == 'PUT') puts.add(req.url.path);
      return http.Response.bytes(utf8.encode('null'), 200);
    });
    // 1) بلا حساب جوجل: لا تُكتب أي نسخة.
    await repo.setSetting('account.email', '');
    final noGoogle = await http.runWithClient(
        () => AutoBackupService.silentWorkspaceBackup(repo), () => client);
    expect(noGoogle, isFalse);
    expect(puts, isEmpty, reason: 'لا رفع سحابي دون حساب جوجل');
    // 2) جهاز عضو (تحت مظلة المؤسسة): لا ينسخ ولو ببريد مربوط.
    await repo.setSetting('account.email', 'member@nexora.test');
    await db.insert(
        'sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final asMember = await http.runWithClient(
        () => AutoBackupService.silentWorkspaceBackup(repo), () => client);
    expect(asMember, isFalse);
    expect(puts, isEmpty, reason: 'نسخة المجموعة يكتبها جهاز المدير وحده');
  });
}
