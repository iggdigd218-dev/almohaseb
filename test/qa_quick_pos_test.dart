import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/services/floating_pos_overlay.dart';
import 'package:nexora_app/services/floating_pos_service.dart';
import 'package:nexora_app/services/quick_pos_protocol.dart';

/// مصدر بيانات وهمي: يسجّل الاستدعاءات ويعيد نتائج ثابتة.
class _FakeSource implements QuickPosDataSource {
  final List<String> lookups = <String>[];
  bool boom = false;

  @override
  Future<QuickPosHello> hello() async =>
      const QuickPosHello(currency: 'YER', symbol: 'ر.ي');

  @override
  Future<List<QuickPosItem>> lookup(String query) async {
    lookups.add(query);
    if (boom) throw StateError('قاعدة البيانات مقفولة');
    return const <QuickPosItem>[
      QuickPosItem(
          id: 1, name: 'شاي', sku: '100', unit: 'علبة', price: 500, qty: 12),
      QuickPosItem(
          id: 2, name: 'سكر', sku: '200', unit: 'كيس', price: 900, qty: 0),
    ];
  }

  @override
  Future<QuickPosSaleResult> sell({
    required int itemId,
    required double qty,
  }) async {
    if (boom) throw StateError('لا صلاحية إضافة عملية');
    return QuickPosSaleResult(
        ok: true, ref: '77', name: 'شاي', qty: qty, total: 500 * qty);
  }
}

/// قناة وهمية: تُسلّم الردود فور إرسال الطلب (نفس سلوك المحرك الحقيقي).
class _FakeLink implements QuickPosLink {
  final StreamController<Object?> _ctl = StreamController<Object?>.broadcast();
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];

  @override
  Stream<Object?> get replies => _ctl.stream;

  @override
  Future<void> send(Map<String, Object?> message) async {
    sent.add(message);
    final op = '${message['op']}';
    final id = message['rid'];
    if (op == 'hello') {
      _ctl.add(<String, Object?>{
        'rid': id,
        'ok': true,
        'currency': 'YER',
        'symbol': 'ر.ي'
      });
    } else if (op == 'lookup') {
      _ctl.add(<String, Object?>{
        'rid': id,
        'ok': true,
        'items': <Map<String, Object?>>[
          <String, Object?>{
            'id': 1,
            'name': 'شاي',
            'sku': '100',
            'unit': 'علبة',
            'price': 500,
            'qty': 12,
            'currency': 'YER',
          },
          <String, Object?>{
            'id': 2,
            'name': 'سكر',
            'sku': '200',
            'unit': 'كيس',
            'price': 900,
            'qty': 0,
            'currency': 'YER',
          },
        ],
      });
    } else if (op == 'sell') {
      _ctl.add(<String, Object?>{
        'rid': id,
        'ok': true,
        'ref': '77',
        'name': 'شاي',
        'qty': message['qty'],
        'total': 500,
        'remaining': 11,
      });
    }
  }
}

