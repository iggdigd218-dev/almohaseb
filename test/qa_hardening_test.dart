// QA: دفعة التحصين (توحيد الهوية، workspaceMode، تقليم الحمولات،
// ترقيم الفواتير بالبادئة، تجزئة كلمات المرور المملّحة).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/security.dart';
import 'package:nexora_app/core/workspace_mode.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/device_id.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final now = DateTime(2026, 9, 9);

  group('WorkspaceMode normalization', () {
    test('QA-WM-01 parse normalizes legacy managed to host', () {
      expect(WorkspaceMode.parse('managed'), WorkspaceMode.host);
      expect(WorkspaceMode.parse('host'), WorkspaceMode.host);
      expect(WorkspaceMode.parse('member'), WorkspaceMode.member);
      expect(WorkspaceMode.parse(''), WorkspaceMode.standalone);
      expect(WorkspaceMode.parse(null), WorkspaceMode.standalone);
      expect(WorkspaceMode.parse('garbage'), WorkspaceMode.standalone);
    });

    test('QA-WM-02 repo.workspaceMode never returns managed', () async {
      final tmp = await Directory.systemTemp.createTemp('nexora_wm_');
      final db = await databaseFactory.openDatabase('${tmp.path}/wm.db');
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra();
      await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'managed'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      expect(await repo.workspaceMode(), 'host');
      expect((await repo.workspaceModeEnum()).isHost, isTrue);
      await db.close();
      await tmp.delete(recursive: true);
    });
  });

  group('توحيد الهوية', () {
    test('QA-ID-01 default device name is «مستخدم جديد»', () async {
      final tmp = await Directory.systemTemp.createTemp('nexora_id_');
      final db = await databaseFactory.openDatabase('${tmp.path}/id.db');
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra();
      expect(await deviceName(repo), kDefaultMemberName);
      await setDeviceName(repo, 'جهاز المحل');
      expect(await deviceName(repo), 'جهاز المحل');
      await db.close();
      await tmp.delete(recursive: true);
    });
  });

  group('تقليم حمولات العمليات', () {
    test('QA-PRUNE-01 incoming chat media op is stored without file_b64',
        () async {
      final tmp = await Directory.systemTemp.createTemp('nexora_prune_');
      final db = await databaseFactory.openDatabase('${tmp.path}/p.db');
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEVICE-PRUNETST1');
      await repo.initSyncInfra();
      final fatB64 = base64Encode(List<int>.filled(4096, 65));
      final op = SyncOperation(
        id: 'OP-PRUNE-1',
        deviceId: 'DEVICE-REMOTE001',
        workspaceId: 'default',
        userId: null,
        entityType: EntityKind.message,
        entityId: '900001',
        opType: OpKind.create,
        version: 1,
        parentOpId: '',
        payload: {
          'conversation_id': 700001,
          'conv_title': 'مجموعة',
          'sender_device_id': 'DEVICE-REMOTE001',
          'body': '',
          'kind': 'image',
          'file_b64': fatB64,
          'file_name': 'pic.jpg',
          'created_at': now.toIso8601String(),
        },
        deviceTime: now.toIso8601String(),
        timestamp: now.toIso8601String(),
      );
      // path_provider غير متاح في اختبار VM — فشل حفظ الملف مقبول،
      // المهم أن العملية المخزنة لا تحمل base64.
      await db.transaction((txn) async {
        await repo.applyRemoteOperation(txn, op, ConflictResolver());
      });
      final stored = await db.query('operations',
          where: 'id = ?', whereArgs: ['OP-PRUNE-1']);
      expect(stored, hasLength(1));
      final payload = '${stored.first['payload']}';
      expect(payload.contains('file_b64'), isFalse,
          reason: 'حمولة base64 يجب أن تُجرَّد من جدول العمليات');
      expect(payload.contains('file_pruned'), isTrue);
      await db.close();
      await tmp.delete(recursive: true);
    });
  });

  group('ترقيم الفواتير بالبادئة', () {
    test('QA-INV-01 standalone stays pure numeric', () async {
      final tmp = await Directory.systemTemp.createTemp('nexora_inv_');
      final db = await databaseFactory.openDatabase('${tmp.path}/i.db');
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra();
      final n = await repo.nextTxNumber();
      expect(int.tryParse(n), isNotNull);
      await db.close();
      await tmp.delete(recursive: true);
    });

    test('QA-INV-02 group mode prefixes with device code', () async {
      final tmp = await Directory.systemTemp.createTemp('nexora_inv2_');
      final db = await databaseFactory.openDatabase('${tmp.path}/i2.db');
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEVICE-QAPREFIX');
      await repo.initSyncInfra();
      await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      final n = await repo.nextTxNumber();
      expect(n, startsWith('QAPR-'),
          reason: 'داخل مجموعة: بادئة من رمز الجهاز تمنع تصادم الأرقام');
      expect(n.split('-').last.length, 5);
      // متتابعة: الرقم التالي يزيد.
      final n2 = await repo.nextTxNumber();
      expect(n2.compareTo(n) > 0, isTrue);
      await db.close();
      await tmp.delete(recursive: true);
    });
  });

  group('تجزئة كلمات المرور', () {
    test('QA-SEC-01 new hashes use per-user random salt (v2)', () {
      final h1 = Security.hash('secret123');
      final h2 = Security.hash('secret123');
      expect(h1, startsWith('v2\$'));
      expect(h1 == h2, isFalse, reason: 'ملح عشوائي مختلف لكل تجزئة');
      expect(Security.verify('secret123', h1), isTrue);
      expect(Security.verify('secret123', h2), isTrue);
      expect(Security.verify('wrong', h1), isFalse);
    });

    test('QA-SEC-02 legacy static-salt hashes still verify + flagged', () {
      // نفس خوارزمية التجزئة القديمة (ملح ثابت nexora::).
      final legacyHash =
          sha256.convert(utf8.encode('nexora::pass')).toString();
      expect(Security.verify('pass', legacyHash), isTrue);
      expect(Security.verify('nope', legacyHash), isFalse);
      expect(Security.needsRehash(legacyHash), isTrue);
      expect(Security.needsRehash(Security.hash('pass')), isFalse);
    });

    test('QA-SEC-03 empty stored password accepts anything (unchanged)', () {
      expect(Security.verify('anything', ''), isTrue);
    });
  });
}
