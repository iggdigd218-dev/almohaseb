// تعمية التوكنات الحساسة عند التخزين (id_token وأسرار مشابهة).
//
// المفتاح عشوائي 32 بايت يُولَّد مرة واحدة ويُحفظ في ملف خاص خارج قاعدة
// البيانات (documents/.nexora_key). النتيجة: أي نسخة من ملف قاعدة البيانات
// (نسخ احتياطي مُصدَّر، سحب الملف من الجهاز) لا تكشف التوكن بنص صريح —
// فك التعمية يتطلب ملف المفتاح الذي لا يغادر الجهاز أبداً.
//
// الصيغة المخزنة: `enc1:<base64>` حيث المحتوى XOR مع keystream مشتق من
// المفتاح عبر SHA-256 (counter mode مبسّط). ليست بديلاً عن Keystore العتادي،
// لكنها تفصل المفتاح عن البيانات وهو الهدف العملي هنا.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

class TokenCipher {
  static const _prefix = 'enc1:';
  static Uint8List? _cachedKey;

  static Future<Uint8List?> _key() async {
    if (_cachedKey != null) return _cachedKey;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/.nexora_key');
      if (await f.exists()) {
        final b = await f.readAsBytes();
        if (b.length >= 32) {
          _cachedKey = Uint8List.fromList(b.sublist(0, 32));
          return _cachedKey;
        }
      }
      final rnd = Random.secure();
      final fresh =
          Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
      await f.writeAsBytes(fresh, flush: true);
      _cachedKey = fresh;
      return fresh;
    } catch (_) {
      // منصة بلا path_provider (اختبارات VM) — نعمل بلا تعمية.
      return null;
    }
  }

  static Uint8List _xorStream(Uint8List data, Uint8List key) {
    final out = Uint8List(data.length);
    var block = 0;
    var i = 0;
    while (i < data.length) {
      final ks = sha256.convert([...key, block & 0xff, block >> 8]).bytes;
      for (var j = 0; j < ks.length && i < data.length; j++, i++) {
        out[i] = data[i] ^ ks[j];
      }
      block++;
    }
    return out;
  }

  /// يعمّي نصاً للتخزين. إن تعذّر الوصول للمفتاح يُعاد النص كما هو.
  static Future<String> protect(String plain) async {
    if (plain.isEmpty || plain.startsWith(_prefix)) return plain;
    final key = await _key();
    if (key == null) return plain;
    final enc = _xorStream(Uint8List.fromList(utf8.encode(plain)), key);
    return '$_prefix${base64Encode(enc)}';
  }

  /// يفك التعمية. القيم القديمة (نص صريح) تُعاد كما هي — توافق خلفي.
  static Future<String> reveal(String stored) async {
    if (!stored.startsWith(_prefix)) return stored;
    final key = await _key();
    if (key == null) return '';
    try {
      final raw = base64Decode(stored.substring(_prefix.length));
      return utf8.decode(_xorStream(Uint8List.fromList(raw), key));
    } catch (_) {
      return '';
    }
  }
}
