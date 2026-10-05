// (3.70 — المرحلة 5) طلبات خروج الموظفين المؤمَّنة.
//
// الموظف/العضو لا يخرج فوراً: الضغط على «تسجيل الخروج» يحوَّل إلى طلب
// موافقة يُرسل إلى المدير أو الوكيل عبر السحابة (عقدة logout_requests ضمن
// مساحة العمل)، ويبقى جهاز الموظف يعمل حتى الاعتماد. المدير/الوكيل نفسه
// لا يخرج إلا بعد تحقق أمان الجهاز (بصمة/قفل شاشة) وتعيين وكيل.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../repository.dart';
import 'firebase_auth_service.dart';

class LogoutRequestInfo {
  final String id;
  final String email;
  final String name;
  final String status; // pending | approved | rejected
  final int createdAtMs;

  const LogoutRequestInfo({
    required this.id,
    required this.email,
    required this.name,
    required this.status,
    required this.createdAtMs,
  });

  factory LogoutRequestInfo.fromMap(String id, Map<String, dynamic> m) =>
      LogoutRequestInfo(
        id: '${m['id'] ?? id}',
        email: '${m['email'] ?? ''}',
        name: '${m['name'] ?? ''}',
        status: '${m['status'] ?? 'pending'}',
        createdAtMs: int.tryParse('${m['createdAt'] ?? ''}') ?? 0,
      );

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';
}

class LogoutRequests {
  LogoutRequests._();

  static String _root(String base, String ws) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/${Uri.encodeComponent(ws)}';

  static Future<String?> _ensureToken() async {
    var t = FirebaseAuthRest.cachedIdToken;
    if (t != null && t.isNotEmpty) return t;
    try {
      t = await FirebaseAuthRest.cloudIdToken();
    } catch (_) {}
    return t;
  }

  static Uri _authedUrl(String url, String? token) {
    final uri = Uri.parse(url);
    if (token == null || token.isEmpty) return uri;
    final q = Map<String, String>.from(uri.queryParameters)..['auth'] = token;
    return uri.replace(queryParameters: q);
  }

  static Future<Map<String, dynamic>?> _getJson(String url) async {
    var token = await _ensureToken();
    var res = await http
        .get(_authedUrl(url, token))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 401 || res.statusCode == 403) {
      final fresh = await FirebaseAuthRest.forceRefreshToken();
      if (fresh != null && fresh.isNotEmpty) {
        token = fresh;
        res = await http
            .get(_authedUrl(url, token))
            .timeout(const Duration(seconds: 20));
      }
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('HTTP ${res.statusCode}');
    }
    final t = res.body.trim();
    if (t.isEmpty || t == 'null') return null;
    final d = jsonDecode(t);
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  static Future<void> _putJson(String url, Object body) async {
    final token = await _ensureToken();
    final res = await http
        .put(_authedUrl(url, token),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('HTTP ${res.statusCode}');
    }
  }

  /// (الموظف) إنشاء طلب خروج — يعيد معرف الطلب ويُخزّنه محلياً للمتابعة.
  static Future<String> create(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
    required String email,
    String name = '',
  }) async {
    final em = email.trim().toLowerCase();
    if (em.isEmpty) throw StateError('لا يوجد بريد للمستخدم الحالي.');
    final id = 'lo_${DateTime.now().millisecondsSinceEpoch}_'
        '${em.hashCode.toUnsigned(32).toRadixString(36)}';
    await _putJson(
      '${_root(backendUrl, workspaceId)}/logout_requests/$id.json',
      {
        'id': id,
        'email': em,
        'name': name,
        'status': 'pending',
        'createdAt': {'.sv': 'timestamp'},
      },
    );
    await repo.setSetting('logout.requestId', id);
    return id;
  }

  /// (المدير/الوكيل) قائمة الطلبات المعلقة في المساحة.
  static Future<List<LogoutRequestInfo>> listPending({
    required String backendUrl,
    required String workspaceId,
  }) async {
    final node = await _getJson(
        '${_root(backendUrl, workspaceId)}/logout_requests.json');
    if (node == null) return const [];
    final out = <LogoutRequestInfo>[];
    for (final e in node.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final info =
          LogoutRequestInfo.fromMap(e.key, Map<String, dynamic>.from(v));
      if (info.isPending) out.add(info);
    }
    out.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    return out;
  }

  /// (المدير/الوكيل) اعتماد أو رفض طلب.
  static Future<void> resolve({
    required String backendUrl,
    required String workspaceId,
    required String id,
    required bool approve,
  }) async {
    await _putJson(
      '${_root(backendUrl, workspaceId)}/logout_requests/$id/status.json',
      approve ? 'approved' : 'rejected',
    );
  }

  /// (الموظف) حالة طلبه الحالي — تُستطلع حتى الاعتماد أو الرفض.
  static Future<String> statusOf({
    required String backendUrl,
    required String workspaceId,
    required String id,
  }) async {
    final node = await _getJson(
        '${_root(backendUrl, workspaceId)}/logout_requests/$id.json');
    return '${node?['status'] ?? ''}';
  }
}
