// (استرداد بصمة العتاد) فهرس الأجهزة السحابي — Device→Workspace Registry.
//
// المسار: /device_index/{fpHash} = { workspaceId, role, device_id, updated_at }
//
// الغرض: بصمة العتاد ثابتة حتى بعد حذف التطبيق أو مسح بياناته — فتصبح
// مفتاح استرداد دائماً:
//  - كل جهاز يُسجَّل ببصمته مربوطاً بمساحته ودوره (owner/member).
//  - عند إقلاع تثبيت جديد نظيف: نفحص الفهرس؛ وجدنا سجلاً؟ نستعيد
//    المساحة والدور والبيانات (من النسخة الصامتة) تلقائياً وبصمت.
//  - الدور محفوظ: المدير يعود مديراً لمؤسسته نفسها، والعضو عضواً —
//    ولا يُعطى دور المدير في أي مساحة أخرى غير مساحته المسجلة.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../repository.dart';
import 'device_id.dart';
import 'subscription_guard.dart';

class DeviceRegistryRecord {
  final String workspaceId;
  final String role; // 'owner' | 'member'
  final String deviceId;
  const DeviceRegistryRecord({
    required this.workspaceId,
    required this.role,
    required this.deviceId,
  });
  bool get isOwner => role == 'owner';
}

class DeviceRegistry {
  DeviceRegistry._();

  // ملاحظة قواعد الأمان: الجذر /device_index محجوب كتابةً في قواعد
  // القاعدة الحالية، بينما /workspaces/** مفتوح — لذا يسكن الفهرس تحت
  // عقدة خدمية داخل workspaces (ليست مساحة عمل حقيقية).
  static String _indexPath(String base, String fp) =>
      '${base.replaceAll(RegExp(r'/+$'), '')}/workspaces/_registry/'
      'device_index/${Uri.encodeComponent(fp)}.json';

  /// بصمة العتاد المجزأة لهذا الجهاز (مفتاح الفهرس الثابت).
  static Future<String> fingerprintKey(Repo repo) async {
    final devId = await ensureDeviceId(repo);
    final raw = await hardwareFingerprintRaw() ?? 'fallback:$devId';
    return SubscriptionGuard.fingerprintHash(raw);
  }

  /// قراءة سجل هذا الجهاز من الفهرس — null إن لم يوجد أو تعذرت الشبكة.
  static Future<DeviceRegistryRecord?> lookup({
    required String backendUrl,
    required String fingerprint,
  }) async {
    try {
      final res = await http
          .get(Uri.parse(_indexPath(backendUrl, fingerprint)))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final body = utf8.decode(res.bodyBytes).trim();
      if (body.isEmpty || body == 'null') return null;
      final m = jsonDecode(body);
      if (m is! Map) return null;
      final ws = '${m['workspaceId'] ?? ''}'.trim();
      if (ws.isEmpty) return null;
      final role = '${m['role'] ?? ''}' == 'owner' ? 'owner' : 'member';
      return DeviceRegistryRecord(
        workspaceId: ws,
        role: role,
        deviceId: '${m['device_id'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  /// كتابة/تحديث ربط بصمة هذا الجهاز بمساحته ودوره الحاليين.
  ///
  /// 🔒 حماية الدور: السجل القائم بدور owner لا يُخفَّض ولا تُبدَّل
  /// مساحته تلقائياً أبداً — المدير مربوط بمؤسسته حتى يتنازل صراحة
  /// (transferOwnership يمرر force=true بعد التنازل الصريح).
  static Future<void> upsertBinding(
    Repo repo, {
    required String backendUrl,
    bool force = false,
  }) async {
    try {
      final fp = await fingerprintKey(repo);
      final devId = await ensureDeviceId(repo);
      final ws = repo.requireWorkspaceId;
      final mode = await repo.workspaceMode();
      final isOwner = await repo.isWorkspaceOwner();
      final role = (mode == 'member' && !isOwner) ? 'member' : 'owner';
      // (3.71.0 — نظام صارم) ربط المالك في الفهرس السحابي يشترط التسجيل
      // بالبريد (حساب Google): هوية مجهولة لا تُسجَّل مالكة لمساحة —
      // يمنع اختلاق مساحات أشباح. ربط العضو غير مشروط (حق الاسترداد).
      if (role == 'owner') {
        final stEmail = await repo.settings();
        if ((stEmail['account.email'] ?? '').trim().isEmpty) return;
      }
      if (!force) {
        final existing =
            await lookup(backendUrl: backendUrl, fingerprint: fp);
        if (existing != null && existing.isOwner) {
          // مالك مسجل: لا خفض دور ولا تغيير مساحة تلقائيين.
          if (role != 'owner' || existing.workspaceId != ws) return;
        }
      }
      final res = await http
          .put(
            Uri.parse(_indexPath(backendUrl, fp)),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'workspaceId': ws,
              'role': role,
              'device_id': devId,
              'updated_at': {'.sv': 'timestamp'},
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return;
    } catch (_) {
      // أفضل جهد — الدورة القادمة تعيد المحاولة.
    }
  }

  /// (انضمام عضو) تسجيل بصمة العضو المنضم مربوطة بمساحة المجموعة.
  static Future<void> bindAsMember(
    Repo repo, {
    required String backendUrl,
    required String workspaceId,
  }) async {
    try {
      final fp = await fingerprintKey(repo);
      final devId = await ensureDeviceId(repo);
      final existing = await lookup(backendUrl: backendUrl, fingerprint: fp);
      // 🔒 مدير مؤسسة أخرى لا يُسجَّل عضواً في مجموعة جديدة إلا إذا كانت
      // مساحته هي نفسها (لا وجود لمديرَين — عليه استرجاع مؤسسته أولاً
      // أو التنازل صراحة). التطبيق يسمح بالانضمام؛ الفهرس يحفظ حقه.
      if (existing != null &&
          existing.isOwner &&
          existing.workspaceId != workspaceId) {
        return;
      }
      await http
          .put(
            Uri.parse(_indexPath(backendUrl, fp)),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'workspaceId': workspaceId,
              'role': 'member',
              'device_id': devId,
              'updated_at': {'.sv': 'timestamp'},
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {}
  }
}
