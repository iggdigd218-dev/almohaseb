// QA — حارس الهجرات (2026-09-24).
//
// العلة التي يستهدفها هذا الاختبار: `migrateToV24` كانت معرّفة في
// lib/core/database.dart ولا يستدعيها أحد — لا `_migrate` (آخر شرط فيه
// from < 22) ولا `ensureFullSchema` — فلم تصل أي قاعدة مُرقّاة إلى عمود
// section_id، وأول إضافة فئة كانت ترمي DatabaseException.
//
// الحارس: يقرأ مصدر database.dart نصّياً ويتحقق من شرطين:
//   1) كل دالة `migrateToV*` معرّفة ⇒ مستدعاة داخل إحدى الحاضنتين.
//   2) رقم المخطط `_version` لا يقل عن أعلى رقم هجرة معرّف.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _path = 'lib/core/database.dart';

/// يُعيد نص الدالة (من توقيعها إلى قوسها المغلق) بمطابقة الأقواس.
String _functionBody(String src, String signature) {
  final start = src.indexOf(signature);
  if (start < 0) return '';
  var depth = 0;
  var started = false;
  for (var i = start; i < src.length; i++) {
    final ch = src[i];
    if (ch == '{') {
      depth++;
      started = true;
    } else if (ch == '}') {
      depth--;
      if (started && depth == 0) return src.substring(start, i + 1);
    }
  }
  return src.substring(start);
}

void main() {
  final src = File(_path).readAsStringSync();

  test('MIG-01 كل هجرة migrateToV* مستدعاة في _migrate أو ensureFullSchema',
      () {
    final defs = RegExp(r'static Future<void>\s+(migrateToV\d+)\s*\(')
        .allMatches(src)
        .map((m) => m.group(1)!)
        .toSet()
        .toList()
      ..sort();
    expect(defs, isNotEmpty, reason: 'لم يُعثر على أي هجرة — تغيّر المصدر؟');

    final migrateBody = _functionBody(src, '_migrate(Database db');
    final ensureBody = _functionBody(src, 'ensureFullSchema(Database db');
    expect(migrateBody, isNotEmpty);
    expect(ensureBody, isNotEmpty);

    for (final d in defs) {
      expect(migrateBody.contains(d) || ensureBody.contains(d), isTrue,
          reason: '«$d» معرّفة ولا يستدعيها أحد ⇒ هجرة معلّقة: أي قاعدة '
              'مُرقّاة لن تصل مخططها (تكرار علة section_id). '
              'أضف شرطاً في _migrate أو نداءً في ensureFullSchema.');
    }
  });

  test('MIG-02 رقم المخطط يغطي أعلى هجرة معرّفة', () {
    final nums = RegExp(r'static Future<void>\s+migrateToV(\d+)\s*\(')
        .allMatches(src)
        .map((m) => int.parse(m.group(1)!))
        .toList();
    final maxV = nums.reduce((a, b) => a > b ? a : b);
    final m = RegExp(r'static const int _version = (\d+);').firstMatch(src);
    expect(m, isNotNull, reason: 'لم يُعثر على _version');
    final version = int.parse(m!.group(1)!);
    expect(version, greaterThanOrEqualTo(maxV),
        reason: '_version = $version بينما أعلى هجرة V$maxV ⇒ '
            'مسار onUpgrade لن يصلها أبداً.');
  });

  test('MIG-03 أعمدة الفئات الأساسية موجودة في التعريف وفي الترميم', () {
    // التعريف (onCreate).
    final create = RegExp(
      r'CREATE TABLE IF NOT EXISTS item_categories \((.*?)\)\)',
      dotAll: true,
    ).firstMatch(src);
    expect(create, isNotNull);
    final createBody = create!.group(1)!;
    for (final col in ['parent_id', 'section_id', 'deleted_at']) {
      expect(createBody.contains(col), isTrue,
          reason: 'عمود $col غائب عن تعريف item_categories');
    }
    expect(createBody.contains('ON DELETE SET NULL'), isTrue,
        reason: 'parent_id يجب أن يفك الربط (SET NULL) لا أن يمحو الأبناء '
            '(CASCADE) — حذف متتالٍ بلا عمليات مزامنة يخالف بقية الأجهزة.');

    // الترميم الذاتي (onOpen).
    final heal = _functionBody(src, 'ensureItemCategoryColumns(Database db');
    expect(heal, isNotEmpty);
    for (final col in [
      'parent_id',
      'section_id',
      'deleted_at',
      'deleted_by',
      'restore_op_id',
    ]) {
      expect(heal.contains("'$col'"), isTrue,
          reason: 'عمود $col غير مُرمَّم ذاتياً في ensureItemCategoryColumns');
    }
  });

  test('MIG-04 الفهارس الحيوية منشأة في مسار الترميم', () {
    final heal = _functionBody(src, 'ensureItemCategoryColumns(Database db');
    for (final idx in [
      'idx_item_cat_ws',
      'idx_items_qty',
      'idx_items_price',
      'idx_item_cat_parent',
      'idx_cat_section',
    ]) {
      expect(heal.contains(idx), isTrue, reason: 'الفهرس $idx غير منشأ');
    }
  });
}
