// (دفعة 57) تعمية أسرار الأجهزة (devices.auth_secret) عند التخزين.
//
// المبدأ: القيمة تبقى نصاً صريحاً في الذاكرة وعلى بروتوكول LAN (القرين
// يحتاجها كما هي)، لكنها لا تلمس قرص SQLite إلا معمّاة عبر TokenCipher
// (enc1:base64 — مفتاح 32 بايت خارج قاعدة البيانات في documents/.nexora_key).
// النتيجة: نسخة قاعدة بيانات مسرّبة/مُصدَّرة لا تكشف أسرار مصادقة الأقران.
//
// التعمية حتمية (نفس النص → نفس الناتج على نفس الجهاز) فمقارنات
// `WHERE auth_secret = ?` تعمل بتمرير الشكلين معاً (صريح قديم + معمّى)
// — توافق خلفي كامل مع الصفوف المخزنة قبل هذه الدفعة.
//
// في بيئة اختبارات VM (بلا path_provider) يعمل الصنف كهوية شفافة.
import 'token_cipher.dart';

class SecretStore {
  /// للتخزين: يعمّي السر قبل كتابته في قاعدة البيانات.
  static Future<String> protect(String plain) => TokenCipher.protect(plain);

  /// للاستخدام: يفك التعمية عند القراءة (القيم القديمة الصريحة تُعاد كما هي).
  static Future<String> reveal(String stored) => TokenCipher.reveal(stored);

  /// للمقارنة في WHERE: يعيد الشكلين المقبولين لسرّ وارد صريح —
  /// [الصريح كما ورد، المعمّى بمفتاحنا] لتغطية الصفوف القديمة والجديدة.
  static Future<List<String>> matchForms(String plain) async {
    final p = await protect(plain);
    return p == plain ? [plain, plain] : [plain, p];
  }
}
