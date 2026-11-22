// QA — الانضمام عبر السحابة (CloudJoin):
// - المدير ينشئ دعوة: تُرفع لقطة كاملة + رمز دعوة إلى سحابة وهمية.
// - جهاز مستقل ينضم بالرمز: تُحذف بياناته المحلية بالكامل وتُستبدل بنسخة
//   المجموعة، يصبح عضواً، وتُضبط إعدادات السحابة بنفس رابط المدير.
// - الدعوة تُستخدم مرة واحدة، والعضو لا يستطيع إنشاء دعوة.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_join.dart';
import 'package:nexora_app/data/sync/device_id.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// سحابة وهمية: تخزّن أي PUT حسب المسار وتعيد GET من نفس المخزن.
class FakeCloudStore {
  final Map<String, Object?> store = {};

  /// محاكاة خادم يرفض DELETE (لاختبار الإبطال الحتمي للدعوات).
  bool failDeletes = false;

  static http.Response _utf8Json(String body, int status) =>
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
            return _utf8Json('{"id_token":"TOK-QA","refresh_token":"REF-QA",'
                '"expires_in":"3600","user_id":"UID-QA-ANON"}', 200);
          }
          return _utf8Json('{"idToken":"TOK-QA","refreshToken":"REF-QA",'
              '"expiresIn":"3600","localId":"UID-QA-ANON"}', 200);
        }
        final key = req.url.path;
        if (req.method == 'PUT') {
          store[key] = jsonDecode(req.body);
          return _utf8Json(req.body, 200);
        }
        if (req.method == 'DELETE') {
          if (failDeletes) {
            return _utf8Json('{"error":"Permission denied"}', 401);
          }
          store.remove(key);
          return _utf8Json('null', 200);
        }
        // GET — دعم جلب عقدة كاملة مثل roster.json (تجميع الأبناء).
        final v = store[key];
        if (v != null) return _utf8Json(jsonEncode(v), 200);
        final prefix = key.replaceAll('.json', '');
        final children = <String, Object?>{};
        for (final e in store.entries) {
          if (e.key.startsWith('$prefix/')) {
            final child = e.key
                .substring(prefix.length + 1)
                .replaceAll('.json', '');
            children[Uri.decodeComponent(child)] = e.value;
          }
        }
        if (children.isNotEmpty) return _utf8Json(jsonEncode(children), 200);
        return _utf8Json('null', 200);
      });
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database a;
  late Database b;
  late Repo repoA;
  late Repo repoB;
  final now = DateTime(2026, 9, 9);
  const url = 'https://qa-join.firebaseio.com';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_join_');
    Future<Database> open(String name) =>
        databaseFactory.openDatabase('${tmp.path}/$name.db',
            options: OpenDatabaseOptions(
                onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON')));
    a = await open('a');
    b = await open('b');
    await AppDatabase.createSchema(a);
    await AppDatabase.createSchema(b);
    repoA = Repo(databaseProvider: () async => a);
    repoB = Repo(databaseProvider: () async => b);
    await repoA.initSyncInfra();
    await repoB.initSyncInfra();
    await repoA.setSetting('cloudBackendUrl', url);
    await repoA.setSetting('cloudCode', 'QA123');
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await tmp.delete(recursive: true);
  });

  test('QA-JOIN-01 full cloud join: wipe local data, adopt group snapshot',
      () async {
    final cloud = FakeCloudStore();
    // بيانات المدير التي يجب أن تصل للعضو.
    await repoA.saveAccount(Account(
      name: 'عميل المجموعة',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    // هوية مؤسسة المدير — يجب أن تصل للعضو مع اللقطة.
    await repoA.setSetting('businessName', 'مؤسسة المجموعة الرسمية');
    // بيانات محلية على الجهاز المستقل يجب أن تُحذف بالكامل عند الانضمام:
    // حسابات + قوالب + إشعارات + هوية مؤسسته القديمة.
    await repoB.saveAccount(Account(
      name: 'بيانات قديمة يجب حذفها',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    await repoB.setSetting('businessName', 'مؤسستي القديمة');
    await b.insert('templates', {
      'name': 'قالب قديم',
      'body': 'نص',
      'created_at': now.toIso8601String(),
    });
    await b.insert('notifications', {
      'title': 'إشعار قديم',
      'body': '-',
      'kind': 'info',
      'seen': 0,
      'created_at': now.toIso8601String(),
    });

    final invite = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    expect(invite.token, isNotEmpty);
    expect(invite.backendUrl, url);
    expect(invite.cloudCode, 'QA123');
    // اللقطة والدعوة موجودتان في السحابة.
    expect(
        cloud.store.keys.any((k) => k.contains('joinSnapshot')), isTrue);
    expect(
        cloud.store.keys
            .any((k) => k.contains('/invites/${invite.token}')),
        isTrue);
    // محتوى QR قابل للتحليل.
    final parsed = CloudInviteInfo.parseQr(invite.qrContent);
    expect(parsed?['tok'], invite.token);
    expect(parsed?['url'], url);

    await http.runWithClient(
        () => CloudJoin.join(repoB,
            backendUrl: invite.backendUrl,
            token: invite.token,
            workspaceId: invite.workspaceId,
            cloudCode: invite.cloudCode),
        cloud.client);

    // أصبح عضواً وبياناته القديمة اختفت وبيانات المجموعة حلّت محلها.
    expect(await repoB.workspaceMode(), 'member');
    final accounts = await b.query('accounts');
    expect(accounts.length, 1);
    expect(accounts.first['name'], 'عميل المجموعة');
    // الحذف الكامل: قوالبه وإشعاراته القديمة اختفت أيضاً.
    expect(await b.query('templates'), isEmpty);
    expect(await b.query('notifications'), isEmpty);
    // هوية مؤسسته القديمة استُبدلت بهوية المجموعة.
    final stAfter = await repoB.settings();
    expect(stAfter['businessName'], 'مؤسسة المجموعة الرسمية');
    // إعدادات السحابة بنفس رابط المدير.
    final st = await repoB.settings();
    expect(st['cloudBackendUrl'], url);
    expect(st['cloudCode'], 'QA123');
    expect(st['cloudAutoSync'], '1');
    // جهاز العضو سُجّل في سجل الأجهزة السحابي.
    final ourId = st['sync.deviceId'];
    expect(
        cloud.store.keys.any((k) => k.contains('/roster/') &&
            k.contains(Uri.encodeComponent(ourId!))),
        isTrue);
    // الدعوة أُتلفت بعد الاستخدام (مرة واحدة فقط).
    expect(
        cloud.store.keys
            .any((k) => k.contains('/invites/${invite.token}')),
        isFalse);
  });

  test('QA-JOIN-02 invalid/used token rejected; member cannot invite',
      () async {
    final cloud = FakeCloudStore();
    final invite = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    // رمز خاطئ.
    await expectLater(
        http.runWithClient(
            () => CloudJoin.join(repoB,
                backendUrl: url,
                token: 'WRONG123',
                workspaceId: invite.workspaceId),
            cloud.client),
        throwsA(isA<CloudJoinException>()));
    // انضمام صحيح ثم إعادة استخدام نفس الرمز من جهاز آخر → مرفوض.
    await http.runWithClient(
        () => CloudJoin.join(repoB,
            backendUrl: url,
            token: invite.token,
            workspaceId: invite.workspaceId),
        cloud.client);
    // العضو (repoB الآن عضو) لا يستطيع إنشاء دعوة.
    await expectLater(
        http.runWithClient(() => CloudJoin.createInvite(repoB), cloud.client),
        throwsA(isA<CloudJoinException>()));
    // ولا يستطيع الانضمام لمجموعة أخرى.
    await expectLater(
        http.runWithClient(
            () => CloudJoin.join(repoB,
                backendUrl: url,
                token: invite.token,
                workspaceId: invite.workspaceId),
            cloud.client),
        throwsA(isA<CloudJoinException>()));
  });

  test(
      'QA-JOIN-03 invite revocation is strict: join aborts when cloud '
      'DELETE fails (no silent error swallowing)', () async {
    final cloud = FakeCloudStore();
    final invite = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    // السحابة ترفض الحذف → يجب أن يفشل الانضمام كله (لا نترك توكناً حياً).
    cloud.failDeletes = true;
    await expectLater(
        http.runWithClient(
            () => CloudJoin.join(repoB,
                backendUrl: url,
                token: invite.token,
                workspaceId: invite.workspaceId),
            cloud.client),
        throwsA(isA<CloudJoinException>()));
    // ولم تُمس بيانات العضو (الانضمام أُجهض قبل تطبيق اللقطة).
    expect(await repoB.workspaceMode(), isNot('member'),
        reason: 'فشل إبطال الدعوة يجب أن يوقف الانضمام قبل أي تغيير');
    // بعد عودة السحابة للعمل: نفس الدعوة ما تزال صالحة وينجح الانضمام.
    cloud.failDeletes = false;
    await http.runWithClient(
        () => CloudJoin.join(repoB,
            backendUrl: url,
            token: invite.token,
            workspaceId: invite.workspaceId),
        cloud.client);
    expect(await repoB.workspaceMode(), 'member');
    // والدعوة أُبطلت فعلاً بعد النجاح.
    final inviteKey = cloud.store.keys
        .where((k) => k.contains('/invites/'))
        .toList();
    expect(inviteKey, isEmpty, reason: 'التوكن حُذف حتمياً بعد الانضمام');
  });

  test('QA-JOIN-05 (دفعة 65) المطرود سابقاً يعود: لا يُحبس في «عضو»',
      () async {
    final cloud = FakeCloudStore();
    await repoA.saveAccount(Account(
      name: 'عميل المجموعة',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    final devB = await ensureDeviceId(repoB);

    // 1) انضمام أول ناجح.
    var inv = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    final wsId = inv.workspaceId;
    await http.runWithClient(
        () => CloudJoin.join(repoB,
            backendUrl: inv.backendUrl,
            token: inv.token,
            workspaceId: wsId,
            cloudCode: inv.cloudCode),
        cloud.client);
    expect(await repoB.workspaceMode(), 'member');

    // 2) المدير يزيله من المجموعة (إزالة غير تدميرية — بلا شواهد طرد).
    await http.runWithClient(
        () => CloudJoin.removePeerFromCloud(repoA,
            backendUrl: url, deviceId: devB, workspaceId: wsId),
        cloud.client);
    expect(cloud.store['/workspaces/$wsId/roster/$devB.json'], isNull,
        reason: 'الإزالة تحذف عضويته السحابية بلا أي شاهدة طرد');
    expect(cloud.store.keys.where((k) => k.contains('/evictions/')), isEmpty,
        reason: 'لا تُكتب أي شاهدة طرد بعد اليوم');

    // 3) الجهاز لم يعالج الإزالة (كان مغلقاً) فما زال محلياً member —
    //    وإعادة الانضمام يجب أن تنجح كترميم للعضوية لا أن تُرفض.
    expect(await repoB.workspaceMode(), 'member',
        reason: 'الجهاز المحلي لم يعالج الطرد — هذه هي الحالة المفخخة');

    inv = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    await http.runWithClient(
        () => CloudJoin.join(repoB,
            backendUrl: inv.backendUrl,
            token: inv.token,
            workspaceId: wsId,
            cloudCode: inv.cloudCode),
        cloud.client);

    expect(await repoB.workspaceMode(), 'member');
  });

  test('QA-JOIN-07 (إصلاح 2026-09-19) تبديل المساحة يصحّح الكاش ويصوّب '
      'الصفوف الضالة', () async {
    // محاكاة جهاز ربط للتو: الجدول يحمل مساحة المجموعة لكن الكاش قديم.
    final db = await repoA.database;
    final oldWs = repoA.requireWorkspaceId;
    // join الحقيقي يمسح الجدول ويستبدله بلقطة مساحة المجموعة.
    await db.delete('workspaces');
    await db.insert('workspaces', {
      'id': 'WS-JOINED-77',
      'name': 'مجموعة الاختبار',
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    // صفوف ضالة سُجلت بالمعرّف القديم قبل التصحيح.
    await repoA.queueOperation(
        entityType: EntityKind.account,
        entityId: 'QA07-1',
        opType: OpKind.create,
        payload: const {});
    await repoA.refreshWorkspaceId();
    expect(repoA.requireWorkspaceId, 'WS-JOINED-77',
        reason: 'الكاش يعكس جدول workspaces بعد التبديل');
    // جدول operations هو حامل المعرّف (sync_queue يشير له فقط).
    final stranded = await db.query('operations',
        where: 'workspace_id = ?', whereArgs: [oldWs]);
    expect(stranded, isEmpty,
        reason: 'الصفوف الضالة تُصوّب للمساحة الصحيحة فلا تُدفع للخاطئة');
    // العمليات الجديدة تُسجَّل مباشرة بالمعرّف الصحيح.
    await repoA.queueOperation(
        entityType: EntityKind.account,
        entityId: 'QA07-2',
        opType: OpKind.create,
        payload: const {});
    final q2 = await db.query('operations', where: "entity_id = 'QA07-2'");
    expect(q2.single['workspace_id'], 'WS-JOINED-77');
  });

  test('QA-JOIN-06 (دفعة 65) العضو الفعّال يُرفض حقاً',
      () async {
    final cloud = FakeCloudStore();
    await repoA.saveAccount(Account(
      name: 'عميل المجموعة',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    final inv = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    final wsId = inv.workspaceId;
    await http.runWithClient(
        () => CloudJoin.join(repoB,
            backendUrl: inv.backendUrl,
            token: inv.token,
            workspaceId: wsId,
            cloudCode: inv.cloudCode),
        cloud.client);

    // عضو فعّال: سجله قائم في roster بلا طرد — يحاول الانضمام مجدداً.
    final inv2 = await http.runWithClient(
        () => CloudJoin.createInvite(repoA), cloud.client);
    await expectLater(
        http.runWithClient(
            () => CloudJoin.join(repoB,
                backendUrl: inv2.backendUrl,
                token: inv2.token,
                workspaceId: wsId,
                cloudCode: inv2.cloudCode),
            cloud.client),
        throwsA(isA<CloudJoinException>()),
        reason: 'العضو الفعّال يُمنع من الانضمام لمجموعة أخرى');
  });
}
