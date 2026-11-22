// ناقل بسيط لنشاط المزامنة: يستدعيه محرك المزامنة عند أي حدث
// (وصول عملية، تغيّر صلاحيات، اكتمال دفع) لتنبيه طبقة الواجهة للتحديث
// دون أي اعتماد دائري على Riverpod أو طبقة العرض.
import 'dart:async';

class SyncActivityBus {
  SyncActivityBus._();
  static final SyncActivityBus instance = SyncActivityBus._();

  int _tick = 0;
  int get tick => _tick;

  final StreamController<int> _controller =
      StreamController<int>.broadcast();
  Stream<int> get stream => _controller.stream;

  void ping() {
    _tick++;
    if (_controller.hasListener) _controller.add(_tick);
  }
}
