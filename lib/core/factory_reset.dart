// (دفعة 52) إعادة ضبط المصنع لنسخة سطح المكتب:
// حذف ملف قاعدة البيانات نفسه من القرص (nexora.db + wal/shm) بعد إغلاق
// الاتصال — الحل الجذري للبيانات القديمة العالقة التي لا يمكن تنظيفها
// يدوياً على ويندوز، ثم إقلاع نظيف من شاشة الترحيب.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'database.dart';
import 'db_init.dart';
import 'media_paths.dart';

class FactoryReset {
  FactoryReset._();

  /// اسم ملف النسخة الصامتة قبل الانضمام إلى مؤسسة.
  static const String kBackupBeforeJoining = 'backup_before_joining.nexora';

  /// اسم ملف النسخة الصامتة قبل تبديل الحساب إلى مؤسسة أخرى.
  static const String kBackupBeforeSwitch = 'pre_switch_backup.nexora';

  /// (دفعة 65) الجداول المحاسبية وحدها — كل ما يمثل «حسابات الموظف
  /// الشخصية» قبل الانضمام. الترتيب حاسم: الأبناء قبل الآباء احتراماً
  /// لقيود المفتاح الأجنبي.
  /// لا تُمسّ: settings، sync_meta، devices، google_auth، workspaces،
  /// users، currencies — هوية الجهاز وإعداداته تبقى سليمة.
  static const List<String> kAccountingTables = <String>[
    'transaction_items', // ابن transactions/items
    'stock_moves',       // ابن items
    'messages',          // ابن conversations
    'transactions',
    'vouchers',
    'items',
    'item_categories',
    'categories',
    'sections',
    'conversations',
    'trash',
    'activity',
    'notifications',
    'templates',
    'operations',
    'sync_queue',
    'accounts',
    'currencies',
  ];

  /// (دفعة 65) تفريغ الجداول المحاسبية مع **الإبقاء** على هوية الجهاز
  /// وإعداداته. يُستخدم عند الانضمام لمؤسسة أو تبديل الحساب، لمنع تداخل
  /// حركات الموظف السابقة مع حسابات المتجر.
  /// تُعيد عدد الجداول التي فُرّغت فعلاً.
  static Future<int> wipeAccountingTables(Database db) async {
    var wiped = 0;
    for (final table in kAccountingTables) {
      try {
        await db.delete(table);
        wiped++;
      } catch (e) {
        // جدول غير موجود في هذا المخطط — يُتجاوز بلا أثر.
        debugPrint('FactoryReset: wipe $table: $e');
      }
    }
    return wiped;
  }

  /// (دفعة 65) نسخة احتياطية **صامتة** قبل عملية مُدمّرة (الانضمام أو
  /// التبديل). تُكتب في مجلد النسخ داخل مستندات التطبيق — وهو المجلد
  /// نفسه الذي يحفظ فيه المستخدم نسخه، فتظهر له في قائمة الاستعادة.
  /// تُعيد null عند الفشل: الفشل هنا **أفضل جهد** ولا يمنع العملية،
  /// لأن حبس المستخدم عن الانضمام أسوأ من احتمال غياب النسخة.
  static Future<File?> silentBackup(
    Map<String, dynamic> data, {
    required String fileName,
  }) async {
    try {
      final docs = await MediaPaths.ensureDocsDir();
      if (docs == null) return null;
      final dir = Directory(p.join(docs, 'backups'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File(p.join(dir.path, fileName));
      final json = const JsonEncoder.withIndent('  ').convert(data);
      await file.writeAsString(json, flush: true);
      return file;
    } catch (e) {
      debugPrint('FactoryReset: silentBackup: $e');
      return null;
    }
  }

  /// ينفّذ التصفير الكامل. يعيد قائمة بما حُذف (للتشخيص).
  /// الترتيب حاسم:
  ///  1) إغلاق اتصال SQLite (وإلا يقفل ويندوز الملف ويمنع حذفه).
  ///  2) حذف nexora.db و nexora.db-wal و nexora.db-shm.
  ///  3) حذف وسائط الدردشة والمرفقات من مجلد المستندات.
  /// بعدها يجب على المستدعي إعادة تشغيل حالة التطبيق (شاشة الترحيب).
  static Future<List<String>> wipeAllLocalData() async {
    final deleted = <String>[];
    // 1) أغلق القاعدة أولاً — ويندوز يقفل الملفات المفتوحة.
    try {
      await AppDatabase.instance.close();
    } catch (e) {
      debugPrint('FactoryReset: close db: $e');
    }
    // 2) احذف ملفات القاعدة الثلاثة.
    try {
      final dir = await databaseDirectory();
      for (final name in const [
        'nexora.db',
        'nexora.db-wal',
        'nexora.db-shm',
        'nexora.db-journal',
      ]) {
        final f = File(p.join(dir, name));
        if (await f.exists()) {
          await f.delete();
          deleted.add(name);
        }
      }
    } catch (e) {
      debugPrint('FactoryReset: delete db files: $e');
      rethrow; // فشل حذف القاعدة = فشل التصفير — لا نتظاهر بالنجاح.
    }
    // 3) وسائط الدردشة/المرفقات (أفضل جهد — غيابها لا يفشل التصفير).
    try {
      final docs = await MediaPaths.ensureDocsDir();
      if (docs != null) {
        for (final sub in const ['chat_media', 'attachments', 'backups']) {
          final d = Directory(p.join(docs, sub));
          if (await d.exists()) {
            await d.delete(recursive: true);
            deleted.add('$sub/');
          }
        }
      }
    } catch (e) {
      debugPrint('FactoryReset: media wipe: $e');
    }
    return deleted;
  }
}
