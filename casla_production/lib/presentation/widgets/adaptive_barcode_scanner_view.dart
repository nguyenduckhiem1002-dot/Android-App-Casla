import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import '../../core/scanner/barcode_scanner.dart';
import '../../core/scanner/scan_diagnostics.dart';
import '../../core/scanner/scanner_preferences.dart';
import '../../core/telemetry/field_telemetry.dart';
import 'barcode_scan_listener.dart';

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
  final String manualInputLabel;
  final IconData manualInputIcon;

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
    this.manualInputLabel = 'Nhập mã thủ công',
    this.manualInputIcon = Icons.keyboard_alt_outlined,
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
  bool _scanInFlight = false;
  String? _lastAcceptedCode;
  bool? _lastFromCamera;
  DateTime? _lastAcceptedAt;

  Future<bool> _handleScan(String rawCode, {required bool fromCamera}) async {
    if (!mounted || _scanInFlight) return false;
    final code = rawCode.trim();
    if (code.isEmpty) return false;
    final now = DateTime.now();
    if (_lastAcceptedCode == code &&
        _lastFromCamera != fromCamera &&
        _lastAcceptedAt != null &&
        now.difference(_lastAcceptedAt!) < const Duration(milliseconds: 400)) {
      return false;
    }
    _scanInFlight = true;
    try {
      final accepted = await Future<bool>.sync(() => widget.onScan(code));
      if (accepted) {
        _lastAcceptedCode = code;
        _lastFromCamera = fromCamera;
        _lastAcceptedAt = DateTime.now();
      }
      return accepted;
    } catch (_) {
      ScanDiagnostics.instance.record(ScanDiagnosticEvent.callbackError);
      return false;
    } finally {
      _scanInFlight = false;
    }
  }

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
      onScan: (code) => _handleScan(code, fromCamera: false),
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
              manualInputLabel: widget.manualInputLabel,
              manualInputIcon: widget.manualInputIcon,
              onScan: (code) => _handleScan(code, fromCamera: true),
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
            manualInputLabel: widget.manualInputLabel,
            manualInputIcon: widget.manualInputIcon,
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
      color: CaslaColors.background,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(CaslaSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.document_scanner_outlined,
                  color: CaslaColors.primaryNavy,
                  size: 46,
                ),
                SizedBox(height: CaslaSpacing.md),
                LinearProgressIndicator(
                  color: CaslaColors.primaryNavy,
                  backgroundColor: CaslaColors.line,
                ),
                SizedBox(height: CaslaSpacing.sm),
                Text(
                  'Đang dò đầu đọc trên máy...',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: CaslaColors.primaryNavy,
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
  final String manualInputLabel;
  final IconData manualInputIcon;
  final VoidCallback? onUseCamera;

  const _HardwareReadyPanel({
    required this.title,
    required this.subtitle,
    required this.status,
    this.onManualInput,
    this.manualInputLabel = 'Nhập mã thủ công',
    this.manualInputIcon = Icons.keyboard_alt_outlined,
    this.onUseCamera,
  });

  @override
  Widget build(BuildContext context) {
    final busy = status.isBusy;
    final available = status.isAvailable;
    final showFeedback =
        !busy &&
        status.message.isNotEmpty &&
        status.message != 'Sẵn sàng nhận mã từ đầu đọc';

    return ColoredBox(
      color: CaslaColors.background,
      child: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(CaslaSpacing.lg),
              sliver: SliverFillRemaining(
                hasScrollBody: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        if (Navigator.canPop(context)) ...[
                          IconButton.filledTonal(
                            tooltip: 'Quay lại',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.arrow_back),
                            style: IconButton.styleFrom(
                              backgroundColor: CaslaColors.surface,
                              foregroundColor: CaslaColors.primaryNavy,
                            ),
                          ),
                          const SizedBox(width: CaslaSpacing.sm),
                        ],
                        Icon(
                          Icons.sensors_rounded,
                          size: 20,
                          color: available
                              ? CaslaColors.success
                              : CaslaColors.muted,
                        ),
                        const SizedBox(width: CaslaSpacing.xs),
                        Expanded(
                          child: Text(
                            available
                                ? 'Đầu đọc đang hoạt động'
                                : 'Đầu đọc chưa kết nối',
                            style: const TextStyle(
                              fontSize: CaslaType.caption,
                              fontWeight: FontWeight.w600,
                              color: CaslaColors.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: CaslaSpacing.lg),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: CaslaType.display,
                        height: 1.15,
                        letterSpacing: -0.6,
                        fontWeight: FontWeight.w800,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                    const SizedBox(height: CaslaSpacing.xs),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: CaslaType.body,
                        height: 1.4,
                        color: CaslaColors.muted,
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(height: CaslaSpacing.lg),
                    Center(
                      child: Container(
                        width: 112,
                        height: 112,
                        decoration: BoxDecoration(
                          color: CaslaColors.primaryNavy,
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: busy
                            ? const Center(
                                child: SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: CaslaColors.accentGold,
                                  ),
                                ),
                              )
                            : Icon(
                                available
                                    ? Icons.qr_code_scanner_rounded
                                    : Icons.sensors_off_rounded,
                                size: 56,
                                color: CaslaColors.accentGold,
                              ),
                      ),
                    ),
                    const SizedBox(height: CaslaSpacing.md),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        busy
                            ? 'Đang xử lý mã'
                            : available
                            ? 'Sẵn sàng quét'
                            : 'Chưa kết nối',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: CaslaType.subtitle,
                          fontWeight: FontWeight.w700,
                          color: CaslaColors.primaryNavy,
                        ),
                      ),
                    ),
                    if (showFeedback) ...[
                      const SizedBox(height: CaslaSpacing.xs),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          status.message,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: CaslaType.body,
                            height: 1.4,
                            color: CaslaColors.muted,
                          ),
                        ),
                      ),
                    ],
                    if (status.acceptedCount > 0) ...[
                      const SizedBox(height: CaslaSpacing.xs),
                      Text(
                        'Đã quét ${status.acceptedCount} mã',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: CaslaType.caption,
                          color: CaslaColors.muted,
                        ),
                      ),
                    ],
                    const SizedBox(height: CaslaSpacing.lg),
                    const Spacer(),
                    if (onUseCamera != null)
                      FilledButton.icon(
                        onPressed: busy ? null : onUseCamera,
                        icon: const Icon(Icons.photo_camera_outlined, size: 22),
                        label: const Text('Dùng camera thay thế'),
                        style: FilledButton.styleFrom(
                          textStyle: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                          minimumSize: const Size(0, 52),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          backgroundColor: CaslaColors.primaryNavy,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(CaslaRadius.md),
                          ),
                        ),
                      ),
                    if (onManualInput != null) ...[
                      if (onUseCamera != null)
                        const SizedBox(height: CaslaSpacing.xs),
                      OutlinedButton.icon(
                        onPressed: busy ? null : onManualInput,
                        icon: Icon(manualInputIcon, size: 22),
                        label: Text(manualInputLabel),
                        style: OutlinedButton.styleFrom(
                          textStyle: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                          minimumSize: const Size(0, 52),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          foregroundColor: CaslaColors.primaryNavy,
                          side: const BorderSide(color: CaslaColors.line),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(CaslaRadius.md),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
