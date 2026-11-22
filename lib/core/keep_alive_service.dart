// يقظة التطبيق داخل المجموعة + طلب أذونات النظام الحقيقية.
//
// داخل مجموعة مزامنة يشغّل التطبيق خدمة أندرويد أمامية (foreground service)
// مع قفل يقظة جزئي: يبقى خادم LAN مستقبلاً للعمليات والرسائل والإشعارات
// حتى أثناء سكون الهاتف والشاشة مطفأة، ولا يقتله النظام لضغط الذاكرة.
// كما نطلب من المستخدم — عبر نافذة النظام الرسمية وليس نافذة مصطنعة —
// إعفاء التطبيق من تحسينات البطارية وإذن الإشعارات (أندرويد 13+).

import 'package:flutter/services.dart';
import 'platform_info.dart';

class NexKeepAlive {
  static const MethodChannel _channel = MethodChannel('nexora/sfx');

  static bool get _isAndroid => PlatformInfo.isAndroid;

  /// يشغّل/يوقف خدمة اليقظة. تُفعّل عند دخول مجموعة وتُوقف عند مغادرتها.
  static Future<void> setEnabled(bool on) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('keepAlive', {'on': on});
    } catch (_) {}
  }

  /// هل التطبيق معفى من تحسينات البطارية؟ (خارج أندرويد: نعم دائماً)
  static Future<bool> isBatteryExempt() async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod('isBatteryExempt') == true;
    } catch (_) {
      return true;
    }
  }

  /// يفتح نافذة النظام الرسمية لطلب الإعفاء من تحسينات البطارية.
  static Future<void> requestBatteryExempt() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('requestBatteryExempt');
    } catch (_) {}
  }

  /// هل إذن النظام ممنوح؟ (الاسم الكامل مثل android.permission.POST_NOTIFICATIONS)
  static Future<bool> hasPermission(String permission) async {
    if (!_isAndroid) return true;
    try {
      return await _channel
              .invokeMethod('hasSystemPermission', {'permission': permission}) ==
          true;
    } catch (_) {
      return true;
    }
  }

  /// يطلب إذن نظام حقيقي بنافذة أندرويد الرسمية. يعيد هل مُنح.
  static Future<bool> requestPermission(String permission) async {
    if (!_isAndroid) return true;
    try {
      return await _channel.invokeMethod(
              'requestSystemPermission', {'permission': permission}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// أسماء الأذونات الشائعة.
  static const permNotifications = 'android.permission.POST_NOTIFICATIONS';
  static const permRecordAudio = 'android.permission.RECORD_AUDIO';
  static const permCamera = 'android.permission.CAMERA';
  static const permReadContacts = 'android.permission.READ_CONTACTS';
}
