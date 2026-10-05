// (ربط الحساب — بدون لمس هوية المؤسسة) فهرس سحابي اختياري للحساب.
//
// المبدأ بعد 3.61 (استعادة سلوك 3.55):
//   - هوية المؤسسة = معرّف مساحة محلي عشوائي (WS-XXXXXXXX) لكل تثبيت.
//     لا علاقة له بحساب Google إطلاقاً — الربط يعمل بلا إنترنت.
//   - حساب Google يُستخدم للترخيص والنسخ على Drive فقط، ويُسجَّل ربطه
//     بالمساحة الحالية في فهرس اختياري لأجل استرداد يدوي مستقبلي.
//   - انضمام الموظفين يبقى عبر QR/PIN — لا يحتاجون حساب Google.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../core/factory_reset.dart';
import 'auto_backup.dart';
import '../repository.dart';
import 'cloud_join.dart';
import 'workspace_recovery.dart';
import 'device_id.dart';
import 'device_registry.dart';
import 'firebase_auth_service.dart';

/// نتيجة تبنّي/استرداد مساحة الحساب بعد تسجيل الدخول.
enum AccountLinkOutcome {
  /// (محفوظة للتوافق) استُعيدت مساحة سابقة كاملة بالبيانات.
  /// لا يُنتِجها أي مسار تلقائي بعد 3.61 — الاسترداد صار بقرار صريح.
  recovered,

  /// اكتمل ربط الحساب: جلسة محفوظة + فهرس مسجّل — **بلا أي تغيير
  /// على معرّف المساحة المحلي** (سلوك 3.55 المستعاد).
  migrated,

  /// جهاز عضو في مجموعة — لا تغيير على مساحته (يتبع مديره).
  memberUntouched,

  /// (دفعة 65) الحساب مرتبط بمساحة **أخرى**: حُظر الدمج، وأُخذت نسخة
  /// احتياطية، وفُرّغت الجداول، ونُزّلت بيانات المساحة الجديدة.
  switched,

  /// (دفعة 65) الحساب مرتبط بمساحة أخرى لكن **لا نسخة سحابية** لتلك
  /// المساحة — لم يُفرَّغ شيء، وتعذّر إتمام التبديل.
  switchUnavailable,

  /// (دفعة 65) تعذّر إتمام التبديل **بعد** تفريغ الجداول: استُرجعت
  /// بيانات المساحة الأصلية من النسخة المحتفظ بها — **بلا فقدان بيانات**.
  switchRestored,

  /// (دفعة 65) تعذّر التبديل بعد التفريغ **وتعذّر الاسترجاع التلقائي**:
  /// البيانات الأصلية ما زالت في ملف `pre_switch_backup.nexora` داخل
  /// مجلد النسخ — يجب إبلاغ المستخدم بمكانها صراحةً.
  switchDataLost,

  /// تعذر الإكمال (شبكة/إعدادات).
  failed,
}

class AccountWorkspace {
  AccountWorkspace._();

  static String _indexPath(String base, String uid) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/_registry/'
      'accounts_index/${Uri.encodeComponent(uid)}.json';

  static String emailToKey(String email) {
    final clean = email.trim().toLowerCase();
    return sha256.convert(utf8.encode(clean)).toString();
  }

  static String _emailIndexPath(String base, String email) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/_registry/'
      'emails_index/${emailToKey(email)}.json';

  /// قراءة مساحة العمل المرتبطة بالبريد الإلكتروني من الفهرس السحابي — '' إن لم تُسجَّل بعد.
  static Future<String> lookupByEmail({
    required String backendUrl,
    required String email,
  }) async {
    final clean = email.trim().toLowerCase();
    if (clean.isEmpty) return '';
    try {
      final res = await http
          .get(Uri.parse(_emailIndexPath(backendUrl, clean)))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return '';
      final body = utf8.decode(res.bodyBytes).trim();
      if (body.isEmpty || body == 'null') return '';
      final m = jsonDecode(body);
      if (m is! Map) return '';
      final ws = '${m['workspaceId'] ?? ''}'.trim();
      return ws == 'default' ? '' : ws;
    } catch (_) {
      return '';
    }
  }

