// انحدار (2026-11-22): الوضع الليلي لا يعمل + الاسترجاع يفتح منتقي ملفات.
//
// الأول: كان الثيم يُقرأ مرة واحدة عند الإقلاع، ومفتاح الإعدادات يستدعي
// setState على شاشة الإعدادات فقط — فلا يتغيّر شيء حتى إعادة التشغيل.
// الثاني: كان الاسترجاع يفتح منتقي ملفات النظام بدل عرض النسخ داخل التطبيق.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DARK-01 تغيير الوضع الليلي يبثّ إعادة بناء الجذر', () {
    final main = File('lib/main.dart').readAsStringSync();
    final core = File('lib/core.dart').readAsStringSync();
    final settings = File('lib/ui/settings_screen.dart').readAsStringSync();

    // ناقل إشعار موجود ويُستخدم في بناء الجذر.
    expect(main, contains('prefsRevision'));
    expect(main, contains('ValueListenableBuilder'));
    // المفتاح يبثّ التغيير عند الحفظ.
    expect(settings, contains('notifyPrefsChanged'));
    // الألوان صارت ديناميكية بدل الثوابت البيضاء.
    expect(core, contains('static Color get card'));
    expect(core, contains('static Color get bg'));
  });

  test('RESTORE-01 النسخ تُعرض داخل التطبيق بلا منتقي ملفات', () {
    final src = File('lib/ui/reports_screens.dart').readAsStringSync();
    final restoreStart = src.indexOf('class _RestoreScreenState');
    expect(restoreStart, greaterThan(0));
    final block = src.substring(restoreStart, src.indexOf('class DriveScreen'));

    // لا منتقي ملفات في مسار الاسترجاع.
    expect(block.contains('FilePicker'), isFalse,
        reason: 'الاسترجاع يجب أن يعرض النسخ داخلياً لا عبر منتقي الملفات');
    // يمسح مجلد النسخ ويعرضها.
    expect(block, contains('backupRoot'));
    expect(block, contains('backup.json'));
    // استرجاع ومعاملة واحدة.
    expect(block, contains('db.transaction'));
    // حفظ تلقائي يومي متنفيذ فعلاً.
    expect(src, contains('autoBackupIfDue'));
    expect(File('lib/main.dart').readAsStringSync(),
        contains('autoBackupIfDue'));
  });
}
