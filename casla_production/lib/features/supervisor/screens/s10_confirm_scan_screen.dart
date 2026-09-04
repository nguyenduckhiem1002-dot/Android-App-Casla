// Screen S10 — Scan Worker QR & Confirm Production Screen
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../core/utils/worker_qr_parser.dart';
import '../../../domain/policies/worker_scope_policy.dart';
import '../../../main.dart';
import '../../../presentation/widgets/adaptive_barcode_scanner_view.dart';

class S10ConfirmScanScreen extends ConsumerStatefulWidget {
  const S10ConfirmScanScreen({super.key});

  @override
  ConsumerState<S10ConfirmScanScreen> createState() =>
      _S10ConfirmScanScreenState();
}

class _S10ConfirmScanScreenState extends ConsumerState<S10ConfirmScanScreen> {
  bool _isProcessing = false;
  String? _errorMessage;
  final TextEditingController _manualController = TextEditingController();

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _handleWorkerCodeScanned(String rawCode) async {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final parsed = WorkerQrParser.parse(rawCode);
      if (!parsed.isValid) {
        _showError(parsed.error ?? 'Mã QR công nhân không hợp lệ.');
        return;
      }

      final db = ref.read(appStateProvider).db;
      final worker = await db.getEmployeeByCode(parsed.maNv);
      if (worker == null) {
        _showError('Không tìm thấy công nhân có mã ${parsed.maNv}.');
        return;
      }

      final session = ref.read(appStateProvider).currentSession;
      final workerTeamIds =
          (worker['to_ids'] as List<dynamic>? ?? const <dynamic>[])
              .map((value) => value.toString())
              .toList();
      final scopeMatch = WorkerScopePolicy.evaluate(
        workerTeamIds: workerTeamIds,
        supervisorTeamIds: session?.toIds ?? const <String>[],
      );

      // SAP-derived history cache can know the worker before it knows the
      // worker-to-team mapping. Treat that as unknown instead of rejecting a
      // valid scan. SAP still validates work scope on every write operation.
      if (scopeMatch == WorkerScopeMatch.outOfScope) {
        _showError('Công nhân không thuộc phạm vi tổ bạn được phân quyền.');
        return;
      }

      if (!mounted) return;
      unawaited(HapticFeedback.lightImpact());
      await context.push('/supervisor/employee_detail', extra: worker);
    } catch (_) {
      _showError('Không thể kiểm tra mã công nhân lúc này. Vui lòng thử lại.');
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    unawaited(HapticFeedback.heavyImpact());
    setState(() => _errorMessage = message);
  }

  void _dismissError() {
    if (!mounted || _errorMessage == null) return;
    setState(() => _errorMessage = null);
  }

  void _showManualInputDialog() {
    _manualController.clear();
    final formKey = GlobalKey<FormState>();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
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
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
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
                        fontFamily: 'Manrope',
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
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
                const SizedBox(height: 12),
                TextFormField(
                  controller: _manualController,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    labelText: 'Mã số nhân viên / tài khoản',
                    hintText: 'Nhập chính xác mã nhân viên',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    prefixIcon: const Icon(Icons.badge_outlined),
                  ),
                  validator: (value) => value?.trim().isNotEmpty == true
                      ? null
                      : 'Vui lòng nhập mã công nhân.',
                  onFieldSubmitted: (_) => submit(),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: CaslaColors.primaryNavy,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: submit,
                    child: const Text(
                      'Tìm và mở phân công',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
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
          if (_errorMessage case final message?)
            Positioned(
              top: 92,
              left: 16,
              right: 16,
              child: SafeArea(
                bottom: false,
                child: Semantics(
                  liveRegion: true,
                  label: 'Lỗi quét mã. $message',
                  child: Material(
                    color: CaslaColors.dangerBg,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: CaslaColors.danger,
                            size: 24,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Chưa thể mở công nhân',
                                  style: TextStyle(
                                    color: CaslaColors.danger,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  message,
                                  style: const TextStyle(
                                    color: CaslaColors.primaryNavy,
                                    fontSize: 13,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Đóng thông báo',
                            onPressed: _dismissError,
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
                ),
              ),
            ),
          if (_isProcessing)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: IgnorePointer(
                  child: Center(
                    child: Semantics(
                      liveRegion: true,
                      label: 'Đang kiểm tra mã công nhân',
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 28),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 20,
                        ),
                        decoration: BoxDecoration(
                          color: CaslaColors.navy900,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white12),
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
                            SizedBox(width: 14),
                            Flexible(
                              child: Text(
                                'Đang kiểm tra mã công nhân...',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
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
            ),
        ],
      ),
    );
  }
}