  /// تسجيل ربط مساحة العمل بالبريد الإلكتروني في الفهرس السحابي وبيانات المساحة (meta).
  static Future<void> bindEmailWorkspace({
    required String backendUrl,
    required String email,
    required String workspaceId,
  }) async {
    final clean = email.trim().toLowerCase();
    if (clean.isEmpty || workspaceId.isEmpty || workspaceId == 'default') return;
    try {
      await http
          .put(
            Uri.parse(_emailIndexPath(backendUrl, clean)),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'workspaceId': workspaceId,
              'email': clean,
              'updated_at': {'.sv': 'timestamp'},
            }),
          )
          .timeout(const Duration(seconds: 15));

      final root = backendUrl.replaceAll(RegExp(r'/+$'), '');
      await http
          .put(
            Uri.parse('$root/workspaces/${Uri.encodeComponent(workspaceId)}/meta.json'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'id': workspaceId,
              'owner_email': clean,
              'updated_at': {'.sv': 'timestamp'},
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  /// قراءة مساحة الحساب من الفهرس — '' إن لم تُسجَّل بعد.
  static Future<String> lookup({
    required String backendUrl,
    required String uid,
  }) async {
    try {
      final res = await http
          .get(Uri.parse(_indexPath(backendUrl, uid)))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return '';
      final body = utf8.decode(res.bodyBytes).trim();
      if (body.isEmpty || body == 'null') return '';
      final m = jsonDecode(body);
      if (m is! Map) return '';
      final ws = '${m['workspaceId'] ?? ''}'.trim();
      return ws == 'default' ? '' : ws;
    } catch (_) {
      return '';
    }
  }

  /// تسجيل ربط الحساب بمساحته (لا يُستبدل ربط قائم إلا بـ force).
  static Future<void> bind({
    required String backendUrl,
    required String uid,
    required String workspaceId,
    String email = '',
    bool force = false,
  }) async {
    if (workspaceId.isEmpty || workspaceId == 'default') return;
    try {
      if (!force) {
        final existing = await lookup(backendUrl: backendUrl, uid: uid);
        if (existing.isNotEmpty && existing != workspaceId) return;
      }
      if (uid.isNotEmpty) {
        await http
            .put(
              Uri.parse(_indexPath(backendUrl, uid)),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'workspaceId': workspaceId,
                'email': email,
                'updated_at': {'.sv': 'timestamp'},
              }),
            )
            .timeout(const Duration(seconds: 15));
      }
      if (email.trim().isNotEmpty) {
        await bindEmailWorkspace(
          backendUrl: backendUrl,
          email: email,
          workspaceId: workspaceId,
        );
      }
    } catch (_) {}
  }