Future<void> _pump(WidgetTester tester, {int times = 8}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  // ------------------ البروتوكول (منطق صرف) ------------------
  group('QP-بروتوكول', () {
    test('QP-01 hello يردّ بالعملة المعتمدة', () async {
      final p = QuickPosProtocol(_FakeSource());
      final res = await p.handle(<String, Object?>{'op': 'hello', 'id': 1});
      expect(res, isNotNull);
      expect(res!['ok'], true);
      expect(res['currency'], 'YER');
      expect(res['symbol'], 'ر.ي');
      expect(res['t'], 'res');
      expect(res['op'], 'hello');
    });

    test('QP-02 lookup يمرّر الاستعلام ويحدّ النتائج بحد أقصى', () async {
      final src = _FakeSource();
      final p = QuickPosProtocol(src, limit: 1);
      final res = await p.handle(<String, Object?>{'op': 'lookup', 'q': '10'});
      expect(src.lookups, ['10']);
      expect(res!['ok'], true);
      expect((res['items'] as List).length, 1);
    });

    test('QP-03 sell يمرّر الصنف والكمية ويردّ برقم الفاتورة', () async {
      final p = QuickPosProtocol(_FakeSource());
      final res = await p.handle(<String, Object?>{
        'op': 'sell',
        'id': 1,
        'qty': 3,
      });
      expect(res!['ok'], true);
      expect(res['ref'], '77');
      expect(res['total'], 1500);
    });

    test('QP-04 sell مرفوض بلا صنف أو بكمية صفر', () async {
      final p = QuickPosProtocol(_FakeSource());
      final noItem = await p.handle(<String, Object?>{'op': 'sell', 'qty': 1});
      expect(noItem!['ok'], false);
      final zero = await p.handle(<String, Object?>{
        'op': 'sell',
        'id': 1,
        'qty': 0,
      });
      expect(zero!['ok'], false);
      expect('${zero['error']}', contains('الكمية'));
    });

    test('QP-05 خطأ المصدر يتحوّل إلى ردّ ok:false (لا استثناء)', () async {
      final src = _FakeSource()..boom = true;
      final p = QuickPosProtocol(src);
      final res = await p.handle(<String, Object?>{'op': 'lookup', 'q': 'x'});
      expect(res!['ok'], false);
      expect('${res['error']}', contains('قاعدة البيانات'));
      final sell = await p.handle(<String, Object?>{
        'op': 'sell',
        'id': 1,
        'qty': 1,
      });
      expect(sell!['ok'], false);
    });

    test('QP-06 أمر مجهول أو رسالة غير صالحة لا تُسقط المعالج', () async {
      final p = QuickPosProtocol(_FakeSource());
      final unknown = await p.handle(<String, Object?>{'op': 'zzz'});
      expect(unknown!['ok'], false);
      expect(await p.handle(null), isNull);
      expect(await p.handle('نص'), isNull);
      expect(await p.handle(5), isNull);
    });

    test('QP-07 QuickPosItem يحفظ الأنواع عبر الجسر (JSON)', () {
      const it = QuickPosItem(
        id: 9,
        name: 'قهوة',
        sku: '300',
        unit: 'كوب',
        price: 250,
        qty: 4,
        currency: 'YER',
      );
      final back = QuickPosItem.fromMap(it.toMap());
      expect(back.id, 9);
      expect(back.name, 'قهوة');
      expect(back.price, 250);
      expect(back.qty, 4);
      // قيم نصية قادمة من JSON تُحوَّل بأمان
      final fromStrings = QuickPosItem.fromMap(<String, Object?>{
        'id': '3',
        'name': 'ماء',
        'price': '1.5',
        'qty': '10',
      });
      expect(fromStrings.id, 3);
      expect(fromStrings.price, 1.5);
      expect(fromStrings.qty, 10);
    });
  });

  // ------------------ عزل غير أندرويد (بناء آمن) ------------------
  group('QP-عزل المنصات', () {
    test('QP-08 الخدمة معطّلة خارج أندرويد بلا أي قناة منصة', () async {
      expect(FloatingPosService.supported, isFalse);
      expect(FloatingOverlayWindow.supported, isFalse);
      await expectLater(FloatingPosService.instance.show(), completion(isFalse));
      await expectLater(FloatingPosService.instance.hasPermission(),
          completion(isFalse));
      await expectLater(FloatingPosService.instance.requestPermission(),
          completion(isFalse));
      await expectLater(FloatingPosService.instance.isActive(),
          completion(isFalse));
      await FloatingPosService.instance.hide(); // لا ترمي
      await FloatingPosService.instance.restore(); // لا ترمي
      await FloatingOverlayWindow.toBubble();
      await FloatingOverlayWindow.toPanel();
      await FloatingOverlayWindow.close();
    });
  });

  // ------------------ واجهة النافذة العائمة ------------------
  group('QP-واجهة', () {
    testWidgets('QP-09 فقاعة ← بطاقة ← استعلام ← بيع سريع', (tester) async {
      final link = _FakeLink();
      await tester.pumpWidget(QuickPosOverlayApp(link: link));
      await _pump(tester);

      // 1. الفقاعة ظاهرة وطلب المصافحة والاستعلام أُرسلا
      expect(find.byIcon(Icons.flash_on_rounded), findsOneWidget);
      expect(link.sent.map((m) => m['op']).toList(), contains('hello'));
      expect(link.sent.any((m) => m['op'] == 'lookup'), isTrue);

      // 2. النقر يفتح البطاقة (عنوان + لوحة أرقام)
      await tester.tap(find.byIcon(Icons.flash_on_rounded));
      await _pump(tester);
      expect(find.text('استعلام وبيع سريع'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.byIcon(Icons.backspace_outlined), findsOneWidget);

      // 3. الاستعلام المباشر: لوحة الأرقام تُرسل استعلاماً فورياً
      await tester.tap(find.text('1'));
      await _pump(tester);
      expect(
          link.sent.any((m) => m['op'] == 'lookup' && m['q'] == '1'), isTrue);

      // 4. النتائج تظهر مع السعر والكمية
      expect(find.text('شاي'), findsOneWidget);
      expect(find.text('سكر'), findsOneWidget);
      expect(find.text('500 ر.ي'), findsOneWidget);

      // 5. اختيار صنف → شريط البيع
      await tester.tap(find.text('شاي'));
      await _pump(tester);
      expect(find.text('بيع سريع ⚡'), findsOneWidget);

      // 6. البيع السريع: يُرسل الأمر ويعرض رقم الفاتورة
      await tester.tap(find.text('بيع سريع ⚡'));
      await _pump(tester);
      expect(link.sent.any((m) => m['op'] == 'sell' && m['id'] == 1), isTrue);
      expect(find.text('تم البيع ⚡ فاتورة #77'), findsOneWidget);
    });

    testWidgets('QP-10 الضغط المطوّل على الفقاعة يظهر زر الإغلاق',
        (tester) async {
      final link = _FakeLink();
      await tester.pumpWidget(QuickPosOverlayApp(link: link));
      await _pump(tester);
      expect(find.byIcon(Icons.close), findsNothing);
      await tester.longPress(find.byIcon(Icons.flash_on_rounded));
      await _pump(tester);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('QP-11 بلا ردّ من التطبيق تظهر رسالة التوجيه', (tester) async {
      // قناة صامتة: لا ردود إطلاقاً → المصافحة تفشل بعد المهلة.
      final link = _SilentLink();
      await tester.pumpWidget(QuickPosOverlayApp(link: link));
      // ننتظر انقضاء مهلة المصافحة (3 ثوان) بضخّ زمني محدود.
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byIcon(Icons.flash_on_rounded));
      await _pump(tester);
      expect(
        find.text(
            'افتح التطبيق مرة واحدة لتفعيل الاستعلام المباشر من قاعدة البيانات.'),
        findsOneWidget,
      );
    });
  });
  // ------------------ البيع السريع فوق قاعدة بيانات SQLite حقيقية ------------------
  group('QP-قاعدة بيانات', () {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    late Repo repo;
    setUp(() async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
              onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON')));
      await AppDatabase.createSchema(db);
      await AppDatabase.migrateToV23(db);
      await AppDatabase.migrateToV24(db);
      for (final t in <String>[
        'items',
        'item_categories',
        'transactions',
        'transaction_items',
        'stock_moves',
        'operations',
      ]) {
        await db.delete(t);
      }
      repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra();
    });

    Future<int> seedItem() => repo.saveItem(
          Item(
            name: 'شاي',
            sku: '100',
            unit: 'علبة',
            sellPrice: 500,
            quantity: 10,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

    test('QP-12 البيع السريع: قيد مبيعات + خصم مخزون + طابور مزامنة',
        () async {
      final id = await seedItem();
      final proto = QuickPosProtocol(RepoQuickPosSource(repo));

      final hello = await proto.handle(<String, Object?>{'op': 'hello'});
      expect(hello!['ok'], true);
      expect(hello['currency'], 'YER');

      final look = await proto.handle(<String, Object?>{
        'op': 'lookup',
        'q': '100',
      });
      final items = (look!['items'] as List).cast<Map<String, Object?>>();
      expect(items.length, 1);
      expect(items.first['name'], 'شاي');
      expect(items.first['qty'], 10);
      expect(items.first['price'], 500);

      final sell = await proto.handle(<String, Object?>{
        'op': 'sell',
        'id': id,
        'qty': 3,
      });
      expect(sell!['ok'], true, reason: '${sell['error']}');
      expect('${sell['ref']}', isNotEmpty);
      expect(sell['total'], 1500);

      // 1) خُصمت الكمية من المخزون
      final after = await repo.item(id);
      expect(after!.quantity, 7);

      // 2) سُجّلت حركة مخزون بيع واحدة
      final db = await repo.database;
      final moves =
          await db.query('stock_moves', where: 'item_id = ?', whereArgs: [id]);
      expect(moves.length, 1);

      // 3) قيد مبيعات نقدية بقيمة الإجمالي مع سطر فاتورة
      final txs = await db.query('transactions');
      expect(txs.length, 1);
      expect(txs.first['amount'], 1500);
      final lines = await db
          .query('transaction_items', where: 'item_id = ?', whereArgs: [id]);
      expect(lines.length, 1);

      // 4) أُدرجت العملية في طابور المزامنة (sync_queue/operations)
      final ops = await db.query('operations');
      expect(ops.length, greaterThanOrEqualTo(1));
    });

    test('QP-13 رفض البيع فوق الرصيد المتاح (لا مخزون سالب)', () async {
      final id = await seedItem();
      final proto = QuickPosProtocol(RepoQuickPosSource(repo));
      final sell = await proto.handle(<String, Object?>{
        'op': 'sell',
        'id': id,
        'qty': 9999,
      });
      expect(sell!['ok'], false);
      expect('${sell['error']}', contains('غير متوفرة'));
      final db = await repo.database;
      expect(await db.query('transactions'), isEmpty);
      expect((await repo.item(id))!.quantity, 10);
    });

    test('QP-14 الاستعلام بالاسم يعمل كما بالباركود', () async {
      await seedItem();
      await repo.saveItem(
        Item(
          name: 'سكر',
          sku: '200',
          unit: 'كيس',
          sellPrice: 900,
          quantity: 4,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      final proto = QuickPosProtocol(RepoQuickPosSource(repo));
      final byName = await proto
          .handle(<String, Object?>{'op': 'lookup', 'q': 'سكر'});
      expect((byName!['items'] as List).length, 1);
      final all =
          await proto.handle(<String, Object?>{'op': 'lookup', 'q': ''});
      expect((all!['items'] as List).length, 2);
    });
  });

}

/// قناة لا تردّ أبداً: لمحاكاة تطبيق غير مستمع.
class _SilentLink implements QuickPosLink {
  @override
  Stream<Object?> get replies => const Stream<Object?>.empty();

  @override
  Future<void> send(Map<String, Object?> message) async {}
}

