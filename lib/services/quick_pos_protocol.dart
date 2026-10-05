import 'dart:async';

/// بروتوكول «الاستعلام والبيع السريع» بين النافذة العائمة (محرك فلاتر
/// مستقل بلا أي إضافة أصلية) والتطبيق الأم (الذي يملك قاعدة SQLite).
///
/// لماذا هذا العزل؟ محرك النافذة العائمة يُنشأ عبر `FlutterEngineGroup`
/// ولا تُسجَّل فيه إضافات فلاتر (sqflite/path_provider...)، لذا لا يمكنه
/// فتح قاعدة البيانات بنفسه. الحل: النافذة العائمة واجهة صرفة، وكل قراءة
/// وكتابة تمرّ برسائل JSON عبر BasicMessageChannel إلى التطبيق الأم الذي
/// ينفّذها على اتصال SQLite واحد (WAL) ثم يردّ بالنتيجة.

/// صنف مُبسَّط يُرسل إلى النافذة العائمة (حقول عرض فقط).
class QuickPosItem {
  final int id;
  final String name;
  final String sku;
  final String unit;
  final double price;
  final double qty;
  final String currency;

  const QuickPosItem({
    required this.id,
    required this.name,
    this.sku = '',
    this.unit = 'حبة',
    this.price = 0,
    this.qty = 0,
    this.currency = 'YER',
  });

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'name': name,
        'sku': sku,
        'unit': unit,
        'price': price,
        'qty': qty,
        'currency': currency,
      };

  static QuickPosItem fromMap(Object? raw) {
    final m = (raw is Map) ? raw : const <Object?, Object?>{};
    num n(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;
    return QuickPosItem(
      id: n(m['id']).toInt(),
      name: '${m['name'] ?? ''}',
      sku: '${m['sku'] ?? ''}',
      unit: '${m['unit'] ?? 'حبة'}',
      price: n(m['price']).toDouble(),
      qty: n(m['qty']).toDouble(),
      currency: '${m['currency'] ?? 'YER'}',
    );
  }
}

/// نتيجة عملية بيع سريع.
class QuickPosSaleResult {
  final bool ok;
  final String ref;
  final String name;
  final double qty;
  final double total;
  final double remaining;

  /// رسالة الخطأ المقروءة للمستخدم عند ok == false.
  final String error;

  const QuickPosSaleResult({
    required this.ok,
    this.ref = '',
    this.name = '',
    this.qty = 0,
    this.total = 0,
    this.remaining = 0,
    this.error = '',
  });

  Map<String, Object?> toMap() => <String, Object?>{
        'ok': ok,
        'ref': ref,
        'name': name,
        'qty': qty,
        'total': total,
        'remaining': remaining,
        'error': error,
      };
}

/// بيانات الترحيب (هوية العملة المعتمدة) عند اتصال النافذة العائمة.
class QuickPosHello {
  final String currency;
  final String symbol;
  final String appName;

  const QuickPosHello({
    required this.currency,
    required this.symbol,
    this.appName = 'مدير الحسابات',
  });

  Map<String, Object?> toMap() => <String, Object?>{
        'currency': currency,
        'symbol': symbol,
        'appName': appName,
      };
}

/// مصدر البيانات الذي يستدعيه البروتوكول: طبقة رقيقة فوق المستودع (Repo)
/// في التشغيل الفعلي، وبديل وهمي في الاختبارات.
abstract class QuickPosDataSource {
  Future<QuickPosHello> hello();
  Future<List<QuickPosItem>> lookup(String query);
  Future<QuickPosSaleResult> sell({required int itemId, required double qty});
}

/// مفكّك/مُنفّذ أوامر النافذة العائمة. صرف Dart بلا أي اعتماد على منصة،
/// فيُختبر بالكامل على Linux في GitHub Actions.
class QuickPosProtocol {
  final QuickPosDataSource source;

  /// الحد الأقصى لعدد النتائج المرسلة إلى النافذة العائمة.
  final int limit;

  const QuickPosProtocol(this.source, {this.limit = 30});

  /// يعالج رسالة واردة ويعيد خريطة الرد (أو null إن لم تكن رسالة صالحة).
  Future<Map<String, Object?>?> handle(Object? raw) async {
    final msg = _asMap(raw);
    if (msg == null) return null;
    final op = '${msg['op'] ?? ''}';
    switch (op) {
      case 'hello':
        return await _guard('hello', () async {
          final h = await source.hello();
          return <String, Object?>{
            't': 'res',
            'op': 'hello',
            'ok': true,
            ...h.toMap(),
          };
        });
      case 'lookup':
        return await _guard('lookup', () async {
          final q = '${msg['q'] ?? ''}';
          final items = await source.lookup(q);
          return <String, Object?>{
            't': 'res',
            'op': 'lookup',
            'ok': true,
            'q': q,
            'items': items.take(limit).map((e) => e.toMap()).toList(),
          };
        });
      case 'sell':
        return await _guard('sell', () async {
          final id = _asInt(msg['id']);
          final qty = _asDouble(msg['qty']);
          if (id == null || id <= 0) {
            return <String, Object?>{
              't': 'res',
              'op': 'sell',
              'ok': false,
              'error': 'لم يتم تحديد الصنف.',
            };
          }
          if (qty <= 0) {
            return <String, Object?>{
              't': 'res',
              'op': 'sell',
              'ok': false,
              'error': 'الكمية يجب أن تكون أكبر من صفر.',
            };
          }
          final res = await source.sell(itemId: id, qty: qty);
          return <String, Object?>{'t': 'res', 'op': 'sell', ...res.toMap()};
        });
      default:
        return <String, Object?>{
          't': 'res',
          'op': op,
          'ok': false,
          'error': 'أمر غير معروف: $op',
        };
    }
  }

  Future<Map<String, Object?>> _guard(
    String op,
    Future<Map<String, Object?>> Function() run,
  ) async {
    try {
      return await run();
    } catch (e) {
      return <String, Object?>{
        't': 'res',
        'op': op,
        'ok': false,
        'error': '$e',
      };
    }
  }

  static Map<String, Object?>? _asMap(Object? raw) {
    if (raw is Map<String, Object?>) return raw;
    if (raw is Map) return raw.map((k, v) => MapEntry('$k', v));
    return null;
  }

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));

  static double _asDouble(Object? v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);
}
