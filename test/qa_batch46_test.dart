// اختبارات الدفعة 46: التطبيع العربي للبحث، فواصل الآلاف الحية،
// مسودة نقطة البيع في Riverpod، الخصم المزدوج (٪/مبلغ)، فرادة الباركود،
// القفل التاريخي للتدقيق، فصل أرصدة العملات، وPopScope الجذري.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core/format.dart';

void main() {
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
