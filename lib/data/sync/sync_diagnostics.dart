// (3.71.0) محرك التشخيص الصريح للمزامنة — Sync Diagnostics.
//
// خدمة مستقلة ترتبط بمحركات المزامنة الفعلية (دفع processQueue، السحب
// الدوري _periodicCloudPull، وسحب SSE الفوري) وتسجل بصدق كامل:
//  - حالة الإرسال: عدد المعلق/الفاشل في sync_queue، وقت ونتيجة آخر دفعة،
//    وآخر استثناء دفع مع مصدره المصنَّف.
//  - حالة الاستقبال: وقت آخر سحب ناجح وعدد العمليات المطبقة، وآخر
//    استثناء سحب مع مصدره المصنَّف.
//  - مصنف الأعطال: كود التطبيق (FormatException/DatabaseException/
//    TypeError/CastError/Null-check) ← «خطأ داخلي في كود التطبيق» مع
//    الدالة/الجدول المتأثر؛ السحابة (401/403/Permission Denied) ←
//    «رفض من خوادم السحابة (Firebase Rules / Token)»؛ الشبكة
//    (SocketException/TimeoutException/500/502/503) ← «تعذر الاتصال
//    بالإنترنت أو عدم استجابة السيرفر».
//
// الواجهة تستمع عبر ValueNotifier واحد — تحديث الأسهم لا يعيد بناء
// الشاشة أبداً (ValueListenableBuilder محلي داخل الودجت).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show Database, DatabaseException;

import 'error_localization_mapper.dart';

/// مصدر الخلل المصنَّف — يُعرض كوسم صريح في ورقة التشخيص.
enum SyncFaultSource { none, appCode, cloud, network }

extension SyncFaultSourceLabel on SyncFaultSource {
  /// وسم المصدر المختصر: [المصدر: كود التطبيق / السحابة / الشبكة].
  String get tag => switch (this) {
        SyncFaultSource.appCode => 'كود التطبيق',
        SyncFaultSource.cloud => 'السحابة (القواعد/الجلسة)',
        SyncFaultSource.network => 'الشبكة/الاتصال',
        SyncFaultSource.none => '',
      };

  /// عنوان التصنيف الصريح كما يقرأه المستخدم.
  String get headline => switch (this) {
        SyncFaultSource.appCode => 'خطأ داخلي في كود التطبيق',
        SyncFaultSource.cloud =>
          'رفض من خوادم السحابة (Firebase Rules / Token) — القواعد لا '
              'تسمح بالوصول أو الجلسة غير مصرَّحة',
        SyncFaultSource.network =>
          'تعذر الاتصال بالإنترنت أو عدم استجابة السيرفر',
        SyncFaultSource.none => '',
      };
}

/// لقطة ثابتة (immutable) لكامل حالة التشخيص — تُبث عبر ValueNotifier.
class SyncDiagnosticsSnapshot {
  // ── الإرسال (↑) ──
  final bool pushing;
  final int pendingCount;
  final int failedCount;
  final DateTime? lastPushAt;
  final bool lastPushOk;
  final String? lastPushError;
  final SyncFaultSource lastPushFault;
  final String lastPushCtx;

  // ── الاستقبال (↓) ──
  final bool pulling;
  final DateTime? lastPullAt;
  final bool lastPullOk;
  final int lastPullApplied;
  final String? lastPullError;
  final SyncFaultSource lastPullFault;
  final String lastPullCtx;
  final LocalizedSyncError? lastLocalizedError;

  // ── تطابق الكتالوج بين الأجهزة (حسابات، أصناف، أقسام) ──
  final bool catalogMismatch;
  final String? catalogMismatchDetails;

  const SyncDiagnosticsSnapshot({
    this.pushing = false,
    this.pendingCount = 0,
    this.failedCount = 0,
    this.lastPushAt,
    this.lastPushOk = false,
    this.lastPushError,
    this.lastPushFault = SyncFaultSource.none,
    this.lastPushCtx = '',
    this.pulling = false,
    this.lastPullAt,
    this.lastPullOk = false,
    this.lastPullApplied = 0,
    this.lastPullError,
    this.lastPullFault = SyncFaultSource.none,
    this.lastPullCtx = '',
    this.lastLocalizedError,
    this.catalogMismatch = false,
    this.catalogMismatchDetails,
  });

