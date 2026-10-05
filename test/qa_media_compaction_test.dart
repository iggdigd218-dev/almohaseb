// QA: دفعة 43 — مسارات الوسائط النسبية، حد حجم حمولة العملية،
// التقليم العام لجدول operations، وعمود attachment_hash.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/media_paths.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/recorder.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('MediaPaths', () {
    test('QA-MP-01 round-trip نسبي/مطلق مع جذر معروف', () {
      MediaPaths.docsDirForTesting = '/data/user/0/com.nexora.eradata/files';
      const abs = '/data/user/0/com.nexora.eradata/files/chat_media/1_a.jpg';
      final rel = MediaPaths.toRelative(abs);
      expect(rel, 'chat_media/1_a.jpg');
      expect(MediaPaths.toAbsolute(rel), abs);
      MediaPaths.docsDirForTesting = null;
    });

    test('QA-MP-02 مسار مطلق قديم يمر كما هو + خارج الجذر لا يتغير', () {
      MediaPaths.docsDirForTesting = '/root/docs';
      // مطلق قديم مخزَّن — يُعاد كما هو عند العرض.
      expect(
        MediaPaths.toAbsolute('/old/app/files/images/x.png'),
        '/old/app/files/images/x.png',
      );
      // مسار خارج documents لا يُقصّ.
      expect(MediaPaths.toRelative('/elsewhere/f.png'), '/elsewhere/f.png');
      // فارغ يبقى فارغاً.
      expect(MediaPaths.toAbsolute(''), '');
      MediaPaths.docsDirForTesting = null;
    });

    test('QA-MP-03 fileHash يحسب SHA-256 لملف حقيقي', () async {
      final tmp = await Directory.systemTemp.createTemp('nexora_mp_');
      MediaPaths.docsDirForTesting = tmp.path;
      final f = File('${tmp.path}/att/receipt.bin')
        ..createSync(recursive: true);
      f.writeAsBytesSync([1, 2, 3, 4, 5]);
      final h = await MediaPaths.fileHash('att/receipt.bin');
      // sha256 لـ [1,2,3,4,5] معروفة وثابتة.
      expect(h,
          '74f81fe167d99b4cb41d6d0ccda82278caee9f3e2f25d5e5a3936ff3dcec60d0');
      expect(await MediaPaths.fileHash('att/missing.bin'), '');
      MediaPaths.docsDirForTesting = null;
      await tmp.delete(recursive: true);
    });
  });

  group('حد حجم حمولة العملية', () {
    test('QA-SZ-01 recorder يرفض حمولة تتجاوز 8MB', () async {
      final tmp = await Directory.systemTemp.createTemp('nexora_sz_');
      final db = await databaseFactory.openDatabase('${tmp.path}/sz.db');
      await AppDatabase.createSchema(db);
      final rec = SyncRecorder(
          db: db, deviceId: 'DEV-SIZE-TEST-01', workspaceId: 'default');
      final fat = 'x' * (kMaxOperationPayloadBytes + 1024);
      await expectLater(
        rec.record(
          entityType: EntityKind.message,
          entityId: '700001',
          opType: OpKind.create,
          payload: {'file_b64': fat},
        ),
        throwsA(isA<StateError>()),
      );
      // لا صف عالق في operations ولا في sync_queue.
      expect(await db.query('operations'), isEmpty);
      expect(await db.query('sync_queue'), isEmpty);
      await db.close();
      await tmp.delete(recursive: true);
    });
  });

  group('attachment_hash', () {
    test('QA-AH-01 العمود موجود ويُروحل عبر Tx و saveTx يملؤه', () async {
      final tmp = await Directory.systemTemp.createTemp('nexora_ah_');
      final db = await databaseFactory.openDatabase('${tmp.path}/ah.db');
      await AppDatabase.createSchema(db);
      MediaPaths.docsDirForTesting = tmp.path;
      // ملف مرفق حقيقي داخل «documents».
      File('${tmp.path}/images/rcpt.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(64, 7));
      final repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEVICE-HASH-0001');
      await repo.initSyncInfra();
      final acc = await repo.saveAccount(Account(
        name: 'عميل الاختبار',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      final now = DateTime.now();
      final id = await repo.saveTx(Tx(
        accountId: acc,
        type: OpType.debit,
        amount: 100,
        image: '${tmp.path}/images/rcpt.png',
        date: now,
        createdAt: now,
        updatedAt: now,
      ));
      final rows = await db.query('transactions',
          where: 'id = ?', whereArgs: [id], limit: 1);
      final tx = Tx.fromMap(rows.first);
      // المسار خُزّن نسبياً والتجزئة حُسبت (64 hex).
      expect(tx.image, 'images/rcpt.png');
      expect(tx.attachmentHash, hasLength(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(tx.attachmentHash), isTrue);
      // copyWith/toMap/fromMap تُروحل القيمة.
      expect(Tx.fromMap(tx.toMap()).attachmentHash, tx.attachmentHash);
      MediaPaths.docsDirForTesting = null;
      await db.close();
      await tmp.delete(recursive: true);
    });
  });

  group('عداد رسائل الدردشة غير المقروءة', () {
    test('QA-CHAT-BADGE-01 يعد الوارد فقط ويصفّر بعد markChatSeen', () async {
      final tmp = await Directory.systemTemp.createTemp('nexora_badge_');
      final db = await databaseFactory.openDatabase('${tmp.path}/badge.db');
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEVICE-BADGE-001');
      await repo.initSyncInfra();
      final nowIso = DateTime.now().toIso8601String();
      await db.insert('conversations', {
        'id': 500100,
        'title': 'دردشة المجموعة',
        'created_at': nowIso,
        'updated_at': nowIso,
      });
      // رسالتان واردتان من عضو آخر + واحدة منا: العداد يجب أن يكون 2.
      for (final (id, sender) in [
        (600001, 'DEVICE-PEER-XYZ'),
        (600002, 'DEVICE-PEER-XYZ'),
        (600003, 'DEVICE-BADGE-001'),
      ]) {
        await db.insert('messages', {
          'id': id,
          'conversation_id': 500100,
          'sender': sender,
          'body': 'رسالة $id',
          'kind': 'text',
          'created_at': DateTime.now().toIso8601String(),
        });
      }
      expect(await repo.unreadChatMessages(), 2,
          reason: 'رسائلنا لا تُحسب ضمن غير المقروء');
      // فتح شاشة الدردشة يوسم الكل كمقروء.
      await repo.markChatSeen();
      expect(await repo.unreadChatMessages(), 0);
      // رسالة جديدة بعد الوسم تُحسب من جديد.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await db.insert('messages', {
        'id': 600004,
        'conversation_id': 500100,
        'sender': 'DEVICE-PEER-XYZ',
        'body': 'رسالة متأخرة',
        'kind': 'text',
        'created_at': DateTime.now().toIso8601String(),
      });
      expect(await repo.unreadChatMessages(), 1);
      await db.close();
      await tmp.delete(recursive: true);
    });
  });

  group('حماية التعارض: استعادة نسخة كاملة (المرحلة 5.2)', () {
    test('QA-RESTORE-01 importAll يفرغ طابور المزامنة ويصفّر مؤشر السحب '
        'داخل معاملة واحدة', () async {
      final tmp = await Directory.systemTemp.createTemp('nexora_rst_');
      final db = await databaseFactory.openDatabase('${tmp.path}/rst.db');
      await AppDatabase.createSchema(db);
      final repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEVICE-RESTORE-1');
      await repo.initSyncInfra();
      // نسخة للاستعادة (خذها قبل تلويث الحالة).
      final backup = await repo.exportAll(withImages: false);
      // حالة ما قبل الاستعادة: عملية معلقة + مؤشر سحب سحابي قديم.
      final nowIso = DateTime.now().toIso8601String();
      await db.insert('operations', {
        'id': 'OP-STALE-1',
        'device_id': 'DEVICE-RESTORE-1',
        'workspace_id': 'default',
        'entity_type': 'account',
        'entity_id': '42',
        'op_type': 'create',
        'version': 1,
        'parent_op_id': '',
        'payload': '{}',
        'device_time': nowIso,
        'timestamp': nowIso,
        'synced': 0,
      });
      await db.insert('sync_queue', {
        'operation_id': 'OP-STALE-1',
        'status': 'pending',
        'target': 'cloud',
        'created_at': nowIso,
        'updated_at': nowIso,
      });
      await db.insert(
          'sync_meta', {'key': 'lastCloudTs:default', 'value': '999999'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      // الاستعادة.
      await repo.importAll(backup);
      // الطابور المعلق أُفرغ والمؤشر صُفِّر — لا تضارب طابور قديم مع
      // قاعدة مسترجعة، والسحب القادم idempotent يعيد الجلب بأمان.
      final pending = await db.query('sync_queue',
          where: "status IN ('pending','syncing')");
      expect(pending, isEmpty, reason: 'طابور ما قبل الاستعادة يُلغى');
      final cursor = await db.query('sync_meta',
          where: 'key = ?', whereArgs: ['lastCloudTs:default']);
      expect(cursor, isEmpty, reason: 'مؤشر السحب يُصفَّر مع الاستعادة');
      await db.close();
      await tmp.delete(recursive: true);
    });
  });

  group('التقليم العام لجدول operations', () {
    test('QA-GC-01 يحذف النسخ المتجاوزة ويُبقي الأحدث والمعلّق', () async {
      final tmp = await Directory.systemTemp.createTemp('nexora_gc_');
      final db = await databaseFactory.openDatabase('${tmp.path}/gc.db');
      await AppDatabase.createSchema(db);
      final old =
          DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
      final nowIso = DateTime.now().toIso8601String();
      Map<String, Object?> op(String id, int version, String ts,
              {int synced = 1}) =>
          {
            'id': id,
            'device_id': 'DEV-GC',
            'workspace_id': 'default',
            'entity_type': 'tx',
            'entity_id': '42',
            'op_type': 'update',
            'version': version,
            'parent_op_id': '',
            'payload': '{}',
            'device_time': ts,
            'timestamp': ts,
            'synced': synced,
          };
      // v1 قديمة متجاوزة → تُحذف. v2 قديمة لكنها الأحدث → تبقى.
      await db.insert('operations', op('OP-GC-1', 1, old));
      await db.insert('operations', op('OP-GC-2', 2, old));
      // عملية قديمة لكن لها صف طابور pending → تبقى.
      await db.insert('operations', op('OP-GC-3', 1, old)
        ..['entity_id'] = '43');
      await db.insert('operations', op('OP-GC-4', 2, old)
        ..['entity_id'] = '43');
      await db.insert('sync_queue', {
        'operation_id': 'OP-GC-3',
        'status': 'pending',
        'target': 'cloud',
        'created_at': nowIso,
        'updated_at': nowIso,
      });
      // (دفعة 58) لا op_deliveries — معيار التقليم synced=1 فقط.
      final repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEV-GC');
      await repo.initSyncInfra();
      final engine = SyncEngine(repo: repo, dbProvider: () async => db);
      await engine.pruneOperationPayloadsForTesting();
      final ids = (await db.query('operations', columns: ['id']))
          .map((r) => r['id'])
          .toSet();
      expect(ids.contains('OP-GC-1'), isFalse,
          reason: 'النسخة المتجاوزة القديمة تُحذف');
      expect(ids.contains('OP-GC-2'), isTrue,
          reason: 'أحدث نسخة للكيان تبقى دائماً');
      expect(ids.contains('OP-GC-3'), isTrue,
          reason: 'عملية عليها طابور pending لا تُمس');
      expect(ids.contains('OP-GC-4'), isTrue);
      await db.close();
      await tmp.delete(recursive: true);
    });
  });
}
