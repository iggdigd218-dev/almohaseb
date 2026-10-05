import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/accounting.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../data/repository.dart';
import 'floating_pos_overlay.dart';
import 'quick_pos_protocol.dart';
import '../core/platform_info.dart';
import '../core/data_change.dart';

/// إدارة «الزر العائم للاستعلام والبيع السريع» من جانب التطبيق الأم.
///
/// قواعد العزل (بناء آمن على ويندوز/سطح المكتب):
///  * كل استدعاء لإضافة flutter_overlay_window محمي بـ [supported]
///    ([PlatformInfo.supportsOverlay]) — لا يُستدعى شيء منها على غير أندرويد إطلاقاً.
///  * قراءة وكتابة SQLite تتم حصراً هنا (اتصال واحد، WAL) ثم تُرسل
///    النتيجة كرسالة JSON إلى واجهة النافذة العائمة.
class FloatingPosService {
  FloatingPosService._();

  static final FloatingPosService instance = FloatingPosService._();

  /// قناة أمر الإعدادات السريعة (الستارة): MainActivity يرسل «tile».
  static const MethodChannel _host = MethodChannel('nexora/overlay');

  static const String _prefKey = 'floating_pos_enabled';

  QuickPosProtocol? _protocol;
  StreamSubscription<Object?>? _sub;
  bool _bound = false;

  /// أندرويد فقط — الميزة عديمة المعنى على ويندوز/سطح المكتب.
  static bool get supported => PlatformInfo.supportsOverlay;

  // ---------------- التفضيل المحلي (جهاز واحد، بلا مزامنة) ----------------

