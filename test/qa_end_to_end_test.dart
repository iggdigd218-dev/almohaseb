import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora_app/core/accounting.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/models.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/sync_engine.dart';
import 'package:nexora_app/ui/home_shell.dart';
import 'package:nexora_app/ui/tx_form.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nexora_app/core/cloud_config.dart';

/// (استقرار CI) الكتابة إلى SQLite تتم في مهمة غير متزامنة بعد إغلاق
/// النموذج؛ تحت حمل الآلة قد تتأخر بضعة أجزاء من الثانية، والتأكيد
/// الفوري كان يرى صفر صفوف في fail متقلّب. ننتظر وصول الصف بحدّ زمني
/// واضح، ثم نُبقي التأكيد نفسه (hasLength(1)) صارماً في كشف التكرار.
Future<List<Tx>> _awaitTransactions(Repo repo, {int expected = 1}) async {
  for (var i = 0; i < 80; i++) {
    final rows = await repo.transactions();
    if (rows.length >= expected) return rows;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return repo.transactions();
}

/// يفتح **نسخة** من ملف القاعدة بمقبض منفصل تماماً، وينتظر أن تصل عملية
/// الاختبار إلى القرص قبل الفحص.
///
/// تدفق SQLite إلى القرص غير متزامن: نسخة الملف قد تسبق كتابة العملية
/// بفاصل وجيز تحت حمل الآلة، فيُرى صفر صفوف على القرص رغم نجاحها في
/// المقبض الحيّ — وهو ما جعل هذا الاختبار يفشل مرة ويمرّ أخرى بتغيّر
/// تجميع الشُعب في CI. ننتظر وصول الصف بحدّ زمني واضح (6 ثوانٍ)، ثم
/// يبقى التأكيد (hasLength(1)) صارماً في كشف التكرار أو الفقد.
Future<Database> _openDiskCopy(String dir) async {
  const src = 'e2e.db';
  for (var i = 0; i < 60; i++) {
    final copy = '$dir/e2e_verify_$i.db';
    for (final suf in const ['', '-wal', '-shm']) {
      final f = File('$dir/$src$suf');
      if (await f.exists()) await f.copy('$copy$suf');
    }
    final verify = await databaseFactory.openDatabase(copy);
    final rows = await verify.query('transactions');
    if (rows.isNotEmpty) return verify;
    await verify.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('انتهت مهلة انتظار وصول العملية إلى القرص (6 ثوانٍ).');
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// (إصلاح CI 2026-09-19 #2 — تذبذب QA-E2E) انتظار مقيّد لظهور عنصر:
/// على آلات CI المحمّلة يتأخر تحميل الشاشة الأولى (قراءة القاعدة الحقيقية
/// تتم خارج الزمن الافتراضي) عن الضخ الثابت، فيرمي ensureVisible/tap
/// «No element» ويسقط الاختبار بلا عطل حقيقي — ويفشل بعده انتظار القرص
/// كتابعة. نضخ إطارات مع فسحات حقيقية حتى يظهر العنصر (سقف ~6 ثوانٍ
/// حقيقية) ثم تكمل التدفقات الحازمة كما هي.
Future<void> _waitFor(WidgetTester tester, Finder finder,
    {int maxTries = 60}) async {
  for (var i = 0; i < maxTries && finder.evaluate().isEmpty; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  // هذه الحزمة تحاكي سيناريوهات «لا سحابة» — نلغي الرابط الافتراضي
  // المضمن (Zero-Config) حتى تبقى فرضياتها صالحة.
  debugDefaultBackendUrlOverride = '';
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  testWidgets(
      'QA-E2E real HomeShell button to validation to SQLite to list and balance refresh to reopen',
      (tester) async {
    late Directory tmp;
    late Database db;
    late Repo repo;
    late SyncEngine engine;
    late int accountId;
    await tester.runAsync(() async {
      await initializeDateFormatting('ar');
      await initializeDateFormatting('en');
      await (FontLoader('Tajawal')
            ..addFont(rootBundle.load('assets/fonts/Tajawal-Regular.ttf')))
          .load();
      tmp = await Directory.systemTemp.createTemp('nexora_e2e_');
      db = await databaseFactory.openDatabase('${tmp.path}/e2e.db',
          options: OpenDatabaseOptions(
              onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON')));
      await AppDatabase.createSchema(db);
      repo = Repo(databaseProvider: () async => db);
      await repo.initSyncInfra(); // (دفعة 57) هوية الجهاز إلزامية قبل الكتابة.
      final now = DateTime(2026, 9, 6);
      accountId = await repo.saveAccount(Account(
          name: 'QA E2E customer',
          kind: AccountKind.customer,
          openingBalance: 1000,
          notifyChannel: 'none',
          createdAt: now,
          updatedAt: now));
      engine = SyncEngine(repo: repo, dbProvider: () async => db);
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    Sfx.setMuted(true);
    try {
      await tester.pumpWidget(ProviderScope(
          overrides: [
            repoProvider.overrideWithValue(repo),
            syncEngineProvider.overrideWithValue(engine),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            locale: const Locale('ar'),
            supportedLocales: const [Locale('ar')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: const HomeShell(),
          )));
      await _drain(tester);
      // (2026-09-22) زر الإضافة السريعة (+) يظهر في الشاشة الرئيسية فقط:
      // نفتح ورقة الإجراء السريع من لوحة التحكم مباشرة، ثم ننتقل لقسم
      // العمليات بعد الحفظ للتحقق من القائمة.
      final fab = find.text('عملية');
      await _waitFor(tester, fab);
      await tester.ensureVisible(fab);
      // (إصلاح CI 2026-09-22) نضخ إطارات مقيّدة بدل pumpAndSettle: على
      // آلات CI البطيئة قد لا تهدأ الحركة ضمن المهلة فيفشل الاختبار زوراً.
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(fab, warnIfMissed: false);
      await _drain(tester);
      // (قانون 2026-09-19) الزر العائم «إجراء سريع»: يفتح ورقة خيارات —
      // نختار «تسجيل عملية مالية» منها فيفتح نموذج العملية.
      final sheetAction = find.text('تسجيل عملية مالية');
      await _waitFor(tester, sheetAction);
      await tester.tap(sheetAction);
      await _drain(tester);
      final debitTab = find.text('عليه');
      await _waitFor(tester, debitTab);
      await tester.tap(debitTab);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'المبلغ *'), '٥٠٠');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'البيان / الوصف'), 'QA UI SAVE');
      final save = find.text('حفظ العملية');
      await _waitFor(tester, save);
      await tester.ensureVisible(save);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(save);
      await tester
          .tap(save); // Same frame: there must still be exactly one write.
      await tester.pump(const Duration(milliseconds: 70));
      await _drain(tester);
      await _drain(tester);
      // (إصلاح CI 2026-09-24) ننتظر اكتمال حركة إغلاق النموذج واختفائه
      // كلياً قبل محاولة النقر على الشريط الجانبي؛ لأن حاجز النموذج
      // (Modal Barrier) يغطي كامل الشاشة ويحجب النقرات حتى زواله.
      for (var i = 0;
          i < 40 && find.byType(TxForm).evaluate().isNotEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(TxForm), findsNothing);
      // (تحديث الواجهة 2026-09-19) شاشة العمليات تُفتح من الشريط الجانبي
      // ببلاطة «سجل الفواتير اليومية» — بعد الحفظ من الرئيسية.
      final txTile = find.text('سجل الفواتير اليومية');
      await _waitFor(tester, txTile);
      await tester.ensureVisible(txTile);
      // (إصلاح CI 2026-09-22) pumpAndSettle لا يستقر على آلات CI البطيئة
      // فينتهي بمهلة ويُسقط الاختبار بلا عطل حقيقي — نضخ إطارات مقيّدة
      // حتى تهدأ الحركة (نفس معالجة التذبذب السابقة في هذا الملف).
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(txTile, warnIfMissed: false);
      await _drain(tester);
      // (إصلاح CI 2026-09-19 — تذبذب QA-E2E) انتظار مقيّد بدل pump ثابت:
      // على آلات CI البطيئة قد يتأخر انعكاس البطاقة في القائمة عن المهلة
      // الثابتة فيسقط الاختبار أحمر بلا عطل حقيقي. نضخ إطارات حتى تظهر
      // البطاقة أو حتى سقف 15 ثانية زمنية افتراضية.
      for (var i = 0;
          i < 75 && find.textContaining('QA UI SAVE').evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      // (دفعة 58 — متطلب 10) البطاقة تعرض «الوصف · HH:MM» — نطابق جزئياً.
      expect(find.textContaining('QA UI SAVE'), findsOneWidget);
      await tester.runAsync(() async {
        final rows = await _awaitTransactions(repo);
        expect(rows, hasLength(1));
        expect(rows.single.amount, 500);
        expect(rows.single.reference, '1');
        expect(rows.single.accountId, accountId);
        expect(await repo.balanceOf((await repo.account(accountId))!), 1500);
      });
      // عرض 1000 > عتبة سطح المكتب (900): الشريط السفلي استُبدل بشريط
      // جانبي (Rail) — ننقر عنوان «دفتر الحسابات والديون» فيه.
      await tester.tap(find.text('دفتر الحسابات والديون'));
      await _drain(tester);
      expect(find.textContaining('1,500'), findsWidgets);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      engine.stop();
      await tester.runAsync(() async {
        // (استقرار CI) إثبات الاستمرارية على القرص يتم عبر **نسخة** من
        // ملف القاعدة ومقبض منفصل تماماً — بلا إغلاق مقبض `repo` أثناء
        // حياته. النمط القديم (قراءة الصفوف عبر `repo` بعد هدم الشجرة)
        // كان يجعل النتيجة رهينةً لتجميع الشُعب: المقبض مرتبط بدورة حياة
        // الواجهة، وتدفق SQLite إلى القرص غير متزامن.
        // ملاحظة: sqflite يعيد النسخة نفسها للمسار الواحد، لذا فتح مسار
        // ثانٍ قبل إغلاق الأول لا يعطي مقبضاً مستقلاً — النسخ تحلّها.
        final verify = await _openDiskCopy(tmp.path);
        try {
          final txRows = await verify.query('transactions');
          expect(txRows, hasLength(1),
              reason: 'عملية واحدة بالضبط على القرص — لا تكرار ولا فقد');
          expect(txRows.single['deleted_at'] ?? '', '',
              reason: 'العملية ليست محذوفة ناعماً');
          expect(txRows.single['amount'], 500);
          expect(txRows.single['reference'], '1');
          expect(await verify.query('accounts'), hasLength(1));
        } finally {
          await verify.close();
        }
        await db.close();
        await tmp.delete(recursive: true);
      });
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}
