// اختبارات عناصر الواجهة الصغيرة.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core.dart';

void main() {
  testWidgets('زر التبديل الوردي يُبنى', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Switch(
          value: true,
          onChanged: (_) {},
          activeColor: AppColors.toggleOn,
        ),
      ),
    ));
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('ألوان التطبيق معرّفة', (tester) async {
    expect(AppColors.primary, isNotNull);
    expect(AppColors.pink, isNotNull);
  });
}
