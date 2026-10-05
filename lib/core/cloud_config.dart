import 'dart:io' show Platform;

// إعدادات السحابة المضمنة برمجياً.
//
// kDefaultCloudBackendUrl: رابط قاعدة Firebase RTDB الرسمي للنظام (النطاق
// الإقليمي europe-west1 — قواعد المناطق خارج us-central1 تُخدَم حصرياً عبر
// نطاق firebasedatabase.app؛ استخدام firebaseio.com معها يعيد 404 ويكسر SSE) —
// مثبّت كرابط افتراضي دائم (Zero-Config Cloud Onboarding): المستخدم
// الجديد تبدأ تجربته ويعمل محرك المزامنة فوراً دون أي إعداد يدوي.
// يمكن تجاوزه وقت البناء عبر --dart-define=NEXORA_BACKEND_URL=...
// أو وقت التشغيل بضبط رابط مخصص في الإعدادات ← المزامنة السحابية.
const String kDefaultCloudBackendUrl = String.fromEnvironment(
  'NEXORA_BACKEND_URL',
  // (إعادة تثبيت 2026-09-19) الرابط الرسمي الافتراضي الدائم — بدونه
  // يموت الإقلاع صفري الإعداد (Zero-Config) وتفشل CLOUD-CFG-01: التراجع
  // الأخير تركه فارغاً بينما توثيق هذا الملف وعقد الاختبار يتطلبانه.
  defaultValue:
      'https://nexora-ledger-default-rtdb.europe-west1.firebasedatabase.app',
);

/// (اختبارات فقط) تجاوز الرابط الافتراضي — تضبطه حزم الاختبار على ''
/// لمحاكاة «لا سحابة»؛ null = السلوك الإنتاجي الطبيعي.
String? debugDefaultBackendUrlOverride;

/// 🔒 عزل بيئة الاختبار عن قاعدة الإنتاج: flutter test يضبط المتغير
/// FLUTTER_TEST — أي تشغيل اختباري لا يتراجع أبداً للرابط الرسمي
/// المضمّن، فلا تكتب الاختبارات على بيانات المستخدمين الحقيقية إطلاقاً
/// (كانت اختبارات الشاشات/التفكيك تبث أجهزة وشواهد طرد على الإنتاج!).
final bool _isTestEnvironment = () {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}();

/// الرابط الفعّال: المضبوط يدوياً في الإعدادات أولاً، ثم الرسمي المضمّن.
String effectiveBackendUrl(String? customUrl) {
  final trimmed = (customUrl ?? '').trim().replaceAll(RegExp(r'/+$'), '');
  if (trimmed.isNotEmpty) return trimmed;
  if (debugDefaultBackendUrlOverride != null) {
    return debugDefaultBackendUrlOverride!;
  }
  if (_isTestEnvironment) return ''; // الاختبارات لا تلمس الإنتاج أبداً.
  return kDefaultCloudBackendUrl;
}

/// (المعمارية الصامتة) المزامنة التلقائية مثبتة دائماً في الخلفية —
/// لم يعد للمستخدم مفتاح لإيقافها بعد إخفاء بطاقة الإعدادات التقنية.
/// getter (لا const) كي لا يطوي المحلل الشروط المعتمدة عليه كـ dead code.
bool get kCloudAutoSyncAlways => true;
