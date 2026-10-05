// QA — دفعة 57: معالجة نتائج التدقيق المعماري.
//  * تقليم شواهد الطرد المنتهية (TTL 7 أيام) pruneExpiredEvictions.
//  * ضغط سجل العمليات السحابي compactOperations (المغطى باللقطة فقط).
//  * زوال اللقطة purgeStaleInviteArtifacts (دعوة منتهية → حذف joinSnapshot).
//  * الحذف الناعم المتماثل للرسائل والمحادثات (deleted_at/deleted_by).
//  * فك JWT exp استباقياً jwtExpiryMs.
//  * المعاملة الموحدة setDeviceIdentity (ربط مستخدم + دور معاً).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/cloud_firebase_transport.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// سحابة وهمية (نفس نمط qa_cloud_join_test).
class FakeCloudStore {
  final Map<String, Object?> store = {};

  static http.Response _utf8Json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });

  http.Client client() => MockClient((req) async {
        final key = req.url.path;
        if (req.method == 'PUT') {
          store[key] = jsonDecode(req.body);
          return _utf8Json(req.body, 200);
        }
        if (req.method == 'DELETE') {
          store.remove(key);
          return _utf8Json('null', 200);
        }
        final v = store[key];
        if (v != null) return _utf8Json(jsonEncode(v), 200);
        final prefix = key.replaceAll('.json', '');
        final children = <String, Object?>{};
        for (final e in store.entries) {
          if (e.key.startsWith('$prefix/')) {
            final child =
                e.key.substring(prefix.length + 1).replaceAll('.json', '');
            children[Uri.decodeComponent(child)] = e.value;
          }
        }
        if (children.isNotEmpty) return _utf8Json(jsonEncode(children), 200);
        return _utf8Json('null', 200);
      });
}

