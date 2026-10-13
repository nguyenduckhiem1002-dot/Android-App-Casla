import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/router/app_route_observer.dart';
import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import '../../core/scanner/scan_feedback.dart';
import '../../core/scanner/scan_payload_logger.dart';

/// Camera fallback for handsets with no imager.
///
/// A hardware reader, when present, stays armed behind this view: the owning
/// [AdaptiveBarcodeScannerView] keeps its listener running, so a trigger pull
/// still registers even while the camera is on screen.
///
/// When a QR is found the brackets snap onto that code and everything around
/// it blurs, so the operator sees which label was taken. The decoded text is
/// never shown.
class QrScannerView extends StatefulWidget {
  final String title;
  final String subtitle;
  final String? deviceLabel;
  final VoidCallback? onManualInput;
  final String manualInputLabel;
  final IconData manualInputIcon;
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
    this.manualInputLabel = 'Nhập bằng tay',
    this.manualInputIcon = Icons.keyboard_alt_outlined,
    this.onUseHardware,
  });

  @override
  State<QrScannerView> createState() => _QrScannerViewState();
}

class _QrScannerViewState extends State<QrScannerView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  final MobileScannerController controller = MobileScannerController(
    autoStart: false,
    // Frames keep flowing while a code is handled so the preview never
    // freezes; repeats are dropped by [_isHandlingScan] instead.
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 120,
    facing: CameraFacing.back,
    // Operation labels carry a dense JSON QR; 720p often misses its modules
    // from a comfortable reading distance.
    cameraResolution: const Size(1920, 1080),
    autoZoom: true,
    formats: const [BarcodeFormat.qrCode],
    torchEnabled: false,
  );

  /// How long the brackets rest on the code before it is handed over, so the
  /// operator sees which label was taken.
  static const Duration _lockDwell = Duration(milliseconds: 160);
  static const Duration _snap = Duration(milliseconds: 180);

  late AnimationController _breath;
  ModalRoute<dynamic>? _route;
  bool _isHandlingScan = false;
  bool _isRouteVisible = true;
  bool _isDisposed = false;
  bool _appActive = true;
  Future<void> _cameraTask = Future<void>.value();

  /// Size of the preview box the overlay paints into.
  Size _viewSize = Size.zero;

  /// Screen rectangle of the code being read; null while aiming.
  Rect? _lockRect;
  bool _lockRejected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startCamera());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _breath
        ..stop()
        ..value = 1;
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
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
    unawaited(_startCamera());
  }

  @override
  void didPop() {
    _isRouteVisible = false;
    unawaited(_stopCamera());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;
    _appActive = state == AppLifecycleState.resumed;

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

  Future<void> _startCamera() => _cameraTask = _cameraTask.then((_) async {
    if (_isDisposed ||
        !_isRouteVisible ||
        !_appActive ||
        !(_route?.isCurrent ?? true) ||
        controller.value.isRunning) {
      return;
    }
    try {
      await controller.start();
    } on MobileScannerException {
      // The controller error is rendered by the camera error panel.
    }
  });

  Future<void> _stopCamera() => _cameraTask = _cameraTask.then((_) async {
    if (_isDisposed || !controller.value.isRunning) return;
    try {
      await controller.stop();
    } on MobileScannerException {
      // Camera có thể đã được hệ điều hành thu hồi trong lúc đổi lifecycle.
    }
  });

  /// The guide frame shown while aiming, centred a little above the middle.
  Rect _guideRect(Size size) {
    final side = (size.width * 0.68)
        .clamp(160.0, 300.0)
        .clamp(0.0, size.height * 0.42)
        .toDouble();
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.42),
      width: side,
      height: side,
    );
  }

  /// Maps a code's corners from camera-image space onto the preview, which
  /// [MobileScanner] paints with [BoxFit.cover] — the same math as the
  /// package's own BarcodePainter.
  Rect? _screenRectOf(Barcode barcode, Size imageSize) {
    if (barcode.corners.length < 4 || imageSize.isEmpty || _viewSize.isEmpty) {
      return null;
    }
    final orientation = controller.value.deviceOrientation;
    final landscape =
        orientation == DeviceOrientation.landscapeLeft ||
        orientation == DeviceOrientation.landscapeRight;
    final preview = landscape ? imageSize.flipped : imageSize;
    final ratios = ScanWindowUtils.calculateBoxFitRatio(
      boxFit: BoxFit.cover,
      cameraPreviewSize: preview,
      size: _viewSize,
    );
    final padX = (preview.width * ratios.widthRatio - _viewSize.width) / 2;
    final padY = (preview.height * ratios.heightRatio - _viewSize.height) / 2;
    Rect? bounds;
    for (final corner in barcode.corners) {
      final point = Offset(
        corner.dx * ratios.widthRatio - padX,
        corner.dy * ratios.heightRatio - padY,
      );
      final dot = Rect.fromPoints(point, point);
      bounds = bounds == null ? dot : bounds.expandToInclude(dot);
    }
    if (bounds == null || bounds.width < 8 || bounds.height < 8) return null;
    // Square it up and leave the brackets a little breathing room.
    final side = math.max(bounds.width, bounds.height) + 20;
    return Rect.fromCenter(center: bounds.center, width: side, height: side);
  }

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_isHandlingScan || !_isRouteVisible || !mounted) return;

    // Several labels may be in view: take the one nearest the guide frame,
    // which is where the operator is aiming.
    final aim = _guideRect(_viewSize).center;
    String? code;
    Rect? rect;
    var best = double.infinity;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;
      final onScreen = _screenRectOf(barcode, capture.size);
      final distance = onScreen == null
          ? double.maxFinite
          : (onScreen.center - aim).distanceSquared;
      if (code == null || distance < best) {
        code = value;
        rect = onScreen;
        best = distance;
      }
    }
    if (code == null) return;

    logScanPayload(code, source: 'camera');
    _isHandlingScan = true;
    setState(() {
      _lockRect = rect ?? _guideRect(_viewSize);
      _lockRejected = false;
    });
    var accepted = false;
    try {
      await Future<void>.delayed(_lockDwell);
      if (!mounted) return;
      accepted = await Future<bool>.sync(() => widget.onScan(code!));
    } finally {
      if (accepted) {
        ScanFeedback.success();
      } else {
        ScanFeedback.failure();
        if (mounted) setState(() => _lockRejected = true);
        // Only a rejected code needs a pause: without it the camera re-reads
        // the same label immediately and the operator sees the error flash
        // over and over. An accepted code has already navigated away.
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      if (mounted) {
        setState(() {
          _lockRect = null;
          _lockRejected = false;
        });
      }
      _isHandlingScan = false;
      if (mounted && _isRouteVisible && (_route?.isCurrent ?? true)) {
        await _startCamera();
      }
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    unawaited(_cameraTask.whenComplete(controller.dispose));
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _snap;
    return Stack(
      fit: StackFit.expand,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            _viewSize = constraints.biggest;
            final guide = _guideRect(_viewSize);
            final locked = _lockRect != null;
            return Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: controller,
                  // Render errors in the overlay below, including startup
                  // failures before the platform reports preview ready.
                  errorBuilder: (_, _) => const SizedBox.shrink(),
                  onDetect: _handleDetection,
                ),
                IgnorePointer(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: locked ? 1 : 0),
                    duration: snap,
                    curve: Curves.easeOutCubic,
                    builder: (context, focus, _) =>
                        TweenAnimationBuilder<Rect?>(
                          tween: RectTween(end: _lockRect ?? guide),
                          duration: snap,
                          curve: Curves.easeOutCubic,
                          builder: (context, rect, _) {
                            final hole = rect ?? guide;
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                _FocusScrim(hole: hole, focus: focus),
                                Positioned.fromRect(
                                  rect: hole,
                                  child: AnimatedBuilder(
                                    animation: _breath,
                                    builder: (context, child) =>
                                        Transform.scale(
                                          // Breathe only while aiming.
                                          scale: locked
                                              ? 1
                                              : 0.97 + 0.03 * _breath.value,
                                          child: child,
                                        ),
                                    child: _Brackets(
                                      color: _lockRejected
                                          ? CaslaColors.danger
                                          : CaslaColors.accentGold,
                                      stroke: locked ? 5 : 4,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                  ),
                ),
                Positioned(
                  left: CaslaSpacing.lg,
                  right: CaslaSpacing.lg,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    minimum: const EdgeInsets.only(bottom: CaslaSpacing.lg),
                    child: ValueListenableBuilder<MobileScannerState>(
                      // The error panel replaces this; leaving it underneath
                      // keeps a second, hidden manual action reachable.
                      valueListenable: controller,
                      builder: (context, state, child) => state.error != null
                          ? const SizedBox.shrink()
                          : child!,
                      child: AnimatedOpacity(
                        opacity: locked ? 0.35 : 1,
                        duration: snap,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.title,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: CaslaType.subtitle,
                                color: Colors.white,
                                shadows: [
                                  Shadow(color: Colors.black54, blurRadius: 8),
                                ],
                              ),
                            ),
                            if (widget.onManualInput != null) ...[
                              const SizedBox(height: CaslaSpacing.xs),
                              TextButton.icon(
                                onPressed: widget.onManualInput,
                                icon: Icon(widget.manualInputIcon, size: 18),
                                label: Text(widget.manualInputLabel),
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
                                icon: const Icon(
                                  Icons.sensors_rounded,
                                  size: 18,
                                ),
                                label: const Text('Quay lại đầu đọc'),
                                style: TextButton.styleFrom(
                                  foregroundColor: CaslaColors.accentGold,
                                  textStyle: const TextStyle(
                                    fontSize: CaslaType.body,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),

        ValueListenableBuilder<MobileScannerState>(
          valueListenable: controller,
          builder: (context, state, child) => state.error != null
              ? _CameraErrorPanel(
                  permissionDenied:
                      state.error!.errorCode ==
                      MobileScannerErrorCode.permissionDenied,
                  onRetry: _startCamera,
                  onManualInput: widget.onManualInput,
                  manualInputLabel: widget.manualInputLabel,
                  manualInputIcon: widget.manualInputIcon,
                )
              : child!,
          child: const SizedBox.expand(),
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
              onPressed: () {
                if (controller.value.isRunning) {
                  unawaited(controller.toggleTorch());
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Darkens the preview outside [hole]; as [focus] rises towards 1 it also
/// blurs it, so the code being read is the only sharp thing on screen.
class _FocusScrim extends StatelessWidget {
  const _FocusScrim({required this.hole, required this.focus});

  final Rect hole;
  final double focus;

  @override
  Widget build(BuildContext context) {
    final dim = ColoredBox(
      color: Colors.black.withValues(alpha: 0.45 + 0.2 * focus),
    );
    return ClipPath(
      clipper: _OutsideClipper(hole),
      // Blur only while locked: a permanent blur costs GPU on every frame and
      // makes aiming harder.
      child: focus <= 0.01
          ? dim
          : BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8 * focus, sigmaY: 8 * focus),
              child: dim,
            ),
    );
  }
}

class _OutsideClipper extends CustomClipper<Path> {
  const _OutsideClipper(this.hole);

  final Rect hole;

  @override
  Path getClip(Size size) => Path.combine(
    PathOperation.difference,
    Path()..addRect(Offset.zero & size),
    Path()..addRRect(
      RRect.fromRectAndRadius(hole, const Radius.circular(CaslaRadius.md)),
    ),
  );

  @override
  bool shouldReclip(_OutsideClipper oldClipper) => hole != oldClipper.hole;
}

/// Four rounded corner brackets filling their box, so they can follow the
/// target as it moves and resizes.
class _Brackets extends StatelessWidget {
  const _Brackets({required this.color, required this.stroke});

  final Color color;
  final double stroke;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _BracketsPainter(color: color, stroke: stroke),
  );
}

class _BracketsPainter extends CustomPainter {
  const _BracketsPainter({required this.color, required this.stroke});

  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final arm = math.min(36.0, size.shortestSide * 0.26);
    const radius = 10.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final w = size.width;
    final h = size.height;

    // From the end of one arm, round the corner [b], out along the other arm.
    Path corner(Offset a, Offset b, Offset c) {
      Offset toward(Offset from, Offset to) =>
          from +
          Offset((to.dx - from.dx).sign, (to.dy - from.dy).sign) * radius;
      final start = toward(b, a);
      final end = toward(b, c);
      return Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(start.dx, start.dy)
        ..quadraticBezierTo(b.dx, b.dy, end.dx, end.dy)
        ..lineTo(c.dx, c.dy);
    }

    for (final path in [
      corner(Offset(0, arm), Offset.zero, Offset(arm, 0)),
      corner(Offset(w - arm, 0), Offset(w, 0), Offset(w, arm)),
      corner(Offset(w, h - arm), Offset(w, h), Offset(w - arm, h)),
      corner(Offset(arm, h), Offset(0, h), Offset(0, h - arm)),
    ]) {
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_BracketsPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.stroke != stroke;
}

class _CameraErrorPanel extends StatelessWidget {
  final bool permissionDenied;
  final Future<void> Function() onRetry;
  final VoidCallback? onManualInput;
  final String manualInputLabel;
  final IconData manualInputIcon;

  const _CameraErrorPanel({
    required this.permissionDenied,
    required this.onRetry,
    this.onManualInput,
    this.manualInputLabel = 'Nhập bằng tay',
    this.manualInputIcon = Icons.keyboard_alt_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: CaslaColors.navy900,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 80, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
                  : 'Camera đang bận hoặc chưa sẵn sàng. Bạn có thể thử lại hoặc ${manualInputLabel.toLowerCase()}.',
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
                    icon: Icon(manualInputIcon),
                    label: Text(manualInputLabel),
                  ),
              ],
            ),
          ],
        ),
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
