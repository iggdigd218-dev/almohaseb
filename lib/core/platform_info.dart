// (2026-09-24) المرجع الموحّد لفحوصات المنصّة.
//
// قبل هذا الملف كانت الفحوصات متفرّقة في 8 ملفات (Platform.isWindows /
// Platform.isAndroid / Platform.isLinux …) بصيغ مكرّرة؛ فأي ميزة تُقيَّد
// بمنصّة كانت تحتاج تعديل كل موضع على حدة، وأي سهو في أحدها يعني تشغيل
// ميزة أندرويد على سطح المكتب (أو العكس). الآن: مصدر واحد للقرار، وكل
// ملف يستورد هذا الصف.
//
// ملاحظة: المشروع يستهدف أندرويد + ويندوز/لينكس/ماك (لا ويب)، لذا `dart:io`
// متاح دائماً ولا حاجة لـ kIsWeb.
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// قدرات المنصّة الحالية — تُقرأ من [Platform] مرة واحدة عند الطلب.
abstract final class PlatformInfo {
  /// `dart:io` غير متاح على الويب — كل الفحوصات محمية به.
  static bool get isNative => !kIsWeb;

  static bool get isAndroid => isNative && Platform.isAndroid;
  static bool get isIOS => isNative && Platform.isIOS;
  static bool get isWindows => isNative && Platform.isWindows;
  static bool get isLinux => isNative && Platform.isLinux;
  static bool get isMacOS => isNative && Platform.isMacOS;

  /// سطح المكتب (ويندوز/لينكس/ماك) — التخطيط المزدوج، التحديث، القيود الناعمة.
  static bool get isDesktop => isWindows || isLinux || isMacOS;

  /// جوال (أندرويد/آيفون) — الأذونات، النوافذ العائمة، التثبيت الصامت.
  static bool get isMobile => isAndroid || isIOS;

  /// ══ حوكمة الميزات ══
  /// النافذة العائمة (الزر العائم) وبلاطة الستارة: أندرويد حصراً.
  /// أي ميزة أندرويد خاصة جديدة تُضاف هنا بدل تشتيت `Platform.isAndroid`.
  static bool get supportsOverlay => isAndroid;

  /// التحديث الذاتي داخل التطبيق (تنزيل APK/EXE وتثبيته).
  static bool get supportsSelfUpdate => isAndroid || isWindows;

  /// المزامنة اللحظية/خدمات اليقظة (أندرويد فقط).
  static bool get supportsBackgroundSync => isAndroid;
}
