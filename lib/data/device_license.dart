// (3.70 — المرحلة 1.3) فحص ترخيص الأجهزة: الاستخدام **الوحيد** المشروع
// لبصمة/هوية الجهاز خارج بروتوكول المزامنة — مطابقة عدد الأجهزة المتصلة
// مع الحد الأقصى المسموح في خطة الاشتراك والترخيص.
//
// معزول تماماً: لا يربط ملكية أي بيانات أو فواتير أو عمليات حسابية
// بالجهاز أو بمعرّف العتاد — الملكية حصراً store_id + user_email.
import '../core/cloud_config.dart';
import 'repository.dart';
import 'sync/subscription_guard.dart';

class DeviceLicenseStatus {
  /// عدد الأجهزة **المقترنة** فعلاً (غير ملغاة ولا مطرودة) في المساحة.
  final int connectedDevices;

  /// مقاعد الخطة (من عقدة الاشتراك السحابية، أو المستنتج محلياً).
  final int maxSeats;

  final bool withinPlan;

  /// true = الحد معروف من حالة سحابية حقيقية (أو مثبّتة)؛
  /// false = تعذّرت القراءة ⇒ لا يُبنى عليه منع (قاعدة: لا نُقفل بالشك).
  final bool resolved;

  const DeviceLicenseStatus({
    required this.connectedDevices,
    required this.maxSeats,
    required this.withinPlan,
    this.resolved = true,
  });
}

class DeviceLicense {
  DeviceLicense._();

  /// الفحص المعزول الوحيد المسموح له بقراءة هوية الأجهزة لأغراض الترخيص.
  ///
  /// (إصلاح 2026-09-23 — مراجعة مدير الترخيص)
  ///  • المقاعد لم تعد تُؤخذ من حالة «none» (max_devices الافتراضي = 1)
  ///    متى تعذّرت القراءة السحابية: مضيف مجموعة بلا شبكة كان يُعرض له
  ///    مقعد واحد. الآن يُستنتج الحد من وضع المساحة المحلي (مجموعة =
  ///    مؤسسة بمقاعدها الافتراضية، وإلا فردي بمقعد)، مع عَلَم resolved
  ///    يمنع بناء أي منع على حدّ غير معروف.
  ///  • «المتصلة» = المقترنة فقط (`is_paired = 1`) — نفس قاعدة استنتاج
  ///    الخطة وعدّاد المقاعد السحابي. الطلبات المعلّقة كانت تُحتسب فتُظهر
  ///    «3/5» بلا جهاز فعلي متصل، وتناقض استنتاج الخطة نفسه.
  ///  • مساحة العمل تُقرأ من المرجع الموحّد لا من أول صف بلا ترتيب.
  ///  • الفشل لا يُسقط استثناءً إلى الواجهة: قراءة جدول devices ومعرف
  ///    المساحة كانت خارج أي try/catch فتصل أخطاؤها لـ SeatUsageBadge.
  static Future<DeviceLicenseStatus> check(Repo repo) async {
    const unknown = DeviceLicenseStatus(
      connectedDevices: 0,
      maxSeats: 0,
      withinPlan: true,
      resolved: false,
    );
    try {
      final db = await repo.database;
      final ws = await SubscriptionGuard.workspaceIdFor(repo);
      final rows = await db.query(
        'devices',
        columns: ['id'],
        where: "workspace_id = ? AND is_paired = 1 "
            "AND (revoked_at IS NULL OR revoked_at = '') "
            "AND (expelled_at IS NULL OR expelled_at = '')",
        whereArgs: [ws],
      );
      final connected = rows.length;

      var seats = 0;
      var resolved = false;
      try {
        final stt = await repo.settings();
        final url = effectiveBackendUrl(stt['cloudBackendUrl']);
        if (url.isNotEmpty) {
          final sub = await SubscriptionGuard.check(repo,
              backendUrl: url, workspaceId: ws);
          // «none» = لا حالة سحابية معروفة (شبكة غائبة/لم يُفحص بعد):
          // max_devices فيه مجرد افتراضي (1) لا معلومة — لا يُعتمد.
          if (sub.status != 'none' && sub.maxDevices > 0) {
            seats = sub.maxDevices;
            resolved = true;
          }
        }
      } catch (_) {}
      if (seats <= 0) {
        // بلا سحابة: الخطة تُستنتج محلياً — الفردي مقعد واحد لا خمسة.
        final mode = await repo.workspaceMode();
        seats =
            (mode == 'host' || mode == 'member') ? kDefaultEnterpriseSeats : 1;
      }
      return DeviceLicenseStatus(
        connectedDevices: connected,
        maxSeats: seats,
        withinPlan: !resolved ? true : connected <= seats,
        resolved: resolved,
      );
    } catch (_) {
      return unknown;
    }
  }
}
