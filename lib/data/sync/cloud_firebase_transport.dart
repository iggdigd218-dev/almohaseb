// طبقة Firebase Realtime Database (REST) للمزامنة السحابية التزايدية (Production-hardened).
//
// التطويرات عن النسخة السابقة:
//  - سحب تزايدي (incremental pull) باستخدام sync_meta.lastCloudOpId بدل آخر 500 عملية فقط.
//  - إرسال auth=<idToken> مع كل طلب: حساب Google إن وُجد، وإلا هوية
//    الجهاز المجهولة (المرحلة 2) — فلا طلب بلا مصادقة بعد اليوم.
//  - تحقق HTTPS فقط (رفض http).
//  - validation لـ URL.
//  - استخدام startAfter لـ pagination عند تجاوز الدفعات.
//  - لا نعتمد على ترتيب السيرفر فقط؛ نحتفظ cursor محلي.
//  - استماع فوري SSE: قناة مفتوحة تُخطرنا لحظة وصول أي عملية جديدة
//    (المزامنة تصبح شبه فورية بدل انتظار السحب الدوري).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../core/desktop_net.dart';
import '../repository.dart';
import 'apply_remote.dart';
import 'conflict_resolver.dart';
import 'device_id.dart';
import 'firebase_auth_service.dart';
import 'chat_hooks.dart';
import 'operation.dart';
import 'sync_engine.dart';

class CloudFirebaseTransport implements SyncTransport {
  final Repo repo;
  final String backendUrl;
  final String workspaceId;
  final Future<Database> Function() _dbProvider;
  final Future<String?> Function() _idTokenProvider;
  static const int kPullPageSize = 500;
  bool _serverIndexAvailable = true;

  CloudFirebaseTransport({
    required this.repo,
    required Future<Database> Function() dbProvider,
    required this.backendUrl,
    required this.workspaceId,
    Future<String?> Function()? idTokenProvider,
  })  : _dbProvider = dbProvider,
        _idTokenProvider = idTokenProvider ?? (() async => null);

  factory CloudFirebaseTransport.validated({
    required Repo repo,
    required Future<Database> Function() dbProvider,
    required String backendUrl,
    required String workspaceId,
    Future<String?> Function()? idTokenProvider,
  }) {
    final trimmed = backendUrl.trim();
    if (trimmed.isEmpty) throw ArgumentError('backendUrl فارغ');
    final u = Uri.tryParse(trimmed);
    if (u == null || !u.hasScheme || !u.isScheme('https')) {
      throw ArgumentError('رابط Firebase يجب أن يبدأ بـ https://');
    }
    if (!u.host.contains('firebaseio.com') &&
        !u.host.contains('firebasedatabase.app')) {
      // نقبل أيضًا روابط مخصصة ولكن مع تحذير ضمني — نسمح لمرونة التطوير.
    }
    return CloudFirebaseTransport(
      repo: repo,
      dbProvider: dbProvider,
      backendUrl: trimmed,
      workspaceId: workspaceId,
      idTokenProvider: idTokenProvider,
    );
  }

  Future<Database> get _db => _dbProvider();

  @override
  String get targetId => SyncTarget.cloud;

  String get _root =>
      '${backendUrl.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(workspaceId)}';

  String _opPath(String opId) =>
      '$_root/operations/${Uri.encodeComponent(opId)}.json';
  /// مسار الاستماع SSE — بالصيغة القياسية المعتمدة للنطاق الإقليمي:
  ///   `$baseUrl/workspaces/$workspaceId/operations.json`
  /// baseUrl يصل مُطبَّعاً بلا شرطة نهائية (effectiveBackendUrl) —
  /// شرطة مكررة قبل /workspaces كانت تُنتج 404 (sse-http-404) على نطاق
  /// firebasedatabase.app الإقليمي، و_root يزيل أي بقايا احتياطاً.
  String get _opsPath => '$_root/operations.json';

  Map<String, String> get _authHeaders {
    return {'Content-Type': 'application/json'};
  }

