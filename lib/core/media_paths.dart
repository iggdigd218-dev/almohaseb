// مسارات وسائط الدردشة والمرفقات — نسبية دائماً عند التخزين/المزامنة.
//
// المشكلة القديمة: المسار المطلق (/data/user/0/...) كان يُخزَّن في payload
// ويُرسَل عبر المزامنة، وهو بلا معنى على الجهاز المستقبل ويتعطل حتى محلياً
// إذا غيّر النظام مسار التطبيق بعد تحديث. الحل: نخزّن مساراً نسبياً من جذر
// documents (مثل chat_media/123_pic.jpg) ونحوّله لمطلق وقت الاستخدام فقط.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class MediaPaths {
  static String? _docsDir;

  /// يهيئ جذر documents مرة واحدة (تُستدعى مبكراً؛ آمنة التكرار).
  static Future<String?> ensureDocsDir() async {
    if (_docsDir != null) return _docsDir;
    try {
      _docsDir = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      _docsDir = null; // بيئة اختبار VM بلا path_provider.
    }
    return _docsDir;
  }

  /// حقن الجذر في الاختبارات.
  static set docsDirForTesting(String? dir) => _docsDir = dir;

  /// يحوّل مساراً مطلقاً تحت documents إلى نسبي (للتخزين والمزامنة).
  /// مسار خارج documents أو جذر غير معروف يُعاد كما هو.
  static String toRelative(String absolute) {
    final root = _docsDir;
    if (root == null || root.isEmpty) return absolute;
    final norm = absolute.replaceAll('\\', '/');
    final rootNorm = root.replaceAll('\\', '/');
    if (norm.startsWith('$rootNorm/')) {
      return norm.substring(rootNorm.length + 1);
    }
    return absolute;
  }

  /// يحوّل مساراً مخزناً (نسبي جديد أو مطلق قديم) إلى مطلق للاستخدام.
  static String toAbsolute(String stored) {
    if (stored.isEmpty) return stored;
    // مطلق قديم (يبدأ بـ / أو حرف قرص ويندوز) — يُستخدم كما هو.
    if (stored.startsWith('/') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(stored)) {
      return stored;
    }
    final root = _docsDir;
    if (root == null || root.isEmpty) return stored;
    return '$root/$stored';
  }

  /// تجزئة SHA-256 (hex) لملف مخزَّن (نسبي أو مطلق). تُستخدم لجلب المرفقات
  /// عبر LAN بمعرّف محتوى ثابت بدل مسار الملف. تعيد '' عند أي فشل.
  static Future<String> fileHash(String stored) async {
    if (stored.isEmpty) return '';
    try {
      final f = File(toAbsolute(stored));
      if (!await f.exists()) return '';
      final digest = await sha256.bind(f.openRead()).first;
      return digest.toString();
    } catch (_) {
      return '';
    }
  }

  /// هل الملف المخزن (نسبي أو مطلق) موجود فعلاً؟
  static bool exists(String stored) {
    if (stored.isEmpty) return false;
    try {
      return File(toAbsolute(stored)).existsSync();
    } catch (_) {
      return false;
    }
  }
}
