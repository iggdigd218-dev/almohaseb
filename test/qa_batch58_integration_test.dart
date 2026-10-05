// QA — دفعة 58 المرحلة 6 (متطلب 21): اختبار تكاملي شامل بعد اجتثاث LAN:
// - المزامنة سحابية-فقط تعمل بين جهازين (حساب + عملية مالية تصل كاملة).
// - النسخ الاحتياطي والاسترجاع (محلي + سحابي برمز) يعملان.
// - لا بقايا LAN في الشيفرة (منفذ 43053 / lan_http) ولا في المخطط.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/sync/auto_backup.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/cloud_firebase_transport.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/data/sync/workspace_service.dart';

/// سحابة وهمية موحّدة: عمليات تزايدية + نسخ كاملة برمز.
class _FakeCloud {
  final Map<String, Map<String, Object?>> operations = {};
  Map<String, Object?>? codeRecord;

  static http.Response _json(String body, int status) =>
      http.Response.bytes(utf8.encode(body), status, headers: {
        'content-type': 'application/json; charset=utf-8',
      });

  http.Client client() => MockClient((req) async {
        final path = req.url.path;
        if (path.contains('/codes/')) {
          if (req.method == 'PUT') {
            codeRecord =
                Map<String, Object?>.from(jsonDecode(req.body) as Map);
            return _json(req.body, 200);
          }
          return _json(
              codeRecord == null ? 'null' : jsonEncode(codeRecord), 200);
        }
        if (path.contains('/operations')) {
          if (req.method == 'PUT') {
            final opId = Uri.decodeComponent(
                path.split('/operations/').last.replaceAll('.json', ''));
            operations[opId] =
                Map<String, Object?>.from(jsonDecode(req.body) as Map);
            return _json(req.body, 200);
          }
          if (operations.isEmpty) return _json('null', 200);
          return _json(jsonEncode(operations), 200);
        }
        return _json('null', 200);
      });
}

