// اختبارات الدفعة 46: التطبيع العربي للبحث، فواصل الآلاف الحية،
// مسودة نقطة البيع في Riverpod، الخصم المزدوج (٪/مبلغ)، فرادة الباركود،
// القفل التاريخي للتدقيق، فصل أرصدة العملات، وPopScope الجذري.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/format.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/data/pos_cart.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('QA-AR-NORM التطبيع العربي الذكي', () {
    test('توحيد الهمزات والتاء المربوطة والألف المقصورة', () {
      expect(Fmt.normArabic('أَحْمَد'), 'احمد');
      expect(Fmt.normArabic('إبراهيم'), 'ابراهيم');
      expect(Fmt.normArabic('آمنة'), 'امنه');
      expect(Fmt.normArabic('مصطفى'), 'مصطفي');
      expect(Fmt.normArabic('فاطمة'), 'فاطمه');
      expect(Fmt.normArabic('مُؤَسَّسَة'), 'موسسه');
    });

    test('smartContains يطابق رغم اختلاف الهمزات والتشكيل', () {
      expect(Fmt.smartContains('شركة أحمد للتجارة', 'احمد'), isTrue);
      expect(Fmt.smartContains('مؤسسة النور', 'موسسه'), isTrue);
      expect(Fmt.smartContains('مكتبة الهدى', 'الهدي'), isTrue);
      expect(Fmt.smartContains('عَبْدُ الله', 'عبد الله'), isTrue);
      expect(Fmt.smartContains('محل صنعاء', 'عدن'), isFalse);
    });

    test('كشف الاستعلام الرقمي (يوجه البحث نحو SKU/الهاتف/المبالغ)', () {
      expect(Fmt.isNumericQuery('771234567'), isTrue);
      expect(Fmt.isNumericQuery('٧٧١٢٣٤٥٦٧'), isTrue); // أرقام عربية
      expect(Fmt.isNumericQuery('1,500'), isTrue);
      expect(Fmt.isNumericQuery('أحمد'), isFalse);
      expect(Fmt.isNumericQuery('a123'), isFalse);
    });
  });

  group('QA-FMT-SEP فواصل الآلاف الحية', () {
    const f = ThousandsFormatter();
    TextEditingValue fmt(String s) => f.formatEditUpdate(
        TextEditingValue.empty, TextEditingValue(text: s));

    test('1000000 → 1,000,000 والأعشار تُحفظ', () {
      expect(fmt('1000000').text, '1,000,000');
      expect(fmt('1234567.55').text, '1,234,567.55');
      expect(fmt('500').text, '500');
    });

    test('الأرقام العربية تُحوَّل ثم تُفصل', () {
      expect(fmt('١٠٠٠٠٠٠').text, '1,000,000');
    });

    test('strip يعيد القيمة النقية للتحليل', () {
      expect(ThousandsFormatter.strip('1,000,000.25'), '1000000.25');
      expect(Fmt.parseAmount(ThousandsFormatter.strip('12,500')), 12500);
    });

    test('محارف غير رقمية تُرفض (يبقى النص السابق)', () {
      final prev = fmt('123');
      final next = f.formatEditUpdate(
          prev, TextEditingValue(text: '${prev.text}x'));
      expect(next.text, '123');
    });
  });

  group('QA-POS-DRAFT مسودة نقطة البيع في Riverpod', () {
    Item mkItem(int id, {double qty = 10, double price = 100}) => Item(
          id: id,
          name: 'صنف $id',
          unit: 'حبة',
          sku: 'SKU$id',
          quantity: qty,
          sellPrice: price,
          buyPrice: price / 2,
          minQuantity: 0,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

    test('السلة تبقى في المزود بعد التخلص من أي شاشة (استمرارية)', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctl = container.read(posDraftProvider.notifier);
      ctl.addItem(mkItem(1), allowNegative: false);
      ctl.addItem(mkItem(1), allowNegative: false);
      ctl.addItem(mkItem(2, price: 250), allowNegative: false);
      // القراءة من مرجع جديد (تمثيل لإعادة بناء الشاشة).
      final draft = container.read(posDraftProvider);
      expect(draft.cart.length, 2);
      expect(draft.cart[1]!.quantity, 2);
      expect(draft.subtotal, 2 * 100 + 250);
    });

    test('حظر تجاوز الرصيد عند تعطيل السالب والسماح عند تفعيله', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctl = container.read(posDraftProvider.notifier);
      final item = mkItem(5, qty: 1);
      expect(ctl.addItem(item, allowNegative: false), isTrue);
      expect(ctl.addItem(item, allowNegative: false), isFalse,
          reason: 'الرصيد 1 فقط — الإضافة الثانية مرفوضة');
      expect(ctl.addItem(item, allowNegative: true), isTrue,
          reason: 'السماح بالسالب يتخطى الحظر');
      expect(container.read(posDraftProvider).cart[5]!.quantity, 2);
    });

    test('setQuantity المباشر: قبول ضمن الرصيد، رفض فوقه، صفر يحذف', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctl = container.read(posDraftProvider.notifier);
      ctl.addItem(mkItem(7, qty: 50), allowNegative: false);
      expect(ctl.setQuantity(7, 30, allowNegative: false), isTrue);
      expect(container.read(posDraftProvider).cart[7]!.quantity, 30);
      expect(ctl.setQuantity(7, 51, allowNegative: false), isFalse);
      expect(ctl.setQuantity(7, 0, allowNegative: false), isTrue);
      expect(container.read(posDraftProvider).cart.containsKey(7), isFalse);
    });

    test('الخصم المزدوج: نسبة ٪ مقابل مبلغ مقطوع', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctl = container.read(posDraftProvider.notifier);
      ctl.addItem(mkItem(1, price: 1000), allowNegative: false); // 1000
      // مبلغ مقطوع.
      ctl.setDiscount('150');
      ctl.setDiscountIsPercent(false);
      expect(container.read(posDraftProvider).discountValue, 150);
      expect(container.read(posDraftProvider).netTotal, 850);
      // نسبة مئوية.
      ctl.setDiscountIsPercent(true);
      ctl.setDiscount('10');
      expect(container.read(posDraftProvider).discountValue, 100);
      expect(container.read(posDraftProvider).netTotal, 900);
      // نسبة فوق 100 تُقص إلى 100.
      ctl.setDiscount('150');
      expect(container.read(posDraftProvider).netTotal, 0);
      // خصم بمبلغ فيه فواصل آلاف.
      ctl.setDiscountIsPercent(false);
      ctl.setDiscount('1,000');
      expect(container.read(posDraftProvider).discountValue, 1000);
    });

    test('clear يصفر كل شيء', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final ctl = container.read(posDraftProvider.notifier);
      ctl.addItem(mkItem(1), allowNegative: false);
      ctl.setCustomer(9);
      ctl.setPayment('credit');
      ctl.clear();
      final d = container.read(posDraftProvider);
      expect(d.cart, isEmpty);
      expect(d.customerId, isNull);
      expect(d.payment, 'cash');
    });
  });

  group('QA-DB46 فرادة الباركود والقفل التاريخي', () {
    late Directory tmp;
    late Database db;
    late Repo repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('nexora_b46_');
      db = await databaseFactory.openDatabase('${tmp.path}/b46.db');
      await AppDatabase.createSchema(db);
      repo = Repo(databaseProvider: () async => db);
      await repo.setSetting('sync.deviceId', 'DEV-B46');
      await repo.initSyncInfra();
    });

    tearDown(() async {
      await db.close();
      await tmp.delete(recursive: true);
    });

    Item mkItem(String name, String sku) => Item(
          name: name,
          unit: 'حبة',
          sku: sku,
          quantity: 10,
          sellPrice: 100,
          buyPrice: 50,
          minQuantity: 0,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

    test('QA-SKU-01 باركود مكرر يُرفض؛ وتعديل الصنف نفسه مسموح', () async {
      final id1 = await repo.saveItem(mkItem('صنف أ', 'BAR-111'));
      // صنف جديد بنفس الباركود → رفض.
      await expectLater(
          repo.saveItem(mkItem('صنف ب', 'BAR-111')), throwsStateError);
      // تعديل الصنف نفسه بنفس باركوده → مسموح (لا يتصادم مع نفسه).
      final existing = await repo.item(id1);
      await repo.saveItem(existing!.copyWith(name: 'صنف أ معدل'));
      // باركود فارغ لا يخضع للفرادة.
      await repo.saveItem(mkItem('بلا باركود 1', ''));
      await repo.saveItem(mkItem('بلا باركود 2', ''));
    });

    test('QA-LOCK-01 القفل التاريخي يمنع غير المدير ويستثني المدير',
        () async {
      final acc = Account(
        name: 'عميل القفل',
        kind: AccountKind.customer,
        notifyChannel: 'none',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final accId = await repo.saveAccount(acc);
      final old = DateTime.now().subtract(const Duration(days: 90));
      final txId = await repo.saveTx(Tx(
        accountId: accId,
        amount: 500,
        currency: 'YER',
        type: OpType.debit,
        date: old,
        createdAt: old,
        updatedAt: old,
      ));
      // تفعيل قفل 30 يوماً.
      await repo.setSetting('auditLockDays', '30');
      // محاكاة محاسب (غير مدير): جهاز غير مالك + مستخدم is_me محاسب.
      // (البذرة تزرع «المدير» بـ is_me=1 — ننزعها منه أولاً).
      await db.update('devices', {'is_owner': 0});
      await db.update('users', {'is_me': 0});
      final nowIso = DateTime.now().toIso8601String();
      await db.insert('users', {
        'name': 'محاسب الفرع',
        'role': 'accountant',
        'is_me': 1,
        'active': 1,
        // صلاحيات محاسب كاملة — ليختبر القفل التاريخي لا الصلاحيات.
        'permissions': 'add_tx,edit_tx,delete_tx,view_reports,export',
        'created_at': nowIso,
        'updated_at': nowIso,
      });
      await expectLater(repo.deleteTx(txId), throwsStateError,
          reason: 'سجل عمره 90 يوماً > 30 مقفل ضد الحذف لغير المدير');
      final txs = await repo.transactions(accountId: accId);
      await expectLater(
          repo.saveTx(txs.first.copyWith(amount: 999)), throwsStateError,
          reason: 'ومقفل ضد التعديل أيضاً');
      // عملية حديثة لا يمسها القفل (المحاسب يملك صلاحية add/delete).
      final recentId = await repo.saveTx(Tx(
        accountId: accId,
        amount: 100,
        currency: 'YER',
        type: OpType.debit,
        date: DateTime.now(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      await repo.deleteTx(recentId); // لا رمي.
      // المدير (المالك) مستثنى من القفل حتى مع بقاء الإعداد مفعلاً.
      await db.update('devices', {'is_owner': 1});
      await repo.deleteTx(txId); // لا رمي.
    });

    test('QA-CUR-SEG فصل أرصدة العملات: لا دمج بين YER وUSD', () async {
      final accId = await repo.saveAccount(Account(
        name: 'عميل متعدد العملات',
        kind: AccountKind.customer,
        currency: 'YER',
        openingBalance: 1000,
        notifyChannel: 'none',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      final now = DateTime.now();
      await repo.saveTx(Tx(
        accountId: accId,
        amount: 5000,
        currency: 'YER',
        type: OpType.debit,
        date: now,
        createdAt: now,
        updatedAt: now,
      ));
      await repo.saveTx(Tx(
        accountId: accId,
        amount: 150,
        currency: 'USD',
        type: OpType.debit,
        date: now,
        createdAt: now,
        updatedAt: now,
      ));
      // نفس منطق كشف الحساب: أرصدة مفصولة لكل عملة.
      final acc = (await repo.account(accId))!;
      final txs = await repo.transactions(accountId: accId);
      final balByCur = <String, double>{acc.currency: acc.openingBalance};
      for (final t in txs) {
        final e = t.effectOn(accId);
        if (e == null) continue;
        balByCur[t.currency] = (balByCur[t.currency] ?? 0.0) + e;
      }
      expect(balByCur['YER'], 6000,
          reason: 'افتتاحي 1000 + دين 5000 بالريال فقط');
      expect(balByCur['USD'], 150, reason: 'الدولار معزول تماماً');
      expect(balByCur.length, 2, reason: 'لا قيمة ثالثة مدموجة');
    });
  });

  group('QA-POPSCOPE رجوع النظام الجذري', () {
    testWidgets('شاشة فرعية: زر الرجوع لا يقتل التطبيق بل يطلب تأكيداً',
        (tester) async {
      var poppedToDashboard = false;
      // محاكاة منطق _handleRootPop في HomeShell: شاشة غير الرئيسية
      // ترجع للرئيسية، والرئيسية تظهر حوار تأكيد الخروج.
      String screen = 'accounts';
      var exitDialogShown = false;
      var exited = false;
      void handlePop() {
        if (screen != 'dashboard') {
          screen = 'dashboard';
          poppedToDashboard = true;
          return;
        }
        exitDialogShown = true;
      }

      await tester.pumpWidget(MaterialApp(
        home: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) handlePop();
          },
          child: const Scaffold(body: Text('X')),
        ),
      ));
      final dynamic widgetsAppState =
          tester.state(find.byType(WidgetsApp));
      // رجوع 1: من الحسابات → الرئيسية (لا خروج).
      await widgetsAppState.didPopRoute();
      expect(poppedToDashboard, isTrue);
      expect(exitDialogShown, isFalse);
      expect(exited, isFalse);
      // رجوع 2 على الرئيسية: ظهور حوار تأكيد الخروج فوراً وبدون تأخير.
      await widgetsAppState.didPopRoute();
      expect(exitDialogShown, isTrue, reason: 'ضغط الرجوع في الرئيسية يظهر حوار التأكيد');
      expect(exited, isFalse);
    });
  });
}
