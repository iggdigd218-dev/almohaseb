// (2026-09-22 — قاعدة جوجل فقط)
//
// حُذف «الاسترداد الصامت ببصمة العتاد» و«الاسترداد اليدوي برمز المساحة»
// حذفاً نهائياً: بعد مسح بيانات التطبيق لا يجوز استرجاع أي بيانات إلا
// بتسجيل الدخول بحساب جوجل — المسار الوحيد هو
// AccountWorkspace.linkAccountOnly الذي يفهرس الحساب (accounts_index)
// ويجلب مساحة المؤسسة ونسختها الاحتياطية تلقائياً فور الدخول.
//
// تبقى هنا أداة ترحيل معرف المساحة (swapWorkspaceId) التي يستخدمها مسار
// التبديل الآمن عبر جوجل — وهي لا تسترجع بيانات بذاتها.
import 'package:sqflite/sqflite.dart';

class WorkspaceRecovery {
  WorkspaceRecovery._();

  /// (اختبارات) إعادة ضبط — لم يعد هناك علم فحص صامت.
  static void debugReset() {}

  /// تبديل معرف المساحة عبر كل الجداول (نفس منطق ترحيل default الآمن).
  /// يُستدعى فقط من مسار التبديل المرتبط بحساب جوجل
  /// (AccountWorkspace._switchWorkspace).
  static Future<void> swapWorkspaceId(Database db,
      {required String from, required String to}) async {
    await db.transaction((txn) async {
      final old = await txn
          .query('workspaces', where: 'id = ?', whereArgs: [from], limit: 1);
      final row = old.isNotEmpty
          ? Map<String, Object?>.from(old.first)
          : <String, Object?>{
              'name': 'متجري',
              'owner_google_id': '',
              'owner_email': '',
              'owner_name': '',
              'created_at': DateTime.now().toIso8601String(),
            };
      row['id'] = to;
      row['updated_at'] = DateTime.now().toIso8601String();
      final exists = await txn
          .query('workspaces', where: 'id = ?', whereArgs: [to], limit: 1);
      if (exists.isEmpty) await txn.insert('workspaces', row);
      final tables = await txn.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT IN ('workspaces') AND name NOT LIKE 'sqlite_%'");
      for (final t in tables) {
        final name = t['name'] as String;
        final cols = await txn.rawQuery('PRAGMA table_info($name)');
        if (!cols.any((c) => c['name'] == 'workspace_id')) continue;
        await txn.update(name, {'workspace_id': to},
            where: 'workspace_id = ?', whereArgs: [from]);
      }
      await txn.delete('workspaces', where: 'id = ?', whereArgs: [from]);
    });
  }
}
