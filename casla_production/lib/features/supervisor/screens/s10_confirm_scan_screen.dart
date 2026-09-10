// Screen S10 — Scan Worker QR & Confirm Production Screen
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';
import '../../../main.dart';
import '../../../presentation/widgets/adaptive_barcode_scanner_view.dart';
import '../../../presentation/widgets/worker_scan_acceptance.dart';

class S10ConfirmScanScreen extends ConsumerStatefulWidget {
  const S10ConfirmScanScreen({super.key});

  @override
  ConsumerState<S10ConfirmScanScreen> createState() =>
      _S10ConfirmScanScreenState();
}

class _S10ConfirmScanScreenState extends ConsumerState<S10ConfirmScanScreen> {
  final TextEditingController _manualController = TextEditingController();
  bool _isProcessing = false;
  String? _errorMessage;

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  Future<bool> _handleWorkerCodeScanned(String rawCode) async {
    if (_isProcessing) return false;
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final outcome = await acceptScannedWorker(
        context,
        rawCode: rawCode,
        database: ref.read(appStateProvider).db,
      );
      if (!mounted) return false;

      switch (outcome) {
        case WorkerScanAccepted(:final worker):
          await context.push('/supervisor/employee_detail', extra: worker);
          return true;
        case WorkerScanRejected(:final message):
          _showError(message);
          return false;
        case WorkerScanCancelled():
          return false;
      }
    } catch (_) {
      _showError('Không thể kiểm tra mã công nhân lúc này. Vui lòng thử lại.');
      return false;
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _errorMessage = message);
  }

  void _dismissError() {
    if (!mounted || _errorMessage == null) return;
    setState(() => _errorMessage = null);
  }

  void _showManualInputDialog() {
    _manualController.clear();
    final formKey = GlobalKey<FormState>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaslaColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaslaRadius.lg),
        ),
      ),
      builder: (sheetContext) {
        void submit() {
          if (formKey.currentState?.validate() != true) return;
          final text = _manualController.text.trim();
          Navigator.pop(sheetContext);
          _handleWorkerCodeScanned(text);
        }

        return Padding(
          padding: EdgeInsets.only(
            left: CaslaSpacing.lg,
            right: CaslaSpacing.lg,
            top: CaslaSpacing.lg,
            bottom:
                MediaQuery.viewInsetsOf(sheetContext).bottom + CaslaSpacing.lg,
          ),
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Nhập mã công nhân',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: CaslaType.subtitle,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Đóng',
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ],
                ),
                const SizedBox(height: CaslaSpacing.sm),
                TextFormField(
                  controller: _manualController,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    labelText: 'Mã số nhân viên / tài khoản',
                    hintText: 'Nhập chính xác mã nhân viên',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  validator: (value) => value?.trim().isNotEmpty == true
                      ? null
                      : 'Vui lòng nhập mã công nhân.',
                  onFieldSubmitted: (_) => submit(),
                ),
                const SizedBox(height: CaslaSpacing.md),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: CaslaColors.primaryNavy,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: submit,
                    child: const Text('Tìm và mở phân công'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          AdaptiveBarcodeScannerView(
            title: 'Xác nhận công nhân',
            subtitle:
                'Quét thẻ hoặc mã QR công nhân để xem chi tiết và xác nhận.',
            onScan: _handleWorkerCodeScanned,
            onManualInput: _showManualInputDialog,
          ),

          // Sits below the safe area and the back button rather than at a
          // fixed offset, so a small screen or an enlarged font size cannot
          // push it on top of them.
          if (_errorMessage case final message?)
            Positioned(
              left: CaslaSpacing.md,
              right: CaslaSpacing.md,
              top: MediaQuery.paddingOf(context).top + 64,
              child: _ScanErrorCard(message: message, onDismiss: _dismissError),
            ),

          if (_isProcessing) const _ProcessingOverlay(),
        ],
      ),
    );
  }
}

class _ScanErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _ScanErrorCard({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Lỗi quét mã. $message',
      child: Material(
        color: CaslaColors.dangerBg,
        elevation: 6,
        borderRadius: BorderRadius.circular(CaslaRadius.md),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            CaslaSpacing.sm,
            CaslaSpacing.sm,
            CaslaSpacing.xxs,
            CaslaSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: CaslaColors.danger,
                size: 24,
              ),
              const SizedBox(width: CaslaSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Chưa thể mở công nhân',
                      style: TextStyle(
                        color: CaslaColors.danger,
                        fontWeight: FontWeight.w800,
                        fontSize: CaslaType.body,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      message,
                      style: const TextStyle(
                        color: CaslaColors.primaryNavy,
                        fontSize: CaslaType.caption,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Đóng thông báo',
                onPressed: onDismiss,
                icon: const Icon(
                  Icons.close,
                  size: 20,
                  color: CaslaColors.primaryNavy,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProcessingOverlay extends StatelessWidget {
  const _ProcessingOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: IgnorePointer(
          child: Center(
            child: Semantics(
              liveRegion: true,
              label: 'Đang kiểm tra mã công nhân',
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: CaslaSpacing.xl),
                padding: const EdgeInsets.symmetric(
                  horizontal: CaslaSpacing.lg,
                  vertical: CaslaSpacing.lg,
                ),
                decoration: BoxDecoration(
                  color: CaslaColors.navy900,
                  borderRadius: BorderRadius.circular(CaslaRadius.lg),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.6,
                        color: CaslaColors.accentGold,
                      ),
                    ),
                    SizedBox(width: CaslaSpacing.sm),
                    Flexible(
                      child: Text(
                        'Đang kiểm tra mã công nhân...',
                        style: TextStyle(
                          color: Colors.white,
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
      ),
    );
  }
}
