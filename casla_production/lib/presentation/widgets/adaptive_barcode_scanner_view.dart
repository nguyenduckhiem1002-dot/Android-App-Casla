import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  String _hardwareStatus = 'Sẵn sàng nhận mã từ đầu đọc tích hợp';

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
    if (mounted) {
      setState(() => _hardwareStatus = 'Sẵn sàng nhận mã từ đầu đọc tích hợp');
    }
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
    if (code.isEmpty || !_deduplicator.shouldAccept(code)) return;

    _isHandlingScan = true;
    setState(() => _hardwareStatus = 'Đã nhận mã • đang kiểm tra dữ liệu');
    unawaited(HapticFeedback.mediumImpact());

    try {
      await Future<void>.sync(() => widget.onScan(code));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) {
        setState(() {
          _isHandlingScan = false;
          _hardwareStatus = 'Sẵn sàng cho lượt quét tiếp theo';
        });
      }
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
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.document_scanner_outlined,
                    color: CaslaColors.accentGold,
                    size: 46,
                  ),
                  SizedBox(height: 16),
                  LinearProgressIndicator(
                    color: CaslaColors.accentGold,
                    backgroundColor: Colors.white12,
                  ),
                  SizedBox(height: 14),
                  Text(
                    'Đang kiểm tra đầu đọc PDA...',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
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
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Column(
                children: [
                  const SizedBox(height: 18),
                  const CaslaLogoWhite(size: 64, textColor: Colors.white),
                  const Spacer(),
                  Semantics(
                    liveRegion: true,
                    label: _hardwareStatus,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 136,
                      height: 136,
                      decoration: BoxDecoration(
                        color:
                            (_isHandlingScan
                                    ? CaslaColors.success
                                    : CaslaColors.accentGold)
                                .withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color:
                              (_isHandlingScan
                                      ? CaslaColors.success
                                      : CaslaColors.accentGold)
                                  .withValues(alpha: 0.56),
                          width: 1.5,
                        ),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: Icon(
                          _isHandlingScan
                              ? Icons.check_circle_rounded
                              : Icons.qr_code_scanner_rounded,
                          key: ValueKey(_isHandlingScan),
                          size: 70,
                          color: _isHandlingScan
                              ? const Color(0xFF65C56B)
                              : CaslaColors.accentGold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _isHandlingScan ? 'ĐÃ NHẬN MÃ' : 'SẴN SÀNG QUÉT',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    child: Text(
                      _hardwareStatus,
                      key: ValueKey(_hardwareStatus),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFB7C1E4),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Bóp nút trigger bên hông RS38 để quét.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF93A0CC),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Color(0xFF65C56B),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'Đầu đọc PDA đang hoạt động',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          widget.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.subtitle,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFB7C1E4),
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (widget.onManualInput != null)
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: _isHandlingScan
                            ? null
                            : widget.onManualInput,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          disabledForegroundColor: Colors.white38,
                          side: const BorderSide(color: Colors.white54),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.keyboard_alt_outlined),
                        label: const Text(
                          'Nhập mã thủ công',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: TextButton.icon(
                      onPressed: _isHandlingScan ? null : _useCamera,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Dùng camera thay thế'),
                      style: TextButton.styleFrom(
                        foregroundColor: CaslaColors.accentGold,
                        disabledForegroundColor: Colors.white38,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
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