void main() {
  // هذه الحزمة تبني فرضياتها على مسار workspaces/default القديم —
  // نثبّت المعرف القديم بدل التوليد العشوائي (المعمارية الصامتة).
  debugForceLegacyWorkspaceId = true;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  const url = 'https://qa-b57.firebaseio.com';
  const wsPath = '/workspaces/default';

  group('ضغط سجل العمليات السحابي', () {
    test('B57-COMPACT-01 يحذف المغطى باللقطة فقط ويبقي الأحدث', () async {
      final cloud = FakeCloudStore();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final throughTs = nowMs - 30 * 86400000; // حد اللقطة: قبل 30 يوماً.
      cloud.store['$wsPath/operations/OP-OLD.json'] = {
        'id': 'OP-OLD',
        'server_ts': throughTs - 86400000, // أقدم من الحد → يُحذف.
      };
      cloud.store['$wsPath/operations/OP-EDGE.json'] = {
        'id': 'OP-EDGE',
        'server_ts': throughTs, // على الحد بالضبط → يُحذف (≤).
      };
      cloud.store['$wsPath/operations/OP-NEW.json'] = {
        'id': 'OP-NEW',
        'server_ts': nowMs - 3600000, // حديث → يبقى.
      };
      cloud.store['$wsPath/operations/OP-NOTS.json'] = {
        'id': 'OP-NOTS', // بلا server_ts → لا يُمس (أمان).
      };
      final removed = await http.runWithClient(
        () => CloudJoin.compactOperations(
            backendUrl: url, throughTsMs: throughTs),
        cloud.client,
      );
      expect(removed, 2);
      expect(
          cloud.store.containsKey('$wsPath/operations/OP-OLD.json'), isFalse);
      expect(
          cloud.store.containsKey('$wsPath/operations/OP-EDGE.json'), isFalse);
      expect(
          cloud.store.containsKey('$wsPath/operations/OP-NEW.json'), isTrue);
      expect(
          cloud.store.containsKey('$wsPath/operations/OP-NOTS.json'), isTrue);
    });
  });

  group('زوال اللقطة مع انتهاء الدعوات', () {
    test('B57-SNAP-01 دعوة منتهية بلا حيّة → تُحذف الدعوة واللقطة', () async {
      final cloud = FakeCloudStore();
      final past = DateTime.now().subtract(const Duration(hours: 1));
      cloud.store['$wsPath/invites/TOK1.json'] = {
        'expiresAt': past.toIso8601String(),
      };
      cloud.store['$wsPath/joinSnapshot.json'] = {'data': {}};
      final purged = await http.runWithClient(
        () => CloudJoin.purgeStaleInviteArtifacts(backendUrl: url),
        cloud.client,
      );
      expect(purged, isTrue);
      expect(cloud.store.containsKey('$wsPath/invites/TOK1.json'), isFalse);
      expect(cloud.store.containsKey('$wsPath/joinSnapshot.json'), isFalse);
    });

    test('B57-SNAP-02 دعوة سارية → اللقطة تبقى (نافذة الانضمام مفتوحة)',
        () async {
      final cloud = FakeCloudStore();
      final future = DateTime.now().add(const Duration(minutes: 10));
      cloud.store['$wsPath/invites/TOK2.json'] = {
        'expiresAt': future.toIso8601String(),
      };
      cloud.store['$wsPath/joinSnapshot.json'] = {'data': {}};
      final purged = await http.runWithClient(
        () => CloudJoin.purgeStaleInviteArtifacts(backendUrl: url),
        cloud.client,
      );
      expect(purged, isFalse);
      expect(cloud.store.containsKey('$wsPath/joinSnapshot.json'), isTrue);
    });
  });

  group('الحذف الناعم المتماثل للدردشة', () {
    late Directory tmp;
    late Database db;
    late Repo repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('nexora_b57_');
      db = await databaseFactory.openDatabase('${tmp.path}/qa.db',
          options: OpenDatabaseOptions(
            onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          ));
      await AppDatabase.createSchema(db);
      AppDatabase.overrideForTest(db);
      repo = Repo();
      await repo.initSyncInfra();
    });
    tearDown(() async {
      if (db.isOpen) await db.close();
      await tmp.delete(recursive: true);
    });

    test('B57-DEL-01 deleteMessage يوسم لا يمحو + يقيّد عملية delete',
        () async {
      final id = await repo.sendGroupMessage('رسالة ستُحذف');
      await db.delete('operations'); // عزل عملية الإنشاء.
      await repo.deleteMessage(id);
      // الصف باقٍ فيزيائياً موسوماً.
      final raw = await db.query('messages', where: 'id = ?', whereArgs: [id]);
      expect(raw, hasLength(1));
      expect('${raw.single['deleted_at']}', isNotEmpty);
      expect('${raw.single['deleted_by']}', repo.requireDeviceId);
      // مخفي عن القراءة.
      expect((await repo.groupMessages()).where((m) => m.id == id), isEmpty);
      // عملية delete مقيدة للانتشار.
      final ops = await db.query('operations',
          where: "entity_type = 'message' AND op_type = ?",
          whereArgs: ['delete_']);
      expect(ops, hasLength(1));
    });

    test('B57-DEL-02 deleteConversation يوسم المحادثة وكل رسائلها', () async {
      final id = await repo.sendGroupMessage('س1');
      await repo.sendGroupMessage('س2');
      await db.delete('operations');
      await repo.deleteConversation(Repo.groupConversationId);
      final conv = await db.query('conversations',
          where: 'id = ?', whereArgs: [Repo.groupConversationId]);
      expect('${conv.single['deleted_at']}', isNotEmpty);
      final msgs = await db.query('messages',
          where: "conversation_id = ? AND COALESCE(deleted_at,'') = ''",
          whereArgs: [Repo.groupConversationId]);
      expect(msgs, isEmpty);
      expect((await repo.groupMessages()).where((m) => m.id == id), isEmpty);
      final ops = await db.query('operations',
          where: "entity_type = 'conversation' AND op_type = 'delete_'");
      expect(ops, hasLength(1));
    });

    test('B57-DEL-03 حذف وارد من قرين يوسم محلياً (deleted_by = الحاذف)',
        () async {
      final id = await repo.sendGroupMessage('رسالة يحذفها القرين');
      final op = SyncOperation(
        id: 'DEVICE-PEER1-DEL1',
        workspaceId: defaultWorkspaceId,
        deviceId: 'DEVICE-PEER1',
        userId: null,
        entityType: EntityKind.message,
        entityId: '$id',
        opType: OpKind.delete_,
        version: 2,
        parentOpId: '',
        payload: {'id': id, 'deleted_by': 'DEVICE-PEER1'},
        deviceTime: DateTime.now().toIso8601String(),
        timestamp: DateTime.now().toIso8601String(),
      );
      final ok = await db.transaction(
          (txn) => repo.applyRemoteOperation(txn, op, ConflictResolver()));
      expect(ok, isTrue);
      final raw = await db.query('messages', where: 'id = ?', whereArgs: [id]);
      expect(raw, hasLength(1)); // لم يُمح فيزيائياً.
      expect('${raw.single['deleted_at']}', isNotEmpty);
      expect('${raw.single['deleted_by']}', 'DEVICE-PEER1');
      expect('${raw.single['sync_state']}', 'synced'); // لا إعادة بث.
      expect((await repo.groupMessages()).where((m) => m.id == id), isEmpty);
    });

    test('B57-ROLE-01 setDeviceIdentity: ربط مستخدم + دور في نداء واحد',
        () async {
      final now = DateTime.now().toIso8601String();
      await db.insert('devices', {
        'id': 'DEV-MEMBER-X',
        'workspace_id': defaultWorkspaceId,
        'name': 'جهاز العضو',
        'is_paired': 1,
        'auth_secret': '',
        'created_at': now,
        'updated_at': now,
      });
      await repo.setDeviceIdentity('DEV-MEMBER-X',
          role: UserRole.accountant, perms: {'add_tx'});
      final dev = await db.query('devices',
          where: 'id = ?', whereArgs: ['DEV-MEMBER-X'], limit: 1);
      final uid = dev.single['user_id'];
      expect(uid, isNotNull);
      final user =
          await db.query('users', where: 'id = ?', whereArgs: [uid], limit: 1);
      expect('${user.single['role']}', 'accountant');
      expect('${user.single['permissions']}', contains('add_tx'));
      // العملية المتزامنة للمستخدم قُيّدت (انتشار الدور للأقران).
      final ops = await db.query('operations',
          where: "entity_type = 'user' AND entity_id = ?",
          whereArgs: ['$uid']);
      expect(ops, isNotEmpty);
    });

    test('B57-ROLE-02 دور admin مرفوض لأي عضو (الوكيل هو الأقصى)', () async {
      final now = DateTime.now().toIso8601String();
      await db.insert('devices', {
        'id': 'DEV-MEMBER-Y',
        'workspace_id': defaultWorkspaceId,
        'name': 'جهاز',
        'is_paired': 1,
        'auth_secret': '',
        'created_at': now,
        'updated_at': now,
      });
      expect(
        () => repo.setDeviceIdentity('DEV-MEMBER-Y',
            role: UserRole.admin, perms: {}),
        throwsStateError,
      );
    });
  });

  group('JWT استباقي', () {
    String fakeJwt(int expSeconds) {
      String b64(Map<String, Object?> m) =>
          base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
      return '${b64({'alg': 'RS256'})}.${b64({'exp': expSeconds})}.sig';
    }

    test('B57-JWT-01 jwtExpiryMs يفك حقل exp بدقة (base64url بلا حشو)', () {
      final exp =
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
              1000;
      expect(CloudFirebaseTransport.jwtExpiryMs(fakeJwt(exp)), exp * 1000);
    });

    test('B57-JWT-02 توكن مشوه → 0 (لا انهيار، يُرفق كما كان سابقاً)', () {
      expect(CloudFirebaseTransport.jwtExpiryMs('not-a-jwt'), 0);
      expect(CloudFirebaseTransport.jwtExpiryMs('a.!!!.c'), 0);
      expect(CloudFirebaseTransport.jwtExpiryMs(''), 0);
    });
  });
}
