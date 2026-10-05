import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// كائن الخطأ المترجم والمفصل للمزامنة وقاعدة البيانات.
class LocalizedSyncError {
  final String arabicTitle;
  final String arabicExplanation;
  final String rawException;
  final String? sqlQuery;
  final List<Object?>? sqlArgs;
  final DateTime timestamp;

  LocalizedSyncError({
    this.arabicTitle = 'تنبيه تعثر المزامنة / الحفظ',
    required this.arabicExplanation,
    required this.rawException,
    this.sqlQuery,
    this.sqlArgs,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// التقرير الفني الشامل القابل للنسخ والمشاركة مع الدعم الفني.
  String get fullTechnicalReport {
    final b = StringBuffer();
    b.writeln('─── تقرير خطأ المزامنة وقاعدة البيانات ───');
    b.writeln('الوقت: ${timestamp.toIso8601String()}');
    b.writeln('العنوان: $arabicTitle');
    b.writeln('الشرح للمستخدم: $arabicExplanation');
    b.writeln('');
    b.writeln('─── التفاصيل التقنية البرمجية (Raw Details) ───');
    b.writeln('الاستثناء (Raw Exception):');
    b.writeln(rawException);
    if (sqlQuery != null && sqlQuery!.trim().isNotEmpty) {
      b.writeln('');
      b.writeln('استعلام SQL المنفذ:');
      b.writeln(sqlQuery);
    }
    if (sqlArgs != null && sqlArgs!.isNotEmpty) {
      b.writeln('');
      b.writeln('المعاملات والقيم الممررة (Args):');
      b.writeln(sqlArgs.toString());
    }
    return b.toString();
  }

  /// تدوين الخطأ في ملف سجل محلي داخل التطبيق (`sync_errors.log`).
  Future<void> appendToLogFile() async {
    try {
      Directory? dir;
      try {
        dir = await getApplicationDocumentsDirectory();
      } catch (_) {
        dir = Directory.systemTemp;
      }
      final file = File('${dir.path}/sync_errors.log');
      final entry = '$fullTechnicalReport\n═══════════════════════════════════════════════\n\n';
      await file.writeAsString(entry, mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}

/// طبقة ترجمة استثناءات SQLite والمزامنة إلى العربية (Error Localization Mapper).
class ErrorLocalizationMapper {
  /// تحويل أي استثناء إلى كائن مترجم ومفصل مع تدوينه تلقائياً في السجل.
  static LocalizedSyncError map(
    Object error, {
    String? sqlQuery,
    List<Object?>? sqlArgs,
    String? customTitle,
  }) {
    final raw = error.toString();
    final explanation = translate(raw);
    final localized = LocalizedSyncError(
      arabicTitle: customTitle ?? 'تنبيه تعثر المزامنة / الحفظ',
      arabicExplanation: explanation,
      rawException: raw,
      sqlQuery: sqlQuery,
      sqlArgs: sqlArgs,
    );
    // تدوين غير متزامن في الخلفية دون تعطيل واجهة المستخدم
    localized.appendToLogFile();
    return localized;
  }

  /// ترجمة نص رسالة الخطأ الإنجليزية إلى شرح عربي مفهوم ودقيق.
  static String translate(String message) {
    final lower = message.toLowerCase();

    // 1. تعارض القيود الفريدة (UNIQUE constraint failed)
    if (lower.contains('unique constraint failed') ||
        lower.contains('unique constraint violation') ||
        lower.contains('code 2067')) {
      return 'تعذر الحفظ لوجود سجل مسبق مسجل بنفس القيمة (الاسم أو المعرّف مستخدم بالفعل في النظام).';
    }

    // 2. تعارض العلاقات والربط (FOREIGN KEY constraint failed)
    if (lower.contains('foreign key constraint failed') ||
        lower.contains('foreign key violation') ||
        lower.contains('code 787')) {
      return 'تعذر الحذف أو التعديل لارتباط هذا السجل بعمليات أو فواتير أخرى داخل قاعدة البيانات.';
    }

    // 3. الحقول الإلزامية (NOT NULL constraint failed)
    if (lower.contains('not null constraint failed') ||
        lower.contains('not null constraint') ||
        lower.contains('code 1299')) {
      return 'تعذر إتمام العملية لوجود بيانات أساسية مطلوبة تركت فارغة.';
    }

    // 4. قفل قاعدة البيانات (database is locked / busy)
    if (lower.contains('database is locked') ||
        lower.contains('database_locked') ||
        lower.contains('database table is locked') ||
        lower.contains('database busy') ||
        lower.contains('code 5')) {
      return 'قاعدة البيانات مشغولة حالياً بعملية مزامنة أو حفظ أخرى، يرجى الانتظار ثوانٍ والمحاولة مجدداً.';
    }

    // 5. انقطاع شبكة السيرفر (SocketException / Timeout / Network error)
    if (lower.contains('socketexception') ||
        lower.contains('timeoutexception') ||
        lower.contains('timed out') ||
        lower.contains('timeout') ||
        lower.contains('network error') ||
        lower.contains('failed host lookup') ||
        lower.contains('clientexception') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('network is unreachable') ||
        lower.contains('preflight') ||
        lower.contains('500') ||
        lower.contains('502') ||
        lower.contains('503')) {
      return 'فشل الاتصال بخادم المزامنة؛ يرجى التحقق من اتصال الإنترنت والمحاولة لاحقاً.';
    }

    // 6. أي خطأ غير مدرج
    return 'حدث خطأ غير متوقع أثناء معالجة البيانات، يرجى تكرار المحاولة أو إبلاغ الدعم الفني.';
  }
}
