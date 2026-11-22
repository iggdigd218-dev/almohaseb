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

import '../repository.dart';
import 'apply_remote.dart';
import 'conflict_resolver.dart';
import 'firebase_auth_service.dart';
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

    // منع مزامنة الصور عبر المزامنة السحابية (Firebase) — تقتصر الصور حصراً على النسخ المحلية وGoogle Drive.
    if (bodyMap['payload'] is Map) {
      final p = Map<String, Object?>.from(bodyMap['payload'] as Map);
      p['image'] = '';
      p['attachment'] = '';
      p['attachment_hash'] = '';
      p.remove('images');
      p['logo'] = '';
      bodyMap['payload'] = p;
    }

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
      } catch (_) {
        // انقطاع شبكة/خادم — سنعيد المحاولة بعد المهلة.
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
