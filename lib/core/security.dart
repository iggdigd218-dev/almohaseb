import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// البصمة وقفل التطبيق وكلمات مرور المستخدمين.
class Security {
  static final _auth = LocalAuthentication();

  /// هل يدعم الجهاز البصمة/الوجه وهل هناك بصمة مسجّلة؟
  static Future<bool> biometricsAvailable() async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return false;
      final can = await _auth.canCheckBiometrics;
      if (!can) return false;
      final types = await _auth.getAvailableBiometrics();
      return types.isNotEmpty;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// أسماء وسائل التحقق المتاحة، للعرض في الإعدادات.
  static Future<String> availableLabel() async {
    try {
      final types = await _auth.getAvailableBiometrics();
      if (types.isEmpty) return 'غير متاحة على هذا الجهاز';
      final names = <String>[];
      if (types.contains(BiometricType.fingerprint)) names.add('البصمة');
      if (types.contains(BiometricType.face)) names.add('الوجه');
      if (types.contains(BiometricType.iris)) names.add('القزحية');
      if (names.isEmpty) names.add('تحقق بيومتري');
      return names.join(' · ');
    } catch (_) {
      return 'غير متاحة';
    }
  }

  /// يطلب المصادقة. يعيد true عند النجاح فقط.
  static Future<bool> authenticate({
    String reason = 'أكّد هويتك لفتح التطبيق',
  }) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false, // نسمح بنمط القفل كبديل
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// تجزئة كلمة المرور — لا نخزّن النص الصريح إطلاقًا.
  ///
  /// الشكل الجديد (v2): `v2$<salt-base64>$<hash>` حيث hash = PBKDF2-مبسّط
  /// (10000 جولة SHA-256 متسلسلة على salt+password) بملح عشوائي 16 بايت
  /// فريد لكل مستخدم — لا ملح ثابت قابل لهجمات جداول مسبقة.
  /// القيم القديمة (sha256 بملح ثابت) تبقى قابلة للتحقق للتوافق الخلفي،
  /// وتُرقّى تلقائياً عند أول تسجيل دخول ناجح عبر [needsRehash].
  static const int _iterations = 10000;

  static String hash(String password) {
    if (password.isEmpty) return '';
    final rnd = Random.secure();
    final salt = Uint8List.fromList(
        List<int>.generate(16, (_) => rnd.nextInt(256)));
    return _hashWithSalt(password, salt);
  }

  static String _hashWithSalt(String password, Uint8List salt) {
    var digest = sha256.convert([...salt, ...utf8.encode(password)]).bytes;
    for (var i = 1; i < _iterations; i++) {
      digest = sha256.convert([...salt, ...digest]).bytes;
    }
    return 'v2\$${base64Encode(salt)}\$${hex(digest)}';
  }

  static String hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// التجزئة القديمة (ملح ثابت) — للتحقق من كلمات المرور المخزنة سابقاً فقط.
  static String _legacyHash(String password) {
    if (password.isEmpty) return '';
    final salted = utf8.encode('nexora::$password');
    return sha256.convert(salted).toString();
  }

  static bool verify(String password, String stored) {
    if (stored.isEmpty) return true; // لا كلمة مرور مضبوطة
    if (stored.startsWith('v2\$')) {
      final parts = stored.split('\$');
      if (parts.length != 3) return false;
      try {
        final salt = Uint8List.fromList(base64Decode(parts[1]));
        return _constEq(_hashWithSalt(password, salt), stored);
      } catch (_) {
        return false;
      }
    }
    // توافق خلفي: تجزئة قديمة بملح ثابت.
    return _constEq(_legacyHash(password), stored);
  }

  /// هل التجزئة المخزنة قديمة وتحتاج ترقية للشكل الجديد؟
  static bool needsRehash(String stored) =>
      stored.isNotEmpty && !stored.startsWith('v2\$');

  /// مقارنة بوقت ثابت (تمنع هجمات التوقيت).
  static bool _constEq(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
