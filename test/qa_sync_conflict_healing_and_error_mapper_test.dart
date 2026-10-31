// QA — اختبارات المعالجة الذكية لتعارضات المزامنة وترجمة الأخطاء التشخيصية.
//
// العقود:
//  1. ErrorLocalizationMapper: ترجمة استثناءات SQLite والشبكة إلى نصوص عربية واضحة ومحددة.
//  2. التقرير الفني: يحمل الاستثناء الخام + استعلام SQL المنفذ + المعاملات args.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora_app/data/sync/error_localization_mapper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('طبقة ترجمة استثناءات SQLite والمزامنة إلى العربية', () {
    test('MAP-01 تعارض القيود الفريدة (UNIQUE constraint failed)', () {
      const err = 'DatabaseException: UNIQUE constraint failed: item_categories.name (code 2067)';
      final loc = ErrorLocalizationMapper.map(err);
      expect(
        loc.arabicExplanation,
        'تعذر الحفظ لوجود سجل مسبق مسجل بنفس القيمة (الاسم أو المعرّف مستخدم بالفعل في النظام).',
      );
      expect(loc.rawException, err);
    });

    test('MAP-02 تعارض العلاقات والربط (FOREIGN KEY constraint failed)', () {
      const err = 'DatabaseException: FOREIGN KEY constraint failed (code 787)';
      final loc = ErrorLocalizationMapper.map(err);
      expect(
        loc.arabicExplanation,
        'تعذر الحذف أو التعديل لارتباط هذا السجل بعمليات أو فواتير أخرى داخل قاعدة البيانات.',
      );
    });

    test('MAP-03 الحقول الإلزامية (NOT NULL constraint failed)', () {
      const err = 'DatabaseException: NOT NULL constraint failed: items.name (code 1299)';
      final loc = ErrorLocalizationMapper.map(err);
      expect(
        loc.arabicExplanation,
        'تعذر إتمام العملية لوجود بيانات أساسية مطلوبة تركت فارغة.',
      );
    });

    test('MAP-04 قفل قاعدة البيانات (database is locked / busy)', () {
      const err = 'DatabaseException: database is locked (code 5)';
      final loc = ErrorLocalizationMapper.map(err);
      expect(
        loc.arabicExplanation,
        'قاعدة البيانات مشغولة حالياً بعملية مزامنة أو حفظ أخرى، يرجى الانتظار ثوانٍ والمحاولة مجدداً.',
      );
    });

    test('MAP-05 انقطاع شبكة السيرفر (SocketException / Timeout / Network)', () {
      final locSocket = ErrorLocalizationMapper.map(
        const SocketException('Failed host lookup: rtdb.firebaseio.com'),
      );
      expect(
        locSocket.arabicExplanation,
        'فشل الاتصال بخادم المزامنة؛ يرجى التحقق من اتصال الإنترنت والمحاولة لاحقاً.',
      );

      final locTimeout = ErrorLocalizationMapper.map('Connection timed out after 30000ms');
      expect(
        locTimeout.arabicExplanation,
        'فشل الاتصال بخادم المزامنة؛ يرجى التحقق من اتصال الإنترنت والمحاولة لاحقاً.',
      );
    });

    test('MAP-06 خطأ غير مدرج يظهر الشرح العام للخطأ غير المتوقع', () {
      final loc = ErrorLocalizationMapper.map('SomeUnknownCustomException: unexpected parser failure');
      expect(
        loc.arabicExplanation,
        'حدث خطأ غير متوقع أثناء معالجة البيانات، يرجى تكرار المحاولة أو إبلاغ الدعم الفني.',
      );
    });

    test('MAP-07 التقرير الفني يحمل الاستعلام وقيم المعاملات كاملة للنسخ', () {
      final loc = ErrorLocalizationMapper.map(
        'DatabaseException: UNIQUE constraint failed: item_categories.name',
        sqlQuery: 'UPDATE item_categories SET name = ? WHERE id = ?',
        sqlArgs: ['إلكترونيات', 10],
      );
      final report = loc.fullTechnicalReport;
      expect(report, contains('العنوان: تنبيه تعثر المزامنة / الحفظ'));
      expect(report, contains('UNIQUE constraint failed'));
      expect(report, contains('استعلام SQL المنفذ:'));
      expect(report, contains('UPDATE item_categories SET name = ? WHERE id = ?'));
      expect(report, contains('المعاملات والقيم الممررة (Args):'));
      expect(report, contains('[إلكترونيات, 10]'));
    });
  });

}
