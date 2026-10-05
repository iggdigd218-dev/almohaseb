// QA — اختبارات المعالجة الذكية لتعارضات المزامنة وترجمة الأخطاء التشخيصية.
//
// العقود:
//  1. ErrorLocalizationMapper: ترجمة استثناءات SQLite والشبكة إلى نصوص عربية واضحة ومحددة.
//  2. Auto-Healing: معالجة تعارض UNIQUE constraint failed على item_categories.name
//     - إذا كان السجل القديم محذوفاً (deleted_at != NULL)، يُحرر قيد الفرادة بإضافة لاحقة زمنية.
//     - إذا كان السجل القديم نشطاً، يُعاد ربط الأصناف بالمعرف الجديد ويُفرغ الاسم بأمان.
//  3. التقرير الفني: يحمل الاستثناء الخام + استعلام SQL المنفذ + المعاملات args.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/apply_remote.dart';
import 'package:nexora_app/data/sync/conflict_resolver.dart';
import 'package:nexora_app/data/sync/error_localization_mapper.dart';
import 'package:nexora_app/data/sync/operation.dart';
import 'package:nexora_app/data/sync/sync_diagnostics.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('طبقة ترجمة استثناءات SQLite والمزامنة إلى العربية', () {
    test('MAP-01 تعارض القيود الفريدة (UNIQUE constraint failed)', () {
      const err = 'DatabaseException: UNIQUE constraint failed: item_categories.name (code 2067)';
      final loc = ErrorLocalizationMapper.map(err);
      expect(
        loc.arabicExplanation,
        'تعذر الحفظ لوجود سجل مسبق مسجل بنفس القيمة (الاسم أو المعرّف مستخدم بالفعل في النظام).',
      );
      expect(loc.rawException, err);
    });

    test('MAP-02 تعارض العلاقات والربط (FOREIGN KEY constraint failed)', () {
      const err = 'DatabaseException: FOREIGN KEY constraint failed (code 787)';
      final loc = ErrorLocalizationMapper.map(err);
      expect(
        loc.arabicExplanation,
        'تعذر الحذف أو التعديل لارتباط هذا السجل بعمليات أو فواتير أخرى داخل قاعدة البيانات.',
      );
    });

    test('MAP-03 الحقول الإلزامية (NOT NULL constraint failed)', () {
      const err = 'DatabaseException: NOT NULL constraint failed: items.name (code 1299)';
      final loc = ErrorLocalizationMapper.map(err);
      expect(
        loc.arabicExplanation,
        'تعذر إتمام العملية لوجود بيانات أساسية مطلوبة تركت فارغة.',
      );
    });

    test('MAP-04 قفل قاعدة البيانات (database is locked / busy)', () {
      const err = 'DatabaseException: database is locked (code 5)';
      final loc = ErrorLocalizationMapper.map(err);
      expect(
        loc.arabicExplanation,
        'قاعدة البيانات مشغولة حالياً بعملية مزامنة أو حفظ أخرى، يرجى الانتظار ثوانٍ والمحاولة مجدداً.',
      );
    });

    test('MAP-05 انقطاع شبكة السيرفر (SocketException / Timeout / Network)', () {
      final locSocket = ErrorLocalizationMapper.map(
        const SocketException('Failed host lookup: rtdb.firebaseio.com'),
      );
      expect(
        locSocket.arabicExplanation,
        'فشل الاتصال بخادم المزامنة؛ يرجى التحقق من اتصال الإنترنت والمحاولة لاحقاً.',
      );

      final locTimeout = ErrorLocalizationMapper.map('Connection timed out after 30000ms');
      expect(
        locTimeout.arabicExplanation,
        'فشل الاتصال بخادم المزامنة؛ يرجى التحقق من اتصال الإنترنت والمحاولة لاحقاً.',
      );
    });

    test('MAP-06 خطأ غير مدرج يظهر الشرح العام للخطأ غير المتوقع', () {
      final loc = ErrorLocalizationMapper.map('SomeUnknownCustomException: unexpected parser failure');
      expect(
        loc.arabicExplanation,
        'حدث خطأ غير متوقع أثناء معالجة البيانات، يرجى تكرار المحاولة أو إبلاغ الدعم الفني.',
      );
    });

    test('MAP-07 التقرير الفني يحمل الاستعلام وقيم المعاملات كاملة للنسخ', () {
      final loc = ErrorLocalizationMapper.map(
        'DatabaseException: UNIQUE constraint failed: item_categories.name',
        sqlQuery: 'UPDATE item_categories SET name = ? WHERE id = ?',
        sqlArgs: ['إلكترونيات', 10],
      );
      final report = loc.fullTechnicalReport;
      expect(report, contains('العنوان: تنبيه تعثر المزامنة / الحفظ'));
      expect(report, contains('UNIQUE constraint failed'));
      expect(report, contains('استعلام SQL المنفذ:'));
      expect(report, contains('UPDATE item_categories SET name = ? WHERE id = ?'));
      expect(report, contains('المعاملات والقيم الممررة (Args):'));
      expect(report, contains('[إلكترونيات, 10]'));
    });
  });

  group('المعالجة الذكية والذاتية لتعارضات الأقسام (Auto-Healing)', () {
    late Database db;
    late Repo repo;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      repo = Repo(databaseProvider: () async => db);

      // تهيئة الجداول الأساسية
      await db.execute('''
        CREATE TABLE item_categories (
          id INTEGER PRIMARY KEY,
          workspace_id TEXT NOT NULL DEFAULT 'default',
          name TEXT NOT NULL,
          parent_id INTEGER NULL,
          section_id INTEGER NULL,
          deleted_at TEXT DEFAULT '',
          deleted_by INTEGER,
          restore_op_id TEXT DEFAULT '',
          icon_key TEXT DEFAULT '',
          color_hex TEXT DEFAULT '',
          image_path TEXT DEFAULT '',
          created_at TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL DEFAULT ''
        )
      ''');
      await db.execute(
        'CREATE UNIQUE INDEX idx_item_categories_name ON item_categories(name COLLATE NOCASE)',
      );

      await db.execute('''
        CREATE TABLE items (
          id INTEGER PRIMARY KEY,
          workspace_id TEXT NOT NULL DEFAULT 'default',
          name TEXT NOT NULL,
          category_id INTEGER NULL,
          section_id INTEGER NULL,
          quantity REAL NOT NULL DEFAULT 0,
          sell_price REAL NOT NULL DEFAULT 0,
          buy_price REAL NOT NULL DEFAULT 0,
          is_deleted INTEGER NOT NULL DEFAULT 0,
          is_active INTEGER NOT NULL DEFAULT 1,
          archived INTEGER NOT NULL DEFAULT 0,
          deleted_at TEXT DEFAULT '',
          created_at TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL DEFAULT ''
        )
      ''');

      await db.execute('''
        CREATE TABLE operations (
          id TEXT PRIMARY KEY,
          device_id TEXT NOT NULL,
          workspace_id TEXT NOT NULL,
          user_id INTEGER,
          op_type TEXT NOT NULL,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          payload TEXT NOT NULL,
          version INTEGER NOT NULL DEFAULT 0,
          parent_op_id TEXT DEFAULT '',
          device_time TEXT NOT NULL,
          server_time TEXT DEFAULT '',
          timestamp TEXT NOT NULL,
          synced INTEGER NOT NULL DEFAULT 0
        )
      ''');

      await db.execute('''
        CREATE TABLE notifications (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          workspace_id TEXT NOT NULL,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          kind TEXT NOT NULL,
          seen INTEGER NOT NULL DEFAULT 0,
          entity_type TEXT,
          entity_id TEXT,
          created_at TEXT NOT NULL
        )
      ''');

      SyncDiagnostics.instance.debugReset();
    });

    tearDown(() async {
      await db.close();
    });

    test('HEAL-01 تحرير قيد الفرادة تلقائياً إذا كان السجل المحلي محذوفاً (deleted_at != NULL)', () async {
      // 1. إدراج فئة محلية باسم "مشروبات" وحذفها ناعماً
      await db.insert('item_categories', {
        'id': 1,
        'workspace_id': 'default',
        'name': 'مشروبات',
        'deleted_at': '2026-09-26T10:00:00.000Z',
      });

      // 2. وصول فئة جديدة من السحابة بنفس الاسم بمعرف جديد (id: 2)
      final op = SyncOperation(
        id: 'op-cat-02',
        deviceId: 'dev-cloud',
        workspaceId: 'default',
        userId: null,
        parentOpId: '',
        opType: OpKind.create,
        entityType: EntityKind.itemCategory,
        entityId: '2',
        payload: {
          'id': 2,
          'name': 'مشروبات',
          'workspace_id': 'default',
        },
        version: 1,
        deviceTime: DateTime.now().toIso8601String(),
        timestamp: DateTime.now().toIso8601String(),
      );

      final resolver = ConflictResolver();
      await db.transaction((txn) async {
        final applied = await repo.applyRemoteOperation(txn, op, resolver);
        expect(applied, isTrue);
      });

      // 3. التحقق من تطبيق الفئة السحابية بنجاح دون استثناء UNIQUE constraint
      final active = await db.query('item_categories', where: 'id = 2');
      expect(active.length, 1);
      expect(active.first['name'], 'مشروبات');
      expect(active.first['deleted_at'], '');

      // 4. السجل القديم المحذوف تم تحرير اسمه بلاحقة (محذوف ...)
      final old = await db.query('item_categories', where: 'id = 1');
      expect(old.length, 1);
      expect(old.first['name'].toString(), startsWith('مشروبات (محذوف '));
    });

    test('HEAL-02 إعادة ربط الأصناف وحل تعارض الفئة النشطة مع المعرف الجديد', () async {
      // 1. إدراج فئة محلية نشطة باسم "حلويات" بمعرف 10
      await db.insert('item_categories', {
        'id': 10,
        'workspace_id': 'default',
        'name': 'حلويات',
      });

      // إدراج صنف محلي مرتبط بهذه الفئة
      await db.insert('items', {
        'id': 101,
        'workspace_id': 'default',
        'name': 'شوكولاتة',
        'category_id': 10,
      });

      // 2. وصول فئة من السحابة بنفس الاسم "حلويات" بمعرف 20
      final op = SyncOperation(
        id: 'op-cat-20',
        deviceId: 'dev-cloud',
        workspaceId: 'default',
        userId: null,
        parentOpId: '',
        opType: OpKind.create,
        entityType: EntityKind.itemCategory,
        entityId: '20',
        payload: {
          'id': 20,
          'name': 'حلويات',
          'workspace_id': 'default',
        },
        version: 1,
        deviceTime: DateTime.now().toIso8601String(),
        timestamp: DateTime.now().toIso8601String(),
      );

      final resolver = ConflictResolver();
      await db.transaction((txn) async {
        final applied = await repo.applyRemoteOperation(txn, op, resolver);
        expect(applied, isTrue);
      });

      // 3. الفئة الجديدة السحابية موجودة باسم "حلويات"
      final newCat = await db.query('item_categories', where: 'id = 20');
      expect(newCat.length, 1);
      expect(newCat.first['name'], 'حلويات');

      // 4. تم إعادة ربط الأصناف المحلية بالمعرف السحابي الجديد 20
      final updatedItem = await db.query('items', where: 'id = 101');
      expect(updatedItem.first['category_id'], 20);
    });
  });
}