  /// إرسال معتل: عمليات فشلت فعلاً أو آخر دفعة انتهت بخطأ.
  bool get uploadFaulted =>
      failedCount > 0 || (lastPushError ?? '').isNotEmpty;

  /// استقبال معتل: آخر دورة سحب انتهت بخطأ أو عدم تطابق في الكتالوج.
  bool get downloadFaulted =>
      (lastPullError ?? '').isNotEmpty || catalogMismatch;

  /// الاتصال مستقر: لا أعطال إرسال ولا استقبال وتطابق تام بين الأجهزة.
  bool get stable =>
      !uploadFaulted && !downloadFaulted && !catalogMismatch;
}

/// الخدمة المفردة — المحرك يغذيها، والواجهة تستمع لها.
class SyncDiagnostics {
  SyncDiagnostics._();

  static final SyncDiagnostics instance = SyncDiagnostics._();

  final ValueNotifier<SyncDiagnosticsSnapshot> notifier =
      ValueNotifier<SyncDiagnosticsSnapshot>(const SyncDiagnosticsSnapshot());

  SyncDiagnosticsSnapshot get snapshot => notifier.value;

  // حالة داخلية mutable — تُبث كلقطة ثابتة مع كل تغيير.
  bool _pushing = false;
  bool _pushErrInCycle = false;
  int _pending = 0;
  int _failed = 0;
  DateTime? _lastPushAt;
  bool _lastPushOk = false;
  String? _lastPushError;
  SyncFaultSource _lastPushFault = SyncFaultSource.none;
  String _lastPushCtx = '';

  bool _pulling = false;
  DateTime? _lastPullAt;
  bool _lastPullOk = false;
  int _lastPullApplied = 0;
  String? _lastPullError;
  SyncFaultSource _lastPullFault = SyncFaultSource.none;
  String _lastPullCtx = '';
  LocalizedSyncError? _lastLocalizedError;

  bool _catalogMismatch = false;
  String? _catalogMismatchDetails;

  void setCatalogMismatch(bool mismatch, {String? details}) {
    if (_catalogMismatch == mismatch && _catalogMismatchDetails == details) return;
    _catalogMismatch = mismatch;
    _catalogMismatchDetails = details;
    _emit();
  }

  void recordLocalizedError(LocalizedSyncError err) {
    _lastLocalizedError = err;
    _emit();
  }

  void _emit() {
    notifier.value = SyncDiagnosticsSnapshot(
      pushing: _pushing,
      pendingCount: _pending,
      failedCount: _failed,
      lastPushAt: _lastPushAt,
      lastPushOk: _lastPushOk,
      lastPushError: _lastPushError,
      lastPushFault: _lastPushFault,
      lastPushCtx: _lastPushCtx,
      pulling: _pulling,
      lastPullAt: _lastPullAt,
      lastPullOk: _lastPullOk,
      lastPullApplied: _lastPullApplied,
      lastPullError: _lastPullError,
      lastPullFault: _lastPullFault,
      lastPullCtx: _lastPullCtx,
      lastLocalizedError: _lastLocalizedError,
      catalogMismatch: _catalogMismatch,
      catalogMismatchDetails: _catalogMismatchDetails,
    );
  }

  // ==================== التصنيف الحقيقي للأعطال ====================

  static final RegExp _cloudRx = RegExp(
      r'cloud-auth-failed|cloud-http-4\d\d|\b40[13]\b|'
      r'permission[ _\-]?denied|unauthorized|forbidden',
      caseSensitive: false);
  static final RegExp _networkRx = RegExp(
      r'cloud-http-5\d\d|\b50[023]\b|failed host lookup|preflight|'
      r'connection (?:refused|reset|closed)|network is unreachable|'
      r'timed?[ _\-]?out|socket',
      caseSensitive: false);
  static final RegExp _appRx = RegExp(
      r'database_closed|database is locked|no such (?:table|column)|'
      r'constraint (?:failed|violation)|DatabaseException',
      caseSensitive: false);

