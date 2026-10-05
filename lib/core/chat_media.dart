// وسائط الدردشة: تسجيل صوتي + تشغيل + فتح ملفات بتطبيق النظام.
// يستخدم MediaRecorder/MediaPlayer الأصليين عبر قناة nexora/sfx —
// بلا أي مكتبات إضافية.

import 'package:flutter/services.dart';
import 'platform_info.dart';

class ChatMedia {
  static const MethodChannel _channel = MethodChannel('nexora/sfx');

  static bool get _isAndroid => PlatformInfo.isAndroid;

  /// يبدأ تسجيلاً صوتياً m4a إلى [path]. يعيد هل بدأ فعلاً.
  static Future<bool> startRecording(String path) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod('startRecording', {'path': path}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// يوقف التسجيل الجاري. يعيد هل كان هناك تسجيل.
  static Future<bool> stopRecording() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod('stopRecording') == true;
    } catch (_) {
      return false;
    }
  }

  /// يشغّل ملفاً صوتياً (رسالة صوتية). يعيد هل بدأ التشغيل.
  static Future<bool> playFile(String path) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod('playFile', {'path': path}) == true;
    } catch (_) {
      return false;
    }
  }

  /// يوقف أي تشغيل صوتي جارٍ.
  static Future<void> stopPlayback() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('stopPlayback');
    } catch (_) {}
  }

  /// يفتح ملفاً (فيديو/مستند/صورة) بتطبيق النظام المناسب.
  static Future<bool> openFile(String path) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod('openFile', {'path': path}) == true;
    } catch (_) {
      return false;
    }
  }
}
