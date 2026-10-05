import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/catalog_sync_guard.dart';
import 'package:nexora_app/data/sync/sync_diagnostics.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database dbA;
  late Database dbB;
  late Repo repoA;
  late Repo repoB;
  final now = DateTime.now();
  final nowIso = now.toIso8601String();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('catalog_match_');
    dbA = await databaseFactory.openDatabase('${tmp.path}/dbA.db');
    dbB = await databaseFactory.openDatabase('${tmp.path}/dbB.db');
    await AppDatabase.createSchema(dbA);
    await AppDatabase.createSchema(dbB);

    repoA = Repo(databaseProvider: () async => dbA);
    repoB = Repo(databaseProvider: () async => dbB);

    await repoA.setSetting('sync.deviceId', 'DEV-A');
    await repoB.setSetting('sync.deviceId', 'DEV-B');
    await repoA.initSyncInfra();
    await repoB.initSyncInfra();

    for (final db in [dbA, dbB]) {
      await db.insert('users', {
        'id': 1,
        'name': 'المدير',
        'role': 'admin',
        'permissions': '',
        'is_me': 1,
        'active': 1,
        'created_at': nowIso,
        'updated_at': nowIso,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await dbA.update('devices', {'user_id': 1, 'is_owner': 1},
        where: 'id = ?', whereArgs: ['DEV-A']);
    await dbB.update('devices', {'user_id': 1, 'is_owner': 0},
        where: 'id = ?', whereArgs: ['DEV-B']);
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
    await tmp.delete(recursive: true);
  });

  group('التحقق الصارم من تطابق الحسابات والأصناف والأقسام بين كافة الأجهزة', () {
    test('1. تطابق تام عندما تحتوي الأجهزة على نفس الحسابات والأصناف والأقسام',
        () async {
      // إدراج نفس القسم والفئة والحساب والصنف على الجهازين
      for (final db in [dbA, dbB]) {
        await db.insert('sections', {
          'id': 1,
          'name': 'المواد الغذائية',
          'created_at': nowIso,
          'updated_at': nowIso,
        });
        await db.insert('item_categories', {
          'id': 1,
          'section_id': 1,
          'name': 'البقوليات',
          'created_at': nowIso,
          'updated_at': nowIso,
        });
        await db.insert('accounts', {
          'id': 100,
          'name': 'عميل النور',
          'kind': 'customer',
          'created_at': nowIso,
          'updated_at': nowIso,
        });
        await db.insert('items', {
          'id': 200,
          'name': 'فاصوليا حمراء',
          'sku': 'BEANS-RED',
          'category_id': 1,
          'section_id': 1,
          'buy_price': 300,
          'sell_price': 450,
          'quantity': 20,
          'created_at': nowIso,
          'updated_at': nowIso,
        });
      }

      // الفحص المباشر للتطابق
      final isMatch = await CatalogSyncGuard.verifyDirect(repoA, repoB);
      expect(isMatch, isTrue, reason: 'يجب أن يكون الكتالوج متطابقاً تماماً');

      final diag = SyncDiagnostics.instance.snapshot;
      expect(diag.catalogMismatch, isFalse);
      expect(diag.stable, isTrue);
    });

    test('2. ظهور تحذير صريح عند وجود تفاوت في الأصناف بين الأجهزة', () async {
      // الجهاز A يملك صنفين
      await dbA.insert('items', {
        'id': 201,
        'name': 'أرز تايلاندي',
        'sku': 'RICE-THAI',
        'buy_price': 1000,
        'sell_price': 1200,
        'quantity': 10,
        'created_at': nowIso,
        'updated_at': nowIso,
      });
      await dbA.insert('items', {
        'id': 202,
        'name': 'زيت نباتي',
        'sku': 'OIL-VEG',
        'buy_price': 2000,
        'sell_price': 2400,
        'quantity': 5,
        'created_at': nowIso,
        'updated_at': nowIso,
      });

      // الجهاز B يملك صنفاً واحداً فقط (تفاوت في البيانات)
      await dbB.insert('items', {
        'id': 201,
        'name': 'أرز تايلاندي',
        'sku': 'RICE-THAI',
        'buy_price': 1000,
        'sell_price': 1200,
        'quantity': 10,
        'created_at': nowIso,
        'updated_at': nowIso,
      });

      // الفحص يجب أن يكشف عدم التطابق
      final isMatch = await CatalogSyncGuard.verifyDirect(repoA, repoB);
      expect(isMatch, isFalse, reason: 'يجب رصد عدم التطابق بين الجهازين');

      final diag = SyncDiagnostics.instance.snapshot;
      expect(diag.catalogMismatch, isTrue);
      expect(diag.catalogMismatchDetails, contains('الأصناف'));
      expect(diag.downloadFaulted, isTrue,
          reason: 'عدم التطابق يعتبر خللاً تنبيهياً في الاستقبال');
      expect(diag.stable, isFalse);
    });

    test('3. إزالة التحذير فور اكتمال مزامنة وتوحيد بيانات الكتالوج', () async {
      // الجهاز A يملك صنفين
      await dbA.insert('items', {
        'id': 201,
        'name': 'أرز تايلاندي',
        'sku': 'RICE-THAI',
        'buy_price': 1000,
        'sell_price': 1200,
        'quantity': 10,
        'created_at': nowIso,
        'updated_at': nowIso,
      });
      await dbA.insert('items', {
        'id': 202,
        'name': 'زيت نباتي',
        'sku': 'OIL-VEG',
        'buy_price': 2000,
        'sell_price': 2400,
        'quantity': 5,
        'created_at': nowIso,
        'updated_at': nowIso,
      });

      // الجهاز B يملك في البداية صنفاً واحداً فقط
      await dbB.insert('items', {
        'id': 201,
        'name': 'أرز تايلاندي',
        'sku': 'RICE-THAI',
        'buy_price': 1000,
        'sell_price': 1200,
        'quantity': 10,
        'created_at': nowIso,
        'updated_at': nowIso,
      });

      var isMatch = await CatalogSyncGuard.verifyDirect(repoA, repoB);
      expect(isMatch, isFalse);

      // الآن تجري المزامنة ويستلم الجهاز B الصنف الثاني
      await dbB.insert('items', {
        'id': 202,
        'name': 'زيت نباتي',
        'sku': 'OIL-VEG',
        'buy_price': 2000,
        'sell_price': 2400,
        'quantity': 5,
        'created_at': nowIso,
        'updated_at': nowIso,
      });

      isMatch = await CatalogSyncGuard.verifyDirect(repoA, repoB);
      expect(isMatch, isTrue);

      final diag = SyncDiagnostics.instance.snapshot;
      expect(diag.catalogMismatch, isFalse);
      expect(diag.stable, isTrue);
    });
  });
}
