import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/router/app_route_observer.dart';
import '../../app/theme/casla_colors.dart';
import 'casla_logo.dart';

class QrScannerView extends StatefulWidget {
  final String title;
  final String subtitle;
  final String? deviceLabel;
  final VoidCallback? onManualInput;
  final FutureOr<void> Function(String code) onScan;

  const QrScannerView({
    super.key,
    required this.title,
    required this.subtitle,
    this.deviceLabel,
    this.onManualInput,
    required this.onScan,
  });

  @override
  State<QrScannerView> createState() => _QrScannerViewState();
}

class _QrScannerViewState extends State<QrScannerView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  final MobileScannerController controller = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  late AnimationController _animController;
  late Animation<double> _scanAnimation;
  ModalRoute<dynamic>? _route;
  bool _isHandlingScan = false;
  bool _isRouteVisible = true;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);

    _scanAnimation = Tween<double>(begin: 14.0, end: 196.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startCamera());
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
    unawaited(_stopCamera());
  }

  @override
  void didPopNext() {
    _isRouteVisible = true;
    _isHandlingScan = false;
    unawaited(_startCamera());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed || !controller.value.hasCameraPermission) return;

    switch (state) {
      case AppLifecycleState.resumed:
        if (_isRouteVisible) unawaited(_startCamera());
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(_stopCamera());
    }
  }

  Future<void> _startCamera() async {
    if (_isDisposed || !_isRouteVisible || controller.value.isRunning) return;
    try {
      await controller.start();
    } on MobileScannerException {
      // MobileScanner.errorBuilder sẽ hiển thị lỗi camera cho người dùng.
    }
  }

  Future<void> _stopCamera() async {
    if (_isDisposed || !controller.value.isRunning) return;
    try {
      await controller.stop();
    } on MobileScannerException {
      // Camera có thể đã được hệ điều hành thu hồi trong lúc đổi lifecycle.
    }
  }

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_isHandlingScan || !_isRouteVisible || !mounted) return;

    String? code;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && value.isNotEmpty) {
        code = value;
        break;
      }
    }
    if (code == null) return;

    _isHandlingScan = true;
    await _stopCamera();
    try {
      await Future<void>.sync(() => widget.onScan(code!));
    } finally {
      // Tránh cùng một QR bị nhận liên tục khi callback chỉ hiện thông báo lỗi.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted && _isRouteVisible && (_route?.isCurrent ?? true)) {
        _isHandlingScan = false;
        await _startCamera();
      }
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    unawaited(controller.dispose());
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Camera feed
        MobileScanner(
          controller: controller,
          errorBuilder: (context, error) {
            return Container(
              color: CaslaColors.navy900,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(24),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.camera_alt_outlined,
                    color: CaslaColors.accentGold,
                    size: 54,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Camera Máy ảo đang sẵn sàng',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Vui lòng bấm "Nhập thủ công" bên dưới để test nhanh',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: CaslaColors.identityMeta,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            );
          },
          onDetect: _handleDetection,
        ),

        // Transparent overlay container for clear camera view

        // UI Overlay Content
        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 16),
              // Brand Logo Header
              Column(
                children: [
                  const CaslaLogoWhite(size: 68, textColor: Colors.white),
                  const SizedBox(height: 6),
                  const Text(
                    'GHI NHẬN SẢN LƯỢNG',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      letterSpacing: 1.0,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),

              const Spacer(),

              // Viewfinder frame
              Center(
                child: SizedBox(
                  width: 210,
                  height: 210,
                  child: Stack(
                    children: [
                      // Top Left Corner
                      Positioned(
                        top: 0,
                        left: 0,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            border: Border(
                              top: BorderSide(
                                color: CaslaColors.accentGold,
                                width: 4,
                              ),
                              left: BorderSide(
                                color: CaslaColors.accentGold,
                                width: 4,
                              ),
                            ),
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      // Top Right Corner
                      Positioned(
                        top: 0,
                        right: 0,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            border: Border(
                              top: BorderSide(
                                color: CaslaColors.accentGold,
                                width: 4,
                              ),
                              right: BorderSide(
                                color: CaslaColors.accentGold,
                                width: 4,
                              ),
                            ),
                            borderRadius: BorderRadius.only(
                              topRight: Radius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      // Bottom Left Corner
                      Positioned(
                        bottom: 0,
                        left: 0,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: CaslaColors.accentGold,
                                width: 4,
                              ),
                              left: BorderSide(
                                color: CaslaColors.accentGold,
                                width: 4,
                              ),
                            ),
                            borderRadius: BorderRadius.only(
                              bottomLeft: Radius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      // Bottom Right Corner
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: CaslaColors.accentGold,
                                width: 4,
                              ),
                              right: BorderSide(
                                color: CaslaColors.accentGold,
                                width: 4,
                              ),
                            ),
                            borderRadius: BorderRadius.only(
                              bottomRight: Radius.circular(10),
                            ),
                          ),
                        ),
                      ),

                      // Laser Scan Line
                      AnimatedBuilder(
                        animation: _scanAnimation,
                        builder: (context, child) {
                          return Positioned(
                            top: _scanAnimation.value,
                            left: 8,
                            right: 8,
                            child: Container(
                              height: 2,
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.transparent,
                                    CaslaColors.accentGold,
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 26),

              // Title & Subtitle
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF93A0CC),
                    height: 1.5,
                  ),
                ),
              ),

              if (widget.onManualInput != null) ...[
                const SizedBox(height: 20),
                TextButton(
                  onPressed: widget.onManualInput,
                  child: const Text(
                    'Nhập bằng tay',
                    style: TextStyle(
                      color: CaslaColors.accentGold,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],

              const Spacer(),

              // Footer Label
              Text(
                widget.deviceLabel ?? 'THIẾT BỊ · PDA-CT02-A17 · v1.0.0',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9.5,
                  color: Color(0xFF5C6690),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),

        // Floating Back Button (Top Left)
        if (Navigator.canPop(context))
          Positioned(
            top: 12,
            left: 12,
            child: SafeArea(
              child: Material(
                color: Colors.black45,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.pop(context),
                  child: const Padding(
                    padding: EdgeInsets.all(10.0),
                    child: Icon(
                      Icons.arrow_back,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
