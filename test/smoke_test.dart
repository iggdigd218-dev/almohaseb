import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core.dart';
import 'package:nexora_app/words.dart' as words;

void main() {
  test('fmtNum ينسّق الأرقام بفواصل الآلاف', () {
    expect(fmtNum(3000), '3,000');
    expect(fmtNum(0), '0');
    expect(fmtNum(1234567.5), '1,234,567.50');
  });

  test('isoToDisplay يعرض dd-MM-yyyy', () {
    expect(isoToDisplay('2026-11-21'), '21-11-2026');
  });

  test('المبلغ كتابة', () {
    expect(words.amountInWords(2000, 'local'), 'ألفان ريال فقط لا غير');
    expect(words.amountInWords(5000, 'local'), 'خمسة آلاف ريال فقط لا غير');
    expect(words.amountInWords(3500, 'dollar'),
        'ثلاثة آلاف و خمسمائة دولار فقط لا غير');
    expect(words.amountInWords(1, 'saudi'), 'واحد ريال سعودي فقط لا غير');
    expect(words.amountInWords(0, 'local'), 'صفر ريال فقط لا غير');
    expect(words.amountInWords(21, 'local'), 'واحد و عشرون ريال فقط لا غير');
  });

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
}
