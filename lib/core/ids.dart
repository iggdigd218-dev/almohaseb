// معرّفات عالمية (globally unique) للصفوف الجديدة.
//
// كانت الجداول تعتمد على AUTOINCREMENT، فينتج جهازان معرّفًا متطابقًا
// (1, 2, 3…) لسجلّين مختلفين فيدهس أحدهما الآخر عند المزامنة
// (Blocker QA-BLOCKER-01). الحل معرّف 63-بت على نمط Snowflake:
//
//   [ 43 بت: ميلي ثانية ] [ 12 بت: بصمة الجهاز/الجلسة ] [ 8 بت: عدّاد ]
//
//  - يبقى INTEGER فيعمل مع المخطط والمفاتيح الأجنبية الحالية دون هجرة بيانات.
//  - مرتّب زمنيًا تقريبًا (مفيد للفهارس).
//  - العدّاد يضمن عدم التكرار محليًا حتى في نفس الميلي ثانية؛ وعند امتلائه
//    نتقدّم بالساعة المنطقية بدل تكرار معرّف.
//  - بصمة الجلسة العشوائية تفصل الأجهزة عن بعضها.
import 'dart:math';

const int _saltBits = 8; // إزاحة العدّاد
const int _seqBits = 8;
const int _seqMask = (1 << _seqBits) - 1;

final int _salt = Random.secure().nextInt(1 << 12);
int _lastMs = 0;
int _seq = 0;

/// معرّف جديد صالح كـ SQLite INTEGER PRIMARY KEY (موجب دائمًا).
int newGlobalId() {
  final ms = DateTime.now().millisecondsSinceEpoch;
  if (ms > _lastMs) {
    _lastMs = ms;
    _seq = 0;
  } else {
    _seq++;
    if (_seq > _seqMask) {
      // امتلأ العدّاد داخل نفس الميلي ثانية: نتقدّم بالساعة المنطقية.
      _lastMs++;
      _seq = 0;
    }
  }
  return (_lastMs << (12 + _seqBits)) | (_salt << _saltBits) | _seq;
}
