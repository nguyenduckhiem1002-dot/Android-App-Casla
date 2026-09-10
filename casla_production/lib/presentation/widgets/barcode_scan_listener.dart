import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/router/app_route_observer.dart';
import '../../core/scanner/barcode_scan_event.dart';
import '../../core/scanner/barcode_scanner.dart';
import '../../core/scanner/composite_barcode_scanner.dart';
import '../../core/scanner/platform_hardware_barcode_scanner.dart';
import '../../core/scanner/scan_deduplicator.dart';
import '../../core/scanner/scan_feedback.dart';
import '../../core/scanner/scanner_preferences.dart';
import '../../core/scanner/wedge_barcode_scanner.dart';
import '../../core/telemetry/field_telemetry.dart';

enum HardwareScanState { probing, ready, busy, unavailable }

/// What the reader is doing right now, for screens that want to show it.
@immutable
class BarcodeScanStatus {
  final HardwareScanState state;
  final String message;
  final int acceptedCount;

  const BarcodeScanStatus({
    required this.state,
    required this.message,
    this.acceptedCount = 0,
  });

  bool get isReady => state == HardwareScanState.ready;

  bool get isBusy => state == HardwareScanState.busy;

  bool get isAvailable => state != HardwareScanState.unavailable;

  BarcodeScanStatus copyWith({
    HardwareScanState? state,
    String? message,
    int? acceptedCount,
  }) => BarcodeScanStatus(
    state: state ?? this.state,
    message: message ?? this.message,
    acceptedCount: acceptedCount ?? this.acceptedCount,
  );
}

class _ScanStatusScope
    extends InheritedNotifier<ValueNotifier<BarcodeScanStatus>> {
  const _ScanStatusScope({required super.notifier, required super.child});
}

/// Keeps a hardware reader armed for the whole subtree.
///
/// This exists so a data-entry screen never has to send the operator through a
/// full-screen "scanner page" just to fire the trigger. The form stays on
/// screen, the reader stays live, and a trigger pull lands straight in the
/// right field — which is the whole point on a site that scans with a laser
/// rather than a camera.
///
/// Both capture paths run at once (vendor broadcast plus keyboard wedge), so a
/// handset the app has never seen before still scans. Deduplication is a
/// double-fire guard only; there is no artificial cooldown, because a trigger
/// pull is already an explicit operator action.
class BarcodeScanListener extends StatefulWidget {
  final Widget child;

  /// Called with the raw payload. Return false to mark the scan rejected, so
  /// the operator hears the failure tone instead of the success tone.
  final FutureOr<bool> Function(String code) onScan;

  /// Set false while the screen is showing a blocking dialog of its own.
  final bool enabled;

  final BarcodeScanner? scanner;
  final ScannerPreferences? preferences;
  final FieldTelemetry? telemetry;

  const BarcodeScanListener({
    super.key,
    required this.child,
    required this.onScan,
    this.enabled = true,
    this.scanner,
    this.preferences,
    this.telemetry,
  });

  /// Live reader status for descendants. Returns null outside a listener.
  static BarcodeScanStatus? statusOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_ScanStatusScope>()
      ?.notifier
      ?.value;

  @override
  State<BarcodeScanListener> createState() => BarcodeScanListenerState();
}

