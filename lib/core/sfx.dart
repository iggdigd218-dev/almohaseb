// خدمة المؤثرات الصوتية والاهتزازية التفاعلية.
//
// على أندرويد: أصوات مخصصة مميزة لكل نوع تفاعل (ملفات WAV مولّدة في res/raw
// تُشغَّل عبر MethodChannel «nexora/sfx»)، مع اهتزاز بمدة قابلة للتحكم
// (1.5 ثانية عند إنشاء عملية) وإشعارات نظام خارجية بصوت مختلف عن صوت
// النظام الافتراضي حتى يعرف المستخدم أن أمراً مهماً حدث.
// على المنصات الأخرى: نعود تلقائياً إلى SystemSound وHapticFeedback المدمجين.
//
// الأنماط:
//   - success   : حفظ/تأكيد — نغمة صعود ثلاثية مشرقة.
//   - payment   : دفع/فاتورة — نمط NFC صاعد رباعي.
//   - delete    : حذف — نزول تحذيري.
//   - warning   : تنبيه غير فادح — نغمتان متوسطتان.
//   - error     : خطأ جسيم — نغمة منخفضة حادة.
//   - scan      : مسح باركود — نقرة عالية سريعة.
//   - pair      : اقتران جهاز — نمط احتفالي صاعد.
//   - synced    : اكتمال مزامنة عملية — نغمتان خفيفتان.
//   - opCreated : إنشاء عملية — صوت الدفع + اهتزاز طويل (1.5 ثانية).

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'platform_info.dart';

class Sfx {
  static const MethodChannel _channel = MethodChannel('nexora/sfx');
  static AudioPlayer? _desktopPlayer;

  static bool _muted = false; // كتم شامل (يستخدمه وضع الاختبار).
  static bool _soundOn = true; // الأصوات.
  static bool _hapticOn = true; // الاهتزاز.

  static bool get muted => _muted;
  static void setMuted(bool v) => _muted = v;

  /// تحدّث حالتي الصوت والاهتزاز من إعدادات المستخدم.
  /// (دفعة 58 — متطلب 7) [mute] كتم شامل اختياري يشمل حتى أصوات
  /// إشعارات النظام الخارجية — مفتاح واحد يسكت كل شيء.
  static void applySettings({
    required bool sound,
    required bool haptic,
    bool? mute,
  }) {
    _soundOn = sound;
    _hapticOn = haptic;
    if (mute != null) _muted = mute;
  }

  static bool get _soundEnabled => !_muted && _soundOn;
  static bool get _hapticEnabled => !_muted && _hapticOn;

  static bool get _isAndroid => PlatformInfo.isAndroid;

  static Future<void> _playDesktopAudio(String name) async {
    if (!_soundEnabled) return;
    try {
      _desktopPlayer ??= AudioPlayer();
      await _desktopPlayer!.stop();
      await _desktopPlayer!.play(AssetSource('audio/$name.wav'));
    } catch (_) {}
  }

  /// يشغّل صوتاً مخصصاً: من res/raw على أندرويد، أو عبر audioplayers على ويندوز وبقية المنصات.
  static Future<void> _playCustom(String name) async {
    if (!_soundEnabled) return;
    if (_isAndroid) {
      try {
        await _channel.invokeMethod('play', {'name': name});
      } catch (_) {}
    } else {
      unawaited(_playDesktopAudio(name));
    }
  }

  /// اهتزاز بمدة محددة على أندرويد (أدق من HapticFeedback المتقطع).
  static Future<void> _vibrateMs(int ms) async {
    if (!_hapticEnabled || !_isAndroid) return;
    try {
      await _channel.invokeMethod('vibrate', {'ms': ms});
    } catch (_) {}
  }

