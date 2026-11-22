// (3.70) خدمة النسخ الاحتياطي التلقائي — المسار الوحيد للنسخ خارج طابور المزامنة.
//
// تستوعب ثلاثي «النسخ الصامت» من cloud_sync.dart القديم (المجتث) وتوسّعه:
//  • نسخة السحابة الخاصة (RTDB workspaces/{ws}/backup.json): للمؤسسة،
//    مقيدة بالتجربة/الاشتراك الساري — تُحجب تلقائياً بعد الانتهاء.
//  • (جديد) جدولة يختارها المستخدم: [كل ساعتين / يومياً في وقت محدد].
//  • (جديد) لقطة SQLite محلية آمنة: backup_{store_id}_{timestamp}.db.
//  • (جديد) وجهة Google Drive مجانية ودائمة للجميع (فردي ومؤسسة) —
//    لا تُحجب أبداً بانتهاء التجربة.
//
// الحساب الفردي: لقطة محلية + Drive فقط — بلا شبكة سحابية خاصة وبلا طابور.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/app_version.dart';
import '../../core/cloud_config.dart';
import '../google_drive_service.dart';
import '../repository.dart';
import 'firebase_auth_service.dart';
import 'subscription_guard.dart';

class AutoBackupService {
  AutoBackupService._();

  /// أقصى فترة بين نسختين سحابيتين صامتتين (المعمارية الصامتة الأصلية).
  static const silentBackupInterval = Duration(hours: 24);

  // ---- مفاتيح جدولة النسخ التلقائي (الإعدادات) ----
  static const kModeKey = 'backup.auto.mode'; // off | every2h | daily
  static const kTimeKey = 'backup.auto.time'; // HH:mm — لوضع «يومياً»
  static const kDriveKey = 'backup.auto.drive'; // 1|0 — وجهة Drive
  static const kLastScheduledKey = 'backup.auto.lastAt';

  // ==================== الثلاثي الصامت (منقول حرفياً) ====================

  static Future<bool> silentBackupDue(Repo repo) async {
    final st = await repo.settings();
    final last = DateTime.tryParse(st['lastSilentBackupAt'] ?? '');
    if (last == null) return true;
    return DateTime.now().difference(last) >= silentBackupInterval;
  }

  /// يرفع نسخة كاملة صامتة لمسار مساحة العمل — أفضل جهد: أي فشل يُبتلع
  /// (شبكة غائبة/اشتراك منتهٍ) وتُعاد المحاولة في الدورة القادمة.
  /// 🔒 مقيدة بالتجربة/الاشتراك: الانتهاء يحجب السحابة الخاصة تلقائياً.
  static Future<bool> silentWorkspaceBackup(Repo repo,
      {bool force = false}) async {
    try {
      final st = await repo.settings();
      final url = effectiveBackendUrl(st['cloudBackendUrl']);
      if (url.isEmpty) return false;
      // ══ (2026-09-22) النسخ الاحتياطي عبر حساب جوجل فقط ══
      // بلا بريد حساب جوجل مربوط لا تُكتب أي نسخة سحابية، وجهاز العضو
      // لا ينسخ إطلاقاً — نسخة المجموعة يكتبها جهاز المدير وحده.
      final mode = await repo.workspaceMode();
      if (mode == 'member') return false;
      if ((st['account.email'] ?? '').trim().isEmpty) return false;
      final ws = await repo.activeWorkspaceId();
      if (!force) {
        final blocked = await SubscriptionGuard.isBlocked(repo,
            backendUrl: url, workspaceId: ws);
        if (blocked) return false;
      }
      final payload = await repo.exportAll(withImages: false, localOnly: true);
      final now = DateTime.now();
      final rec = {
        'app': 'sijil',
        'appVersion': '$kAppVersion+$kAppBuild',
        'workspaceId': ws,
        'updatedAt': now.toIso8601String(),
        'updatedAtLocal': now.toLocal().toString(),
        'sizeKb':
            '${(jsonEncode(payload).length / 1024).toStringAsFixed(1)} KB',
        'payload': payload,
      };
      final root = url.replaceAll(RegExp(r'/+$'), '');
      await _requestJson(
        '$root/workspaces/${Uri.encodeComponent(ws)}/backup.json',
        method: 'PUT',
        body: rec,
      );
      await repo.setSetting('lastSilentBackupAt', now.toIso8601String());
      await repo.setSetting('lastCloudSync', now.toLocal().toString());
      return true;
    } catch (_) {
      return false;
    }
  }

