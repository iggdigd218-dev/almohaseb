// خدمة النسخ الاحتياطي المحلي (تصدير/استيراد JSON).
// تُستخدم للنسخ اليدوية وللنسخة الاحتياطية التلقائية قبل Migration.
// تم فصلها عن Repo لسهولة الاختبار.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../repository.dart';

class BackupInfo {
  final File file;
  final int sizeBytes;
  final DateTime createdAt;
  const BackupInfo({
    required this.file,
    required this.sizeBytes,
    required this.createdAt,
  });
}

class BackupService {
  final Database db;
  BackupService(this.db);

  /// الجداول التي تُصدَّر في النسخة الاحتياطية (لا تشمل cache/session الحساسة).
  static const dataTables = [
    'accounts',
    'transactions',
    'vouchers',
    'currencies',
    'categories',
    'item_categories',
    'items',
    'stock_moves',
    'transaction_items',
    'users',
    'conversations',
    'messages',
    'activity',
    'notifications',
    'templates',
    'settings',
    'workspaces',
    'devices',
    'operations',
  ];

  /// الحقول الحساسة التي لا تُصدَّر في النسخة الاحتياطية.
  static const _scrubColumns = ['auth_secret', 'pair_token', 'pair_token_exp'];

  Future<File> exportToFile(File dest) async {
    final out = <String, Object?>{};
    out['format'] = 'nexora/backup';
    out['version'] = AppDatabaseSchema.version;
    out['created_at'] = DateTime.now().toIso8601String();
    final data = <String, Object?>{};
    for (final t in dataTables) {
      final rows = await db.query(t);
      // إزالة الأعمدة الحساسة من النسخة الاحتياطية (لا تُخزَّن في .nexora).
      final scrubbed = rows.map((r) {
        final copy = Map<String, Object?>.from(r);
        for (final c in _scrubColumns) {
          copy.remove(c);
        }
        return copy;
      }).toList();
      data[t] = scrubbed;
    }
    out['data'] = data;
    await dest.parent.create(recursive: true);
    await dest.writeAsString(jsonEncode(out));
    return dest;
  }

  /// ينشئ نسخة احتياطية مؤقتة (قبل migration مثلاً) ويُعيد الملف.
  Future<File> createPreMigrationBackup() async {
    final dir = await getTemporaryDirectory();
    final ts =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final f = File(p.join(dir.path, 'nexora-backup-before-migration-$ts.json'));
    return exportToFile(f);
  }

  /// استيراد من ملف backup (للاستعادة الكاملة).
  /// في المرحلة الحالية لا نقوم باستيراد داخل قاعدة مفتوحة — يعرض للمستخدم تأكيد أولاً.
  Future<Map<String, int>> inspect(File f) async {
    final text = await f.readAsString();
    final obj = jsonDecode(text);
    if (obj is! Map || obj['data'] is! Map) {
      throw const BackupImportException('ملف النسخة الاحتياطية غير صالح');
    }
    final data = obj['data'] as Map;
    final counts = <String, int>{};
    for (final t in dataTables) {
      final rows = data[t];
      if (rows is List) counts[t] = rows.length;
    }
    return counts;
  }
}

// دالة مساعدة لتجنّب circular imports بين backup_service و database.dart.
class AppDatabaseSchema {
  static const int version = 5;
}
