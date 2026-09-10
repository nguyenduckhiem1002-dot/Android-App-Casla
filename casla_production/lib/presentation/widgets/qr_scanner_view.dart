import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/router/app_route_observer.dart';
import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import '../../core/config/app_config.dart';
import '../../core/scanner/scan_feedback.dart';
import '../../core/utils/device_info.dart';
import 'casla_logo.dart';

/// Camera fallback for handsets with no imager.
///
/// A hardware reader, when present, stays armed behind this view: the owning
/// [AdaptiveBarcodeScannerView] keeps its listener running, so a trigger pull
/// still registers even while the camera is on screen.
class QrScannerView extends StatefulWidget {
  final String title;
  final String subtitle;
  final String? deviceLabel;
  final VoidCallback? onManualInput;
  final VoidCallback? onUseHardware;

  /// Return false when the payload was rejected, so the camera resumes and the
  /// operator hears the failure tone.
  final FutureOr<bool> Function(String code) onScan;

  const QrScannerView({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onScan,
    this.deviceLabel,
    this.onManualInput,
    this.onUseHardware,
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
    if (MediaQuery.disableAnimationsOf(context)) {
      _animController
        ..stop()
        ..value = 0.5;
    } else if (!_animController.isAnimating) {
      _animController.repeat(reverse: true);
    }

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
    var accepted = false;
    try {
      accepted = await Future<bool>.sync(() => widget.onScan(code!));
    } finally {
      if (accepted) {
        ScanFeedback.success();
      } else {
        ScanFeedback.failure();
        // Only a rejected code needs a pause: without it the camera re-reads
        // the same label immediately and the operator sees the error flash
        // over and over. An accepted code has already navigated away.
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
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
        MobileScanner(
          controller: controller,
          errorBuilder: (context, error) => _CameraErrorPanel(
            permissionDenied: error.toString().toLowerCase().contains(
              'permission',
            ),
            onRetry: _startCamera,
            onManualInput: widget.onManualInput,
          ),
          onDetect: _handleDetection,
        ),

        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: CaslaSpacing.md),
              const CaslaLogoWhite(size: 68, textColor: Colors.white),
              const SizedBox(height: CaslaSpacing.xxs),
              const Text(
                'GHI NHẬN SẢN LƯỢNG',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: CaslaType.caption,
                  letterSpacing: 1.0,
                  color: Colors.white,
                ),
              ),

              const Spacer(),

              Center(child: _Viewfinder(scanLine: _scanAnimation)),

              const SizedBox(height: CaslaSpacing.lg),

              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: CaslaType.subtitle,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: CaslaSpacing.xxs),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CaslaSpacing.xl,
                ),
                child: Text(
                  widget.subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: CaslaType.body,
                    color: CaslaColors.onDarkSecondary,
                    height: 1.5,
                  ),
                ),
              ),

              if (widget.onManualInput != null) ...[
                const SizedBox(height: CaslaSpacing.md),
                TextButton.icon(
                  onPressed: widget.onManualInput,
                  icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                  label: const Text('Nhập bằng tay'),
                  style: TextButton.styleFrom(
                    foregroundColor: CaslaColors.accentGold,
                    textStyle: const TextStyle(
                      fontSize: CaslaType.body,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              if (widget.onUseHardware != null)
                TextButton.icon(
                  onPressed: widget.onUseHardware,
                  icon: const Icon(Icons.sensors_rounded, size: 18),
                  label: const Text('Quay lại đầu đọc'),
                  style: TextButton.styleFrom(
                    foregroundColor: CaslaColors.accentGold,
                    textStyle: const TextStyle(
                      fontSize: CaslaType.body,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),

              const Spacer(),

              Text(
                widget.deviceLabel ??
                    'THIẾT BỊ · ${DeviceInfoHelper.deviceId} · v${AppConfig.appVersion}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: CaslaType.caption,
                  color: CaslaColors.onDarkMuted,
                ),
              ),
              const SizedBox(height: CaslaSpacing.md),
            ],
          ),
        ),

        if (Navigator.canPop(context))
          Positioned(
            top: 12,
            left: 12,
            child: SafeArea(
              child: _CircleAction(
                tooltip: 'Quay lại',
                icon: Icons.arrow_back,
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),

        Positioned(
          top: 12,
          right: 12,
          child: SafeArea(
            child: _CircleAction(
              tooltip: 'Bật hoặc tắt đèn pin',
              icon: Icons.flashlight_on_outlined,
              onPressed: () => unawaited(controller.toggleTorch()),
            ),
          ),
        ),
      ],
    );
  }
}