  /// إشعار نظام خارجي بصوت مخصص مختلف عن صوت النظام الافتراضي.
  /// [peaceful] يستخدم صوت التحية الهادئ بدل جرس التنبيه.
  static Future<void> systemNotify({
    required String title,
    required String body,
    bool peaceful = false,
    String entityType = '',
    String entityId = '',
  }) async {
    if (!_isAndroid) return;
    try {
      // (دفعة 58 — متطلب 7) عند الكتم الشامل يصل الإشعار لكن صامتاً —
      // لا يفوّت المستخدم أمراً مهماً ولا يزعجه صوت.
      await _channel.invokeMethod('notify', {
        'title': title,
        'body': body,
        'sound': _muted || !_soundOn
            ? 'silent'
            : (peaceful ? 'nexora_peace' : 'nexora_alert'),
        'entityType': entityType,
        'entityId': entityId,
      });
    } catch (_) {}
  }

  /// يستهلك نقرة إشعار خارجي معلقة (فُتح التطبيق بالضغط على إشعار نظام).
  /// يعيد {entityType, entityId} مرة واحدة أو null إن لم توجد نقرة.
  static Future<Map<String, String>?> takeNotifyTap() async {
    if (!_isAndroid) return null;
    try {
      final r = await _channel.invokeMethod('takeNotifyTap');
      if (r is Map && (r['entityType'] as String?)?.isNotEmpty == true) {
        return {
          'entityType': '${r['entityType']}',
          'entityId': '${r['entityId'] ?? ''}',
        };
      }
    } catch (_) {}
    return null;
  }

  // ============ النجاح ============

  /// صوت نجاح عام (حفظ عملية، إضافة/تعديل سجل).
  static void success() {
    if (_muted) return;
    _playCustom('sfx_success');
    final h = _hapticEnabled;
    if (h) HapticFeedback.mediumImpact();
    Future.delayed(
      const Duration(milliseconds: 70),
      h ? HapticFeedback.lightImpact : null,
    );
    if (!_isAndroid && _soundEnabled) SystemSound.play(SystemSoundType.click);
  }

  /// صوت إتمام فاتورة/دفع.
  static void payment() {
    if (_muted) return;
    _playCustom('sfx_payment');
    final h = _hapticEnabled;
    if (h) HapticFeedback.mediumImpact();
    Future.delayed(
      const Duration(milliseconds: 90),
      h ? HapticFeedback.lightImpact : null,
    );
    Future.delayed(
      const Duration(milliseconds: 200),
      h ? HapticFeedback.mediumImpact : null,
    );
    if (!_isAndroid && _soundEnabled) SystemSound.play(SystemSoundType.click);
  }

  /// إنشاء عملية جديدة: صوت الدفع + اهتزاز طويل ملموس (1.5 ثانية).
  static void opCreated() {
    if (_muted) return;
    _playCustom('sfx_payment');
    if (_isAndroid) {
      _vibrateMs(1500);
    } else {
      // منصات أخرى: أقرب محاكاة بنبضات متتالية.
      final h = _hapticEnabled;
      for (var i = 0; i < 6; i++) {
        Future.delayed(
          Duration(milliseconds: 120 * i),
          h ? HapticFeedback.mediumImpact : null,
        );
      }
    }
  }

  /// اكتمال مزامنة عملية إلى جهاز.
  static void synced() {
    if (_muted) return;
    _playCustom('sfx_synced');
    if (_hapticEnabled) HapticFeedback.lightImpact();
  }

  /// نجاح مسح باركود.
  static void scan() {
    if (_muted) return;
    _playCustom('sfx_scan');
    final h = _hapticEnabled;
    if (h) HapticFeedback.lightImpact();
    if (!_isAndroid && _soundEnabled) SystemSound.play(SystemSoundType.click);
  }

  /// نجاح اقتران/اتصال جهاز.
  static void pair() {
    if (_muted) return;
    _playCustom('sfx_pair');
    final h = _hapticEnabled;
    if (h) HapticFeedback.mediumImpact();
    Future.delayed(
      const Duration(milliseconds: 90),
      h ? HapticFeedback.selectionClick : null,
    );
    Future.delayed(
      const Duration(milliseconds: 180),
      h ? HapticFeedback.mediumImpact : null,
    );
    if (!_isAndroid && _soundEnabled) SystemSound.play(SystemSoundType.click);
  }