  /// (استعادة سلوك 3.55) ربط الحساب **بلا أي مساس بمعرّف المساحة**.
  ///
  /// في 3.55 كان تسجيل الدخول يثبّت الجلسة فقط (Google Drive + الترخيص) ولا
  /// يعيد تسمية مساحة العمل أبداً — ولهذا ظلّ الربط يعمل بدقة حتى بلا إنترنت.
  /// هذا المسار يستعيد ذلك السلوك حرفياً:
  ///   • يثبّت جلسة الحساب محلياً (الترخيص والنسخ على Drive).
  ///   • يسجّل الفهرس السحابي uid → المساحة الحالية (أفضل جهد، للاسترداد
  ///     اليدوي لاحقاً) — لا يفشل الربط إن تعذّر.
  ///   • يترك معرّف المساحة المحلي (WS-XXXXXXXX) كما هو تماماً.
  static Future<AccountLinkOutcome> linkAccountOnly(
    Repo repo, {
    required String backendUrl,
    required FirebaseAccount account,
  }) async {
    if (account.uid.isEmpty && account.email.trim().isEmpty) {
      return AccountLinkOutcome.failed;
    }
    try {
      // جهاز عضو في مجموعة لا يُمَسّ ولا تُبدّل مساحته عند ربط حساب Google.
      if (await repo.workspaceMode() == 'member') {
        await FirebaseAuthRest.saveSession(repo, account);
        if (account.email.trim().isNotEmpty) {
          await repo.setSetting('account.email', account.email.trim());
        }
        return AccountLinkOutcome.memberUntouched;
      }

      // ══ (حارس الربط بالبريد والمساحة الواحدة) ══
      // الفهرس السحابي للبريد (emails_index) هو المرجع السيادي الأول:
      // كل بريد لديه مساحة واحدة فقط في السحابة وتُسترجع بكامل بياناتها فور تسجيل الدخول.
      if (backendUrl.isNotEmpty) {
        final localWs = repo.requireWorkspaceId;
        String remoteWs = '';
        try {
          if (account.email.trim().isNotEmpty) {
            remoteWs = await lookupByEmail(
                backendUrl: backendUrl, email: account.email)
                .timeout(const Duration(seconds: 4), onTimeout: () => '');
          }
          if (remoteWs.isEmpty && account.uid.isNotEmpty) {
            remoteWs = await lookup(backendUrl: backendUrl, uid: account.uid)
                .timeout(const Duration(seconds: 4), onTimeout: () => '');
          }
        } catch (_) {}

        if (remoteWs.isNotEmpty &&
            remoteWs != 'default' &&
            remoteWs != localWs) {
          try {
            final outcome = await _switchWorkspace(
              repo,
              backendUrl: backendUrl,
              account: account,
              fromWorkspaceId: localWs,
              toWorkspaceId: remoteWs,
            ).timeout(const Duration(seconds: 8),
                onTimeout: () => AccountLinkOutcome.failed);
            if (outcome != AccountLinkOutcome.failed) {
              if (outcome == AccountLinkOutcome.switched) {
                await FirebaseAuthRest.saveSession(repo, account);
                if (account.email.trim().isNotEmpty) {
                  await repo.setSetting('account.email', account.email.trim());
                }
                await repo.checkAndAutoPromoteManager();
                await repo.ensureSelfPermissionRow(roleCode: 'admin');
              }
              return outcome;
            }
          } catch (_) {}
        }
      }

      // (Offline-First) الجلسة تُحفظ أولاً — نجاح الربط لا يعتمد على الشبكة.
      await FirebaseAuthRest.saveSession(repo, account);
      if (account.email.trim().isNotEmpty) {
        await repo.setSetting('account.email', account.email.trim());
      }
      await repo.checkAndAutoPromoteManager();
      await repo.ensureSelfPermissionRow(roleCode: 'admin');
      unawaited(repo.restoreManagerOwnership());

      if (backendUrl.isNotEmpty) {
        unawaited(
          _afterLink(repo, backendUrl, account, repo.requireWorkspaceId)
              .timeout(const Duration(seconds: 6), onTimeout: () {})
              .catchError((_) {}),
        );
      }
      return AccountLinkOutcome.migrated;
    } catch (_) {
      return AccountLinkOutcome.failed;
    }
  }