  /// سحب النسخة الصامتة لمساحة محددة — يُستخدم في الاسترداد الذاتي عند
  /// الإقلاع والاسترداد اليدوي وتبديل الحساب. null إن لم توجد نسخة.
  static Future<Map<String, Object?>?> pullWorkspaceBackup(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
  }) async {
    final root = backendUrl.replaceAll(RegExp(r'/+$'), '');
    Map<String, dynamic>? rec;
    try {
      rec = await _requestJson(
          '$root/workspaces/${Uri.encodeComponent(workspaceId)}/backup.json');
    } catch (_) {
      return null;
    }
    final payload = rec?['payload'];
    if (payload is! Map) return null;
    final map = Map<String, Object?>.from(payload);
    final data = map['data'];
    if (data is! Map || data.isEmpty) return null;
    return map;
  }

  static Uri _withAuth(String target, String? token) {
    final u = Uri.parse(target);
    if (token == null || token.isEmpty) return u;
    return u.replace(queryParameters: {...u.queryParameters, 'auth': token});
  }

  static Future<Map<String, dynamic>?> _requestJson(
    String target, {
    String method = 'GET',
    Object? body,
  }) async {
    var uri = _withAuth(target, FirebaseAuthRest.cachedIdToken);
    final headers = {'Content-Type': 'application/json'};
    var res = method == 'PUT'
        ? await http
            .put(uri, headers: headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 60))
        : await http.get(uri, headers: headers).timeout(
            const Duration(seconds: 30));
    if (res.statusCode == 401 || res.statusCode == 403) {
      final fresh = await FirebaseAuthRest.cloudIdToken();
      if (fresh != null && fresh.isNotEmpty) {
        uri = _withAuth(target, fresh);
        res = method == 'PUT'
            ? await http
                .put(uri, headers: headers, body: jsonEncode(body))
                .timeout(const Duration(seconds: 60))
            : await http.get(uri, headers: headers).timeout(
                const Duration(seconds: 30));
      }
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Cloud HTTP ${res.statusCode}');
    }
    final text = utf8.decode(res.bodyBytes).trim();
    if (text.isEmpty || text == 'null') return null;
    return jsonDecode(text) as Map<String, dynamic>;
  }

  // ==================== الجدولة الجديدة (3.70) ====================

  /// هل حان موعد النسخ المجدول؟ off ⇒ أبداً. every2h ⇒ كل ساعتين من آخر
  /// تشغيل. daily ⇒ بعد مرور وقت اليوم المحدد (HH:mm) دون تشغيل لاحق له.
  static Future<bool> scheduledDue(Repo repo) async {
    final st = await repo.settings();
    final mode = st[kModeKey] ?? 'off';
    if (mode != 'every2h' && mode != 'daily') return false;
    final last = DateTime.tryParse(st[kLastScheduledKey] ?? '');
    final now = DateTime.now();
    if (mode == 'every2h') {
      return last == null || now.difference(last) >= const Duration(hours: 2);
    }
    final parts = (st[kTimeKey] ?? '02:00').split(':');
    final hh = int.tryParse(parts.isNotEmpty ? parts[0].trim() : '') ?? 2;
    final mm = int.tryParse(parts.length > 1 ? parts[1].trim() : '') ?? 0;
    final today = DateTime(now.year, now.month, now.day, hh, mm);
    final dueAt = now.isBefore(today)
        ? today.subtract(const Duration(days: 1))
        : today;
    return last == null || last.isBefore(dueAt);
  }

  /// اسم لقطة القاعدة حسب العقد: backup_{store_id}_{timestamp}.db
  static String snapshotName(String storeId, DateTime ts) {
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${ts.year}${two(ts.month)}${two(ts.day)}'
        '-${two(ts.hour)}${two(ts.minute)}${two(ts.second)}';
    final safe = storeId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'backup_${safe}_$stamp.db';
  }

  /// لقطة SQLite آمنة: تفريغ WAL ثم نسخ ملف القاعدة كما هو إلى مجلد
  /// النسخ. يعيد المسار عند النجاح، وnull للقواعد في الذاكرة (اختبارات)
  /// أو عند أي فشل — لا يرمي استثناءات أبداً.
  static Future<String?> takeLocalSnapshot(Repo repo) async {
    try {
      final db = await repo.database;
      final path = db.path;
      if (path.isEmpty || path == ':memory:' || path.contains('in_memory')) {
        return null;
      }
      final src = File(path);
      if (!await src.exists()) return null;
      try {
        await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
      } catch (_) {}
      Directory base;
      try {
        base = await getApplicationDocumentsDirectory();
      } catch (_) {
        base = Directory.systemTemp;
      }
      final dir =
          await Directory('${base.path}${Platform.pathSeparator}backups')
              .create(recursive: true);
      final dest =
          '${dir.path}${Platform.pathSeparator}${snapshotName(repo.requireWorkspaceId, DateTime.now())}';
      await src.copy(dest);
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// دورة نسخ مجدولة كاملة: لقطة محلية + Drive (مجاني دائماً عند توفر
  /// تسجيل الدخول) + السحابة الخاصة (مؤسسة فقط وأثناء التجربة/الاشتراك).
  static Future<void> runScheduled(Repo repo) async {
    final st = await repo.settings();
    final file = await takeLocalSnapshot(repo);
    if (file != null && (st[kDriveKey] ?? '1') == '1') {
      try {
        final svc = GoogleDriveService.instance;
        if (await svc.restoreSession() != null) {
          await svc.uploadLatest(File(file));
        }
      } catch (_) {}
    }
    // السحابة الخاصة: فردي أثناء التجربة/الاشتراك فقط (البوابة داخل
    // silentWorkspaceBackup — تُحجب تلقائياً بعد الانتهاء)، ومؤسسة حسب
    // ضوابط التجربة المعتمدة دون تغيير.
    try {
      if (await silentBackupDue(repo)) await silentWorkspaceBackup(repo);
    } catch (_) {}
    await repo.setSetting(
        kLastScheduledKey, DateTime.now().toIso8601String());
  }

  /// المدخل الموحّد للمحرك: المجدول إن حان (يشمل المحلي/Drive/السحابي)،
  /// وإلا النسخة السحابية الصامتة القديمة إن استحقت.
  static Future<void> maybeRun(Repo repo) async {
    try {
      if (await scheduledDue(repo)) {
        await runScheduled(repo);
        return;
      }
    } catch (_) {}
    try {
      if (await silentBackupDue(repo)) await silentWorkspaceBackup(repo);
    } catch (_) {}
  }
}