/// The four gold corner brackets that frame the camera target area.
class _Viewfinder extends StatelessWidget {
  final Animation<double> scanLine;

  const _Viewfinder({required this.scanLine});

  static const double _size = 210;
  static const double _corner = 34;
  static const double _stroke = 4;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        children: [
          for (final (alignment, radius) in const [
            (
              Alignment.topLeft,
              BorderRadius.only(topLeft: Radius.circular(CaslaRadius.sm)),
            ),
            (
              Alignment.topRight,
              BorderRadius.only(topRight: Radius.circular(CaslaRadius.sm)),
            ),
            (
              Alignment.bottomLeft,
              BorderRadius.only(bottomLeft: Radius.circular(CaslaRadius.sm)),
            ),
            (
              Alignment.bottomRight,
              BorderRadius.only(bottomRight: Radius.circular(CaslaRadius.sm)),
            ),
          ])
            Align(
              alignment: alignment,
              child: Container(
                width: _corner,
                height: _corner,
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border(
                    top: alignment.y < 0
                        ? const BorderSide(
                            color: CaslaColors.accentGold,
                            width: _stroke,
                          )
                        : BorderSide.none,
                    bottom: alignment.y > 0
                        ? const BorderSide(
                            color: CaslaColors.accentGold,
                            width: _stroke,
                          )
                        : BorderSide.none,
                    left: alignment.x < 0
                        ? const BorderSide(
                            color: CaslaColors.accentGold,
                            width: _stroke,
                          )
                        : BorderSide.none,
                    right: alignment.x > 0
                        ? const BorderSide(
                            color: CaslaColors.accentGold,
                            width: _stroke,
                          )
                        : BorderSide.none,
                  ),
                ),
              ),
            ),

          // Sweeping line, inside the frame it belongs to.
          AnimatedBuilder(
            animation: scanLine,
            builder: (context, child) => Positioned(
              top: scanLine.value,
              left: 8,
              right: 8,
              child: child!,
            ),
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
          ),
        ],
      ),
    );
  }
}

class _CameraErrorPanel extends StatelessWidget {
  final bool permissionDenied;
  final Future<void> Function() onRetry;
  final VoidCallback? onManualInput;

  const _CameraErrorPanel({
    required this.permissionDenied,
    required this.onRetry,
    this.onManualInput,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: CaslaColors.navy900,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(CaslaSpacing.lg),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.camera_alt_outlined,
            color: CaslaColors.accentGold,
            size: 54,
          ),
          const SizedBox(height: CaslaSpacing.md),
          const Text(
            'Không thể mở camera',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: CaslaType.subtitle,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: CaslaSpacing.xs),
          Text(
            permissionDenied
                ? 'Hãy cấp quyền camera trong cài đặt thiết bị rồi thử lại.'
                : onManualInput == null
                ? 'Camera đang bận hoặc chưa sẵn sàng. Hãy thử mở lại camera.'
                : 'Camera đang bận hoặc chưa sẵn sàng. Bạn có thể thử lại hoặc nhập mã bằng tay.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: CaslaColors.onDarkSecondary,
              fontSize: CaslaType.body,
              height: 1.4,
            ),
          ),
          const SizedBox(height: CaslaSpacing.md),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: CaslaSpacing.xs,
            runSpacing: CaslaSpacing.xs,
            children: [
              OutlinedButton.icon(
                onPressed: onRetry,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                  minimumSize: const Size(0, 48),
                ),
                icon: const Icon(Icons.refresh),
                label: const Text('Thử mở lại'),
              ),
              if (onManualInput != null)
                FilledButton.icon(
                  onPressed: onManualInput,
                  style: FilledButton.styleFrom(
                    backgroundColor: CaslaColors.accentGold,
                    foregroundColor: CaslaColors.navy900,
                    minimumSize: const Size(0, 48),
                  ),
                  icon: const Icon(Icons.keyboard_alt_outlined),
                  label: const Text('Nhập bằng tay'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  const _CircleAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black45,
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}
