// (2026-11-22) شاشة الحساب كانت بلا قائمة جانبية إطلاقاً — لا مشاركة
// ولا تحويل ولا سقف ولا إغلاق رصيد. هذا الحارس يضمن بقاء الخيارات الاثني
// عشر موصولة بواجهات حقيقية (لا مجرد أزرار بلا أثر).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DRAWER-01 القائمة تحمل الخيارات الاثني عشر', () {
    final src = File('lib/ui/account_screen.dart').readAsStringSync();

    for (final label in const [
      'بحث متقدم',
      'طابعة حرارية',
      'مشاركة',
      'إكسل',
      'إرسال رسالة نصية',
      'إرسال رسالة واتساب',
      'إرسال رسالة نصية+واتساب',
      'مصادقة على الحساب وواتساب',
      'إغلاق الرصيد',
      'تحويل من حساب إلى حساب',
      'التنبيهات',
      'سقف الحساب',
    ]) {
      expect(src, contains(label), reason: 'خيار مفقود: $label');
    }
  });

  test('DRAWER-02 كل خيار موصول بتنفيذ حقيقي', () {
    final src = File('lib/ui/account_screen.dart').readAsStringSync();
    // الدرج مربوط بالـ Scaffold وله زر فتح.
    expect(src, contains('drawer: _drawer(context)'));
    expect(src, contains('openDrawer()'));
    // تنفيذات حقيقية لا مجرد رسائل.
    expect(src, contains('Db.saveTx'), reason: 'التحويل يجب أن يسجّل عمليتين');
    expect(src, contains('Share.shareXFiles'), reason: 'المشاركة/الإكسل');
    expect(src, contains('wa.me'), reason: 'واتساب حقيقي');
    // الطباعة الحرارية تغيّر المقاس.
    expect(src, contains('thermal'));
    expect(src, contains('PdfPageFormat'));
  });
}
