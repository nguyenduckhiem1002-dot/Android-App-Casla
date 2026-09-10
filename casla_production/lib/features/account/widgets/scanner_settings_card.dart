import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';
import '../../../core/scanner/platform_hardware_barcode_scanner.dart';
import '../../../core/scanner/scanner_preferences.dart';
import '../../../core/telemetry/field_telemetry.dart';

/// Commissioning controls for the barcode reader.
///
/// This exists because reader support used to be decided by a hardcoded
/// manufacturer check: a handset the app did not recognise had no way to scan
/// and no way for anyone on site to say otherwise. Detection is now a hint,
/// and this is where a technician overrides it — plus the device facts they
/// need when raising a ticket.
class ScannerSettingsCard extends StatefulWidget {
  final ScannerPreferences? preferences;
  final PlatformHardwareBarcodeScanner scanner;
  final FieldTelemetry? telemetry;

  const ScannerSettingsCard({
    super.key,
    this.preferences,
    this.scanner = const PlatformHardwareBarcodeScanner(),
    this.telemetry,
  });

  @override
  State<ScannerSettingsCard> createState() => _ScannerSettingsCardState();
}

class _ScannerSettingsCardState extends State<ScannerSettingsCard> {
  late final ScannerPreferences _preferences;
  ScannerMode _mode = ScannerMode.auto;
  Map<String, Object?> _diagnostics = const {};
  bool _loading = true;

  FieldTelemetry get _telemetry => widget.telemetry ?? FieldTelemetry.instance;

  @override
  void initState() {
    super.initState();
    _preferences = widget.preferences ?? DatabaseScannerPreferences();
    unawaited(_load());
  }

  Future<void> _load() async {
    final mode = await _preferences.readMode();
    final diagnostics = await widget.scanner.diagnostics();
    if (!mounted) return;
    setState(() {
      _mode = mode;
      _diagnostics = diagnostics;
      _loading = false;
    });
  }

  Future<void> _select(ScannerMode mode) async {
    setState(() => _mode = mode);
    await _preferences.writeMode(mode);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Đã đổi chế độ đầu đọc: ${mode.label}. '
            'Mở lại màn hình quét để áp dụng.',
          ),
          backgroundColor: CaslaColors.primaryNavy,
        ),
      );
  }

  Future<void> _copyDiagnostics() async {
    final snapshot = _telemetry.snapshot();
    final lines = <String>[
      'Chế độ đầu đọc: ${_mode.storageValue}',
      'Hãng máy: ${_diagnostics['manufacturer'] ?? 'không rõ'}',
      'Thương hiệu: ${_diagnostics['brand'] ?? 'không rõ'}',
      'Model: ${_diagnostics['model'] ?? 'không rõ'}',
      'Android SDK: ${_diagnostics['androidSdk'] ?? 'không rõ'}',
      'Nhận diện là máy PDA: ${_diagnostics['recognizedVendor'] == true ? 'có' : 'không'}',
      'Dịch vụ đầu đọc đã cài: ${_readerServices().isEmpty ? 'không có' : _readerServices().join(', ')}',
      'Đã nhận (tổng): ${snapshot.count(FieldMetric.hardwareScanAccepted)}',
      'Trong đó qua bàn phím ảo: ${snapshot.count(FieldMetric.wedgeScanAccepted)}',
      'Bị từ chối: ${snapshot.count(FieldMetric.hardwareScanRejected)}',
      'Trùng lặp bỏ qua: ${snapshot.count(FieldMetric.hardwareScanDuplicate)}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(content: Text('Đã sao chép thông tin đầu đọc.')),
      );
  }

  List<String> _readerServices() {
    final raw = _diagnostics['installedReaderServices'];
    if (raw is! List) return const [];
    return raw.map((value) => value.toString()).toList();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _telemetry.snapshot();
    final accepted = snapshot.count(FieldMetric.hardwareScanAccepted);
    final recognized = _diagnostics['recognizedVendor'] == true;
    final services = _readerServices();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(CaslaSpacing.md),
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        border: Border.all(color: CaslaColors.line),
        borderRadius: BorderRadius.circular(CaslaRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.qr_code_scanner_rounded,
                size: 20,
                color: CaslaColors.primaryNavy,
              ),
              const SizedBox(width: CaslaSpacing.xs),
              const Expanded(
                child: Text(
                  'Đầu đọc mã vạch',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: CaslaType.body,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
              ),
              if (!_loading)
                _ReaderStateChip(
                  detected: recognized || services.isNotEmpty || accepted > 0,
                ),
            ],
          ),
          const SizedBox(height: CaslaSpacing.xs),
          const Text(
            'Máy tự dò đầu đọc. Chỉ đổi khi máy có đầu đọc nhưng app chưa nhận ra, '
            'hoặc khi cần dùng camera.',
            style: TextStyle(
              fontSize: CaslaType.caption,
              color: CaslaColors.muted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: CaslaSpacing.sm),

          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: CaslaSpacing.sm),
              child: LinearProgressIndicator(),
            )
          else ...[
            RadioGroup<ScannerMode>(
              groupValue: _mode,
              onChanged: (value) {
                if (value != null) unawaited(_select(value));
              },
              child: Column(
                children: [
                  for (final mode in ScannerMode.values)
                    RadioListTile<ScannerMode>(
                      value: mode,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        mode.label,
                        style: const TextStyle(
                          fontSize: CaslaType.body,
                          fontWeight: FontWeight.w600,
                          color: CaslaColors.primaryNavy,
                        ),
                      ),
                      subtitle: Text(
                        mode.description,
                        style: const TextStyle(
                          fontSize: CaslaType.caption,
                          color: CaslaColors.muted,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: CaslaSpacing.lg),
            _DiagnosticRow(
              label: 'Máy',
              value: [
                _diagnostics['manufacturer'],
                _diagnostics['model'],
              ].whereType<Object>().join(' · '),
            ),
            _DiagnosticRow(
              label: 'Dịch vụ đầu đọc',
              value: services.isEmpty ? 'Không tìm thấy' : services.join(', '),
            ),
            _DiagnosticRow(
              label: 'Đã quét trên máy này',
              value: '$accepted mã',
            ),
            const SizedBox(height: CaslaSpacing.sm),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _copyDiagnostics,
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: const Text('Sao chép thông tin đầu đọc'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReaderStateChip extends StatelessWidget {
  final bool detected;

  const _ReaderStateChip({required this.detected});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: CaslaSpacing.xs,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: detected ? CaslaColors.successBg : CaslaColors.muted100,
        borderRadius: BorderRadius.circular(CaslaRadius.pill),
      ),
      child: Text(
        detected ? 'Đã nhận diện' : 'Chưa thấy',
        style: TextStyle(
          fontSize: CaslaType.caption,
          fontWeight: FontWeight.w700,
          color: detected ? CaslaColors.success : CaslaColors.muted,
        ),
      ),
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  final String label;
  final String value;

  const _DiagnosticRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: CaslaType.caption,
                color: CaslaColors.muted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? 'Không rõ' : value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: CaslaType.caption,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
