import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/router/app_route_observer.dart';
import '../../app/theme/casla_colors.dart';
import '../../core/scanner/barcode_scan_event.dart';
import '../../core/scanner/barcode_scanner.dart';
import '../../core/scanner/platform_hardware_barcode_scanner.dart';
import '../../core/scanner/scan_deduplicator.dart';
import 'casla_logo.dart';
import 'qr_scanner_view.dart';

/// Scanner surface that prefers a dedicated PDA imager and falls back to the
/// existing camera scanner everywhere else.
class AdaptiveBarcodeScannerView extends StatefulWidget {
  final String title;
  final String subtitle;
  final VoidCallback? onManualInput;
  final FutureOr<void> Function(String code) onScan;
  final BarcodeScanner? hardwareScanner;

  const AdaptiveBarcodeScannerView({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onScan,
    this.onManualInput,
    this.hardwareScanner,
  });

  @override
  State<AdaptiveBarcodeScannerView> createState() =>
      _AdaptiveBarcodeScannerViewState();
}

class _AdaptiveBarcodeScannerViewState extends State<AdaptiveBarcodeScannerView>
    with RouteAware {
  late final BarcodeScanner _hardwareScanner;
  final ScanDeduplicator _deduplicator = ScanDeduplicator();

  StreamSubscription<BarcodeScanEvent>? _scanSubscription;
  ModalRoute<dynamic>? _route;
  bool _checkingHardware = true;
  bool _hardwareAvailable = false;
  bool _forceCamera = false;
  bool _isHandlingScan = false;
  bool _isRouteVisible = true;

  @override
  void initState() {
    super.initState();
    _hardwareScanner =
        widget.hardwareScanner ?? const PlatformHardwareBarcodeScanner();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_detectHardwareScanner());
    });
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
  void didPushNext() {
    _isRouteVisible = false;
  }

  @override
  void didPopNext() {
    _isRouteVisible = true;
    _isHandlingScan = false;
    _deduplicator.reset();
  }

  Future<void> _detectHardwareScanner() async {
    final available = await _hardwareScanner.isAvailable();
    if (!mounted) return;

    setState(() {
      _checkingHardware = false;
      _hardwareAvailable = available;
    });

    if (available) _subscribeHardwareScanner();
  }

  void _subscribeHardwareScanner() {
    _scanSubscription?.cancel();
    _scanSubscription = _hardwareScanner.scans.listen(
      (event) => unawaited(_handleHardwareScan(event)),
      onError: (_) {
        if (!mounted) return;
        setState(() => _hardwareAvailable = false);
      },
    );
  }

  Future<void> _handleHardwareScan(BarcodeScanEvent event) async {
    if (!_hardwareAvailable ||
        _forceCamera ||
        !_isRouteVisible ||
        !mounted ||
        _isHandlingScan) {
      return;
    }

    final code = event.rawValue.trim();
    if (!_deduplicator.shouldAccept(code)) return;

    _isHandlingScan = true;
    try {
      await Future<void>.sync(() => widget.onScan(code));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) _isHandlingScan = false;
    }
  }

  Future<void> _useCamera() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    if (!mounted) return;
    setState(() => _forceCamera = true);
  }

  @override
  void dispose() {
    final subscription = _scanSubscription;
    if (subscription != null) unawaited(subscription.cancel());
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingHardware) {
      return const ColoredBox(
        color: CaslaColors.navy900,
        child: Center(
          child: CircularProgressIndicator(color: CaslaColors.accentGold),
        ),
      );
    }

    if (!_hardwareAvailable || _forceCamera) {
      return QrScannerView(
        title: widget.title,
        subtitle: widget.subtitle,
        onManualInput: widget.onManualInput,
        onScan: widget.onScan,
      );
    }

    return ColoredBox(
      color: CaslaColors.navy900,
      child: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 18),
                  const CaslaLogoWhite(size: 68, textColor: Colors.white),
                  const Spacer(),
                  Container(
                    width: 124,
                    height: 124,
                    decoration: BoxDecoration(
                      color: CaslaColors.accentGold.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: CaslaColors.accentGold.withValues(alpha: 0.42),
                      ),
                    ),
                    child: const Icon(
                      Icons.qr_code_scanner_rounded,
                      size: 64,
                      color: CaslaColors.accentGold,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'SẴN SÀNG QUÉT',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Bóp nút trigger bên hông PDA để quét mã.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFB7C1E4),
                      fontSize: 14,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 26),
                  Text(
                    widget.title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF93A0CC),
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                  const Spacer(),
                  if (widget.onManualInput != null)
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: widget.onManualInput,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                        ),
                        icon: const Icon(Icons.keyboard_alt_outlined),
                        label: const Text('Nhập mã thủ công'),
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _useCamera,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Dùng camera'),
                    style: TextButton.styleFrom(
                      foregroundColor: CaslaColors.accentGold,
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
              ),
            ),
          ),
          if (Navigator.canPop(context))
            Positioned(
              top: 12,
              left: 12,
              child: SafeArea(
                child: Material(
                  color: Colors.black38,
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: 'Quay lại',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
