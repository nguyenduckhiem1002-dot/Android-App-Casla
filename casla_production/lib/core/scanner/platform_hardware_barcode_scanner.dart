import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'barcode_scan_event.dart';
import 'barcode_scanner.dart';

/// Hardware scanner adapter backed by the Android native bridge.
///
/// CipherLab ReaderConfig can broadcast decoded barcode data through
/// `com.cipherlab.barcodebaseapi.PASS_DATA_2_APP`. The Android side receives
/// that broadcast while the app is foregrounded and forwards sanitized scan
/// events through an EventChannel. Non-Android platforms simply report that no
/// hardware scanner is available, allowing the UI to fall back to camera scan.
class PlatformHardwareBarcodeScanner implements BarcodeScanner {
  static const _control = MethodChannel('casla/scanner/control');
  static const _events = EventChannel('casla/scanner/events');

  const PlatformHardwareBarcodeScanner();

  @override
  Future<bool> isAvailable() async {
    if (kIsWeb) return false;

    try {
      return await _control.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Stream<BarcodeScanEvent> get scans => _events
      .receiveBroadcastStream()
      .map(BarcodeScanEvent.fromPlatform);
}
