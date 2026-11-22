// QA — دفعة 48: معالج الإعداد الأول + عزل الوضع المستقل:
// - shouldShowOnboarding: يظهر مرة واحدة فقط (علم دائم + قاعدة فارغة).
// - completeOnboarding: يحفظ اسم المتجر والعملة ويعلّم الإكمال.
// - الترقية لاحقاً لا تُظهر الإعداد الأول أبداً (بيانات قائمة = مكتمل).
// - عضو/مضيف مجموعة لا يرى الإعداد الأول إطلاقاً.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/ui/onboarding_screen.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nexora_ob_');
    db = await databaseFactory.openDatabase(
      p.join(tmp.path, 'ob.db'),
      options: OpenDatabaseOptions(
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        version: 1,
        onCreate: (db, _) => AppDatabase.createSchema(db),
      ),
    );
    repo = Repo(databaseProvider: () async => db);
    // (دفعة 57) requireDeviceId لم يعد يتراجع صامتاً إلى 'DEVICE-UNKNOWN' —
    // أي كتابة تتطلب هوية جهاز مهيأة عبر initSyncInfra.
    await repo.initSyncInfra();
  });

  tearDown(() async {
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('حارس الإعداد الأول shouldShowOnboarding', () {
    test('قاعدة جديدة فارغة (مستقل، بلا علم) → يظهر', () async {
      expect(await shouldShowOnboarding(repo), isTrue);
      // ولا يُعلَّم مكتملاً لمجرد الفحص — يبقى ظاهراً حتى يُكمل المستخدم.
      expect(await shouldShowOnboarding(repo), isTrue);
    });

    test('بعد completeOnboarding لا يظهر مرة أخرى', () async {
      await completeOnboarding(repo,
          storeName: 'بقالة الأمل', currencyCode: 'SAR');
      expect(await shouldShowOnboarding(repo), isFalse);
      final st = await repo.settings();
      expect(st[kOnboardingDoneKey], '1');
      expect(st['businessName'], 'بقالة الأمل');
      expect(st['defaultCurrency'], 'SAR');
    });

    test('اسم فارغ → الافتراضي «متجري»', () async {
      await completeOnboarding(repo, storeName: '   ', currencyCode: 'YER');
      final st = await repo.settings();
      expect(st['businessName'], 'متجري');
      expect(st['defaultCurrency'], 'YER');
    });

    test('بيانات قائمة (ترقية تطبيق) → لا يظهر ويُعلَّم مكتملاً', () async {
      await repo.saveAccount(Account(
        name: 'عميل قديم',
        kind: AccountKind.customer,
        openingBalance: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      expect(await shouldShowOnboarding(repo), isFalse);
      // العلم انحفظ حتى لا يتكرر فحص القاعدة في كل تشغيل.
      final st = await repo.settings();
      expect(st[kOnboardingDoneKey], '1');
    });

    test('عضو مجموعة → لا يظهر أبداً حتى بقاعدة فارغة', () async {
      await db.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': 'member'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      expect(await shouldShowOnboarding(repo), isFalse);
    });

    test('مضيف مجموعة → لا يظهر أبداً', () async {
      await db.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': 'host'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      expect(await shouldShowOnboarding(repo), isFalse);
    });
  });

  group('عزل الوضع المستقل', () {
    test('الافتراضي بعد الإعداد الشخصي يبقى standalone', () async {
      await completeOnboarding(repo,
          storeName: 'متجري', currencyCode: 'YER');
      expect(await repo.workspaceMode(), 'standalone');
    });

    test('علم الإكمال يبقى بعد إعادة فتح القاعدة (استمرارية)', () async {
      await completeOnboarding(repo,
          storeName: 'متجري', currencyCode: 'USD');
      await db.close();
      db = await databaseFactory.openDatabase(
        p.join(tmp.path, 'ob.db'),
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          version: 1,
          onCreate: (db, _) => AppDatabase.createSchema(db),
        ),
      );
      final repo2 = Repo(databaseProvider: () async => db);
      expect(await shouldShowOnboarding(repo2), isFalse);
      final st = await repo2.settings();
      expect(st['defaultCurrency'], 'USD');
    });

    test('الترقية إلى مضيف تحفظ البيانات القائمة كاملة', () async {
      // إعداد شخصي + بيانات فعلية.
      await completeOnboarding(repo,
          storeName: 'متجري', currencyCode: 'YER');
      await repo.saveAccount(Account(
        name: 'عميل مهم',
        kind: AccountKind.customer,
        openingBalance: 500,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      // الترقية: ضبط الوضع host (كما يفعل معالج الاقتران/السحابة).
      await db.insert(
        'sync_meta',
        {'key': 'workspaceMode', 'value': 'host'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      expect(await repo.workspaceMode(), 'host');
      // لا فقدان بيانات: الحساب والإعدادات باقية.
      final accs = await repo.accounts();
      expect(accs.map((a) => a.name), contains('عميل مهم'));
      final st = await repo.settings();
      expect(st['businessName'], 'متجري');
      expect(st[kOnboardingDoneKey], '1');
    });
  });
}
