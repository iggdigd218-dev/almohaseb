// إدارة معرّف الجهاز الثابت + بصمة العتاد الحتمية.
// deviceId يُشتق من بصمة عتاد الجهاز (device_info_plus) بحيث تنتج نفس
// الهوية بعد حذف التطبيق وإعادة تثبيته — يمنع «الأشباح» في قائمة الأجهزة:
// إعادة الانضمام تُحيي السجل القديم بدوره وصلاحياته بدل إنشاء جهاز مكرر.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';

import '../repository.dart';
import '../../core/platform_info.dart';

const _chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const _deviceIdKey = 'sync.deviceId';
const _deviceNameKey = 'sync.deviceName';
const _hwFingerprintKey = 'sync.hwFingerprint';

/// يولّد سلسلة عشوائية من 8 أحرف من قاعدة Base32 مبسطة.
String generateDeviceCode([int len = 8]) {
  final rnd = Random.secure();
  return List.generate(len, (_) => _chars[rnd.nextInt(_chars.length)]).join();
}

String formatDeviceId(String code) => 'DEVICE-$code';

/// يحوّل تجزئة SHA-256 إلى رمز Base32 مبسط بطول [len] — نفس أبجدية
/// generateDeviceCode حتى تبقى المعرفات متجانسة الشكل.
String _hashToCode(String input, [int len = 12]) {
  final digest = sha256.convert(utf8.encode(input)).bytes;
  final buf = StringBuffer();
  for (var i = 0; i < len; i++) {
    buf.write(_chars[digest[i % digest.length] % _chars.length]);
  }
  return buf.toString();
}

String? Function()? debugHardwareFingerprintOverride;

/// يجمع معرفات العتاد الثابتة للمنصة الحالية عبر device_info_plus.
/// يعيد null إن تعذر الجمع (بيئة اختبار VM بلا plugin) — عندها نتراجع
/// للمعرف العشوائي القديم.
Future<String?> hardwareFingerprintRaw() async {
  if (debugHardwareFingerprintOverride != null) {
    return debugHardwareFingerprintOverride!();
  }
  try {
    final plugin = DeviceInfoPlugin();
    if (PlatformInfo.isAndroid) {
      final a = await plugin.androidInfo
          .timeout(const Duration(milliseconds: 400));
      // (تدعيم البصمة) مكوّنات عتادية ثابتة لنفس الجهاز الفعلي حتى بعد
      // مسح بيانات التطبيق أو إعادة تثبيته:
      //  • ANDROID_ID (a.id): ثابت عبر إعادة التثبيت ومسح البيانات —
      //    عنصر التفرد الأساسي (طرازان متطابقان لا يتصادمان).
      //  • مقدمة a.fingerprint الثابتة (brand/product/device قبل «:»):
      //    تعريف الجهاز المصنعي — دون ذيل البناء المتغير مع تحديثات
      //    النظام OTA حتى لا تُمنح تجربة جديدة بعد كل تحديث.
      //  • hardware + model + board: صفات لوحة وعتاد مصنعية لا تتبدل.
      final fpRaw = a.fingerprint;
      final fpStable =
          fpRaw.contains(':') ? fpRaw.substring(0, fpRaw.indexOf(':')) : fpRaw;
      final parts = [a.id, fpStable, a.hardware, a.model, a.board];
      return 'android:${parts.join('|')}';
    }
    if (PlatformInfo.isWindows) {
      final w = await plugin.windowsInfo
          .timeout(const Duration(milliseconds: 400));
      // deviceId = MachineGuid — ثابت عبر إعادة تثبيت التطبيق.
      return 'windows:${w.deviceId}|${w.computerName}';
    }
    if (PlatformInfo.isLinux) {
      final l = await plugin.linuxInfo
          .timeout(const Duration(milliseconds: 400));
      // machineId من /etc/machine-id — ثابت للنظام.
      return 'linux:${l.machineId ?? l.id}|${l.name}';
    }
    if (PlatformInfo.isMacOS) {
      final m = await plugin.macOsInfo
          .timeout(const Duration(milliseconds: 400));
      return 'macos:${m.systemGUID ?? m.computerName}';
    }
    if (PlatformInfo.isIOS) {
      final i =
          await plugin.iosInfo.timeout(const Duration(milliseconds: 400));
      return 'ios:${i.identifierForVendor ?? i.utsname.machine}';
    }
  } catch (_) {
    // بيئة اختبار أو منصة بلا device_info — التراجع للعشوائي.
  }
  return null;
}

/// معرف الجهاز المشتق من بصمة العتاد: DEVICE-<12 حرفاً حتمياً>.
/// نفس الجهاز يعيد إنتاج نفس المعرف بعد أي إعادة تثبيت.
Future<String?> deterministicDeviceId() async {
  final raw = await hardwareFingerprintRaw();
  if (raw == null || raw.trim().isEmpty) return null;
  return formatDeviceId(_hashToCode(raw));
}

/// يُعيد deviceId الثابت لهذا الجهاز.
/// الأولوية: (1) المعرف المحفوظ (لا يتغير أبداً بعد أول توليد — حتى لا
/// تنقلب هوية أجهزة قائمة بعد الترقية)، (2) المعرف الحتمي من بصمة العتاد،
/// (3) التراجع العشوائي القديم (بيئات الاختبار).
Future<String> ensureDeviceId(Repo repo) async {
  final st = await repo.settings();
  final existing = st[_deviceIdKey];
  if (existing != null && existing.trim().isNotEmpty) return existing.trim();
  final hw = await deterministicDeviceId();
  final fresh = hw ?? formatDeviceId(generateDeviceCode());
  await repo.setSetting(_deviceIdKey, fresh);
  // نحفظ البصمة الخام (مُجزأة) للمطابقة المستقبلية ضد سجلات قديمة.
  final raw = await hardwareFingerprintRaw();
  if (raw != null) {
    await repo.setSetting(_hwFingerprintKey, _hashToCode(raw, 24));
  }
  return fresh;
}

Future<String?> getDeviceIdCached(Repo repo) async {
  final st = await repo.settings();
  return st[_deviceIdKey];
}

Future<void> setDeviceName(Repo repo, String name) =>
    repo.setSetting(_deviceNameKey, name);

/// الاسم الافتراضي الموحّد لأي جهاز/مستخدم جديد لم يحدد اسماً بعد.
/// (توحيد الهوية: يظهر نفسه في لوحة المدير والقوائم والإشعارات.)
const String kDefaultMemberName = 'مستخدم جديد';

Future<String> deviceName(Repo repo) async {
  final st = await repo.settings();
  final n = st[_deviceNameKey];
  if (n != null && n.trim().isNotEmpty) return n;
  // الاسم الافتراضي الموحّد — لا أسماء عتاد ولا أسماء متفرقة.
  return kDefaultMemberName;
}