  /// مصنف الأعطال: نوع الاستثناء أولاً (أدق)، ثم أنماط الرسالة.
  /// أي استثناء داخلي غير مصنَّف يسقط لـ«كود التطبيق» — فالاستثناء
  /// بحد ذاته خلل برمجي مهما كان نصه.
  static SyncFaultSource classify(Object? error) {
    if (error == null) return SyncFaultSource.none;
    if (error is SocketException || error is TimeoutException) {
      return SyncFaultSource.network;
    }
    if (error is FormatException ||
        error is TypeError ||
        error is DatabaseException) {
      // TypeError يغطي CastError وفشل عامل Null-check معاً.
      return SyncFaultSource.appCode;
    }
    final s = error.toString();
    if (_cloudRx.hasMatch(s)) return SyncFaultSource.cloud;
    if (_networkRx.hasMatch(s)) return SyncFaultSource.network;
    if (_appRx.hasMatch(s)) return SyncFaultSource.appCode;
    return SyncFaultSource.appCode;
  }

  /// استخراج الجدول/الدالة المتأثرة من رسالة خطأ القاعدة — «تحديد اسم
  /// الدالة أو الجدول المتأثر» لخلل كود التطبيق.
  static String extractDbDetail(String message) {
    final m = RegExp(r'(?:no such (?:table|column):\s*(\w+))|'
            r'(?:table\s+(\w+))',
        caseSensitive: false)
        .firstMatch(message);
    final t = m?.group(1) ?? m?.group(2) ?? '';
    return t.isEmpty ? '' : 'الجدول المتأثر: $t';
  }

  // ==================== تغذية الإرسال (↑) ====================

  /// بداية دورة دفع (processQueue).
  void pushStarted() {
    _pushing = true;
    _pushErrInCycle = false;
    _emit();
  }

  /// استثناء دفع واحد — يُسجَّل فوراً بمصدره المصنَّف وسياقه (الدالة
  /// والجدول المتأثر).
  void recordPushError(Object error,
      {String context = '', String? sqlQuery, List<Object?>? sqlArgs}) {
    final msg = error.toString();
    final fault = classify(error);
    final detail = extractDbDetail(msg);
    _pushErrInCycle = true;
    _lastPushOk = false;
    _lastPushAt = DateTime.now();
    _lastPushError = msg;
    _lastPushFault = fault;
    _lastPushCtx = [
      if (context.isNotEmpty) context,
      if (detail.isNotEmpty) detail,
    ].join(' · ');
    _lastLocalizedError = ErrorLocalizationMapper.map(
      error,
      sqlQuery: sqlQuery,
      sqlArgs: sqlArgs,
    );
    _emit();
  }

  /// نهاية دورة دفع: نجاح الدورة يمسح آخر خطأ (الأسهم تخضرّ فوراً).
  void pushFinished() {
    _pushing = false;
    if (!_pushErrInCycle) {
      _lastPushAt = DateTime.now();
      _lastPushOk = true;
      _lastPushError = null;
      _lastPushFault = SyncFaultSource.none;
      _lastPushCtx = '';
      _lastLocalizedError = null;
    }
    _emit();
  }

  // ==================== تغذية الاستقبال (↓) ====================

  /// بداية دورة سحب (دورية أو SSE).
  void pullStarted() {
    _pulling = true;
    _emit();
  }

  /// نهاية دورة سحب بنتيجتها الصريحة: النجاح يمسح آخر خطأ ويسجل عدد
  /// العمليات المطبقة (عبر applyRemoteOperation داخل transport.pull).
  void pullFinished({
    required bool ok,
    int applied = 0,
    Object? error,
    String context = '',
    String? sqlQuery,
    List<Object?>? sqlArgs,
  }) {
    _pulling = false;
    _lastPullAt = DateTime.now();
    if (ok) {
      _lastPullOk = true;
      _lastPullApplied = applied;
      _lastPullError = null;
      _lastPullFault = SyncFaultSource.none;
      _lastPullCtx = '';
      _lastLocalizedError = null;
    } else {
      final msg = error?.toString() ?? 'فشل سحب غير معروف';
      _lastPullOk = false;
      _lastPullError = msg;
      _lastPullFault = classify(error);
      final detail = extractDbDetail(msg);
      _lastPullCtx = [
        if (context.isNotEmpty) context,
        if (detail.isNotEmpty) detail,
      ].join(' · ');
      if (error != null) {
        _lastLocalizedError = ErrorLocalizationMapper.map(
          error,
          sqlQuery: sqlQuery,
          sqlArgs: sqlArgs,
        );
      }
    }
    _emit();
  }

  /// تصفير علم النشاط فقط (شبكة أمان في finally — لا تلمس النتائج).
  void pullIdle() {
    if (_pulling) {
      _pulling = false;
      _emit();
    }
  }

  // ==================== عدّادات الطابور ====================

