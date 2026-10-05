// 🔑 QA — اختبارات نظام إدارة التراخيص والتحقق الإلزامي 2026-09-24.
//
// يختبر هذا الملف:
//  LIC-M01: توليد مفتاح ترخيص منظم بنمط NX-XXXX-XXXX-XXXX
//  LIC-M02: تسلسل واستعادة كائن LicenseModel بجميع الحقول الإلزامية
//  LIC-M03: التحقق من حساب حالات الترخيص والانتهاء
//  LIC-SG01: تسجيل طلب الترخيص عبر SubscriptionGuard مع الحقول الإلزامية في RTDB
//  LIC-UI01: التحقق الإلزامي من الحقول في PurchaseScreen ومنع الإرسال مع رسالة الخطأ
//  LIC-UI02: عرض معرف الجهاز وكود الترخيص المخصص مع أزرار النسخ
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora_app/core/database.dart';
import 'package:nexora_app/core/license_model.dart';
import 'package:nexora_app/core/sfx.dart';
import 'package:nexora_app/core/theme.dart';
import 'package:nexora_app/data/providers.dart';
import 'package:nexora_app/data/repository.dart';
import 'package:nexora_app/data/sync/device_id.dart';
import 'package:nexora_app/data/sync/subscription_guard.dart';
import 'package:nexora_app/ui/trial_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MockCloud {
  final Map<String, Object?> store = {};

  http.Client client() => MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'PUT' || req.method == 'PATCH') {
          final data = jsonDecode(req.body);
          if (req.method == 'PATCH' && store[path] is Map) {
            store[path] = {
              ...(store[path] as Map<String, dynamic>),
              ...(data as Map<String, dynamic>),
            };
          } else {
            store[path] = data;
          }
          return http.Response(jsonEncode(store[path]), 200);
        }
        final val = store[path];
        return http.Response(val == null ? 'null' : jsonEncode(val), 200);
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late Database db;
  late Repo repo;
  late ProviderContainer container;

  setUpAll(() {
    Sfx.setMuted(true);
  });

  setUp(() async {
    debugHardwareFingerprintOverride = () => 'test_raw_fp';
    debugLaunchActivationWhatsAppOverride = (text) => true;
    tmp = await Directory.systemTemp.createTemp('nexora_lic_form_');
    db = await databaseFactory.openDatabase(
      '${tmp.path}/test.db',
      options: OpenDatabaseOptions(
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await AppDatabase.createSchema(db);
    repo = Repo(databaseProvider: () async => db);
    await repo.initSyncInfra();
    await repo.setSetting('sync.deviceId', 'DEVICE-QA-TEST1234');
    SubscriptionGuard.debugReset();

    container = ProviderContainer(overrides: [
      repoProvider.overrideWithValue(repo),
    ]);
  });

  tearDown(() async {
    debugHardwareFingerprintOverride = null;
    debugLaunchActivationWhatsAppOverride = null;
    container.dispose();
    SubscriptionGuard.debugReset();
    if (db.isOpen) await db.close();
    await tmp.delete(recursive: true);
  });

  group('LicenseModel Unit Tests', () {
    test('LIC-M01 توليد مفتاح ترخيص بالنمط المحدد NX-XXXX-XXXX-XXXX', () {
      final key = generateLicenseKey('DEVICE-ABCD-1234-EF56');
      expect(key.startsWith('NX-'), isTrue);
      final parts = key.split('-');
      expect(parts.length, greaterThanOrEqualTo(3));
      expect(parts[0], 'NX');
    });

    test('LIC-M02 تحويل LicenseModel إلى JSON ومنه بنجاح', () {
      final expMs = DateTime(2027, 1, 1).millisecondsSinceEpoch;
      final model = LicenseModel(
        licenseKey: 'NX-ABCD-1234-EF56',
        deviceId: 'DEVICE-TEST-001',
        clientName: 'أحمد المحمدي',
        storeName: 'تموينات الأمل',
        phone: '777123456',
        workspaceId: 'WS-TEST-01',
        expiryDate: expMs,
        status: 'active',
        planType: 'enterprise',
        maxDevices: 5,
      );

      final json = model.toJson();
      expect(json['licenseKey'], 'NX-ABCD-1234-EF56');
      expect(json['clientName'], 'أحمد المحمدي');
      expect(json['storeName'], 'تموينات الأمل');
      expect(json['phone'], '777123456');
      expect(json['status'], 'active');
      expect(json['max_devices'], 5);

      final restored = LicenseModel.fromJson(json);
      expect(restored.licenseKey, model.licenseKey);
      expect(restored.deviceId, model.deviceId);
      expect(restored.clientName, model.clientName);
      expect(restored.storeName, model.storeName);
      expect(restored.phone, model.phone);
      expect(restored.licenseStatus, LicenseStatus.active);
      expect(restored.isExpired, isFalse);
    });

    test('LIC-M03 حساب حالة انتهاء الصلاحية وتسمية الحالة', () {
      final expiredModel = LicenseModel(
        licenseKey: 'NX-EXPD-0000-0000',
        deviceId: 'DEV-01',
        clientName: 'عميل منتهي',
        storeName: 'محل منتهي',
        phone: '1234567',
        workspaceId: 'WS-01',
        expiryDate: DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch,
        status: 'expired',
      );

      expect(expiredModel.isExpired, isTrue);
      expect(expiredModel.licenseStatus.label, 'منتهي');

      final trialModel = LicenseModel(
        licenseKey: 'NX-TRIL-0000-0000',
        deviceId: 'DEV-02',
        clientName: 'عميل تجريبي',
        storeName: 'محل تجريبي',
        phone: '1234567',
        workspaceId: 'WS-02',
        expiryDate: DateTime.now().add(const Duration(days: 20)).millisecondsSinceEpoch,
        status: 'trial',
      );

      expect(trialModel.isExpired, isFalse);
      expect(trialModel.licenseStatus.label, 'تجريبي');
    });
  });

  group('SubscriptionGuard Registration Tests', () {
    test('LIC-SG01 تسجيل طلب الترخيص يكتب في RTDB مع الحقول الإلزامية', () async {
      final cloud = _MockCloud();
      const backendUrl = 'https://qa-test.firebaseio.com';
      await repo.setSetting('cloudBackendUrl', backendUrl);

      final devId = await ensureDeviceId(repo);
      final wsId = repo.requireWorkspaceId;

      await http.runWithClient(
        () => SubscriptionGuard.registerLicenseRequest(
          repo,
          backendUrl: backendUrl,
          workspaceId: wsId,
          clientName: 'زيد العماد',
          storeName: 'سوبرماركت المدينة',
          phone: '771234567',
          deviceId: devId,
          licenseKey: 'NX-REQS-1111-2222',
        ),
        cloud.client,
      );

      // تحقق من تسجيل الطلب في /workspaces/$wsId/license_request.json
      final reqKey = '/workspaces/$wsId/license_request.json';
      expect(cloud.store.containsKey(reqKey), isTrue);
      final savedReq = cloud.store[reqKey] as Map;
      expect(savedReq['clientName'], 'زيد العماد');
      expect(savedReq['storeName'], 'سوبرماركت المدينة');
      expect(savedReq['phone'], '771234567');
      expect(savedReq['licenseKey'], 'NX-REQS-1111-2222');
      expect(savedReq['deviceId'], devId);

      // تحقق من تحديث /trials
      final raw = await hardwareFingerprintRaw() ?? 'fallback:$devId';
      final hwFp = SubscriptionGuard.fingerprintHash(raw);
      final trialKey = '/trials/$hwFp.json';
      expect(cloud.store.containsKey(trialKey), isTrue);
      final savedTrial = cloud.store[trialKey] as Map;
      expect(savedTrial['storeName'], 'سوبرماركت المدينة');
      expect(savedTrial['clientName'], 'زيد العماد');
      expect(savedTrial['phone'], '771234567');
      expect(savedTrial['licenseKey'], 'NX-REQS-1111-2222');
    });
  });

  group('PurchaseScreen Widget Validation Tests', () {
    testWidgets('LIC-UI01 التحقق الإلزامي يمنع الإرسال ويعرض رسالة الخطأ',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Directionality(
              textDirection: TextDirection.rtl,
              child: PurchaseScreen(
                initialDeviceId: "DEVICE-QA-TEST1234",
                initialLicenseKey: "NX-QA01-TEST-1234",
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // التحقق من ظهور شاشة طلب التفعيل
      expect(find.text('طلب الترخيص وتفعيل الحساب'), findsOneWidget);
      expect(find.text('بيانات المشترك والمنشأة (إلزامية)'), findsOneWidget);

      // الحقول فارغة مبدئياً
      // نضغط زر "إرسال طلب الترخيص ومعرف الجهاز (واتساب)"
      final submitBtn = find.text('إرسال طلب الترخيص ومعرف الجهاز (واتساب)');
      expect(submitBtn, findsOneWidget);
      await tester.ensureVisible(submitBtn);
      await tester.tap(submitBtn, warnIfMissed: false);
      await tester.pumpAndSettle();

      // يجب أن تظهر رسالة الخطأ الإلزامية باللون الأحمر في حقول الإدخال
      expect(
        find.text('يرجى إدخال اسم المنشأة والمستخدم ورقم الهاتف للمتابعة'),
        findsWidgets,
      );

      // الآن نقوم بملء الحقول الثلاثة
      final clientField = find.widgetWithText(TextFormField, 'اسم العميل / المسؤول *');
      final storeField = find.widgetWithText(TextFormField, 'اسم المنشأة / المحل *');
      final phoneField = find.widgetWithText(TextFormField, 'رقم الهاتف / الواتساب *');

      await tester.enterText(storeField, 'بقالة السلام');
      await tester.enterText(clientField, 'محمد صالح');
      await tester.enterText(phoneField, '771234567');
      await tester.pumpAndSettle();

      // إخفاء إشعارات الـ snackbar السابقة للتأكد من حالة الحقول
      ScaffoldMessenger.of(tester.element(submitBtn)).clearSnackBars();
      await tester.pumpAndSettle();

      // نضغط مجدداً
      await tester.ensureVisible(submitBtn);
      await tester.tap(submitBtn, warnIfMissed: false);
      await tester.pumpAndSettle();

      // رسالة الخطأ الإلزامية يجب ألا تظهر على أي حقل
      final formState = tester.state<FormState>(find.byType(Form));
      expect(formState.validate(), isTrue);

      // unmount widget before tearDown
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });

    testWidgets('LIC-UI02 كود الترخيص ومعرف الجهاز موجودان مع أزرار النسخ',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Directionality(
              textDirection: TextDirection.rtl,
              child: PurchaseScreen(
                initialDeviceId: "DEVICE-QA-TEST1234",
                initialLicenseKey: "NX-QA01-TEST-1234",
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // التحقق من وجود معرف الجهاز وكود الترخيص المخصص
      expect(find.text('معرف الجهاز (Device ID):'), findsOneWidget);
      expect(find.text('كود الترخيص:'), findsOneWidget);

      // وجود أزرار النسخ (نسخ المعرف + نسخ كود الترخيص)
      expect(find.byIcon(Icons.copy), findsNWidgets(2));

      // unmount widget before tearDown
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
    });
  });
}