  /// (دفعة 65) تنفيذ التبديل الآمن إلى مساحة أخرى: **الدمج ممنوع**.
  ///
  /// الترتيب حاسم — لا نفرّغ شيئاً قبل التأكد من وجود بيانات للمساحة
  /// الجديدة في السحابة، فلا يُترك المستخدم بجهاز فارغ عند أي فشل:
  ///   1) سحب استباقي لنسخة المساحة (ب) — الفشل هنا يُلغي التبديل بلا أثر.
  ///   2) نسخة احتياطية صامتة pre_switch_backup.nexora (أفضل جهد).
  ///   3) تفريغ الجداول المحاسبية (تمنع تداخل حسابات (أ) مع (ب)).
  ///   4) ترحيل معرّف المساحة واستيراد بيانات (ب).
  ///   5) هوية سحابية جديدة مقترنة بالمساحة الجديدة + account.type=enterprise.
  static Future<AccountLinkOutcome> _switchWorkspace(
    Repo repo, {
    required String backendUrl,
    required FirebaseAccount account,
    required String fromWorkspaceId,
    required String toWorkspaceId,
  }) async {
    // 1) تحقّق مسبق — لا تفريغ قبل ضمان وجود ما يُنزَّل (نسخة أو لقطة).
    Map<String, Object?>? pulled;
    try {
      pulled = await AutoBackupService.pullWorkspaceBackup(repo,
          backendUrl: backendUrl, workspaceId: toWorkspaceId);
    } catch (_) {
      pulled = null;
    }
    if (pulled == null) {
      try {
        final snapRes = await http.get(
          Uri.parse('${backendUrl.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(toWorkspaceId)}/joinSnapshot.json')
        ).timeout(const Duration(seconds: 15));
        if (snapRes.statusCode == 200 && snapRes.body.trim().isNotEmpty && snapRes.body.trim() != 'null') {
          final snapDecoded = jsonDecode(snapRes.body);
          if (snapDecoded is Map && snapDecoded['data'] is Map) {
            pulled = {
              'format': 'nexora-backup',
              'data': snapDecoded['data'],
            };
          }
        }
      } catch (_) {}
    }
    if (pulled == null) return AccountLinkOutcome.switchUnavailable;

    // 2) نسخة احتياطية صامتة — نُبقي البيانات في الذاكرة أيضاً:
    //    الاسترجاع منها مضمون حتى لو تعذّرت كتابة الملف أو قُرئ مشوّهاً.
    Map<String, Object?>? backupData;
    try {
      final data = await repo.exportAll(withImages: false);
      backupData = data;
      await FactoryReset.silentBackup(data,
          fileName: FactoryReset.kBackupBeforeSwitch);
    } catch (_) {}

    // ══ (دفعة 65) حارس ما بعد التفريغ ══
    // كل ما يلي مُدمّر: التفريغ أول خطوة فيه، وأي فشل في الترحيل أو
    // الاستيراد أو تدوير الهوية كان يترك الجهاز **فارغاً** بلا بيانات
    // المساحة الجديدة — فقدان بيانات صامت. والأسوأ: الاستثناء كان يهرب
    // متجاوزاً `catch` في linkAccountOnly (لأن الإرجاع بلا await)، فلا
    // يُسترجع شيء ويُبلّغ المستخدم برسالة عامة لا تذكر نسخته أبداً.
    // الآن نحيط الجزء المدمر بـ try، وعند أي فشل نتراجع فوراً.
    var swapped = false;
    try {
      // 3) تفريغ الجداول المحاسبية.
      final db = await repo.database;
      await FactoryReset.wipeAccountingTables(db);

      // 4) ترحيل المساحة ثم استيراد بياناتها.
      if (fromWorkspaceId != toWorkspaceId) {
        await WorkspaceRecovery.swapWorkspaceId(db,
            from: fromWorkspaceId, to: toWorkspaceId);
        swapped = true; // صار لزاماً عكسه إن فشل ما بعده.
        await repo.setSetting('sync.workspaceId', toWorkspaceId);
        repo.debugSetWorkspaceId(toWorkspaceId);
      }
      await repo.importAll(pulled);

      // 5) هوية سحابية مستقلة مقترنة بالمساحة الجديدة.
      await FirebaseAuthRest.resetAnonymousSession(repo);
      await FirebaseAuthRest.ensureScopedAnonymous(repo, toWorkspaceId);
      // بعد تدوير الهوية: ابدأ جلسة مجهولة جديدة ثم احفظ جلسة الحساب فوقها.
      await FirebaseAuthRest.initSilentAuth(repo);
      await FirebaseAuthRest.saveSession(repo, account);
      if (account.email.trim().isNotEmpty) {
        await repo.setSetting('account.email', account.email.trim());
      }
      await repo.setSetting('account.type', 'enterprise');
      await repo.checkAndAutoPromoteManager();
      await repo.ensureSelfPermissionRow(roleCode: 'admin');
      unawaited(repo.restoreManagerOwnership());
      try {
        await db.insert(
          'sync_meta',
          {'key': 'workspaceMode', 'value': 'host'},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (_) {}
      return AccountLinkOutcome.switched;
    } catch (e) {
      debugPrint('AccountWorkspace: فشل التبديل بعد التفريغ: $e');
      return await _undoFailedSwitch(
        repo,
        backupData: backupData,
        fromWorkspaceId: fromWorkspaceId,
        toWorkspaceId: toWorkspaceId,
        swapped: swapped,
      );
    }
  }

  /// (دفعة 65) تراجع عن تبديل فاشل **بعد** التفريغ: يعكس ترحيل المساحة
  /// (إن حصل) ثم يستعيد بيانات المساحة الأصلية من النسخة المحتفظ بها.
  ///
  /// لا يرمي أبداً — يُبلّغ بالنتيجة ليشرحها المستدعي للمستخدم.
  static Future<AccountLinkOutcome> _undoFailedSwitch(
    Repo repo, {
    required Map<String, Object?>? backupData,
    required String fromWorkspaceId,
    required String toWorkspaceId,
    required bool swapped,
  }) async {
    // أ) عكس الترحيل أولاً: الاستيراد لا يلمس جدول workspaces، فلو بقي
    //    موسوماً بـ (ب) لصارت البيانات المسترجعة (الموسومة بـ (أ)) يتيمة.
    if (swapped) {
      try {
        final db = await repo.database;
        await WorkspaceRecovery.swapWorkspaceId(db,
            from: toWorkspaceId, to: fromWorkspaceId);
        await repo.setSetting('sync.workspaceId', fromWorkspaceId);
        repo.debugSetWorkspaceId(fromWorkspaceId);
      } catch (e) {
        debugPrint('AccountWorkspace: تعذّر عكس ترحيل المساحة: $e');
      }
    }
    // ب) استعادة البيانات الأصلية.
    if (backupData == null) return AccountLinkOutcome.switchDataLost;
    try {
      await repo.importAll(backupData);
      return AccountLinkOutcome.switchRestored;
    } catch (e) {
      debugPrint('AccountWorkspace: تعذّر استرجاع النسخة: $e');
      return AccountLinkOutcome.switchDataLost;
    }
  }

  /// تثبيت الربط بعد أي مسار ناجح: جلسة + فهرس الحساب + فهرس البصمة +
  /// ربط الـ workspace بحساب Google في الجدول المحلي.
  static Future<void> _afterLink(Repo repo, String backendUrl,
      FirebaseAccount account, String workspaceId) async {
    // (401) الهوية السابقة (المجهولة) قبل ترقية الجلسة: إثر ربط الحساب
    // يتغيّر auth.uid، وتُنقل عضوية المالك من القديمة إلى UID الحساب.
    final previousUid = FirebaseAuthRest.anonymousUid;
    await FirebaseAuthRest.saveSession(repo, account);
    await bind(
      backendUrl: backendUrl,
      uid: account.uid,
      workspaceId: workspaceId,
      email: account.email,
      force: true,
    );
    // (401) ترحيل فوري لعضوية المالك: بدونها يبقى المالك بلا صلاحية كتابة
    // على مساحته، وأول عرض للخلل هو رفض إنشاء الدعوة بـ HTTP 401.
    try {
      await CloudJoin.migrateOwnerMembership(repo,
          backendUrl: backendUrl,
          workspaceId: workspaceId,
          previousUid: previousUid);
    } catch (_) {}
    try {
      await DeviceRegistry.upsertBinding(repo,
          backendUrl: backendUrl, force: true);
    } catch (_) {}
    try {
      final db = await repo.database;
      await db.update(
        'workspaces',
        {
          'owner_google_id': account.uid,
          'owner_email': account.email.trim().toLowerCase(),
          'owner_name': account.displayName,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [workspaceId],
      );
    } catch (_) {}
    // معرف الجهاز يبقى كما هو — الربط بالحساب لا يغيّر هوية الجهاز.
    await ensureDeviceId(repo);
  }
}
