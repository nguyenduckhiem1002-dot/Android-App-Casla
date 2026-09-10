import 'dart:async';

import 'barcode_scan_event.dart';
import 'barcode_scanner.dart';

/// Listens to every capture path at once and republishes them as one stream.
///
/// The two paths are complementary rather than alternatives: the vendor
/// broadcast bridge is faster and carries a real symbology, but only works on
/// handsets whose reader service the app recognises, while the keyboard wedge
/// works everywhere and needs no configuration. Running both means a device
/// that matches neither assumption still scans.
///
/// Duplicate suppression is deliberately left to the caller's
/// [ScanDeduplicator]: a reader configured to both broadcast and type would
/// otherwise deliver the same code twice.
class CompositeBarcodeScanner implements BarcodeScanner {
  final List<BarcodeScanner> delegates;

  final List<StreamSubscription<BarcodeScanEvent>> _subscriptions = [];

  /// Closed by [dispose], which every owner calls from its own `dispose`.
  // ignore: close_sinks
  late final StreamController<BarcodeScanEvent> _controller =
      StreamController<BarcodeScanEvent>.broadcast(
        onListen: _subscribeAll,
        onCancel: _cancelAll,
      );

  CompositeBarcodeScanner(this.delegates);

  /// True when any delegate reports itself usable.
  @override
  Future<bool> isAvailable() async {
    for (final delegate in delegates) {
      if (await delegate.isAvailable()) return true;
    }
    return false;
  }

  @override
  Stream<BarcodeScanEvent> get scans => _controller.stream;

  void _subscribeAll() {
    _cancelAll();
    for (final delegate in delegates) {
      _subscriptions.add(
        delegate.scans.listen(
          (event) {
            if (_controller.isClosed) return;
            _controller.add(event);
          },
          // One path failing must not take the others down with it. A PDA whose
          // reader service dies mid-shift keeps scanning through the wedge.
          onError: (Object _) {},
        ),
      );
    }
  }

  void _cancelAll() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  Future<void> dispose() async {
    _cancelAll();
    if (!_controller.isClosed) await _controller.close();
  }
}
