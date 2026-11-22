// انحدار (2026-11-21): «الإعدادات لا تستجيب عند تفعيل أي خيار».
//
// السبب الجذري: كل مفاتيح الإعدادات تحفظ القيمة عبر setSetting ثم تكتفي
// بـ setState، بينما الشاشة تقرأ القيم من `settingsProvider`. بلا إبطال
// المزوّد تبقى القيمة القديمة في الذاكرة فيُعاد رسم المفتاح على حالته
// السابقة — فيبدو التفعيل بلا أثر إطلاقاً.
//
// هذا الحارس يفحص المصدر: كل دالة تحفظ إعداداً يجب أن تُبطل المزوّد.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SET-REACT-01 كل حفظ إعداد يُبطل settingsProvider', () {
    final src = File('lib/ui/settings_screen.dart').readAsStringSync();

    // عدد مرات الحفظ يجب ألا يتجاوز عدد الإبطالات + الحفظات المتتالية
    // التي يغطيها إبطال واحد بعدها (حفظ البيانات الشخصية: 5 مفاتيح).
    final saves = 'setSetting('.allMatches(src).length;
    final invalids = 'invalidate(settingsProvider)'.allMatches(src).length;

    expect(saves, greaterThan(0));
    expect(invalids, greaterThan(0),
        reason: 'يجب إبطال settingsProvider بعد الحفظ وإلا لا تظهر القيمة');

    // لا يوجد حفظ «يتيم» بعيد عن أي إبطال: كل كتلة حفظ يجب أن يتبعها
    // إبطال خلال الأسطر العشرة التالية (الحفظ المتتالي مغطّى بإبطال واحد).
    final lines = src.split('\n');
    final orphans = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].contains('setSetting(')) continue;
      final window = lines
          .sublist(i, (i + 11).clamp(0, lines.length))
          .join('\n');
      if (!window.contains('invalidate(settingsProvider)')) {
        orphans.add(i + 1);
      }
    }
    // الحفظ المتتالي في _save وكتلة الأمان: كل ما بعد آخر حفظ مغطّى.
    expect(orphans, isEmpty,
        reason: 'حفظ إعداد بلا إبطال — المفتاح لن يستجيب: أسطر $orphans');
  });

  test('SET-REACT-02 شاشة المظهر تُبطل المزوّد أيضاً', () {
    final src = File('lib/ui/appearance_screen.dart').readAsStringSync();
    expect(src, contains('invalidate(settingsProvider)'));
  });
}
