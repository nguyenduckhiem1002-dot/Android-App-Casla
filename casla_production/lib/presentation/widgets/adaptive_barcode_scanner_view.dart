import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import '../../core/scanner/barcode_scanner.dart';
import '../../core/scanner/scanner_preferences.dart';
import '../../core/telemetry/field_telemetry.dart';
import 'barcode_scan_listener.dart';
import 'casla_logo.dart';
import 'qr_scanner_view.dart';

/// Full-screen capture surface that prefers a hardware reader and falls back
/// to the camera.
///
/// The reader stays armed in both presentations. Showing the camera does not
/// disarm the wedge, so an operator who pulls the trigger on a handset the app
/// failed to recognise still gets a scan instead of nothing.
class AdaptiveBarcodeScannerView extends StatefulWidget {
  final String title;
  final String subtitle;
  final VoidCallback? onManualInput;

  /// Return false when the payload was rejected, so the operator hears the
  /// failure tone rather than the success tone.
  final FutureOr<bool> Function(String code) onScan;

  final BarcodeScanner? hardwareScanner;
  final ScannerPreferences? preferences;
  final FieldTelemetry? telemetry;

  const AdaptiveBarcodeScannerView({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onScan,
    this.onManualInput,
    this.hardwareScanner,
    this.preferences,
    this.telemetry,
  });

  @override
  State<AdaptiveBarcodeScannerView> createState() =>
      _AdaptiveBarcodeScannerViewState();
}

class _AdaptiveBarcodeScannerViewState
    extends State<AdaptiveBarcodeScannerView> {
  late final ScannerPreferences _preferences;
  ScannerMode _mode = ScannerMode.auto;
  bool _modeLoaded = false;
  bool _forceCamera = false;

  @override
  void initState() {
    super.initState();
    _preferences = widget.preferences ?? DatabaseScannerPreferences();
    unawaited(_loadMode());
  }

  Future<void> _loadMode() async {
    final mode = await _preferences.readMode();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _modeLoaded = true;
    });
  }

  void _useCamera() => setState(() => _forceCamera = true);

  void _useHardware() => setState(() => _forceCamera = false);

  @override
  Widget build(BuildContext context) {
    return BarcodeScanListener(
      onScan: widget.onScan,
      scanner: widget.hardwareScanner,
      preferences: _preferences,
      telemetry: widget.telemetry,
      child: Builder(
        builder: (context) {
          final status = BarcodeScanListener.statusOf(context);
          if (!_modeLoaded ||
              status == null ||
              status.state == HardwareScanState.probing) {
            return const _ScannerProbePanel();
          }

          final showCamera = switch (_mode) {
            ScannerMode.camera => true,
            ScannerMode.hardware => false,
            ScannerMode.auto => _forceCamera || !status.isAvailable,
          };

          if (showCamera) {
            return QrScannerView(
              title: widget.title,
              subtitle: widget.subtitle,
              onManualInput: widget.onManualInput,
              onScan: widget.onScan,
              // Only offered when switching back could actually help.
              onUseHardware: _mode == ScannerMode.auto && _forceCamera
                  ? _useHardware
                  : null,
            );
          }

          return _HardwareReadyPanel(
            title: widget.title,
            subtitle: widget.subtitle,
            status: status,
            onManualInput: widget.onManualInput,
            onUseCamera: _mode == ScannerMode.hardware ? null : _useCamera,
          );
        },
      ),
    );
  }
}

class _ScannerProbePanel extends StatelessWidget {
  const _ScannerProbePanel();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: CaslaColors.navy900,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(CaslaSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.document_scanner_outlined,
                  color: CaslaColors.accentGold,
                  size: 46,
                ),
                SizedBox(height: CaslaSpacing.md),
                LinearProgressIndicator(
                  color: CaslaColors.accentGold,
                  backgroundColor: Colors.white24,
                ),
                SizedBox(height: CaslaSpacing.sm),
                Text(
                  'Đang dò đầu đọc trên máy...',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: CaslaType.body,
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
}

class _HardwareReadyPanel extends StatelessWidget {
  final String title;
  final String subtitle;
  final BarcodeScanStatus status;
  final VoidCallback? onManualInput;
  final VoidCallback? onUseCamera;