void main() {
  // هذه الحزمة تبني فرضياتها على مسار workspaces/default القديم —
  // نثبّت المعرف القديم بدل التوليد العشوائي (المعمارية الصامتة).
  debugForceLegacyWorkspaceId = true;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory tmp;
  late Database a;
  late Database b;
  late Repo repoA;
  late Repo repoB;
  final now = DateTime(2026, 9, 12);
  const url = 'https://qa-b58.firebaseio.com';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_b58_e2e_');
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
  });
  tearDown(() async {
    if (a.isOpen) await a.close();
    if (b.isOpen) await b.close();
    await tmp.delete(recursive: true);
  });

  CloudFirebaseTransport transport(Repo repo, Database db) =>
      CloudFirebaseTransport.validated(
        repo: repo,
        dbProvider: () async => db,
        backendUrl: url,
        workspaceId: 'default',
      );

  test('B58-E2E-01 cloud-only sync: account + transaction flow A → cloud → B',
      () async {
    final cloud = _FakeCloud();
    // المدير أ يسجّل حساباً وعملية مالية.
    final accId = await repoA.saveAccount(Account(
      name: 'عميل التكامل 58',
      kind: AccountKind.customer,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    await repoA.saveTx(Tx(
      accountId: accId,
      accountKind: AccountKind.customer,
      type: OpType.debit,
      amount: 750,
      currency: 'YER',
      sign: '+',
      fromId: null,
      toId: null,
      rate: 1,
      description: 'دين تكاملي',
      reference: '',
      notes: '',
      category: '',
      attachment: '',
      attachmentHash: '',
      image: '',
      status: 'done',
      syncState: 'pending',
      date: now,
      createdAt: now,
      updatedAt: now,
    ));
    // دفع كل العمليات المسجلة إلى السحابة (القناة الوحيدة).
    final tA = transport(repoA, a);
    final pending = await a.query('operations', where: 'synced = 0');
    expect(pending.length, greaterThanOrEqualTo(2),
        reason: 'حساب + عملية مالية على الأقل');
    for (final row in pending) {
      await http.runWithClient(
          () => tA.push(SyncOperation.fromMap(row)), cloud.client);
    }
    // الجهاز ب يسحب فيتبنى كل شيء.
    final tB = transport(repoB, b);
    final applied = await http.runWithClient(
        () => tB.pull(resolver: ConflictResolver()), cloud.client);
    expect(applied, greaterThanOrEqualTo(2));
    final bAcc = await b
        .query('accounts', where: 'id = ?', whereArgs: [accId], limit: 1);
    expect(bAcc, isNotEmpty);
    expect(bAcc.first['name'], 'عميل التكامل 58');
    final bTx = await b.query('transactions',
        where: 'account_id = ?', whereArgs: [accId]);
    expect(bTx, hasLength(1));
    expect(bTx.first['amount'], 750);
    // سحب ثانٍ idempotent.
    final again = await http.runWithClient(
        () => tB.pull(resolver: ConflictResolver()), cloud.client);
    expect(again, 0);
  });

  test('B58-E2E-02 backup: local export/import + silent workspace backup',
      () async {
    // (3.70) مسار النسخ الوحيد: AutoBackupService (النسخة الصامتة لمسار
    // المساحة) — بديل خدمة cloud_sync الرمزية القديمة المجتثة.
    await repoA.setSetting('cloudBackendUrl', url);
    // (2026-09-22) بوابة جوجل: النسخ السحابي يتطلب حساباً مربوطاً.
    await repoA.setSetting('account.email', 'boss58@nexora.test');
    await repoA.saveAccount(Account(
      name: 'حساب النسخة 58',
      kind: AccountKind.supplier,
      notifyChannel: 'none',
      createdAt: now,
      updatedAt: now,
    ));
    // نسخة محلية.
    final local = await repoA.exportForLocalBackup();
    expect(local['app'], 'nexora');
    // نسخة كاملة إلى السحابة الخاصة (مسار المساحة) ثم سحبها.
    final store = <String, Object?>{};
    http.Response js(Object? v) => http.Response.bytes(
        utf8.encode(v == null ? 'null' : jsonEncode(v)), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    final client = MockClient((req) async {
      if (req.method == 'PUT') {
        store[req.url.path] = jsonDecode(req.body);
        return js(store[req.url.path]);
      }
      return js(store[req.url.path]);
    });
    final ok = await http.runWithClient(
        () => AutoBackupService.silentWorkspaceBackup(repoA), () => client);
    expect(ok, isTrue);
    final pulled = await http.runWithClient(
        () => AutoBackupService.pullWorkspaceBackup(repoA,
            backendUrl: url, workspaceId: repoA.requireWorkspaceId),
        () => client);
    expect(pulled, isNotNull);
    // الاسترجاع في نفس المجموعة يُقبل ويعيد البيانات.
    // pullWorkspaceBackup يعيد حمولة exportAll نفسها (بلا غلاف).
    final restored =
        await repoA.importAll(Map<String, Object?>.from(pulled!));
    expect(restored, greaterThan(0));
    final accs = await repoA.accounts();
    expect(accs.map((x) => x.name), contains('حساب النسخة 58'));
  });

  test('B58-E2E-03 zero LAN residue: no port 43053 / lan_http in lib, '
      'no LAN artifacts in schema', () async {
    // مسح مصدري: لا منفذ LAN ولا ناقل lan_http في lib/.
    final libDir = Directory('lib');
    final offenders = <String>[];
    for (final f in libDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      if (src.contains('43053') || src.contains('lan_http')) {
        offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'بقايا LAN في: ${offenders.join('، ')}');
    // المخطط: لا op_deliveries ولا أعمدة ip/port.
    final t = await a.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='op_deliveries'");
    expect(t, isEmpty);
    final cols = await a.rawQuery('PRAGMA table_info(devices)');
    final names = cols.map((c) => '${c['name']}').toSet();
    expect(names.contains('ip_address'), isFalse);
    expect(names.contains('port'), isFalse);
    // الاستعلامات الأساسية سليمة (لا أعمدة مفقودة).
    await repoA.transactions();
    await repoA.accounts();
    await repoA.users();
  });
}
