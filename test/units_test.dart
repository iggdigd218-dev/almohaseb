// اختبارات التنسيق والتحويلات الأساسية.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/core.dart';

void main() {
  test('fmtNum ينسّق الأرقام بفواصل الآلاف', () {
    expect(fmtNum(3000), '3,000');
    expect(fmtNum(0), '0');
    expect(fmtNum(1234567.5), '1,234,567.50');
  });

  test('isoToDisplay يعرض dd-MM-yyyy', () {
    expect(isoToDisplay('2026-11-21'), '21-11-2026');
  });
}