  const _HardwareReadyPanel({
    required this.title,
    required this.subtitle,
    required this.status,
    this.onManualInput,
    this.onUseCamera,
  });

  @override
  Widget build(BuildContext context) {
    final busy = status.isBusy;
    final accent = busy ? CaslaColors.successOnDark : CaslaColors.accentGold;

    return ColoredBox(
      color: CaslaColors.navy900,
      child: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: CaslaSpacing.lg),
              child: Column(
                children: [
                  const SizedBox(height: CaslaSpacing.md),
                  const CaslaLogoWhite(size: 64, textColor: Colors.white),
                  const Spacer(),
                  Semantics(
                    liveRegion: true,
                    label: status.message,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 136,
                      height: 136,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(CaslaRadius.lg),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.56),
                          width: 1.5,
                        ),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: Icon(
                          busy
                              ? Icons.check_circle_rounded
                              : Icons.qr_code_scanner_rounded,
                          key: ValueKey(busy),
                          size: 70,
                          color: accent,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: CaslaSpacing.lg),
                  Text(
                    busy ? 'ĐÃ NHẬN MÃ' : 'SẴN SÀNG QUÉT',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: CaslaType.display,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: CaslaSpacing.xs),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    child: Text(
                      status.message,
                      key: ValueKey(status.message),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: CaslaColors.onDarkSecondary,
                        fontSize: CaslaType.body,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: CaslaSpacing.xs),
                  const Text(
                    'Bóp cò trên máy để quét.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: CaslaColors.onDarkSecondary,
                      fontSize: CaslaType.body,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: CaslaSpacing.lg),
                  _ScanTargetCard(
                    title: title,
                    subtitle: subtitle,
                    acceptedCount: status.acceptedCount,
                  ),
                  const Spacer(),
                  if (onManualInput != null)
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : onManualInput,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          disabledForegroundColor: Colors.white38,
                          side: const BorderSide(color: Colors.white70),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(CaslaRadius.md),
                          ),
                        ),
                        icon: const Icon(Icons.keyboard_alt_outlined),
                        label: const Text(
                          'Nhập mã thủ công',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  if (onUseCamera != null) ...[
                    const SizedBox(height: CaslaSpacing.xs),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: TextButton.icon(
                        onPressed: busy ? null : onUseCamera,
                        icon: const Icon(Icons.camera_alt_outlined),
                        label: const Text('Dùng camera thay thế'),
                        style: TextButton.styleFrom(
                          foregroundColor: CaslaColors.accentGold,
                          disabledForegroundColor: Colors.white38,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(CaslaRadius.md),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: CaslaSpacing.sm),
                ],
              ),
            ),
          ),
          if (Navigator.canPop(context))
            const Positioned(top: 12, left: 12, child: _ScannerBackButton()),
        ],
      ),
    );
  }
}

class _ScanTargetCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final int acceptedCount;

  const _ScanTargetCard({
    required this.title,
    required this.subtitle,
    required this.acceptedCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: CaslaSpacing.md,
        vertical: CaslaSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(CaslaRadius.md),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.sensors_rounded,
                size: 16,
                color: CaslaColors.successOnDark,
              ),
              const SizedBox(width: CaslaSpacing.xs),
              Text(
                acceptedCount > 0
                    ? 'Đầu đọc hoạt động · đã quét $acceptedCount mã'
                    : 'Đầu đọc đang hoạt động',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: CaslaType.body,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: CaslaSpacing.sm),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: CaslaType.subtitle,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: CaslaSpacing.xxs),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: CaslaColors.onDarkSecondary,
              fontSize: CaslaType.body,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScannerBackButton extends StatelessWidget {
  const _ScannerBackButton();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Material(
        color: Colors.black38,
        shape: const CircleBorder(),
        child: IconButton(
          tooltip: 'Quay lại',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back, color: Colors.white),
        ),
      ),
    );
  }
}
