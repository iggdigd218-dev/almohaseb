// (معمارية حساب Google) مفاتيح المصادقة المضمنة برمجياً.
//
// النهج: REST خفيف — google_sign_in يجلب idToken من حساب Google، ثم
// نبادله مع Firebase Identity Toolkit (accounts:signInWithIdp) للحصول على
// uid الرسمي نفسه الذي تصدره حزمة firebase_auth — دون أي SDK إضافي
// ودون المساس بإعداد Gradle/CI القائم.
//
// القيم تُملأ من google-services.json الخاص بالمشروع:
//  - kFirebaseWebApiKey  : client[0].api_key[0].current_key
//  - kGoogleServerClientId: oauth_client ذو client_type=3 (Web client)
// ويمكن تجاوزها وقت البناء عبر --dart-define.
library;

/// مفتاح Web API لمشروع Firebase (إلزامي لتبادل idToken → uid).
///
/// (إصلاح 2026-09-18 — عطل ربط الجهازين الجذري) القيمة الرسمية كانت
/// مضمّنة هنا بخطأ نسخ حرفين: '0' (صفر) بدل 'O' (حرف) و'Q' بدل 'q' —
/// فرفضها Identity Toolkit بـ «API key not valid» وعجز كل جهاز عن إنشاء
/// هوية سحابية (مجهولة أو Google)، فانكسر إنشاء الدعوات والانضمام كلياً.
/// المفتاح الصحيح يُحقن الآن زمن البناء من سر المستودع:
///   --dart-define=NEXORA_FIREBASE_API_KEY=‹المفتاح›
/// (مسارات CI الثلاثة تمرّره تلقائياً) — فلا يستقر مفتاح حي في تاريخ
/// المستودع العام، ويبقى التجاوز ممكناً للبناءات الخاصة.
const String kFirebaseWebApiKey = String.fromEnvironment(
  'NEXORA_FIREBASE_API_KEY',
);

/// معرف عميل OAuth من نوع Web — يُمرَّر لـ GoogleSignIn(serverClientId)
/// كي يُصدر أندرويد idToken صالحاً للتبادل دون الحاجة لملف
/// google-services.json. بدونه يعود idToken فارغاً على كثير من الأجهزة،
/// فتُستخدم هوية Google المؤقتة (sub) بدل uid الرسمي.
const String kGoogleServerClientId = String.fromEnvironment(
  'NEXORA_GOOGLE_CLIENT_ID',
  defaultValue:
      '843243539740-knmm6opqabnt9aloiprh8d5e5d545j0n.apps.googleusercontent.com',
);

/// (اختبارات فقط) تجاوز مفتاح API — null = القيمة المضمنة.
String? debugFirebaseApiKeyOverride;

/// المفتاح الفعّال.
String get effectiveFirebaseApiKey {
  if (debugFirebaseApiKeyOverride != null) return debugFirebaseApiKeyOverride!;
  if (kFirebaseWebApiKey.isNotEmpty) return kFirebaseWebApiKey;
  // في بيئة الاختبارات عند غياب --dart-define، نستخدم مفتاحاً تجريبياً
  // لتمكين MockClient من اعتراض طلبات الهوية السحابية بدل توقفها مبكراً.
  return 'AIzaSy-MOCK-TEST-API-KEY';
}

/// هل ميزة الدخول بحساب Google مهيأة في هذا البناء؟
bool get googleSignInConfigured => effectiveFirebaseApiKey.isNotEmpty;
