// QA — دفعة 58: اجتثاث LAN + الحذف التلقائي للدردشة (24 ساعة) + طلب المغادرة.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/auth_config.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// سحابة وهمية مصغّرة: PUT/GET/DELETE حسب المسار.
class _FakeCloud {
  final Map<String, Object?> store = {};
  static http.Response _json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });
  http.Client client() => MockClient((req) async {
        // (إصلاح 2026-09-18) محاكاة Identity Toolkit/securetoken — منذ
        // اعتماد الهوية السحابية الإلزامية (Rules: auth != null) تمر كل
        // مسارات الدعوة/الانضمام أولاً بـ accounts:signUp. بلا هذه
        // الاستجابة كان المحاكي يرجع 'null' لطلبات POST فيفشل إنشاء
        // الهوية وتنهار اختبارات الربط كلها (11 اختباراً).
        if (req.method == 'POST') {
          if (req.url.host.contains('securetoken')) {
            return _json('{"id_token":"TOK-QA","refresh_token":"REF-QA",'
                '"expires_in":"3600","user_id":"UID-QA-ANON"}', 200);
          }
          return _json('{"idToken":"TOK-QA","refreshToken":"REF-QA",'
              '"expiresIn":"3600","localId":"UID-QA-ANON"}', 200);
        }
        final key = req.url.path;
        if (req.method == 'PUT') {
          store[key] = jsonDecode(req.body);
          return _json(req.body, 200);
        }
        if (req.method == 'DELETE') {
          store.remove(key);
          return _json('null', 200);
        }
        final v = store[key];
        if (v != null) return _json(jsonEncode(v), 200);
        final prefix = key.replaceAll('.json', '');
        final children = <String, Object?>{};
        for (final e in store.entries) {
          if (e.key.startsWith('$prefix/')) {
            children[Uri.decodeComponent(e.key
                .substring(prefix.length + 1)
                .replaceAll('.json', ''))] = e.value;
          }
        }
        if (children.isNotEmpty) return _json(jsonEncode(children), 200);
        return _json('null', 200);
      });
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() async {
    debugFirebaseApiKeyOverride = 'AIzaSyFakeKeyForTesting';
    tmp = await Directory.systemTemp.createTemp('nexora_b58_');
    db = await databaseFactory.openDatabase('${tmp.path}/qa.db');
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
  });
  tearDown(() async {
    debugFirebaseApiKeyOverride = null;
    if (db.isOpen) await db.close();
    await tmp.delete(recursive: true);
  });

  test('B58-SCHEMA-01 لا جدول op_deliveries ولا أعمدة ip/port في devices',
      () async {
    final t = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='op_deliveries'");
    expect(t, isEmpty, reason: 'v22 يسقط op_deliveries نهائياً');
    final cols = await db.rawQuery('PRAGMA table_info(devices)');
    final names = cols.map((c) => '${c['name']}').toSet();
    expect(names.contains('ip_address'), isFalse);
    expect(names.contains('port'), isFalse);
  });

  test('B58-CHAT-01 رسائل أقدم من 24 ساعة تُحذف نهائياً والأحدث تبقى',
      () async {
    // محادثة المجموعة + رسالتان: قديمة (25 ساعة) وحديثة.
    final now = DateTime.now();
    await db.insert('conversations', {
      'id': Repo.groupConversationId,
      'workspace_id': 'default',
      'title': 'دردشة المجموعة',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
    await db.insert('messages', {
      'conversation_id': Repo.groupConversationId,
      'workspace_id': 'default',
      'sender': 'DEV-A',
      'body': 'قديمة',
      'kind': 'text',
      'payload': '',
      'created_at':
          now.subtract(const Duration(hours: 25)).toIso8601String(),
    });
    await db.insert('messages', {
      'conversation_id': Repo.groupConversationId,
      'workspace_id': 'default',
      'sender': 'DEV-A',
      'body': 'حديثة',
      'kind': 'text',
      'payload': '',
      'created_at': now.toIso8601String(),
    });
    final purged = await repo.purgeExpiredChatMessages();
    expect(purged, 1);
    final left = await db.query('messages');
    expect(left, hasLength(1));
    expect(left.single['body'], 'حديثة');
  });

  test('B58-CHAT-02 عمليات message المرفوعة القديمة تُقلَّم مع التطهير',
      () async {
    final old = DateTime.now().subtract(const Duration(hours: 30));
    await db.insert('operations', {
      'id': 'OP-CHAT-OLD',
      'workspace_id': 'default',
      'device_id': 'DEV-A',
      'entity_type': 'message',
      'entity_id': '1',
      'op_type': 'create',
      'version': 1,
      'parent_op_id': '',
      'payload': '{"file_b64":"xxxx"}',
      'device_time': old.toIso8601String(),
      'timestamp': old.toIso8601String(),
      'synced': 1,
    });
    await repo.purgeExpiredChatMessages();
    final ops = await db.query('operations', where: "id = 'OP-CHAT-OLD'");
    expect(ops, isEmpty,
        reason: 'حمولة الدردشة المرفوعة الأقدم من المهلة تُحذف محلياً');
  });

  test('B58-LEAVE-01 طلب المغادرة يُكتب في joinRequests بوسم leave ويُجلب للمدير',
      () async {
    final cloud = _FakeCloud();
    const url = 'https://qa-leave.firebaseio.com';
    // العضو يرسل طلب مغادرة.
    await http.runWithClient(
        () => CloudJoin.requestLeave(repo, backendUrl: url), cloud.client);
    // وصل للسحابة بوسم leave وحالة pending.
    final entry = cloud.store.entries
        .firstWhere((e) => e.key.contains('/joinRequests/'));
    final m = Map<String, Object?>.from(entry.value as Map);
    expect(m['kind'], 'leave');
    expect(m['status'], 'pending');
    // المدير يجلبه ضمن الطلبات المعلقة (نفس قناة الانضمام).
    final reqs = await http.runWithClient(
        () => CloudJoin.fetchJoinRequests(repo, backendUrl: url),
        cloud.client);
    expect(reqs, hasLength(1));
    expect('${reqs.first['kind']}', 'leave');
    // الرفض/الاستهلاك: حذف الطلب من السحابة.
    await http.runWithClient(
        () => CloudJoin.deleteJoinRequest(
            backendUrl: url, deviceId: '${reqs.first['deviceId']}'),
        cloud.client);
    expect(cloud.store.keys.where((k) => k.contains('/joinRequests/')),
        isEmpty);
  });
}
