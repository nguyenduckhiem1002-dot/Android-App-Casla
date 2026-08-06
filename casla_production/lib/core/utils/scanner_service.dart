// Core Utilities — QR Scanner Service
// Wrapper around mobile_scanner

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QrScannerService {
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  void dispose() {
    controller.dispose();
  }

  void toggleTorch() {
    controller.toggleTorch();
  }

  /// Helper widget for the camera view
  Widget buildScannerView(Function(String) onDetect) {
    return MobileScanner(
      controller: controller,
      onDetect: (capture) {
        final List<Barcode> barcodes = capture.barcodes;
        for (final barcode in barcodes) {
          if (barcode.rawValue != null) {
            onDetect(barcode.rawValue!);
            break; // take first
          }
        }
      },
    );
  }
}