class BarcodeScanListenerState extends State<BarcodeScanListener>
    with RouteAware {
  static const String _readyMessage = 'Sẵn sàng nhận mã từ đầu đọc';
  static const String _probingMessage = 'Đang dò đầu đọc...';

  late final BarcodeScanner _scanner;
  late final ScannerPreferences _preferences;
  final ScanDeduplicator _deduplicator = ScanDeduplicator(
    // A double-fire guard, not a cooldown. Long enough to absorb a reader that
    // both broadcasts and types the same code, short enough that scanning the
    // same card twice on purpose still works.
    window: const Duration(milliseconds: 400),
  );

  final ValueNotifier<BarcodeScanStatus> _status =
      ValueNotifier<BarcodeScanStatus>(
        const BarcodeScanStatus(
          state: HardwareScanState.probing,
          message: _probingMessage,
        ),
      );

  StreamSubscription<BarcodeScanEvent>? _subscription;
  ModalRoute<dynamic>? _route;
  bool _isRouteVisible = true;
  bool _isHandling = false;
  int _acceptedCount = 0;

  FieldTelemetry get _telemetry => widget.telemetry ?? FieldTelemetry.instance;

  /// Lets a screen re-arm after it has consumed a scan, so the same code can
  /// be scanned again straight away.
  void resetDeduplication() => _deduplicator.reset();

  @override
  void initState() {
    super.initState();
    // Both paths, always. The wedge reader is constructed per listener rather
    // than shared, because each one attaches its own key handler and has to
    // detach it again on dispose.
    _scanner =
        widget.scanner ??
        CompositeBarcodeScanner([
          const PlatformHardwareBarcodeScanner(),
          WedgeBarcodeScanner(),
        ]);
    _preferences = widget.preferences ?? DatabaseScannerPreferences();
    _subscribe();
    unawaited(_probeAvailability());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route) return;

    if (_route != null) appRouteObserver.unsubscribe(this);
    _route = route;
    if (route != null) appRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() => _isRouteVisible = false;

  @override
  void didPopNext() {
    _isRouteVisible = true;
    _isHandling = false;
    _deduplicator.reset();
    _setStatus(HardwareScanState.ready, _readyMessage);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    appRouteObserver.unsubscribe(this);
    final scanner = _scanner;
    if (scanner is CompositeBarcodeScanner) unawaited(scanner.dispose());
    _status.dispose();
    super.dispose();
  }

  Future<void> _probeAvailability() async {
    final available = await _scanner.isAvailable();
    final seenBefore = await _preferences.wasHardwareScanSeen();
    if (!mounted) return;

    // A wedge reader is invisible until it first fires, so a device that has
    // scanned before stays in "ready" even when detection says otherwise.
    _setStatus(
      available || seenBefore
          ? HardwareScanState.ready
          : HardwareScanState.unavailable,
      available || seenBefore
          ? _readyMessage
          : 'Chưa phát hiện đầu đọc trên máy này',
    );
  }

  void _subscribe() {
    _subscription?.cancel();
    _subscription = _scanner.scans.listen(
      (event) => unawaited(_handle(event)),
      onError: (Object _) {
        if (!mounted) return;
        // The wedge path survives a broadcast-channel failure, so this is a
        // status downgrade rather than a shutdown.
        _setStatus(HardwareScanState.ready, 'Đầu đọc gặp lỗi, đang chờ lại');
      },
    );
  }

  bool get _canAccept =>
      widget.enabled &&
      mounted &&
      _isRouteVisible &&
      !_isHandling &&
      TickerMode.valuesOf(context).enabled &&
      (_route?.isCurrent ?? true);

  Future<void> _handle(BarcodeScanEvent event) async {
    if (!_canAccept) return;

    final code = event.rawValue.trim();
    if (code.isEmpty) return;

    // Deduplicate against when the reader fired, not when this handler ran.
    // The broadcast path carries the reader service's own timestamp, so a
    // queued burst is judged by its real spacing rather than by delivery order.
    if (!_deduplicator.shouldAccept(code, now: event.timestamp)) {
      _telemetry.increment(FieldMetric.hardwareScanDuplicate);
      ScanFeedback.duplicate();
      return;
    }

    _telemetry.increment(FieldMetric.hardwareScanAccepted);
    if (event.symbology == 'wedge') {
      _telemetry.increment(FieldMetric.wedgeScanAccepted);
    }
    unawaited(_preferences.rememberHardwareScanSeen());

    _isHandling = true;
    _setStatus(HardwareScanState.busy, 'Đã nhận mã, đang kiểm tra');

    var accepted = false;
    try {
      accepted = await Future<bool>.sync(() => widget.onScan(code));
    } finally {
      _isHandling = false;
      if (mounted) {
        if (accepted) {
          _acceptedCount += 1;
          ScanFeedback.success();
          _setStatus(HardwareScanState.ready, 'Đã nhận. Mời quét tiếp.');
        } else {
          _telemetry.increment(FieldMetric.hardwareScanRejected);
          ScanFeedback.failure();
          _setStatus(HardwareScanState.ready, _readyMessage);
        }
      }
    }
  }

  void _setStatus(HardwareScanState state, String message) {
    if (!mounted) return;
    _status.value = BarcodeScanStatus(
      state: state,
      message: message,
      acceptedCount: _acceptedCount,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _ScanStatusScope(notifier: _status, child: widget.child);
  }
}
