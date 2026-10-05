// QA — فهرس الأجهزة + قاعدة «جوجل فقط» (2026-09-22).
//
// device_index: بصمة الجهاز ← {workspaceId, role}. العقود:
//  - lookup يقرأ السجل؛ upsertBinding يسجل owner للمستقل (ببريد جوجل).
//  - سجل owner قائم لا يُخفَّض ولا تُبدَّل مساحته إلا بـ force (تنازل صريح).
//  - bindAsMember لا يسجل مدير مؤسسة أخرى عضواً في مجموعة غريبة.
//  - حُذف الاسترداد الصامت ببصمة العتاد: الاسترجاع عبر جوجل فقط —
//    ودور المدير يلتئم ذاتياً (حساب مؤسسة + جهاز مالك ⇒ host).
//  - العضو المطرود (عضويته السحابية منتهية) لا يمنعه وضعه المحلي
//    `member` من قبول دعوة جديدة.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/cloud_config.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/device_registry.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;
  const url = 'https://qa-registry.europe-west1.firebasedatabase.app';

  setUp(() async {
    debugForceLegacyWorkspaceId = false;
    debugDefaultBackendUrlOverride = url;
    tmp = await Directory.systemTemp.createTemp('nexora_registry_');
    db = await databaseFactory.openDatabase('${tmp.path}/reg.db',
        options: OpenDatabaseOptions(
            onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
    // (3.71.0) ربط المالك السحابي مشروط بالتسجيل بالبريد — العقد الجديد.
    await repo.setSetting('account.email', 'boss@firm.test');
  });

  tearDown(() async {
    debugDefaultBackendUrlOverride = null;
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  MockClient fakeCloud(Map<String, Object?> store,
      {List<String>? putLog}) =>
      MockClient((req) async {
        final p = req.url.path;
        if (req.method == 'PUT') {
          store[p] = jsonDecode(req.body);
          putLog?.add(p);
          return http.Response.bytes(utf8.encode(req.body), 200);
        }
        if (req.method == 'DELETE') {
          store.remove(p);
          return http.Response.bytes(utf8.encode('null'), 200);
        }
        return http.Response.bytes(
            utf8.encode(jsonEncode(store[p])), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });

  test('REG-01 upsertBinding يسجل المستقل مالكاً لمساحته', () async {
    final store = <String, Object?>{};
    await http.runWithClient(
        () => DeviceRegistry.upsertBinding(repo, backendUrl: url),
        () => fakeCloud(store));
    final fp = await DeviceRegistry.fingerprintKey(repo);
    final rec = store['/workspaces/_registry/device_index/$fp.json'] as Map?;
    expect(rec, isNotNull);
    expect(rec!['workspaceId'], repo.requireWorkspaceId);
    expect(rec['role'], 'owner');
  });

  test('REG-01b (3.71.0) هوية بلا بريد مسجل لا تُربط مالكة في السحابة',
      () async {
    await repo.setSetting('account.email', '');
    final store = <String, Object?>{};
    await http.runWithClient(
        () => DeviceRegistry.upsertBinding(repo, backendUrl: url),
        () => fakeCloud(store));
    final fp = await DeviceRegistry.fingerprintKey(repo);
    expect(store['/workspaces/_registry/device_index/$fp.json'], isNull);
  });

  test('REG-02 سجل owner قائم لا يُخفَّض لمساحة أخرى بلا force', () async {
    final fp = await DeviceRegistry.fingerprintKey(repo);
    final store = <String, Object?>{
      '/workspaces/_registry/device_index/$fp.json': {
        'workspaceId': 'WS-OLDFIRM1',
        'role': 'owner',
        'device_id': 'OLD-DEV',
      },
    };
    // بلا force: الربط الحالي (مساحة مختلفة) يُرفض — السجل القديم يبقى.
    await http.runWithClient(
        () => DeviceRegistry.upsertBinding(repo, backendUrl: url),
        () => fakeCloud(store));
    var rec = store['/workspaces/_registry/device_index/$fp.json'] as Map;
    expect(rec['workspaceId'], 'WS-OLDFIRM1');
    // بـ force (تنازل صريح): يُحدَّث.
    await http.runWithClient(
        () => DeviceRegistry.upsertBinding(repo,
            backendUrl: url, force: true),
        () => fakeCloud(store));
    rec = store['/workspaces/_registry/device_index/$fp.json'] as Map;
    expect(rec['workspaceId'], repo.requireWorkspaceId);
  });

  test('REG-03 مدير مؤسسة أخرى لا يُسجَّل عضواً في مجموعة غريبة', () async {
    final fp = await DeviceRegistry.fingerprintKey(repo);
    final store = <String, Object?>{
      '/workspaces/_registry/device_index/$fp.json': {
        'workspaceId': 'WS-OLDFIRM1',
        'role': 'owner',
        'device_id': 'OLD-DEV',
      },
    };
    await http.runWithClient(
        () => DeviceRegistry.bindAsMember(repo,
            backendUrl: url, workspaceId: 'WS-OTHERGRP'),
        () => fakeCloud(store));
    final rec = store['/workspaces/_registry/device_index/$fp.json'] as Map;
    expect(rec['role'], 'owner', reason: 'حق المدير في مؤسسته محفوظ');
    expect(rec['workspaceId'], 'WS-OLDFIRM1');
  });

  test('REG-04 (2026-09-22) التئام ذاتي: حساب مؤسسة + جهاز مالك ⇒ host',
      () async {
    // تثبيت نظيف: الوضع standalone حتى مع بريد جوجل مربوط.
    expect(await repo.workspaceMode(), 'standalone');
    // الاسترجاع بجوجل يثبّت هوية المؤسسة — الدور يلتئم ذاتياً لأن
    // sync_meta ليس ضمن جداول النسخة الاحتياطية.
    await repo.setSetting('account.type', 'enterprise');
    expect(await repo.workspaceMode(), 'host',
        reason: 'جهاز المالك بحساب مؤسسة يجب أن يعود host تلقائياً');
    // الحساب الفردي لا يتحول host.
    await db.update('sync_meta', {'value': 'standalone'},
        where: "key = 'workspaceMode'");
    await repo.setSetting('account.type', 'individual');
    expect(await repo.workspaceMode(), 'standalone');
    // الطرد يصفّي الهوية: الجهاز المطرود لا يلتئم host أبداً.
    await repo.setSetting('account.type', 'enterprise');
    await repo.resetToStandaloneAfterExpulsion();
    expect(await repo.workspaceMode(), 'standalone');
    expect((await repo.settings())['account.type'] ?? '', isEmpty);
  });

  test('REG-05 (2026-09-22) المطرود لا يمنعه وضع member المحلي من دعوة جديدة',
      () async {
    final devId = repo.requireDeviceId;
    await repo.setSetting('sync.deviceId', devId);
    await db.insert(
        'sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    final curWs = repo.requireWorkspaceId;
    // سحابة بلا سجل roster للجهاز — طُرد (removePeerFromCloud حذف سجله).
    final store = <String, Object?>{};
    await expectLater(
      http.runWithClient(
          () => CloudJoin.requestJoin(repo,
              backendUrl: url,
              tokenOrPin: 'TOK-EXPIRED1',
              deviceName: 'جهاز حمود',
              workspaceId: curWs),
          () => fakeCloud(store)),
      throwsA(predicate((e) => '$e'.contains('رمز الاقتران'))),
      reason: 'تجاوز فحص العضوية المنتهية ووصل لمطابقة الدعوة',
    );
    // الوضع المحلي صُفّي أثناء المرور.
    expect(await repo.workspaceMode(), 'standalone');

    // عضو فعّال (سجله قائم بلا طرد) يحاول مجموعة أخرى ⇒ يبقى الرفض.
    await db.insert(
        'sync_meta', {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    store['/workspaces/$curWs/roster/$devId.json'] = {'device_id': devId};
    await expectLater(
      http.runWithClient(
          () => CloudJoin.requestJoin(repo,
              backendUrl: url,
              tokenOrPin: 'TOK-EXPIRED1',
              deviceName: 'جهاز حمود',
              workspaceId: 'WS-OTHERGRP'),
          () => fakeCloud(store)),
      throwsA(isA<CloudJoinException>()),
      reason: 'العضو الفعّال يُمنع من الانضمام لمجموعة أخرى',
    );
  });
}