  // ============ التحذيرات ============

  /// تنبيه متوسط (مخزون منخفض، رسالة غير فادحة).
  static void warning() {
    if (_muted) return;
    _playCustom('sfx_warning');
    final h = _hapticEnabled;
    if (h) HapticFeedback.lightImpact();
    Future.delayed(
      const Duration(milliseconds: 120),
      h ? HapticFeedback.lightImpact : null,
    );
  }

  // ============ الفشل ============

  /// صوت فشل/خطأ جسيم.
  static void error() {
    if (_muted) return;
    _playCustom('sfx_error');
    final h = _hapticEnabled;
    if (h) HapticFeedback.heavyImpact();
    Future.delayed(
      const Duration(milliseconds: 110),
      h ? HapticFeedback.lightImpact : null,
    );
    if (!_isAndroid && _soundEnabled) SystemSound.play(SystemSoundType.alert);
  }

  /// فشل بسيط/رفض (مدخلات غير صالحة).
  static void reject() {
    if (_muted) return;
    final h = _hapticEnabled;
    if (h) HapticFeedback.selectionClick();
    Future.delayed(
      const Duration(milliseconds: 80),
      h ? HapticFeedback.selectionClick : null,
    );
  }

  // ============ الأزرار/التنقل ============

  /// نقرة خفيفة عامة للأزرار والتبويبات.
  static void tap() => click();

  static void click() {
    if (_muted) return;
    final h = _hapticEnabled;
    if (h) HapticFeedback.selectionClick();
  }

  /// فتح/إغلاق نوافذ أو إجراء كبير.
  static void pop() {
    if (_muted) return;
    final h = _hapticEnabled;
    if (h) HapticFeedback.lightImpact();
    if (!_isAndroid && _soundEnabled) SystemSound.play(SystemSoundType.click);
  }

  /// حذف (ثقيل قصير).
  static void delete() {
    if (_muted) return;
    _playCustom('sfx_delete');
    final h = _hapticEnabled;
    if (h) HapticFeedback.mediumImpact();
    Future.delayed(
      const Duration(milliseconds: 90),
      h ? HapticFeedback.heavyImpact : null,
    );
  }

  // ============ مساعدات ============

  /// اهتزاز إشعار ملموس.
  static void notify() {
    if (_muted) return;
    final h = _hapticEnabled;
    if (h) HapticFeedback.mediumImpact();
    Future.delayed(
      const Duration(milliseconds: 180),
      h ? HapticFeedback.lightImpact : null,
    );
    Future.delayed(
      const Duration(milliseconds: 360),
      h ? HapticFeedback.mediumImpact : null,
    );
  }

  /// حوارات التأكيد المدمرة (حذف، طرد).
  static void dangerConfirm() {
    if (_muted) return;
    final h = _hapticEnabled;
    if (h) HapticFeedback.heavyImpact();
  }

  /// كل أنواع المؤثرات القابلة للمعاينة في الإعدادات:
  /// (المعرّف، الاسم المعروض، الدالة).
  static List<(String, String, void Function())> previewable() => [
        ('success', 'نجاح الحفظ', success),
        ('payment', 'إتمام دفع/فاتورة', payment),
        ('opCreated', 'إنشاء عملية (اهتزاز طويل)', opCreated),
        ('synced', 'اكتمال مزامنة', synced),
        ('scan', 'مسح باركود', scan),
        ('pair', 'اقتران جهاز', pair),
        ('warning', 'تحذير', warning),
        ('error', 'خطأ', error),
        ('delete', 'حذف', delete),
        ('notify', 'إشعار داخلي', notify),
      ];
}
