// (دفعة 52) تسجيل قاعدة جدار حماية ويندوز تلقائياً عند أول تشغيل.
//
// المُثبّت (NexoraSetup.exe) يسجّل القاعدتين أثناء التثبيت بصلاحية المسؤول،
// لكن النسخة المحمولة (zip) لا تمر بالمُثبّت — لذا نحاول هنا أيضاً:
//  - إن كانت العملية مرتفعة الصلاحية: netsh يضيف قاعدتي in/out بصمت.
//  - إن رُفض الرفع (خطأ 5 Access denied): لا نفشل — نسجّل الحاجة ونعرض
//    توجيهاً واضحاً للمستخدم: «يرجى السماح للتطبيق بالوصول إلى الشبكة عبر
//    جدار الحماية» (تظهر مرة واحدة عبر إشعار الواجهة).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'platform_info.dart';

class WindowsFirewall {
  WindowsFirewall._();

  static const ruleName = 'Nexora Enterprise';

  /// رسالة توجيه للمستخدم إن تعذّر التسجيل الآلي (تعرضها الواجهة مرة).
  static final ValueNotifier<String?> firewallNotice =
      ValueNotifier<String?>(null);

  /// يتحقق من وجود القاعدة ثم يسجّلها إن غابت. آمن تماماً:
  /// أي فشل (رفض صلاحية/بيئة غريبة) لا يمس إقلاع التطبيق.
  static Future<void> ensureRegistered() async {
    if (!PlatformInfo.isWindows) return;
    try {
      final exe = Platform.resolvedExecutable;
      // 1) هل القاعدة مسجلة أصلاً؟ (فحص لا يحتاج صلاحيات.)
      final check = await Process.run('netsh', [
        'advfirewall', 'firewall', 'show', 'rule', 'name=$ruleName',
      ]).timeout(const Duration(seconds: 10));
      final out = '${check.stdout}';
      if (check.exitCode == 0 && out.contains(ruleName)) {
        firewallNotice.value = null;
        return; // مسجلة — لا شيء يُفعل.
      }
      // 2) محاولة التسجيل المباشر (تنجح إن كانت العملية مرتفعة).
      var ok = true;
      for (final dir in const ['in', 'out']) {
        final r = await Process.run('netsh', [
          'advfirewall', 'firewall', 'add', 'rule',
          'name=$ruleName',
          'dir=$dir',
          'action=allow',
          'program=$exe',
          'enable=yes',
        ]).timeout(const Duration(seconds: 10));
        if (r.exitCode != 0) ok = false;
      }
      if (ok) {
        firewallNotice.value = null;
        return;
      }
      // 3) رفض صلاحية: محاولة أخيرة برفع UAC عبر PowerShell -Verb RunAs
      //    (تظهر نافذة UAC واحدة؛ إن رفضها المستخدم نكتفي بالتوجيه).
      final psCmd = "Start-Process netsh -Verb RunAs -WindowStyle Hidden "
          "-Wait -ArgumentList 'advfirewall firewall add rule "
          "name=\"$ruleName\" dir=in action=allow program=\"$exe\" enable=yes'; "
          "Start-Process netsh -Verb RunAs -WindowStyle Hidden "
          "-Wait -ArgumentList 'advfirewall firewall add rule "
          "name=\"$ruleName\" dir=out action=allow program=\"$exe\" enable=yes'";
      final elev = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', psCmd],
      ).timeout(const Duration(seconds: 45));
      if (elev.exitCode == 0) {
        firewallNotice.value = null;
        return;
      }
      firewallNotice.value =
          'يرجى السماح للتطبيق بالوصول إلى الشبكة عبر جدار الحماية';
    } catch (e) {
      debugPrint('WindowsFirewall.ensureRegistered: $e');
      firewallNotice.value =
          'يرجى السماح للتطبيق بالوصول إلى الشبكة عبر جدار الحماية';
    }
  }
}
