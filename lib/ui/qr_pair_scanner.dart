// شاشة مسح QR للاقتران السحابي (دفعة 58: الدعوات السحابية حصرياً —
// حُذف تماماً تحليل رموز LAN القديمة nexora://pair بعنوان IP).
// تستخدم mobile_scanner نفسها المستخدمة في barcode_scanner.dart.

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/sync/cloud_join.dart';
import '../core/platform_info.dart';

class PairingData {
  final String ws;
  final String ip;
  final int port;
  final String tok;

  /// نوع الاقتران: 'cloud' حصرياً منذ الدفعة 58 (اجتُثت رموز LAN).
  final String kind;

  /// لدعوات السحابة: رابط قاعدة البيانات ورمز النسخة السحابية.
  final String cloudUrl;
  final String cloudCode;
  const PairingData({
    required this.ws,
    required this.ip,
    required this.port,
    required this.tok,
    this.kind = 'cloud',
    this.cloudUrl = '',
    this.cloudCode = '',
  });

  bool get isCloud => kind == 'cloud';
}

Future<PairingData?> scanQrPair(BuildContext context) async {
  if (!PlatformInfo.isMobile) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'مسح QR متاح على الهاتف فقط. يمكنك إدخال البيانات يدوياً',
        ),
      ),
    );
    return null;
  }
  return Navigator.of(context).push<PairingData>(
    MaterialPageRoute(builder: (_) => const _QrPairScanner()),
  );
}

class _QrPairScanner extends StatefulWidget {
  const _QrPairScanner();

  @override
  State<_QrPairScanner> createState() => _QrPairScannerState();
}

class _QrPairScannerState extends State<_QrPairScanner> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: [BarcodeFormat.qrCode],
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture cap) {
    if (_handled) return;
    for (final b in cap.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      // دعوة سحابية؟ nexora://cloudjoin?...
      final cloud = CloudInviteInfo.parseQr(raw);
      if (cloud != null &&
          (cloud['url'] ?? '').isNotEmpty &&
          (cloud['tok'] ?? '').isNotEmpty) {
        _handled = true;
        Navigator.of(context).pop(PairingData(
          ws: cloud['ws'] ?? 'default',
          ip: '',
          port: 0,
          tok: cloud['tok'] ?? '',
          kind: 'cloud',
          cloudUrl: cloud['url'] ?? '',
          cloudCode: cloud['code'] ?? '',
        ));
        return;
      }
      // (دفعة 58) رمز غير سحابي = غير مدعوم — نتجاهله بصمت ونواصل المسح.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مسح QR للاقتران'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // Overlay مربع مسح.
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.9),
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                'وجّه الكاميرا إلى QR الظاهر على الجهاز الرئيسي',
                style: TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
