import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'barcode_scan_event.dart';
import 'barcode_scanner.dart';
import 'scan_diagnostics.dart';

/// Hardware scanner adapter backed by the Android native bridge.
///
/// PDA reader services broadcast decoded barcode data using their own
/// documented app-output action (CipherLab's `PASS_DATA_2_APP`, Honeywell's
/// `com.honeywell.scan.broadcast`, and so on). The Android side receives those
/// broadcasts while the app is foregrounded and forwards sanitized scan events
/// through an EventChannel.
///
/// [isAvailable] is a hint, not a gate: it reports whether this handset looks
/// like a data-capture device. Capture itself never depends on that answer,
/// because [WedgeBarcodeScanner] covers the handsets this cannot recognise.
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
      ScanDiagnostics.instance.record(ScanDiagnosticEvent.channelError);
      return false;
    } on PlatformException {
      ScanDiagnostics.instance.record(ScanDiagnosticEvent.channelError);
      return false;
    }
  }

  /// Clears the native decision-event buffer, so a fresh support trace only
  /// covers the scans made after this call.
  Future<bool> clearDiagnostics() async {
    if (kIsWeb) return false;
    try {
      await _control.invokeMethod<void>('clearDiagnostics');
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Device and reader-service facts plus recent privacy-safe native events.
  ///
  /// Returns an empty map on any platform without the bridge, so callers can
  /// render "không xác định" rather than handling an error.
  Future<Map<String, Object?>> diagnostics() async {
    if (kIsWeb) return const {};

    try {
      final result = await _control.invokeMapMethod<String, Object?>(
        'diagnostics',
      );
      return result ?? const {};
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  @override
  Stream<BarcodeScanEvent> get scans =>
      _events.receiveBroadcastStream().map((payload) {
        try {
          return BarcodeScanEvent.fromPlatform(payload);
        } on FormatException {
          ScanDiagnostics.instance.record(ScanDiagnosticEvent.invalidEnvelope);
          rethrow;
        }
      });
}
