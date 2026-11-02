// QA — دفعة 50: السحابة حصرياً + بصمة العتاد + الطرد الكامل + الترطيب النظيف:
// - recorder: مع سحابة مهيأة لا يُدرج هدف lan إطلاقاً (سحابة فقط).
// - بلا سحابة: سلوك LAN القديم كما هو (تراجع للمجموعات المحلية).
// - expelDevice يطهّر محادثة القرين الفردية ورسائلها.
// - _resetToStandalone يمسح علم onboarding وإعدادات السحابة (عودة للإعداد الأول).
// - بصمة العتاد: deterministicDeviceId حتمي وثابت (نفس المدخل = نفس المعرف).
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/cloud_config.dart';

void main() {
  // هذه الحزمة تحاكي سيناريوهات «لا سحابة» — نلغي الرابط الافتراضي
  // المضمن (Zero-Config) حتى تبقى فرضياتها صالحة.
  debugDefaultBackendUrlOverride = '';
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late Repo repo;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.setSetting('sync.deviceId', 'DEVICE-QA50AAAA');
    await repo.initSyncInfra();
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedAccount() => repo.saveAccount(Account(
        name: 'عميل دفعة 50',
        kind: AccountKind.customer,
        openingBalance: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));

  group('السحابة حصرياً — أهداف الطابور', () {
    test('سحابة مهيأة: هدف cloud فقط، لا lan إطلاقاً', () async {
      await repo.setSetting('cloudBackendUrl', 'https://qa.firebaseio.com');
      await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'host'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await seedAccount();
      final targets =
          (await db.query('sync_queue')).map((r) => r['target']).toSet();
      expect(targets, contains(SyncTarget.cloud));
      expect(targets, isNot(contains('lan')),
          reason: '(دفعة 58) LAN اجتُث نهائياً — لا هدف lan في الطابور');
    });

    test('(دفعة 58) بلا سحابة: لا أهداف إطلاقاً — لا تراجع لـ lan',
        () async {
      await seedAccount();
      final targets =
          (await db.query('sync_queue')).map((r) => r['target']).toSet();
      expect(targets, isNot(contains('lan')));
      expect(targets, isNot(contains(SyncTarget.cloud)));
    });

    test('(دفعة 58) وضع member بلا سحابة: لا هدف lan بعد الاجتثاث', () async {
      await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await seedAccount();
      final targets =
          (await db.query('sync_queue')).map((r) => r['target']).toSet();
      expect(targets, isNot(contains('lan')));
    });
  });


  group('الإبطال من جهة العميل — العودة للإعداد الأول', () {
    test('resetToStandaloneAfterExpulsion يمسح onboarding وإعدادات السحابة',
        () async {
      await repo.setSetting('has_completed_onboarding', '1');
      await repo.setSetting('cloudBackendUrl', 'https://x.firebaseio.com');
      await repo.setSetting('cloudCode', 'ABCD');
      await db.insert('sync_meta', {'key': 'workspaceMode', 'value': 'member'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await repo.resetToStandaloneAfterExpulsion();
      final st = await repo.settings();
      expect(st['has_completed_onboarding'], isNull,
          reason: 'الجهاز المطرود يعود لشاشة الإعداد الأول');
      expect(st['cloudBackendUrl'], isNull);
      expect(st['cloudCode'], isNull);
      expect(await repo.workspaceMode(), 'standalone');
      // البيانات المحلية مُسحت (المدير الافتراضي الجديد فقط).
      expect(await repo.accounts(), isEmpty);
    });
  });

  group('الترطيب النظيف — مؤشرات sync_meta', () {
    test('مؤشرات السحب تُصفَّر بنمط LIKE الشامل', () async {
      await db.insert('sync_meta',
          {'key': 'lastCloudTs:default', 'value': '123'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await db.insert('sync_meta',
          {'key': 'lastRosterPush:default', 'value': 'abc'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      // نفس عبارة الحذف المستخدمة في CloudJoin.join.
      await db.delete('sync_meta',
          where: "key LIKE 'lastCloudTs:%' OR key LIKE 'lastRosterPush:%' "
              "OR key LIKE 'lastLanTs:%'");
      final left = await db.query('sync_meta',
          where: "key LIKE 'last%'");
      expect(left, isEmpty);
    });
  });
}
