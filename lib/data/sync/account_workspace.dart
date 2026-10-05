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
import 'cloud_firebase_transport.dart';
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

  /// تطبيع رقم الهاتف مع الرمز الدولي إلى مفتاح موحّد (أرقام فقط بعد إزالة البادئة 00/+).
  static String normalizePhone(String phone) {
    var digits = phone.trim().replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.startsWith('+')) digits = digits.substring(1);
    if (digits.startsWith('00')) digits = digits.substring(2);
    return digits;
  }

  static String phoneToKey(String phone) {
    final norm = normalizePhone(phone);
    if (norm.isEmpty) return '';
    return sha256.convert(utf8.encode('phone:$norm')).toString();
  }

  static String _phoneIndexPath(String base, String phone) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/_registry/'
      'phones_index/${phoneToKey(phone)}.json';

  /// قراءة مساحة العمل المرتبطة برقم الهاتف (مع الرمز الدولي) من الفهرس السحابي.
  static Future<String> lookupByPhone({
    required String backendUrl,
    required String phone,
  }) async {
    final norm = normalizePhone(phone);
    if (norm.length < 7) return '';
    try {
      final res = await http
          .get(Uri.parse(_phoneIndexPath(backendUrl, norm)))
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

  /// ربط رقم الهاتف بمساحة العمل مع منع تكرار الرقم لمساحة أخرى.
  static Future<bool> bindPhoneWorkspace({
    required String backendUrl,
    required String phone,
    required String workspaceId,
    String email = '',
  }) async {
    final norm = normalizePhone(phone);
    if (norm.length < 7 || workspaceId.isEmpty || workspaceId == 'default') {
      return false;
    }
    try {
      final existingWs =
          await lookupByPhone(backendUrl: backendUrl, phone: norm);
      if (existingWs.isNotEmpty && existingWs != workspaceId) {
        // رقم الهاتف مسجّل مسبقاً لمساحة أخرى — يمنع التكرار منعاً باتاً.
        return false;
      }
      await http
          .put(
            Uri.parse(_phoneIndexPath(backendUrl, norm)),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'workspaceId': workspaceId,
              'phone': norm,
              if (email.trim().isNotEmpty)
                'email': email.trim().toLowerCase(),
              'updated_at': {'.sv': 'timestamp'},
            }),
          )
          .timeout(const Duration(seconds: 15));
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _trimSlashes(String url) {
    var out = url.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /// قراءة مساحة العمل المرتبطة بالبريد الإلكتروني من الفهرس السحابي — '' إن لم تُسجَّل بعد.
  static Future<String> lookupByEmail({
    required String backendUrl,
    required String email,
  }) async {
    final clean = email.trim().toLowerCase();
    if (clean.isEmpty) return '';
    final root = _trimSlashes(backendUrl);
    try {
      final res = await http
          .get(Uri.parse(_emailIndexPath(backendUrl, clean)))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = utf8.decode(res.bodyBytes).trim();
        if (body.isNotEmpty && body != 'null') {
          final m = jsonDecode(body);
          if (m is Map) {
            final ws = '${m['workspaceId'] ?? ''}'.trim();
            if (ws.isNotEmpty && ws != 'default') return ws;
          }
        }
      }
      // فحص احتياطي في accounts_index للمساحات القديمة التي سُجّلت قبل فهرس البريد
      final accRes = await http
          .get(Uri.parse('$root/workspaces/_registry/accounts_index.json'))
          .timeout(const Duration(seconds: 12));
      if (accRes.statusCode >= 200 && accRes.statusCode < 300) {
        final accBody = utf8.decode(accRes.bodyBytes).trim();
        if (accBody.isNotEmpty && accBody != 'null') {
          final allAcc = jsonDecode(accBody);
          if (allAcc is Map) {
            for (final entry in allAcc.entries) {
              final v = entry.value;
              if (v is Map &&
                  '${v['email'] ?? ''}'.trim().toLowerCase() == clean) {
                final ws = '${v['workspaceId'] ?? ''}'.trim();
                if (ws.isNotEmpty && ws != 'default') return ws;
              }
            }
          }
        }
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  /// تسجيل ربط مساحة العمل بالبريد الإلكتروني في الفهرس السحابي وبيانات المساحة (meta).
  static Future<void> bindEmailWorkspace({
    required String backendUrl,
    required String email,
    required String workspaceId,
    Map<String, Object?>? extraMeta,
  }) async {
    final clean = email.trim().toLowerCase();
    if (clean.isEmpty || workspaceId.isEmpty || workspaceId == 'default') return;
    try {
      // منع إضافة مساحة ثانية لنفس البريد الإلكتروني إذا كانت له مساحة سابقة مسجلة.
      final existing = await lookupByEmail(backendUrl: backendUrl, email: clean);
      final targetWs =
          (existing.isNotEmpty && existing != 'default') ? existing : workspaceId;

      await http
          .put(
            Uri.parse(_emailIndexPath(backendUrl, clean)),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'workspaceId': targetWs,
              'email': clean,
              if (extraMeta != null) ...extraMeta,
              'updated_at': {'.sv': 'timestamp'},
            }),
          )
          .timeout(const Duration(seconds: 15));

      final root = backendUrl.replaceAll(RegExp(r'/+$'), '');
      await http
          .put(
            Uri.parse('$root/workspaces/${Uri.encodeComponent(targetWs)}/meta.json'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'id': targetWs,
              'owner_email': clean,
              if (extraMeta != null) ...extraMeta,
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

  /// تسجيل ربط الحساب بمساحته (لا يُستبدل ربط قائم بمساحة أخرى أبداً).
  static Future<void> bind({
    required String backendUrl,
    required String uid,
    required String workspaceId,
    String email = '',
    String phone = '',
    Map<String, Object?>? extraMeta,
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
                if (phone.trim().isNotEmpty) 'phone': normalizePhone(phone),
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
          extraMeta: extraMeta,
        );
      }
      if (phone.trim().isNotEmpty) {
        await bindPhoneWorkspace(
          backendUrl: backendUrl,
          phone: phone,
          workspaceId: workspaceId,
          email: email,
        );
      }
    } catch (_) {}
  }

  /// ربط الحساب مع استرجاع حتمي للمساحة السابقة المرتبطة بالبريد أو UID أو رقم الهاتف:
  ///   • يمنع منعاً باتاً إنشاء مساحة ثانية لنفس البريد أو نفس الهاتف.
  ///   • يسترجع بيانات المنشأة والحسابات والعمليات والإعدادات بالكامل حتى لو تغيّرت بصمة الجهاز.
  static Future<AccountLinkOutcome> linkAccountOnly(
    Repo repo, {
    required String backendUrl,
    required FirebaseAccount account,
  }) async {
    if (account.uid.isEmpty && account.email.trim().isEmpty) {
      return AccountLinkOutcome.failed;
    }
    try {
      // جهاز عضو في مجموعة لا يُمَسّ ولا يُسمح له بتسجيل حساب Google أثناء ارتباطه بالمنشأة.
      if (await repo.workspaceMode() == 'member') {
        return AccountLinkOutcome.memberUntouched;
      }

      // ══ (حارس الربط بالبريد والهاتف والمساحة الواحدة) ══
      // الفهرس السحابي للبريد (emails_index) ثم الحساب (accounts_index) ثم الهاتف (phones_index):
      // كل بريد/هاتف لديه مساحة واحدة فقط في السحابة وتُسترجع بكامل بياناتها فور تسجيل الدخول.
      if (backendUrl.isNotEmpty) {
        final localWs = repo.requireWorkspaceId;
        String remoteWs = '';
        try {
          if (account.email.trim().isNotEmpty) {
            remoteWs = await lookupByEmail(
                    backendUrl: backendUrl, email: account.email)
                .timeout(const Duration(seconds: 6), onTimeout: () => '');
          }
          if (remoteWs.isEmpty && account.uid.isNotEmpty) {
            remoteWs = await lookup(backendUrl: backendUrl, uid: account.uid)
                .timeout(const Duration(seconds: 6), onTimeout: () => '');
          }
          if (remoteWs.isEmpty) {
            final st0 = await repo.settings();
            final savedPhone =
                (st0['phone'] ?? st0['whatsapp'] ?? st0['user.phone'] ?? '')
                    .trim();
            if (savedPhone.isNotEmpty) {
              remoteWs = await lookupByPhone(
                      backendUrl: backendUrl, phone: savedPhone)
                  .timeout(const Duration(seconds: 6), onTimeout: () => '');
            }
          }
        } catch (_) {}

        if (remoteWs.isNotEmpty &&
            remoteWs != 'default' &&
            remoteWs != localWs) {
          final outcome = await _switchWorkspace(
            repo,
            backendUrl: backendUrl,
            account: account,
            fromWorkspaceId: localWs,
            toWorkspaceId: remoteWs,
          ).timeout(const Duration(seconds: 25),
              onTimeout: () => AccountLinkOutcome.failed);
          if (outcome == AccountLinkOutcome.switched) {
            await FirebaseAuthRest.saveSession(repo, account);
            if (account.email.trim().isNotEmpty) {
              await repo.setSetting('account.email', account.email.trim());
            }
            await repo.checkAndAutoPromoteManager();
            await repo.ensureSelfPermissionRow(roleCode: 'admin');
            await _afterLink(repo, backendUrl, account, remoteWs)
                .timeout(const Duration(seconds: 8), onTimeout: () {})
                .catchError((_) {});
          }
          // ⚠️ حاسم: طالما وُجدت مساحة سابقة (remoteWs) لهذا البريد/الحساب،
          // يُمنع منعاً باتاً المتابعة لربط المساحة المحلية الفارغة (localWs)
          // أو الكتابة فوق الفهرس السحابي بمساحة ثانية!
          return outcome;
        }
      }

      // (Offline-First) الجلسة تُحفظ أولاً — نجاح الربط لا يعتمد على الشبكة.
      await FirebaseAuthRest.saveSession(repo, account);
      if (account.email.trim().isNotEmpty) {
        await repo.setSetting('account.email', account.email.trim());
      }
      await repo.checkAndAutoPromoteManager();
      await repo.ensureSelfPermissionRow(roleCode: 'admin');
      await repo.restoreManagerOwnership();

      if (backendUrl.isNotEmpty) {
        await _afterLink(repo, backendUrl, account, repo.requireWorkspaceId)
            .timeout(const Duration(seconds: 6), onTimeout: () {})
            .catchError((_) {});
      }
      return AccountLinkOutcome.migrated;
    } catch (_) {
      return AccountLinkOutcome.failed;
    }
  }

  /// (دفعة 65) تنفيذ التبديل الآمن إلى مساحة أخرى: **الدمج ممنوع**.
  static Future<AccountLinkOutcome> _switchWorkspace(
    Repo repo, {
    required String backendUrl,
    required FirebaseAccount account,
    required String fromWorkspaceId,
    required String toWorkspaceId,
  }) async {
    final root = backendUrl.replaceAll(RegExp(r'/+$'), '');
    final wsUrl = '$root/workspaces/${Uri.encodeComponent(toWorkspaceId)}';

    // 1) تحقّق مسبق — سحب نسخة المساحة السابقة (backup.json ثم joinSnapshot.json ثم snapshot.json).
    Map<String, Object?>? pulled;
    try {
      pulled = await AutoBackupService.pullWorkspaceBackup(repo,
          backendUrl: backendUrl, workspaceId: toWorkspaceId);
    } catch (_) {
      pulled = null;
    }
    if (pulled == null) {
      for (final snapName in const ['joinSnapshot.json', 'snapshot.json']) {
        try {
          final snapRes = await http
              .get(Uri.parse('$wsUrl/$snapName'))
              .timeout(const Duration(seconds: 15));
          if (snapRes.statusCode == 200 &&
              snapRes.body.trim().isNotEmpty &&
              snapRes.body.trim() != 'null') {
            final snapDecoded = jsonDecode(utf8.decode(snapRes.bodyBytes));
            if (snapDecoded is Map) {
              final dataMap = snapDecoded['data'] is Map
                  ? snapDecoded['data']
                  : ((snapDecoded['accounts'] != null ||
                          snapDecoded['settings'] != null)
                      ? snapDecoded
                      : null);
              if (dataMap is Map && dataMap.isNotEmpty) {
                pulled = {
                  'format': 'nexora-backup',
                  'data': dataMap,
                };
                break;
              }
            }
          }
        } catch (_) {}
      }
    }

    // قراءة meta.json للمساحة السابقة (لاسترجاع اسم المنشأة والعنوان والهاتف والعملة حتى لو لم تكتمل النسخة بعد).
    Map<String, dynamic>? remoteMeta;
    try {
      final metaRes = await http
          .get(Uri.parse('$wsUrl/meta.json'))
          .timeout(const Duration(seconds: 10));
      if (metaRes.statusCode == 200 &&
          metaRes.body.trim().isNotEmpty &&
          metaRes.body.trim() != 'null') {
        final d = jsonDecode(utf8.decode(metaRes.bodyBytes));
        if (d is Map) remoteMeta = Map<String, dynamic>.from(d);
      }
    } catch (_) {}

    // إذا لم توجد backup.json بعد، ولكن توجد meta.json على السحابة وكان الجهاز
    // حديث التثبيت (بلا حسابات محلية)، نبني حمولة استعادة أولية من meta.json
    // ليتم التحول فوراً إلى المساحة الأصلية ويجلب SyncEngine بقية العمليات من /operations.
    if (pulled == null && remoteMeta != null) {
      final localAccounts =
          await repo.accounts(includeArchived: true, includeDeleted: true);
      if (localAccounts.isEmpty) {
        final settingsRows = <Map<String, Object?>>[];
        void addSetting(String k, Object? v) {
          final s = '${v ?? ''}'.trim();
          if (s.isNotEmpty) settingsRows.add({'key': k, 'value': s});
        }

        addSetting(
            'businessName',
            remoteMeta['storeName'] ??
                remoteMeta['store_name'] ??
                remoteMeta['businessName']);
        addSetting('businessActivity', remoteMeta['businessActivity']);
        addSetting('address', remoteMeta['address']);
        addSetting('phone', remoteMeta['phone']);
        addSetting('whatsapp', remoteMeta['phone']);
        addSetting('defaultCurrency', remoteMeta['defaultCurrency']);
        addSetting('account.email',
            remoteMeta['owner_email'] ?? account.email.trim());
        addSetting(
            'account.name',
            remoteMeta['owner_name'] ??
                remoteMeta['clientName'] ??
                account.displayName);
        if (settingsRows.isNotEmpty) {
          pulled = {
            'format': 'nexora-backup',
            'data': {
              'settings': settingsRows,
            },
          };
        }
      }
    }

    if (pulled == null) return AccountLinkOutcome.switchUnavailable;

    // 2) نسخة احتياطية صامتة — نُبقي البيانات في الذاكرة أيضاً:
    Map<String, Object?>? backupData;
    try {
      final data = await repo.exportAll(withImages: false, localOnly: true);
      backupData = data;
      await FactoryReset.silentBackup(data,
          fileName: FactoryReset.kBackupBeforeSwitch);
    } catch (_) {}

    var swapped = false;
    try {
      // 3) تفريغ الجداول المحاسبية.
      final db = await repo.database;
      await FactoryReset.wipeAccountingTables(db);

      // 4) ترحيل المساحة ثم استيراد بياناتها (مع السماح باختلاف بصمة الجهاز بعد إعادة التثبيت).
      if (fromWorkspaceId != toWorkspaceId) {
        await WorkspaceRecovery.swapWorkspaceId(db,
            from: fromWorkspaceId, to: toWorkspaceId);
        swapped = true;
        await repo.setSetting('sync.workspaceId', toWorkspaceId);
        repo.debugSetWorkspaceId(toWorkspaceId);
      }
      await repo.importAll(pulled, allowCrossFingerprint: true);

      // استرجاع إعدادات المنشأة من meta.json إن وُجدت ولم تكن في النسخة
      if (remoteMeta != null) {
        final curSt = await repo.settings();
        Future<void> restoreIfMissing(String settingKey, List<String> metaKeys) async {
          final currentVal = (curSt[settingKey] ?? '').trim();
          if (currentVal.isNotEmpty && currentVal != 'متجري') return;
          for (final mk in metaKeys) {
            final mv = '${remoteMeta![mk] ?? ''}'.trim();
            if (mv.isNotEmpty) {
              await repo.setSetting(settingKey, mv);
              break;
            }
          }
        }

        await restoreIfMissing(
            'businessName', ['storeName', 'store_name', 'businessName']);
        await restoreIfMissing('businessActivity', ['businessActivity']);
        await restoreIfMissing('address', ['address']);
        await restoreIfMissing('phone', ['phone', 'whatsapp']);
        await restoreIfMissing('whatsapp', ['whatsapp', 'phone']);
        await restoreIfMissing('defaultCurrency', ['defaultCurrency']);
        await restoreIfMissing(
            'account.name', ['owner_name', 'clientName', 'client_name']);
      }

      // سحب أي عمليات مزامنة إضافية من عقدة /operations للمساحة المسترجعة
      try {
        await CloudFirebaseTransport(
          repo: repo,
          dbProvider: () => repo.database,
          backendUrl: backendUrl,
          workspaceId: toWorkspaceId,
          idTokenProvider: () => FirebaseAuthRest.cloudIdToken(),
        ).pull(forceFullSync: true).timeout(const Duration(seconds: 10));
      } catch (_) {}

      // 5) هوية سحابية مستقلة مقترنة بالمساحة الجديدة.
      await FirebaseAuthRest.resetAnonymousSession(repo);
      await FirebaseAuthRest.ensureScopedAnonymous(repo, toWorkspaceId);
      await FirebaseAuthRest.initSilentAuth(repo);
      await FirebaseAuthRest.saveSession(repo, account);
      if (account.email.trim().isNotEmpty) {
        await repo.setSetting('account.email', account.email.trim());
        await repo.setSetting('email', account.email.trim());
      }
      if (account.displayName.trim().isNotEmpty) {
        final curName = ((await repo.settings())['account.name'] ?? '').trim();
        if (curName.isEmpty) {
          await repo.setSetting('account.name', account.displayName.trim());
        }
      }
      await repo.setSetting('account.type', 'enterprise');
      await repo.checkAndAutoPromoteManager();
      await repo.ensureSelfPermissionRow(roleCode: 'admin');
      await repo.restoreManagerOwnership();
      // تنظيف أي مساحات محلية يتيمة حتى تبقى مساحة واحدة فقط في الجهاز
      try {
        await repo.purgeNonEmailWorkspaces();
      } catch (_) {}
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
  static Future<AccountLinkOutcome> _undoFailedSwitch(
    Repo repo, {
    required Map<String, Object?>? backupData,
    required String fromWorkspaceId,
    required String toWorkspaceId,
    required bool swapped,
  }) async {
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
    if (backupData == null) return AccountLinkOutcome.switchDataLost;
    try {
      await repo.importAll(backupData, allowCrossFingerprint: true);
      return AccountLinkOutcome.switchRestored;
    } catch (e) {
      debugPrint('AccountWorkspace: تعذّر استرجاع النسخة: $e');
      return AccountLinkOutcome.switchDataLost;
    }
  }

  /// تثبيت الربط بعد أي مسار ناجح: جلسة + فهرس الحساب + فهرس البريد + فهرس الهاتف +
  /// فهرس البصمة + ربط الـ workspace بحساب Google في الجدول المحلي.
  static Future<void> _afterLink(Repo repo, String backendUrl,
      FirebaseAccount account, String workspaceId) async {
    final previousUid = FirebaseAuthRest.anonymousUid;
    await FirebaseAuthRest.saveSession(repo, account);
    final st = await repo.settings();
    final phone = (st['phone'] ?? st['whatsapp'] ?? '').trim();
    final storeName = (st['businessName'] ?? '').trim();
    final address = (st['address'] ?? '').trim();
    final activity = (st['businessActivity'] ?? '').trim();
    final currency = (st['defaultCurrency'] ?? '').trim();
    final ownerName = account.displayName.trim().isNotEmpty
        ? account.displayName.trim()
        : (st['account.name'] ?? st['sync.deviceName'] ?? '').trim();

    final extraMeta = <String, Object?>{
      if (storeName.isNotEmpty) 'storeName': storeName,
      if (ownerName.isNotEmpty) 'owner_name': ownerName,
      if (phone.isNotEmpty) 'phone': phone,
      if (address.isNotEmpty) 'address': address,
      if (activity.isNotEmpty) 'businessActivity': activity,
      if (currency.isNotEmpty) 'defaultCurrency': currency,
    };

    await bind(
      backendUrl: backendUrl,
      uid: account.uid,
      workspaceId: workspaceId,
      email: account.email,
      phone: phone,
      extraMeta: extraMeta,
      force: true,
    );
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
          'owner_name': ownerName,
          if (storeName.isNotEmpty) 'name': storeName,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [workspaceId],
      );
    } catch (_) {}
    await ensureDeviceId(repo);
  }

  /// مزامنة بيانات المنشأة والملف الشخصي (الاسم، الهاتف، العنوان، النشاط، البريد)
  /// مع عقدة meta.json والفهارس السحابية (emails_index / phones_index) + نسخة احتياطية فورية.
  static Future<void> syncWorkspaceMetaToCloud(
    Repo repo, {
    required String backendUrl,
  }) async {
    if (backendUrl.isEmpty) return;
    try {
      if (await repo.workspaceMode() == 'member') return;
      final wsId = repo.requireWorkspaceId;
      if (wsId.isEmpty || wsId == 'default') return;
      final st = await repo.settings();
      final email = (st['account.email'] ?? st['email'] ?? '').trim();
      final phone = (st['phone'] ?? st['whatsapp'] ?? '').trim();
      final storeName = (st['businessName'] ?? '').trim();
      final address = (st['address'] ?? '').trim();
      final activity = (st['businessActivity'] ?? '').trim();
      final currency = (st['defaultCurrency'] ?? '').trim();
      final ownerName =
          (st['account.name'] ?? st['sync.deviceName'] ?? '').trim();
      final uid = await FirebaseAuthRest.savedUid(repo);

      final extraMeta = <String, Object?>{
        if (storeName.isNotEmpty) 'storeName': storeName,
        if (ownerName.isNotEmpty) 'owner_name': ownerName,
        if (phone.isNotEmpty) 'phone': phone,
        if (address.isNotEmpty) 'address': address,
        if (activity.isNotEmpty) 'businessActivity': activity,
        if (currency.isNotEmpty) 'defaultCurrency': currency,
      };

      await bind(
        backendUrl: backendUrl,
        uid: uid,
        workspaceId: wsId,
        email: email,
        phone: phone,
        extraMeta: extraMeta,
        force: true,
      );
      await AutoBackupService.silentWorkspaceBackup(repo, force: true);
    } catch (_) {}
  }
}
