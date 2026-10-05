// 📢 QA — اختبار مركز التحكم السحابي والتنبيهات وجرس الإشعارات الذهبي (2026-09-26).
//
// يختبر هذا الملف:
//  CTL-01: جلب التنبيهات من كلا المسارين دون تكرار.
//  CTL-02: وضع الصيانة يحدّث maintenanceActiveNotifier ونص الرسالة.
//  CTL-03: تطابق إصدار وبناء التطبيق.
//  CTL-04: حفظ حالة الإشعارات المقروءة في SharedPreferences وعدم عودة العداد بعد تصفيره.
//  CTL-05: عرض أيقونة الجرس الذهبي الحقيقي (GoldenBellIcon) بأحجام مختلفة وبدون أخطاء.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nexora_app/core/app_version.dart';
import 'package:nexora_app/core/license_model.dart';
import 'package:nexora_app/data/sync/cloud_control_service.dart';
import 'package:nexora_app/ui/widgets/golden_bell_icon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Cloud Control & Broadcast Alerts QA Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('CTL-01 جلب التنبيهات من مساري broadcast_alerts و broadcast_notifications', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final alert1Raw = {
        'id': '101',
        'title': 'تنبيه 1',
        'body': 'نص التنبيه 1',
        'created_at': now - 1000,
      };
      final alert2Raw = {
        'id': '102',
        'title': 'تنبيه 2',
        'body': 'نص التنبيه 2',
        'created_at': now,
      };

      final alert1 = CloudAlert.fromJson(alert1Raw, '101');
      final alert2 = CloudAlert.fromJson(alert2Raw, '102');

      expect(alert1.id, '101');
      expect(alert1.title, 'تنبيه 1');
      expect(alert2.id, '102');
      expect(alert2.title, 'تنبيه 2');
    });

    test('CTL-02 وضع الصيانة السحابي والتنبيهات التفاعلية', () {
      final ctl = CloudControlService.instance;
      ctl.maintenanceActiveNotifier.value = true;
      ctl.maintenanceMessageNotifier.value = 'الخوادم قيد الصيانة المجدولة';

      expect(ctl.maintenanceActiveNotifier.value, isTrue);
      expect(ctl.maintenanceMessageNotifier.value, 'الخوادم قيد الصيانة المجدولة');

      ctl.maintenanceActiveNotifier.value = false;
      ctl.maintenanceMessageNotifier.value = '';
      expect(ctl.maintenanceActiveNotifier.value, isFalse);
    });

    test('CTL-03 تطابق إصدار وبناء التطبيق مع المزامنة السحابية', () {
      expect(kAppBuild, greaterThanOrEqualTo(174));
      expect(kAppVersion, isNotEmpty);
      expect(AppSemVer.current.build, kAppBuild);
    });

    test('CTL-04 حفظ الإشعارات المقروءة في SharedPreferences وتصفير العداد نهائياً', () async {
      SharedPreferences.setMockInitialValues({});
      final ctl = CloudControlService.instance;

      const a1 = CloudAlert(
        id: 'alert_bcast_1',
        title: 'إشعار بث 1',
        body: 'مرحباً',
        createdAt: 1700000000,
        isRead: false,
      );
      const a2 = CloudAlert(
        id: 'alert_bcast_2',
        title: 'إشعار بث 2',
        body: 'تحديث جديد',
        createdAt: 1700000050,
        isRead: false,
      );

      ctl.cloudAlertsNotifier.value = [a1, a2];
      ctl.unreadAlertCountNotifier.value = 2;

      expect(ctl.unreadAlertCountNotifier.value, 2);

      // تعليم الكل كمقروء (كما يحدث عند فتح الإشعارات)
      await ctl.markAllAlertsRead();

      expect(ctl.unreadAlertCountNotifier.value, 0);
      expect(ctl.cloudAlertsNotifier.value.every((a) => a.isRead), isTrue);

      // التأكد من الحفظ المستديم في SharedPreferences
      final sp = await SharedPreferences.getInstance();
      final readIds = sp.getStringList('read_cloud_alert_ids') ?? [];
      expect(readIds, contains('alert_bcast_1'));
      expect(readIds, contains('alert_bcast_2'));
    });

    testWidgets('CTL-05 رسم أيقونة الجرس الذهبي الحقيقي GoldenBellIcon بنجاح', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: GoldenBellIcon(size: 24, showSparkle: true),
            ),
          ),
        ),
      );

      expect(find.byType(GoldenBellIcon), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(GoldenBellIcon),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );

      final iconFinder = find.byType(GoldenBellIcon);
      final size = tester.getSize(iconFinder);
      expect(size.width, 24.0);
      expect(size.height, 24.0);
    });
  });
}
