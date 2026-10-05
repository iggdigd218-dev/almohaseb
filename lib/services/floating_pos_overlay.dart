import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'quick_pos_protocol.dart';
import '../core/platform_info.dart';

import '../core/theme.dart';
/// لون الهوية الموحّد (المخزون • نقطة البيع • الزر العائم).
const Color kQuickPosTeal = AppColors.primary;

/// قناة الربط بين واجهة النافذة العائمة والتطبيق الأم.
///
/// في التشغيل الفعلي تُرسل الرسائل عبر `BasicMessageChannel` الخاص بحزمة
/// flutter_overlay_window؛ وفي الاختبارات يُمرَّر بديل وهمي.
abstract class QuickPosLink {
  Stream<Object?> get replies;
  Future<void> send(Map<String, Object?> message);
}

/// الربط الحقيقي داخل محرك النافذة العائمة (أندرويد فقط).
class OverlayQuickPosLink implements QuickPosLink {
  @override
  Stream<Object?> get replies => FlutterOverlayWindow.overlayListener;

  @override
  Future<void> send(Map<String, Object?> message) async {
    try {
      await FlutterOverlayWindow.shareData(message);
    } catch (_) {
      // التطبيق الأم غير مستمع — تُعرض رسالة «افتح التطبيق» في الواجهة.
    }
  }
}

/// تحجيم النافذة العائمة: فقاعة صغيرة عند التصغير، بطاقة كاملة عند الفتح.
class FloatingOverlayWindow {
  static const int bubbleSize = 64;
  static const int panelWidth = 330;
  static const int panelHeight = 480;

  const FloatingOverlayWindow._();

  static bool get supported => PlatformInfo.supportsOverlay;

  static Future<void> toBubble() async {
    if (!supported) return;
    try {
      await FlutterOverlayWindow.updateFlag(OverlayFlag.defaultFlag);
      await FlutterOverlayWindow.resizeOverlay(bubbleSize, bubbleSize, true);
    } catch (_) {}
  }

  static Future<void> toPanel() async {
    if (!supported) return;
    try {
      // focusPointer: يسمح بمرور أحداث اللمس ويفتح لوحة مفاتيح النظام.
      await FlutterOverlayWindow.updateFlag(OverlayFlag.focusPointer);
      await FlutterOverlayWindow.resizeOverlay(panelWidth, panelHeight, false);
    } catch (_) {}
  }

  /// إخفاء الفقاعة تماماً حتى تُشغَّل من جديد (من الستارة أو الإعدادات).
  static Future<void> close() async {
    if (!supported) return;
    try {
      await FlutterOverlayWindow.closeOverlay();
    } catch (_) {}
  }
}

/// نقطة دخول محرك النافذة العائمة — تُستدعى من `overlayMain()` في main.dart.
///
/// محرك النافذة العائمة **لا تُسجَّل فيه إضافات فلاتر**، لذلك لا يُستدعى
/// هنا أي شيء يتطلب قناة منصة (لا sqflite ولا path_provider ولا مشاركات).
void runQuickPosOverlay() {
  runApp(const QuickPosOverlayApp());
}

class QuickPosOverlayApp extends StatelessWidget {
  const QuickPosOverlayApp({super.key, this.link});

  /// بديل وهمي للاختبارات فقط.
  final QuickPosLink? link;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Cairo',
        colorScheme: ColorScheme.fromSeed(seedColor: kQuickPosTeal),
      ),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: QuickPosOverlayPanel(link: link ?? OverlayQuickPosLink()),
      ),
    );
  }
}

class QuickPosOverlayPanel extends StatefulWidget {
  const QuickPosOverlayPanel({super.key, required this.link});

  final QuickPosLink link;

  @override
  State<QuickPosOverlayPanel> createState() => _QuickPosOverlayPanelState();
}

class _QuickPosOverlayPanelState extends State<QuickPosOverlayPanel> {
  bool _expanded = false;
  bool _showClose = false;
  String _query = '';
  List<QuickPosItem> _items = const <QuickPosItem>[];
  QuickPosItem? _selected;
  double _qty = 1;
  bool _busy = false;
  String? _status;
  bool _statusOk = true;
  String _symbol = '';
  bool _linked = false;
  int _reqId = 0;