  /// قراءة صادقة لـ sync_queue: المعلق والفاشل لهدف السحابة.
  Future<void> refreshQueue(Database db) async {
    try {
      final p = await db.rawQuery(
          "SELECT COUNT(*) c FROM sync_queue WHERE target = 'cloud' "
          "AND status IN ('pending','syncing')");
      final f = await db.rawQuery(
          "SELECT COUNT(*) c FROM sync_queue WHERE target = 'cloud' "
          "AND status = 'failed'");
      _pending = (p.first['c'] as int?) ?? 0;
      _failed = (f.first['c'] as int?) ?? 0;
      _emit();
    } catch (_) {
      // قاعدة مغلقة/جدول غائب — اللقطة السابقة تبقى.
    }
  }

  // ==================== التقرير الفني ====================

  /// تقرير فني كامل للحافظة: الإصدار، معرف المنشأة/الجهاز، الحالتان،
  /// الأخطاء بمصادرها المصنَّفة وسياقاتها.
  /// (2026-09-22) عمليات وصلت من مساحة أخرى فأُسقطت في السحب — مؤشر
  /// «كل جهاز في مساحة منفصلة». تُقرأ من الإعدادات التي يكتبها الناقل.
  int droppedOtherWs = 0;
  String droppedOtherWsSample = '';

  String buildTechnicalReport({
    required String appVersion,
    required String workspaceId,
    required String deviceId,
    required String backendUrl,
  }) {
    final s = snapshot;
    String fault(String dir, SyncFaultSource f, String? err, String ctx) {
      if (err == null || err.isEmpty) return '$dir: لا أخطاء مسجلة';
      return '$dir:\n'
          '  [المصدر: ${f.tag}]\n'
          '  التصنيف: ${f.headline}\n'
          '${ctx.isEmpty ? '' : '  السياق: $ctx\n'}'
          '  الرسالة: $err';
    }

    return [
      '── تقرير المزامنة الفني ──',
      'الإصدار: $appVersion',
      'معرف المنشأة (المساحة): $workspaceId',
      'معرف الجهاز: $deviceId',
      'السحابة: $backendUrl',
      'الوقت: ${DateTime.now().toIso8601String()}',
      '',
      '↑ الإرسال: ${s.pushing ? 'نشط الآن' : (s.lastPushOk ? 'آخر دفعة ناجحة' : 'متعثّر')}'
          '${s.lastPushAt == null ? '' : ' — ${s.lastPushAt!.toIso8601String()}'}',
      '  المعلق في sync_queue: ${s.pendingCount} | الفاشل: ${s.failedCount}',
      fault('  آخر استثناء دفع', s.lastPushFault, s.lastPushError, s.lastPushCtx),
      '',
      '↓ الاستقبال: ${s.pulling ? 'نشط الآن' : (s.lastPullOk ? 'آخر سحب ناجح' : 'متعثّر')}'
          '${s.lastPullAt == null ? '' : ' — ${s.lastPullAt!.toIso8601String()}'}',
      '  عمليات طُبقت في آخر سحب: ${s.lastPullApplied}',
      if (droppedOtherWs > 0)
        '  ⚠️ عمليات مُهمَلة من مساحة أخرى: $droppedOtherWs'
            '${droppedOtherWsSample.isEmpty ? '' : ' (مثال: $droppedOtherWsSample)'}'
            ' — الربط بمساحة غير مساحة المجموعة',
      fault('  آخر استثناء سحب', s.lastPullFault, s.lastPullError, s.lastPullCtx),
    ].join('\n');
  }

  /// إعادة ضبط وتصفير حالة التشخيص عند حل التعارض أو الاستيراد
  void reset() {
    debugReset();
    _lastLocalizedError = null;
    _catalogMismatch = false;
    _catalogMismatchDetails = null;
    _emit();
  }

  void debugReset() {
    _pushing = false;
    _pushErrInCycle = false;
    _pending = 0;
    _failed = 0;
    _lastPushAt = null;
    _lastPushOk = false;
    _lastPushError = null;
    _lastPushFault = SyncFaultSource.none;
    _lastPushCtx = '';
    _pulling = false;
    _lastPullAt = null;
    _lastPullOk = false;
    _lastPullApplied = 0;
    _lastPullError = null;
    _lastPullFault = SyncFaultSource.none;
    _lastPullCtx = '';
    _emit();
  }
}