  static Future<bool> isEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_prefKey) ?? false;
  }

  static Future<void> setEnabled(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_prefKey, value);
  }

  // ---------------- صلاحية الظهور فوق التطبيقات ----------------

  Future<bool> hasPermission() async {
    if (!supported) return false;
    try {
      return await FlutterOverlayWindow.isPermissionGranted();
    } catch (_) {
      return false;
    }
  }

  /// يفتح شاشة أندرويد الرسمية لمنح الصلاحية ويعيد true إن مُنحت.
  Future<bool> requestPermission() async {
    if (!supported) return false;
    try {
      return await FlutterOverlayWindow.requestPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isActive() async {
    if (!supported) return false;
    try {
      return await FlutterOverlayWindow.isActive();
    } catch (_) {
      return false;
    }
  }

  // ---------------- التشغيل / الإيقاف ----------------

  /// يُظهر الفقاعة العائمة (إن كانت الصلاحية ممنوحه).
  Future<bool> show() async {
    if (!supported) return false;
    if (!await hasPermission()) return false;
    try {
      if (await isActive()) return true;
      await FlutterOverlayWindow.showOverlay(
        height: FloatingOverlayWindow.bubbleSize,
        width: FloatingOverlayWindow.bubbleSize,
        alignment: OverlayAlignment.centerRight,
        flag: OverlayFlag.defaultFlag,
        enableDrag: true,
        positionGravity: PositionGravity.auto,
        visibility: NotificationVisibility.visibilityPublic,
        overlayTitle: 'استعلام نكسورا — بيع سريع',
        overlayContent: 'انقر للاستعلام الفوري أو أخفِ الزر من الإعدادات',
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// إخفاء الفقاعة تماماً.
  Future<void> hide() async {
    if (!supported) return;
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
  }

  /// يُعيد تشغيل الفقاعة إن كان المستخدم قد فعّلها سابقاً على هذا الجهاز.
  Future<void> restore() async {
    if (!supported) return;
    if (!await isEnabled()) return;
    if (!await hasPermission()) return;
    await show();
  }

  // ---------------- الربط بقاعدة البيانات ----------------

  /// يستمع لرسائل النافذة العائمة وينفّذها على المستودع، ويردّ بالنتيجة.
  Future<void> bind(Repo repo) async {
    if (!supported || _bound) return;
    _bound = true;
    _protocol = QuickPosProtocol(RepoQuickPosSource(repo));
    _sub = FlutterOverlayWindow.overlayListener.listen(_onOverlayMessage);
    _host.setMethodCallHandler(_onHostCall);
    await _consumePendingTileAction();
  }

  /// أمر ستارة وصل قبل اكتمال إقلاع فلاتر (إقلاع بارد) — MainActivity
  /// يحتفظ به ويُسلّمه هنا عبر قناة nexora/overlay.
  Future<void> _consumePendingTileAction() async {
    try {
      final res = await _host.invokeMethod('takeTile');
      if (res is! Map) return;
      if (res['permission'] == true) {
        // النقرة جاءت بلا صلاحية: نفتح شاشة أندرويد الرسمية لمنحها.
        await requestPermission();
        return;
      }
      if (await show()) await setEnabled(true);
    } catch (_) {}
  }

  Future<void> unbind() async {
    await _sub?.cancel();
    _sub = null;
    _host.setMethodCallHandler(null);
    _bound = false;
  }

  Future<void> _onOverlayMessage(Object? raw) async {
    final res = await _protocol?.handle(raw);
    if (res == null) return;
    // إعادة معرّف الارتباط (rid) كما أُرسل لتطابقه الواجهة مع طلبها المعلّق.
    if (raw is Map && raw['rid'] is int) res['rid'] = raw['rid'] as int;
    try {
      await FlutterOverlayWindow.shareData(res);
    } catch (_) {}
  }

  /// أوامر قادمة من بلاطة الإعدادات السريعة (الستارة) عبر MainActivity.
  Future<dynamic> _onHostCall(MethodCall call) async {
    switch (call.method) {
      case 'tile':
        final needPermission =
            (call.arguments is Map ? call.arguments['permission'] : null) ==
                true;
        if (needPermission) return await requestPermission();
        final ok = await show();
        if (ok) await setEnabled(true);
        return ok;
      case 'state':
        return await isActive();
      default:
        return false;
    }
  }
}

/// مصدر بيانات حقيقي: كل قراءة/كتابة تمرّ عبر مستودع التطبيق (SQLite/WAL).
class RepoQuickPosSource implements QuickPosDataSource {
  final Repo repo;
  const RepoQuickPosSource(this.repo);

  @override
  Future<QuickPosHello> hello() async {
    final c = await _currency();
    return QuickPosHello(currency: c.code, symbol: c.symbol);
  }

  Future<CurrencyDef> _currency() async {
    try {
      final list = await repo.currencies().timeout(const Duration(seconds: 3));
      if (list.isNotEmpty) return list.first;
    } catch (_) {}
    return kDefaultCurrencies.first;
  }

  @override
  Future<List<QuickPosItem>> lookup(String query) async {
    final all = await repo.items().timeout(const Duration(seconds: 5));
    final cur = (await _currency()).code;
    final q = query.trim().toLowerCase();
    final hits = all.where((i) {
      if (q.isEmpty) return true;
      return i.sku.toLowerCase().contains(q) ||
          i.name.toLowerCase().contains(q) ||
          '${i.id}' == q;
    }).toList();
    if (q.isNotEmpty) {
      // الباركود المطابق تماماً أولاً: الأسرع للوصول عند المسح.
      hits.sort((a, b) {
        final ae = a.sku.toLowerCase() == q ? 0 : 1;
        final be = b.sku.toLowerCase() == q ? 0 : 1;
        return ae != be ? ae.compareTo(be) : a.name.compareTo(b.name);
      });
    }
    return hits
        .take(30)
        .map(
          (i) => QuickPosItem(
            id: i.id ?? 0,
            name: i.name,
            sku: i.sku,
            unit: i.unit,
            price: i.sellPrice,
            qty: i.quantity,
            currency: i.currency.trim().isEmpty ? cur : i.currency,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<QuickPosSaleResult> sell({
    required int itemId,
    required double qty,
  }) async {
    final it = await repo.item(itemId);
    if (it == null) {
      return const QuickPosSaleResult(ok: false, error: 'الصنف غير موجود.');
    }
    if (Fmt.moneyGt(qty, it.quantity)) {
      return QuickPosSaleResult(
        ok: false,
        error: 'الكمية المطلوبة من «${it.name}» غير متوفرة. '
            'المتاح: ${Fmt.money(it.quantity)} ${it.unit}.',
      );
    }
    final cur = await _currency();
    final total = it.sellPrice * qty;
    if (!total.isFinite || total <= 0) {
      return const QuickPosSaleResult(
        ok: false,
        error: 'سعر البيع صفر — حدّث سعر الصنف أولاً.',
      );
    }
    final ref = await repo.nextTxNumber();
    final now = DateTime.now();
    final lines = [
      InvoiceLine(
        itemId: it.id,
        name: it.name,
        unit: it.unit,
        quantity: qty,
        unitPrice: it.sellPrice,
        total: total,
      ),
    ];
    // مبيعات نقدية: إيراد (يسمح المستودع بعملية نقدية بلا حساب عميل).
    final tx = Tx(
      amount: total,
      currency: it.currency.trim().isEmpty ? cur.code : it.currency,
      type: OpType.revenue,
      date: now,
      description: 'بيع سريع من الزر العائم رقم #$ref',
      reference: ref,
      notes: 'طريقة الدفع: نقداً (بيع سريع من الزر العائم)',
      createdAt: now,
      updatedAt: now,
    );
    await repo.saveTx(tx, items: lines);
    // خصم الكمية من المخزون (حركة بيع) مع إدراجها في طابور المزامنة.
    await repo.addStockMove(
      StockMove(
        itemId: itemId,
        quantity: qty,
        kind: StockKind.sale,
        unitPrice: it.sellPrice,
        date: now,
        createdAt: now,
        notes: 'بيع سريع (زر عائم) #$ref',
      ),
    );
    final fresh = await repo.item(itemId);
    // (2026-09-24) أبلغ الواجهة (نقطة البيع/المخزون) أن الأرصدة تغيّرت
    // خارجها فتُحدَّث فوراً بلا انتظار إعادة فتح.
    markDataChanged();
    return QuickPosSaleResult(
      ok: true,
      ref: ref,
      name: it.name,
      qty: qty,
      total: total,
      remaining: fresh?.quantity ?? (it.quantity - qty),
    );
  }
}