  StreamSubscription<Object?>? _sub;
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};

  @override
  void initState() {
    super.initState();
    _sub = widget.link.replies.listen(_onReply);
    _handshake();
  }

  @override
  void dispose() {
    _sub?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(<String, Object?>{'ok': false});
    }
    super.dispose();
  }

  Future<void> _handshake() async {
    final res = await _request(<String, Object?>{'op': 'hello'});
    if (!mounted) return;
    setState(() {
      _linked = res != null && res['ok'] == true;
      _symbol = '${res?['symbol'] ?? ''}';
    });
    if (_linked) _lookup('');
  }

  void _onReply(Object? raw) {
    if (raw is! Map) return;
    final id = raw['rid'];
    final c = id is int ? _pending.remove(id) : null;
    if (c != null && !c.isCompleted) {
      c.complete(raw.map((k, v) => MapEntry('$k', v)));
    }
  }

  Future<Map<String, Object?>?> _request(
    Map<String, Object?> body, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final id = ++_reqId;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    // 'rid' = معرّف الطلب (الارتباط) — 'id' محجوز لمعرّف الصنف في أمر البيع.
    await widget.link.send(<String, Object?>{...body, 'rid': id});
    try {
      return await c.future.timeout(timeout);
    } catch (_) {
      _pending.remove(id);
      return null;
    }
  }

  Future<void> _lookup(String q) async {
    final res = await _request(<String, Object?>{'op': 'lookup', 'q': q});
    if (!mounted || res == null) return;
    final list = res['items'];
    setState(() {
      _items = list is List
          ? list.map(QuickPosItem.fromMap).toList(growable: false)
          : const <QuickPosItem>[];
    });
  }

  Future<void> _expand() async {
    setState(() {
      _expanded = true;
      _showClose = false;
    });
    await FloatingOverlayWindow.toPanel();
  }

  Future<void> _collapse() async {
    setState(() {
      _expanded = false;
      _selected = null;
      _showClose = false;
    });
    await FloatingOverlayWindow.toBubble();
  }

  Future<void> _hide() async {
    await FloatingOverlayWindow.close();
  }

  void _key(String k) {
    setState(() {
      if (k == 'del') {
        if (_query.isNotEmpty) _query = _query.substring(0, _query.length - 1);
      } else if (k == 'clr') {
        _query = '';
      } else if (_query.length < 24) {
        _query += k;
      }
      _status = null;
    });
    _lookup(_query);
  }

  Future<void> _sell() async {
    final it = _selected;
    if (it == null || _busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    final res = await _request(<String, Object?>{
      'op': 'sell',
      'id': it.id,
      'qty': _qty,
    }, timeout: const Duration(seconds: 12));
    if (!mounted) return;
    final ok = res != null && res['ok'] == true;
    setState(() {
      _busy = false;
      _statusOk = ok;
      _status = ok
          ? 'تم البيع ⚡ فاتورة #${res['ref'] ?? ''}'
          : 'تعذّر تسجيل البيع: ${res?['error'] ?? 'افتح التطبيق'}';
      if (ok) {
        _selected = null;
        _qty = 1;
      }
    });
    if (ok) _lookup(_query);
  }

  @override
  Widget build(BuildContext context) {
    if (!_expanded) return _buildBubble();
    return _buildPanel();
  }

  // ---------------- الفقاعة العائمة ----------------
  Widget _buildBubble() {
    return SizedBox.expand(
      child: Stack(
        children: [
          Center(
            child: GestureDetector(
              onTap: _expand,
              onLongPress: () => setState(() => _showClose = true),
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: kQuickPosTeal,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(Icons.flash_on_rounded,
                    color: Colors.white, size: 30),
              ),
            ),
          ),
          if (_showClose)
            PositionedDirectional(
              top: 2,
              start: 2,
              child: GestureDetector(
                onTap: _hide,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: const Color(0xFFDC2626),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.4),
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 14),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------- البطاقة الموسّعة ----------------
  Widget _buildPanel() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Material(
        color: const Color(0xFFF8FAFC),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            _buildCodeRow(),
            if (!_linked) _buildOfflineBanner(),
            Expanded(child: _buildResults()),
            if (_selected != null) _buildSellBar(),
            if (_status != null) _buildStatus(),
            _buildKeypad(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: kQuickPosTeal,
      padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 6, 6),
      child: Row(
        children: [
          const Icon(Icons.flash_on_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              'استعلام وبيع سريع',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13),
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            icon: const Icon(Icons.remove_circle_outline,
                color: Colors.white, size: 18),
            tooltip: 'تصغير',
            onPressed: _collapse,
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            icon: const Icon(Icons.close, color: Colors.white, size: 18),
            tooltip: 'إخفاء',
            onPressed: _hide,
          ),
        ],
      ),
    );
  }

  Widget _buildCodeRow() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.qr_code_scanner, size: 16, color: kQuickPosTeal),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _query.isEmpty ? 'أدخل كود/باركود الصنف' : _query,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.start,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: _query.isEmpty ? Colors.black38 : kQuickPosTeal,
              ),
            ),
          ),
          if (_items.isNotEmpty)
            Text('${_items.length} نتيجة',
                style: const TextStyle(fontSize: 10, color: Colors.black45)),
        ],
      ),
    );
  }

  Widget _buildOfflineBanner() {
    return Container(
      color: const Color(0xFFFFF7ED),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: const Text(
        'افتح التطبيق مرة واحدة لتفعيل الاستعلام المباشر من قاعدة البيانات.',
        style: TextStyle(fontSize: 10, color: Color(0xFFB45309)),
      ),
    );
  }

  Widget _buildResults() {
    if (_items.isEmpty) {
      return const Center(
        child: Text('لا نتائج — جرّب كوداً آخر أو تصفّح القائمة',
            style: TextStyle(fontSize: 11, color: Colors.black45)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final it = _items[i];
        final selected = _selected?.id == it.id;
        final qtyColor = it.qty <= 0
            ? const Color(0xFFDC2626)
            : (it.qty <= 5 ? const Color(0xFFEA580C) : const Color(0xFF059669));
        return InkWell(
          onTap: () => setState(() {
            _selected = it;
            _qty = 1;
            _status = null;
          }),
          child: Container(
            color: selected ? const Color(0xFFCCFBF1) : null,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(it.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5)),
                ),
                Text(
                  '${_num(it.price)} ${_symbol.isEmpty ? it.currency : _symbol}',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: kQuickPosTeal),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: qtyColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${_num(it.qty)} ${it.unit}',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: qtyColor)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSellBar() {
    final it = _selected!;
    final total = it.price * _qty;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${it.name} — ${_num(it.price)} ${_symbol.isEmpty ? it.currency : _symbol}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _stepper(),
              const Spacer(),
              Text(
                'الإجمالي: ${_num(total)} ${_symbol.isEmpty ? it.currency : _symbol}',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0F172A)),
              ),
            ],
          ),
          const SizedBox(height: 5),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: kQuickPosTeal,
              padding: const EdgeInsets.symmetric(vertical: 6),
            ),
            onPressed: _busy ? null : _sell,
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.flash_on_rounded, size: 16),
            label: const Text('بيع سريع ⚡',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _stepper() {
    return Row(
      children: [
        _roundBtn(Icons.remove, () {
          if (_qty > 1) setState(() => _qty = _qty - 1);
        }),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(_num(_qty),
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        ),
        _roundBtn(Icons.add, () {
          setState(() => _qty = _qty + 1);
        }),
      ],
    );
  }

  Widget _roundBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: const Color(0xFFCCFBF1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: kQuickPosTeal),
        ),
      );

  Widget _buildStatus() {
    return Container(
      color: _statusOk ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        _status ?? '',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: _statusOk ? const Color(0xFF047857) : const Color(0xFFB91C1C),
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    // صفوف/أعمدة ثابتة (لا GridView): النافذة العائمة صغيرة الحجم ولا نريد
    // بناءً كسولاً يُخفي مفاتيح عن الاستخدام أو عن الاختبارات.
    const rows = <List<String>>[
      <String>['1', '2', '3'],
      <String>['4', '5', '6'],
      <String>['7', '8', '9'],
      <String>['clr', '0', 'del'],
    ];
    return Container(
      color: const Color(0xFFE2E8F0),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var r = 0; r < rows.length; r++)
            Padding(
              padding: EdgeInsets.only(bottom: r == rows.length - 1 ? 0 : 5),
              child: Row(
                children: [
                  for (final k in rows[r])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2.5),
                        child: SizedBox(height: 36, child: _keyBtn(k)),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _keyBtn(String k) {
    final isDigit = k != 'clr' && k != 'del';
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _key(k),
        child: Center(
          child: isDigit
              ? Text(k,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold))
              : Icon(k == 'del' ? Icons.backspace_outlined : Icons.clear,
                  size: 16, color: const Color(0xFFB91C1C)),
        ),
      ),
    );
  }

  static String _num(double v) =>
      (v % 1 == 0) ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}
