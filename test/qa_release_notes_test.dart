// QA — سجل ملاحظات التحديث (Release Changelog) مقتضب: أحدث إصدار فقط،
// ثلاثة أسطر كحد أقصى، بلا أي دمج مع السجلات التاريخية.
//
// العقد بعد التنفيذ:
//  1. ملف release_notes.txt يحمل أحدث إصدار فقط — لا ترويسات إصدارات
//     قديمة (3.75.0+147، +150، +151 …) ولا سرداً تراكمياً.
//  2. العرض دائماً ثلاثة أسطر على الأكثر (clampReleaseNotes).
//  3. واجهة الإعدادات تعرض سجل الإصدار الأخير وحده: لا زر أرشيف ولا
//     نصوص تاريخية مخزّنة في الكود.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/data/update_service.dart';

const _maxLines = 3;

void main() {
  final file = File('release_notes.txt');
  final section = File('lib/ui/update_section.dart');

  List<String> nonEmptyLines(String text) => text
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  test('RN-01 ملف السجل: أحدث إصدار فقط — ٣ أسطر لا أكثر', () {
    expect(file.existsSync(), isTrue);
    final lines = nonEmptyLines(file.readAsStringSync());
    expect(lines.length, _maxLines, reason: 'السجل يجب أن يكون ٣ أسطر بالضبط');
    for (final l in lines) {
      expect(l.startsWith('•'), isTrue, reason: 'كل سطر يبدأ بنقطة: $l');
    }
    // لا ترويسة إصدار قديم (3.75.0+151) ولا سرد تاريخي متراكم.
    for (final l in lines) {
      expect(RegExp(r'^\d+\.\d+\.\d+\+\d+$').hasMatch(l), isFalse,
          reason: 'ترويسة إصدار داخل السجل: $l');
    }
    final notes = file.readAsStringSync();
    for (final old in ['3.75.0+147', '3.75.0+150', '3.75.0+151', '3.74.']) {
      expect(notes, isNot(contains(old)), reason: 'أثر إصدار قديم: $old');
    }
    // طول معقول يعرضه الحوار بلا تمرير مرهق.
    for (final l in lines) {
      expect(l.length, lessThanOrEqualTo(220));
    }
  });

  test('RN-02 الحافظ يقصّ أي سجل إلى ٣ أسطر ويُسقط ترويسات الإصدارات', () {
    const messy = '''
3.75.0+151
• ميزة قديمة جداً
3.75.0+150
• ميزة قديمة

• الأولى في أحدث إصدار
• الثانية في أحدث إصدار
• الثالثة في أحدث إصدار
• الرابعة تُحذف
• الخامسة تُحذف
''';
    final out = clampReleaseNotes(messy);
    final lines = nonEmptyLines(out);
    expect(lines.length, _maxLines);
    // الترويسات القديمة تُسقط (ليست ميزات) أما نصّ السجل فيُقصّ بأثره.
    expect(out, isNot(contains('3.75.0+151')));
    expect(out, isNot(contains('3.75.0+150')));
    expect(lines.first, contains('ميزة قديمة جداً'));
    expect(lines.last, contains('الأولى في أحدث إصدار'));
    // الزائد بعد الثالث يُحذف.
    expect(out, isNot(contains('الثالثة في أحدث إصدار')));
    // idempotent: تطبيقه مرتين لا يغيّر النتيجة.
    expect(clampReleaseNotes(out), out);
  });

  test('RN-03 الحافظ يتعامل مع الفراغ والأسطر الفارغة وحدّ مخصّص', () {
    expect(clampReleaseNotes(''), '');
    expect(clampReleaseNotes('   \n\n  '), '');
    expect(nonEmptyLines(clampReleaseNotes('• أ\n\n• ب\n• ج\n• د')).length, 3);
    expect(nonEmptyLines(clampReleaseNotes('• أ\n• ب\n• ج', maxLines: 2)).length,
        2);
    // أسطر بلا رمز نقطة تُقبل كما هي (لا تُفقد).
    expect(clampReleaseNotes('بلا نقطة'), 'بلا نقطة');
  });

  test('RN-04 قائمة العرض: ٣ عناصر بلا رمز النقطة في أولها', () {
    final items = releaseNoteLines(file.readAsStringSync());
    expect(items.length, 3);
    for (final it in items) {
      expect(it.startsWith('•'), isFalse);
      expect(it.trim().isNotEmpty, isTrue);
    }
  });

  test('RN-05 الواجهة: لا أرشيف تاريخي ولا دمج للسجلات السابقة', () {
    final src = section.readAsStringSync();
    // الأرشيف المخزّن في الكود ونافذته أُزيلا بالكامل.
    expect(src, isNot(contains('kReleaseNotesArchive')));
    expect(src, isNot(contains('showReleaseNotesArchiveDialog')));
    expect(src, isNot(contains('سجل الإصدارات السابقة')));
    // لا نص تاريخي قديم داخل الكود.
    for (final old in ['3.64.3', '3.63.0', '3.61.0']) {
      expect(src, isNot(contains(old)), reason: 'أرشيف قديم: $old');
    }
    // العرض يمرّ عبر الحافظ (٣ أسطر) في بطاقة الإعدادات وحوار التحديث.
    expect(src, contains('_ReleaseNotesList'));
    // حوار «الجديد في هذا التحديث» يستخدم نفس القاعدة.
    expect(src, contains('releaseNoteLines(notes)'));
  });

  test('RN-06 سير العمل يقصّ السجل عند التوليد (دفاع دائم)', () {
    final wf = File('.github/workflows/build-flutter-apk.yml').readAsStringSync();
    expect(wf, contains('release_notes.txt'));
    expect(wf, contains('lines[:3]'), reason: 'لا قصّ عند ٣ أسطر في التوليد');
  });
}
