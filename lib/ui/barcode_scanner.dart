// شاشة مسح الباركود بالكاميرا (تولّي إضافة صنف/بيع) — محروسة بمنصة لعدم كسر ويندوز.

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/sfx.dart';
import '../core/platform_info.dart';

Future<String?> scanBarcode(BuildContext context) async {
  // الكاميرا غير متاحة على سطح المكتب.
  if (!PlatformInfo.isMobile) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('مسح الباركود متاح على الهاتف فقط')),
    );
    return null;
  }
  return Navigator.of(context)
      .push<String>(MaterialPageRoute(builder: (_) => const _BarcodeScanner()));
}

class _BarcodeScanner extends StatefulWidget {
  const _BarcodeScanner();

  @override
  State<_BarcodeScanner> createState() => _BarcodeScannerState();
}

class _BarcodeScannerState extends State<_BarcodeScanner> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture cap) {
    if (_handled) return;
    final code = cap.barcodes.isNotEmpty ? cap.barcodes.first.rawValue : null;
    if (code == null || code.isEmpty) return;
    _handled = true;
    Sfx.scan(); // "نق" سريع عند التقاط الباركود.
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('مسح الباركود'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Container(
            width: 260,
            height: 170,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white70, width: 3),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          Positioned(
            bottom: 40,
            child: Text(
              'وجّه الكاميرا نحو الباركود',
              style: TextStyle(color: Colors.white.withValues(alpha: .9)),
            ),
          ),
        ],
      ),
    );
  }
}