  // (دفعة 57) تتبع انتهاء صلاحية JWT استباقياً: نفك حقل exp من التوكن
  // ونرفض إرفاق توكن منتهٍ (أو على وشك الانتهاء خلال 60 ثانية) بدل
  // إهدار طلب كامل ينتظر 401/403 ثم يُعاد. نتيجة الفك مُخبأة لكل توكن.
  String? _expCachedToken;
  int _expCachedMs = 0;

  static int jwtExpiryMs(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return 0;
      var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (payload.length % 4 != 0) {
        payload += '=';
      }
      final m = jsonDecode(utf8.decode(base64Decode(payload)));
      if (m is! Map) return 0;
      final exp = (m['exp'] as num?)?.toInt() ?? 0;
      return exp * 1000;
    } catch (_) {
      return 0;
    }
  }

  Future<String?> _idToken() async {
    final tok = await _idTokenProvider();
    if (tok != null && tok.isNotEmpty) {
      if (!identical(tok, _expCachedToken) && tok != _expCachedToken) {
        _expCachedToken = tok;
        _expCachedMs = jwtExpiryMs(tok);
      }
      final expired = _expCachedMs > 0 &&
          DateTime.now().millisecondsSinceEpoch > _expCachedMs - 60000;
      if (!expired) return tok;
      // توكن Google منتهٍ/يوشك → نُكمل للهوية المجهولة أدناه.
    }
    // (المرحلة 2) لا حساب Google (أو توكنه منتهٍ) → توكن هوية الجهاز
    // المجهولة: يضمن أن كل طلب يحمل auth.uid، فتعمل قواعد الأمان.
    return FirebaseAuthRest.cloudIdToken();
  }

  @override
  Future<void> push(SyncOperation op) async {
    final uri = Uri.parse(_opPath(op.id));
    // ختم وقت الخادم: فيربيس يستبدل {".sv":"timestamp"} بوقت خادمه (ملي
    // ثانية) لحظة الكتابة — يقضي على ثغرة انحراف ساعات الأجهزة التي كانت
    // تُسقط عمليات جهازٍ ساعتُه متأخرة عن مؤشر السحب لدى الآخرين.
    final bodyMap = Map<String, Object?>.from(
        jsonDecode(op.toJson()) as Map)
      ..['server_ts'] = {'.sv': 'timestamp'};
    final body = jsonEncode(bodyMap);
    final token = await _idToken();
    final auth =
        token == null ? null : 'auth=${Uri.encodeQueryComponent(token)}';
    final targetUri = auth == null ? uri : uri.replace(query: auth);
    var res = await http
        .put(targetUri, body: body, headers: _authHeaders)
        .timeout(const Duration(seconds: 10));
    if ((res.statusCode == 401 || res.statusCode == 403) && token != null) {
      // (المرحلة 2) إعادة المحاولة **بلا مصادقة** أُلغيت نهائياً: القواعد
      // تشترط `auth != null`، والطلب العاري كان يخفي غياب الهوية فقط
      // (ثغرة أ-1). الآن: نجدّد توكن الجهاز ونعيد المحاولة مرة واحدة.
      final fresh = await FirebaseAuthRest.forceRefreshToken();
      if (fresh != null && fresh != token) {
        res = await http
            .put(
              uri.replace(query: 'auth=${Uri.encodeComponent(fresh)}'),
              body: body,
              headers: _authHeaders,
            )
            .timeout(const Duration(seconds: 10));
      }
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw StateError('cloud-auth-failed: ${res.statusCode}');
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('cloud-http-${res.statusCode}');
    }
    final db = await _db;
    await db.update(
      'operations',
      {'server_time': DateTime.now().toIso8601String(), 'synced': 1},
      where: 'id = ?',
      whereArgs: [op.id],
    );
    await db.update(
      'devices',
      {'last_sync_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [op.deviceId],
    );

    // تسجيل شواهد القبور في السحابة عند حذف صنف لضمان عدم إحيائه على الأجهزة المنضمة
    if (op.entityType == EntityKind.item && op.opType == OpKind.delete_) {
      try {
        final tombUri = Uri.parse(
            '$_root/deleted_items/${Uri.encodeComponent(op.entityId)}.json');
        final targetTombUri =
            auth == null ? tombUri : tombUri.replace(query: auth);
        final tombBody = jsonEncode({
          'id': op.entityId,
          'is_deleted': 1,
          'deleted_at': op.deviceTime.isNotEmpty
              ? op.deviceTime
              : DateTime.now().toIso8601String(),
          'server_ts': {'.sv': 'timestamp'},
        });
        await http
            .put(targetTombUri, body: tombBody, headers: _authHeaders)
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  // ==================== المصافحة النشطة للسجل (دفعة 53) ====================
  // الجهاز يتحقق بنفسه من عضويته في /roster/$deviceId — الطرد يُكتشف حتى
  // لو حُذفت عقدته نهائياً (وليس فقط عند وسمها revoked/expelled).

  /// يُستدعى عند اكتشاف أن هذا الجهاز طُرد/حُذف من سجل المجموعة.
  /// تبديل فحص المفاتيح الأجنبية (خارج المعاملات فقط — PRAGMA داخل
  /// معاملة لا أثر له في SQLite).
  Future<void> _setForeignKeys(bool enabled) async {
    try {
      await (await _db)
          .execute('PRAGMA foreign_keys = ${enabled ? 'ON' : 'OFF'}');
    } catch (_) {}
  }

  Future<int> pull({ConflictResolver? resolver, bool forceFullSync = false}) async {
    final db = await _db;
    // نستخدم timestamp-based cursor مع overlap للسماح بالوصول المتأخر.
    final lastTsRow = await db.query(
      'sync_meta',
      where: 'key = ?',
      whereArgs: ['lastCloudTs:$workspaceId'],
      limit: 1,
    );
    int lastTsMs = 0;
    if (lastTsRow.isNotEmpty && !forceFullSync) {
      final v = '${lastTsRow.first['value']}';
      // القيمة المخزّنة قد تكون ISO (الشكل الجديد) أو ميلي ثانية (قواعد قديمة).
      lastTsMs = DateTime.tryParse(v)?.millisecondsSinceEpoch ??
          (int.tryParse(v) ?? 0);
    }
    // overlap بثانيتين لالتقاط العمليات التي كُتبت أثناء سحبنا السابق.
    // المؤشر و startAt كلاهما بتوقيت خادم فيربيس (server_ts) — لا اعتماد
    // على ساعات الهواتف النصية (ISO) إطلاقاً، فجهاز ساعته متأخرة دقائق
    // لن تسقط عملياته من سحب بقية الأجهزة (Clock Drift).
    final startAtMs = forceFullSync ? 0 : (lastTsMs > 2000 ? lastTsMs - 2000 : 0);
    final r = resolver ?? ConflictResolver();
    int applied = 0;
    int maxTsMs = lastTsMs;
    // (2026-09-22) عمليات مُهمَلة لأنها من مساحة أخرى — كانت تُسقط بصمت.
    int droppedOtherWs = 0;
    String droppedSample = '';
    final ourId = await ensureDeviceId(repo);
    // رسائل دردشة وصلت في هذه السحبة — تُشعر بعد إغلاق المعاملة.
    final chatOps = <SyncOperation>[];
    // (دفعة 58 — متطلب 18) عمليات user واردة: قد تحمل تغيير دور/صلاحيات
    // هذا العضو من المدير — تُفحص بعد كل معاملة لإخطار العضو لحظياً.
    final roleOps = <SyncOperation>[];
    // (إصلاح تسليم الإدارة) عمليات نقل ملكية واردة — إخطار فوري للمستلم.
    final ownershipOps = <SyncOperation>[];

    bool hasMore = true;
    int currentStartAtMs = startAtMs;
    var serverFiltered = _serverIndexAvailable;
    while (hasMore) {
      final params = <String, String>{
        // الترشيح بختم الخادم الرقمي (server_ts) وليس timestamp النصي:
        // فيربيس يكتب server_ts بساعته هو عند الرفع، فالمؤشر محصّن ضد
        // انحراف ساعات الأجهزة كلياً.
        if (serverFiltered) ...{
          'orderBy': jsonEncode('server_ts'),
          'limitToFirst': '$kPullPageSize',
          if (currentStartAtMs > 0) 'startAt': '$currentStartAtMs',
        },
      };
      final tok = await _idToken();
      if (tok != null) params['auth'] = tok;
      final uri = Uri.parse(_opsPath).replace(
          queryParameters: params.isEmpty ? null : params);
      var res = await http.get(uri).timeout(const Duration(seconds: 15));
      if ((res.statusCode == 401 || res.statusCode == 403) && tok != null) {
        // (المرحلة 2) لا محاولة بلا مصادقة — نجدّد التوكن ونعيد مرة واحدة.
        final fresh = await FirebaseAuthRest.forceRefreshToken();
        if (fresh != null && fresh != tok) {
          params['auth'] = fresh;
          final retried =
              Uri.parse(_opsPath).replace(queryParameters: params);
          res = await http.get(retried).timeout(const Duration(seconds: 15));
        }
      }
      // قواعد RTDB بلا فهرس ".indexOn": "timestamp" → فيربيس يرفض orderBy
      // بخطأ 400 فيفشل السحب للأبد رغم نجاح الدفع (البيانات تصعد ولا تنزل
      // أبداً — أخطر عطل صامت). الحل: جلب كامل بلا orderBy والفرز/الترشيح
      // محلياً. يعمل على القواعد الافتراضية دون أي إعداد من المستخدم.
      if (res.statusCode == 400 && serverFiltered) {
        _serverIndexAvailable = false;
        serverFiltered = false;
        final bareParams = <String, String>{if (tok != null) 'auth': tok};
        final bareUri = Uri.parse(_opsPath).replace(
            queryParameters: bareParams.isEmpty ? null : bareParams);
        res = await http.get(bareUri).timeout(const Duration(seconds: 30));
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw StateError('cloud-auth-failed');
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('cloud-http-${res.statusCode}');
      }
      if (res.body.trim().isEmpty || res.body.trim() == 'null') {
        hasMore = false;
        break;
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map || decoded.isEmpty) {
        hasMore = false;
        break;
      }
      var entries = decoded.entries.toList();
      // وقت العملية للمؤشر/الترشيح: نفضّل server_ts (ختم خادم فيربيس،
      // محصّن ضد انحراف ساعات الأجهزة) ونعود لـ timestamp للعمليات القديمة.
      int entryMs(Object? v) {
        if (v is! Map) return 0;
        final sv = v['server_ts'];
        if (sv is int && sv > 0) return sv;
        if (sv is num && sv > 0) return sv.toInt();
        return DateTime.tryParse('${v['timestamp'] ?? ''}')
                ?.millisecondsSinceEpoch ??
            0;
      }

      // في وضع الجلب الكامل (بلا فهرس خادم): رشّح محلياً بنفس شرط startAt
      // حتى لا نعيد معالجة تاريخ كامل في كل دورة (idempotent على أي حال).
      if (!serverFiltered && currentStartAtMs > 0) {
        entries = entries.where((e) => entryMs(e.value) >= currentStartAtMs).toList();
      }
      // فرز محلي حسب ختم الخادم (server_ts) ثم opId لضمان الترتيب —
      // ساعة الخادم مصدر الحقيقة الوحيد، لا ساعات الأجهزة.
      entries.sort((a, b) {
        final va = a.value;
        final vb = b.value;
        if (va is! Map || vb is! Map) return 0;
        final c = entryMs(va).compareTo(entryMs(vb));
        return c != 0 ? c : (a.key as String).compareTo(b.key as String);
      });
      // ══ (2026-09-22) فرز حسب التبعية قبل التطبيق ══
      // الترتيب الزمني لا يراعي أن الفاتورة تحتاج حسابها وصنفها: وصولها
      // أولاً يرفع FOREIGN KEY 787 فيتوقف السحب. نُقدّم الآباء على الأبناء
      // (حسابات ← أصناف ← فواتير ← بنود) ونؤجّل الحذف للنهاية.
      entries.sort((a, b) {
        final c = dependencyRankOfMap(a.value)
            .compareTo(dependencyRankOfMap(b.value));
        if (c != 0) return c;
        final t = entryMs(a.value).compareTo(entryMs(b.value));
        return t != 0 ? t : (a.key as String).compareTo(b.key as String);
      });
      // ══ (2026-09-22) حزام الأمان الأخير ══
      // PRAGMA لا يعمل داخل معاملة — لذلك يُضبط خارجها: يُعطّل فحص
      // المفاتيح الأجنبية أثناء تطبيق الدفعة ويُعاد بعدها فوراً.
      await _setForeignKeys(false);
      try {
        const microBatchSize = 40;
        for (var i = 0; i < entries.length; i += microBatchSize) {
          final end = (i + microBatchSize < entries.length)
              ? i + microBatchSize
              : entries.length;
          final chunk = entries.sublist(i, end);
          await db.transaction((txn) async {
            for (final entry in chunk) {
              final v = entry.value;
              if (v is! Map) continue;
              final op = SyncOperation.fromMap(Map<String, Object?>.from(v));
              if (op.workspaceId != workspaceId &&
                  op.workspaceId != 'default' &&
                  workspaceId != 'default' &&
                  op.workspaceId.isNotEmpty) {
                droppedOtherWs++;
                if (droppedSample.isEmpty) droppedSample = op.workspaceId;
                continue;
              }
              // المؤشر يتقدم دائماً بـ server_ts (ختم خادم فيربيس الموثوق) —
              // في الحالتين (ترشيح خادمي بـ orderBy=server_ts أو جلب كامل).
              // العمليات القديمة جداً بلا server_ts تسقط لـ timestamp كاحتياط.
              final opMs = entryMs(v);
              if (opMs > maxTsMs) maxTsMs = opMs;
              // idempotent: نفس opId موجود مسبقًا -> تجاهل.
              final idempotentQ = await txn.query(
                'operations',
                where: 'id = ?',
                whereArgs: [op.id],
                limit: 1,
              );
              if (idempotentQ.isNotEmpty) {
                continue;
              }
              final ok = await repo.applyRemoteOperation(txn, op, r);
              if (ok) applied++;
              if (ok &&
                  op.entityType == EntityKind.message &&
                  op.deviceId != ourId) {
                chatOps.add(op);
              }
              // (دفعة 58 — متطلب 18) تحديث user وارد من جهاز آخر — قد يكون
              // المدير غيّر دور/صلاحيات هذا العضو: يُفحص بعد المعاملة.
              if (ok &&
                  op.entityType == EntityKind.user &&
                  op.deviceId != ourId) {
                roleOps.add(op);
              }
              // (إصلاح تسليم الإدارة) نقل ملكية وارد: إخطار المستلم فوراً.
              if (ok &&
                  op.entityType == EntityKind.setting &&
                  op.entityId == 'ownershipTransfer' &&
                  op.deviceId != ourId) {
                ownershipOps.add(op);
              }
            }
          });
          if (end < entries.length) {
            // إفساح المجال للاستعلامات والعمليات المحلية الفورية (الحسابات، الإضافة، الحفظ)
            await Future<void>.delayed(Duration.zero);
          }
        }
      } finally {
        // إعادة فحص المفاتيح الأجنبية في كل الحالات (نجاح أو استثناء).
        await _setForeignKeys(true);
      }
      // إشعار وصول رسائل دردشة جماعية عبر السحابة (نفس سلوك LAN):
      // خارج المعاملة، وبعد نجاح التطبيق فقط.
      for (final op in chatOps) {
        try {
          final senderRows = await db.query('devices',
              where: 'id = ?', whereArgs: [op.deviceId], limit: 1);
          // الاسم الموحد: الافتراضي «مستخدم جديد» حتى يسميه المدير.
          var senderName = senderRows.isNotEmpty
              ? ((senderRows.first['name'] as String?) ?? '')
              : '';
          if (senderName.trim().isEmpty) senderName = kDefaultMemberName;
          var body = '${op.payload['body'] ?? ''}';
          if (body.isEmpty) {
            body = switch ('${op.payload['kind'] ?? 'text'}') {
              'image' => '📷 صورة',
              'video' => '🎬 فيديو',
              'audio' => '🎙️ رسالة صوتية',
              'file' => '📎 ملف',
              _ => '',
            };
          }
          if (body.isNotEmpty) {
            ChatHooks.onChatMessage?.call(senderName, body);
          }
        } catch (_) {}
      }
      chatOps.clear();
      // (دفعة 58 — متطلب 18) إخطار لحظي للعضو عند تغيير دوره/صلاحياته:
      // إن كانت عملية user الواردة تخص المستخدم المرتبط بجهازنا نبثّ
      // إشعاراً فورياً + نبضة تحديث حي للواجهة — لا حاجة لإعادة تشغيل.
      for (final op in roleOps) {
        try {
          final own = await db.query('devices',
              columns: ['user_id'],
              where: 'id = ?',
              whereArgs: [ourId],
              limit: 1);
          final myUid = own.isNotEmpty ? own.first['user_id'] : null;
          final isOurUser = (myUid != null && op.entityId == '$myUid') ||
              (await repo.workspaceMode()) == 'member';
          if (!isOurUser) continue;

          final roleCode = '${op.payload['role'] ?? ''}';
          final opUid = int.tryParse(op.entityId);
          if (opUid != null) {
            await db.update('users', {'is_me': 0});
            await db.update('users', {
              'is_me': 1,
              'role': roleCode,
              'active': 1,
            }, where: 'id = ?', whereArgs: [opUid]);
            await db.update('devices', {'user_id': opUid},
                where: 'id = ?', whereArgs: [ourId]);
          }

          final roleLabel = switch (roleCode) {
            'admin' => 'المدير',
            'agent' => 'وكيل المدير',
            'accountant' => 'محاسب',
            'dataentry' => 'مدخل بيانات',
            'viewer' => 'عرض فقط',
            _ => roleCode,
          };
          ChatHooks.onMemberNotice?.call(
            'تحدّثت صلاحياتك',
            roleLabel.isEmpty
                ? 'قام المدير بتحديث صلاحيات حسابك — سرى التغيير فوراً.'
                : 'دورك الآن: $roleLabel — سرى التغيير فوراً على هذا الجهاز.',
          );
        } catch (_) {}
      }
      roleOps.clear();
      // (إصلاح تسليم الإدارة) بلاغ فوري بعد تطبيق نقل الملكية:
      // المستلم يرى «أنت الآن مدير المجموعة» والبقية تُخطر بتغيّر المدير.
      for (final op in ownershipOps) {
        try {
          final decoded = jsonDecode('${op.payload['value'] ?? '{}'}');
          if (decoded is! Map) continue;
          final newOwnerDev = '${decoded['owner_device_id'] ?? ''}';
          if (newOwnerDev == ourId) {
            // (استرداد طارئ) تمييز الإرجاع الطوعي: المستلم يعيد الإدارة
            // للمالك السابق — إشعار «عادت إليك» بدل «سلّمك».
            if (decoded['handback'] == true) {
              ChatHooks.onMemberNotice?.call(
                '👑 عادت إليك الإدارة',
                'لقد تم استلام صلاحية المدير وعادت إليك — أنت الآن مالك '
                    'المجموعة بكل الصلاحيات، وظهرت لديك إدارة المجموعة '
                    'والأجهزة فوراً.',
              );
            } else {
              ChatHooks.onMemberNotice?.call(
                '👑 أنت الآن مدير المجموعة',
                'سلّمك المدير السابق الإدارة — أصبحت مالك المجموعة بكل '
                    'الصلاحيات، وظهرت لديك إدارة المجموعة والأجهزة فوراً.',
              );
            }
          } else {
            final rows = await db.query('devices',
                columns: ['name'],
                where: 'id = ?',
                whereArgs: [newOwnerDev],
                limit: 1);
            final name = rows.isNotEmpty
                ? '${rows.first['name'] ?? 'جهاز آخر'}'
                : 'جهاز آخر';
            ChatHooks.onMemberNotice?.call(
              'تغيّر مدير المجموعة',
              'انتقلت إدارة المجموعة إلى «$name».',
            );
          }
        } catch (_) {}
      }
      ownershipOps.clear();

      int pageMaxTs = 0;
      for (final entry in entries) {
        final ms = entryMs(entry.value);
        if (ms > pageMaxTs) pageMaxTs = ms;
      }
      if (pageMaxTs > maxTsMs) maxTsMs = pageMaxTs;

      // تقدم المؤشر للصفحة التالية (بزيادة ملي ثانية واحدة):
      if (serverFiltered && entries.length >= kPullPageSize && pageMaxTs >= currentStartAtMs) {
        currentStartAtMs = pageMaxTs + 1;
        hasMore = true;
      } else {
        hasMore = false;
      }

    // (2026-09-22) عمليات أُسقطت لأنها من مساحة أخرى: كانت تُهمَل بصمت
    // فيبدو السحب ناجحاً ولا يصل شيء — نسجّلها لتظهر صراحةً.
    if (droppedOtherWs > 0) {
      try {
        await repo.setSetting('sync.droppedOtherWs', '$droppedOtherWs');
        await repo.setSetting('sync.droppedOtherWsSample', droppedSample);
      } catch (_) {}
    }
    }

    if (maxTsMs > lastTsMs) {
      // المؤشر يُخزَّن كملي ثانية خادم (رقم) — الشكل القياسي الجديد.
      // القارئ أعلاه يقبل الرقم و ISO القديم معاً (توافق خلفي).
      await db.insert(
          'sync_meta',
          {
            'key': 'lastCloudTs:$workspaceId',
            'value': '$maxTsMs',
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    // جلب شواهد القبور للأصناف الممسوحة (Tombstones / deleted_items) عند السحب الأولي فقط
    if (startAtMs == 0) {
      try {
        final tombUri = Uri.parse('$_root/deleted_items.json');
        final tok = await _idToken();
        final targetTombUri =
            tok == null ? tombUri : tombUri.replace(queryParameters: {'auth': tok});
        final tombRes =
            await http.get(targetTombUri).timeout(const Duration(seconds: 8));
        if (tombRes.statusCode == 200 &&
            tombRes.body.trim().isNotEmpty &&
            tombRes.body.trim() != 'null') {
          final tombData = jsonDecode(tombRes.body);
          if (tombData is Map) {
            await db.transaction((txn) async {
              for (final entry in tombData.entries) {
                final val = entry.value;
                if (val is! Map) continue;
                final rawId = val['id'] ?? entry.key;
                final itemId = int.tryParse('$rawId') ?? rawId;
                final delAt =
                    '${val['deleted_at'] ?? DateTime.now().toIso8601String()}';
                await txn.update(
                  'items',
                  {
                    'is_deleted': 1,
                    'is_active': 0,
                    'deleted_at': delAt,
                  },
                  where: 'id = ?',
                  whereArgs: [itemId],
                );
              }
            });
          }
        }
      } catch (_) {}
    }

    await repo.setSetting('lastCloudSync', DateTime.now().toLocal().toString());
    return applied;
  }

  // ==================== الاستماع الفوري (SSE) ====================

  HttpClient? _sseClient;
  bool _listening = false;
  int _sseRetrySeconds = 2;

  /// يُستدعى عند وصول إشعار بتغيير في السحابة — يشغّل pull فوراً.
  void Function()? onCloudChanged;

  bool get isListening => _listening;

  /// يفتح قناة SSE على مسار العمليات: فيربيس يرسل حدث `put`/`patch`
  /// لحظة كتابة أي جهاز عملية جديدة، فنستدعي onCloudChanged (الذي يشغّل
  /// pull تزايدياً). القناة تعيد الاتصال تلقائياً بتراجع أسّي عند الانقطاع.
  Future<void> startListening() async {
    if (_listening) return;
    _listening = true;
    _sseRetrySeconds = 2;
    // (دفعة 52) اعتماد مضيف الواجهة الخلفية كموثوق لدى طبقة تشخيص TLS
    // (يُقبل رغم فشل التحقق في شبكات تفتيش TLS — الباقي يُرفض دائماً).
    try {
      DesktopNet.trustedHost = Uri.parse(backendUrl).host;
    } catch (_) {}
    unawaited(_sseLoop());
    // (دفعة 54) قناة ثانية خفيفة على شاهدة الطرد الخاصة بنا —
  }

  Future<void> stopListening() async {
    _listening = false;
    try {
      _sseClient?.close(force: true);
    } catch (_) {}
    _sseClient = null;
  }

  Future<void> _sseLoop() async {
    while (_listening) {
      try {
        // (دفعة 52) فحص وصول سريع قبل فتح القناة: استعلام DNS للمضيف —
        // يكشف انقطاع الإنترنت/حجب جدار الحماية فوراً برسالة دقيقة
        // بدل تعليق ثم فشل صامت.
        final host = Uri.parse(backendUrl).host;
        final pre = await DesktopNet.preflight(host);
        if (pre != null) throw SocketException('preflight: $pre');
        // ملاحظة: HttpClient هنا يرث DesktopHttpOverrides العالمية على
        // سطح المكتب (بروكسي بيئة + مهلات + تشخيص شهادات TLS).
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        _sseClient = client;
        final tok = await _idToken();
        // نستمع على مؤشر خفيف (limitToLast=1 مرتب بالمفتاح) — يكفي كجرس
        // إنذار، والسحب الفعلي يمر عبر pull التزايدي المعتاد.
        final params = <String, String>{
          'orderBy': jsonEncode(r'$key'),
          'limitToLast': '1',
          if (tok != null) 'auth': tok,
        };
        final uri = Uri.parse(_opsPath).replace(queryParameters: params);
        final req = await client.getUrl(uri);
        req.headers.set('Accept', 'text/event-stream');
        req.headers.set('Cache-Control', 'no-cache');
        final resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw StateError('sse-http-${resp.statusCode}');
        }
        _sseRetrySeconds = 2; // الاتصال نجح — صفّر التراجع.
        DesktopNet.clearError(); // الشبكة سليمة — امسح أي خطأ معروض.
        String? eventName;
        var skippedInitial = false;
        await for (final line in resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (!_listening) break;
          if (line.startsWith('event:')) {
            eventName = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            if (eventName == 'put' || eventName == 'patch') {
              // أول حدث put هو اللقطة الأولية عند فتح القناة — نتجاهله
              // (السحب الدوري/الافتتاحي يغطيه) ونتفاعل مع ما بعده فقط.
              if (!skippedInitial && eventName == 'put') {
                skippedInitial = true;
              } else {
                try {
                  onCloudChanged?.call();
                } catch (_) {}
              }
            } else if (eventName == 'auth_revoked') {
              break; // أعد الاتصال بتوكن جديد.
            }
          }
        }
      } catch (e) {
        // انقطاع شبكة/خادم — سنعيد المحاولة بعد المهلة، مع تسجيل
        // الخطأ الدقيق (SocketException/HandshakeException/مهلة...)
        // ليُعرض في واجهة المزامنة بدل الفشل الصامت.
        DesktopNet.recordError(e);
      } finally {
        try {
          _sseClient?.close(force: true);
        } catch (_) {}
        _sseClient = null;
      }
      if (!_listening) break;
      await Future<void>.delayed(Duration(seconds: _sseRetrySeconds));
      // تراجع سريع بين 2 إلى 15 ثانية كحد أقصى لسرعة التعافي وإعادة الاتصال.
      _sseRetrySeconds = (_sseRetrySeconds * 2).clamp(2, 15);
    }
  }
}
