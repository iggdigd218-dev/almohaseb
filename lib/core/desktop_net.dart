// (دفعة 52) تقوية الشبكة لسطح المكتب — ويندوز خصوصاً:
//
// 1) HttpOverrides عالمية: كل HttpClient يُنشأ في التطبيق (بما فيه عميل
//    package:http وقناة SSE) يرث تلقائياً:
//    - حلّ البروكسي من متغيرات البيئة (findProxyFromEnvironment) — شبكات
//      الشركات خلف بروكسي كانت تفشل صامتة.
//    - مهلة اتصال معقولة بدل التعليق اللانهائي.
//    - badCertificateCallback مضبوط: يرفض الشهادات المكسورة لكل المضيفين
//      (أماناً) إلا مضيف الواجهة الخلفية المضبوط صراحةً (trustedHost) —
//      لتجاوز أجهزة فحص TLS الوسيطة في بعض الشبكات — مع تسجيل الخطأ دائماً.
//
// 2) مُبلّغ خطأ الشبكة (netErrorNotifier): آخر خطأ شبكة دقيق
//    (SocketException / HandshakeException / TimeoutException ...) يُعرض
//    في واجهة المزامنة السحابية بدل الفشل الصامت.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

class DesktopNet {
  DesktopNet._();

  /// مضيف الواجهة الخلفية المضبوط حالياً (يحدّثه ناقل السحابة عند التهيئة).
  /// شهادته وحده تُقبل رغم فشل التحقق (شبكات تفتش TLS) — الباقي يُرفض.
  static String? trustedHost;

  /// آخر خطأ شبكة مُشخّص بدقة — null يعني الاتصال سليم.
  static final ValueNotifier<String?> netErrorNotifier =
      ValueNotifier<String?>(null);

  /// وصف موحّد ودقيق لخطأ الشبكة (نوع الاستثناء + التفصيل) للعرض في الواجهة.
  static String describeNetError(Object e) {
    if (e is SocketException) {
      final code = e.osError?.errorCode;
      return 'SocketException${code == null ? '' : ' (رمز $code)'}: '
          '${e.osError?.message ?? e.message}';
    }
    if (e is HandshakeException) {
      return 'HandshakeException (شهادة/تشفير TLS): ${e.message}';
    }
    if (e is TimeoutException) {
      return 'TimeoutException: انتهت مهلة الاتصال بالخادم.';
    }
    if (e is HttpException) return 'HttpException: ${e.message}';
    return '${e.runtimeType}: $e';
  }

  static void recordError(Object e) {
    final msg = describeNetError(e);
    if (netErrorNotifier.value != msg) netErrorNotifier.value = msg;
  }

  static void clearError() {
    if (netErrorNotifier.value != null) netErrorNotifier.value = null;
  }

  /// هل يُقبل مضيف رغم فشل تحقق الشهادة؟ (المضيف الموثوق المضبوط فقط.)
  @visibleForTesting
  static bool shouldTrustBadCert(String host) =>
      trustedHost != null && host == trustedHost;

  /// فحص وصول سريع: استعلام DNS للمضيف قبل فتح قناة SSE — يعيد null عند
  /// النجاح أو وصف الخطأ الدقيق عند الفشل (ويسجّله في المُبلّغ).
  static Future<String?> preflight(String host) async {
    try {
      final addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 8));
      if (addrs.isEmpty) {
        const msg = 'DNS: المضيف بلا عناوين — تحقق من اتصال الإنترنت.';
        netErrorNotifier.value = msg;
        return msg;
      }
      return null;
    } catch (e) {
      recordError(e);
      return describeNetError(e);
    }
  }
}

/// تُثبَّت عالمياً في main() على سطح المكتب فقط:
/// HttpOverrides.global = DesktopHttpOverrides();
class DesktopHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context)
      ..connectionTimeout = const Duration(seconds: 20)
      // حلّ البروكسي تلقائياً من HTTP_PROXY/HTTPS_PROXY/NO_PROXY.
      ..findProxy = (uri) {
        try {
          return HttpClient.findProxyFromEnvironment(uri,
              environment: Platform.environment);
        } catch (_) {
          return 'DIRECT';
        }
      }
      ..badCertificateCallback = (cert, host, port) {
        DesktopNet.recordError(
          HandshakeException(
              'شهادة غير موثوقة من $host:$port — ${cert.subject}'),
        );
        // يُقبل فقط مضيف الواجهة الخلفية المضبوط صراحةً (شبكات تفتش TLS).
        return DesktopNet.shouldTrustBadCert(host);
      };
    return client;
  }
}
