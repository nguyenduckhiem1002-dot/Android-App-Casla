import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';
import '../../../core/scanner/barcode_scanner.dart';
import '../../../core/scanner/scan_intent.dart';
import '../../../core/scanner/scanner_preferences.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../core/utils/operation_qr_parser.dart';
import '../../../domain/policies/work_context_resolver.dart';
import '../../../main.dart';
import '../../../presentation/widgets/active_shift_context_card.dart';
import '../../../presentation/widgets/adaptive_barcode_scanner_view.dart';
import '../../../presentation/widgets/barcode_scan_listener.dart';
import '../../../presentation/widgets/mutation_feedback.dart';
import '../../../presentation/widgets/scan_status_strip.dart';
import '../../../presentation/widgets/searchable_picker_sheet.dart';
import '../../../presentation/widgets/worker_scan_acceptance.dart';
import '../../../presentation/widgets/worker_verification_dialog.dart';

/// Assignment entry, built around the trigger rather than the touchscreen.
///
/// The reader stays armed on this form. Scanning an operation label fills the
/// product field, scanning a worker card fills the worker field, and the two
/// can arrive in either order because the payload itself says which is which.
/// The full-screen scanner routes are still reachable from each field, but they
/// are the camera fallback now, not the main path.
class S07CreateAssignmentWizardScreen extends ConsumerStatefulWidget {
  /// Test seams, mirroring [AdaptiveBarcodeScannerView]. Production always
  /// leaves these null so the listener builds the real broadcast + wedge pair.
  @visibleForTesting
  final BarcodeScanner? scanner;

  @visibleForTesting
  final ScannerPreferences? scannerPreferences;

  const S07CreateAssignmentWizardScreen({
    super.key,
    this.scanner,
    this.scannerPreferences,
  });

  @override
  ConsumerState<S07CreateAssignmentWizardScreen> createState() =>
      _S07CreateAssignmentWizardScreenState();
}

class _S07CreateAssignmentWizardScreenState
    extends ConsumerState<S07CreateAssignmentWizardScreen> {
  final GlobalKey<BarcodeScanListenerState> _scanListenerKey =
      GlobalKey<BarcodeScanListenerState>();
  final TextEditingController _qtyController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();
  final FocusNode _qtyFocus = FocusNode();

  Map<String, dynamic>? _selectedWorker;
  Map<String, dynamic>? _selectedOrder;
  bool _isSubmitting = false;
  bool _isDialogOpen = false;
  String? _quantityError;
  String? _scanError;
  bool _keepProductAfterSubmit = true;

  String get _selectedUom => _selectedOrder?['uom']?.toString().trim() ?? '';

  @override
  void dispose() {
    _qtyController.dispose();
    _noteController.dispose();
    _qtyFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- scanning

  /// Routes one scanned payload to whichever field it belongs in.
  ///
  /// Returns false for anything rejected so the listener plays the failure
  /// tone: on a shop floor the operator is looking at the pallet, not at this
  /// screen, and needs to hear that nothing was captured.
  Future<bool> _handleScan(String code) async {
    final scanned = ScanClassifier.classify(code);

    return switch (scanned.kind) {
      ScannedCodeKind.operation => _applyOperationScan(scanned.operation!),
      ScannedCodeKind.worker => _applyWorkerScan(code),
      ScannedCodeKind.unknown => _rejectScan(scanned.error),
    };
  }

  bool _rejectScan(String message) {
    if (mounted) setState(() => _scanError = message);
    return false;
  }

  Future<bool> _applyOperationScan(OperationQrResult operationQr) async {
    final order = await ref
        .read(appStateProvider)
        .db
        .upsertOrderFromOperationQr(operationQr);
    if (!mounted) return false;
    if (order == null) {
      return _rejectScan('Không lưu được công đoạn từ mã QR vừa quét.');
    }

    setState(() {
      _selectedOrder = order;
      _scanError = null;
    });
    return true;
  }

  Future<bool> _applyWorkerScan(String code) async {
    _isDialogOpen = true;
    try {
      final outcome = await acceptScannedWorker(
        context,
        rawCode: code,
        database: ref.read(appStateProvider).db,
      );
      if (!mounted) return false;

      switch (outcome) {
        case WorkerScanAccepted(:final worker):
          setState(() {
            _selectedWorker = worker;
            _scanError = null;
          });
          return true;
        case WorkerScanRejected(:final message):
          return _rejectScan(message);
        case WorkerScanCancelled():
          // The operator said no. Re-arm so the correct card can be scanned
          // straight away rather than being swallowed as a duplicate.
          _scanListenerKey.currentState?.resetDeduplication();
          return false;
      }
    } finally {
      _isDialogOpen = false;
    }
  }

  // --------------------------------------------------------- manual fallback

  Future<void> _openScannerRoute({
    required String title,
    required String subtitle,
    required VoidCallback onManualInput,
  }) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (routeContext) => Scaffold(
          body: AdaptiveBarcodeScannerView(
            title: title,
            subtitle: subtitle,
            onManualInput: onManualInput,
            onScan: (code) async {
              final accepted = await _handleScan(code);
              if (accepted && routeContext.mounted) {
                Navigator.pop(routeContext);
              }
              return accepted;
            },
          ),
        ),
      ),
    );
    _scanListenerKey.currentState?.resetDeduplication();
  }

  Future<void> _pickWorker({bool closeScannerRoute = false}) async {
    final appState = ref.read(appStateProvider);
    final workers = await appState.db.getEmployeesByTeamIds(
      appState.currentSession?.toIds ?? const <String>[],
    );
    if (!mounted) return;

    final worker = await showSearchablePicker(
      context,
      title: 'Chọn công nhân',
      searchHint: 'Tìm theo tên hoặc mã nhân viên',
      emptyMessage:
          'Chưa có công nhân trong phạm vi trên thiết bị. Hãy kiểm tra đồng bộ danh mục SAP hoặc liên hệ quản trị.',
      items: workers,
      itemTitle: (item) => item['ten']?.toString() ?? 'Công nhân',
      itemSubtitle: (item) =>
          [item['ma_nv'], item['bo_phan']].whereType<Object>().join(' · '),
      searchableText: (item) => [
        item['ten'],
        item['ma_nv'],
        item['bo_phan'],
      ].whereType<Object>().join(' '),
    );
    if (!mounted || worker == null) return;

    if (closeScannerRoute && Navigator.canPop(context)) Navigator.pop(context);
    setState(() {
      _selectedWorker = worker;
      _scanError = null;
    });
  }

  Future<void> _pickOrder({bool closeScannerRoute = false}) async {
    final openOrders = await ref.read(appStateProvider).db.getOpenOrders();
    if (!mounted) return;

    final order = await showSearchablePicker(
      context,
      title: 'Chọn sản phẩm',
      searchHint: 'Tìm theo sản phẩm, mã hoặc đơn hàng',
      emptyMessage:
          'Chưa có đơn hàng mở trên thiết bị. Ứng dụng cần dịch vụ danh mục SAP để tải dữ liệu mới.',
      items: openOrders,
      itemTitle: (item) => item['ten_sp']?.toString() ?? 'Sản phẩm',
      itemSubtitle: (item) => [
        item['ma_sp'],
        item['ma_don_hang'],
        item['dac_tinh'],
      ].whereType<Object>().join(' · '),
      searchableText: (item) => [
        item['ten_sp'],
        item['ma_sp'],
        item['ma_don_hang'],
        item['ma_qr'],
        item['dac_tinh'],
      ].whereType<Object>().join(' '),
    );
    if (!mounted || order == null) return;

    if (closeScannerRoute && Navigator.canPop(context)) Navigator.pop(context);
    setState(() {
      _selectedOrder = order;
      _scanError = null;
    });
  }

  // -------------------------------------------------------------- submission

  void _showAssignmentError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(message), backgroundColor: CaslaColors.danger),
      );
  }

  /// Clears the fields that must not carry over into the next assignment.
  ///
  /// The retained product, when the operator asked to keep it, is shown on the
  /// form itself rather than announced in a snackbar. The old snackbar landed
  /// on top of the SAP result message and replaced it, so the default path
  /// through this screen never told anyone whether the write had actually
  /// reached SAP.
  void _resetAfterSubmit() {
    setState(() {
      _selectedWorker = null;
      _qtyController.clear();
      _noteController.clear();
      _quantityError = null;
      _scanError = null;
      if (!_keepProductAfterSubmit) _selectedOrder = null;
    });
    _scanListenerKey.currentState?.resetDeduplication();
  }

  Future<void> _submitAssignment() async {
    if (_isSubmitting) return;
    FocusScope.of(context).unfocus();

    if (_selectedOrder == null) {
      _showAssignmentError('Hãy quét hoặc chọn mã công đoạn / sản phẩm.');
      return;
    }
    if (_selectedWorker == null) {
      _showAssignmentError('Hãy quét thẻ công nhân hoặc chọn trong danh sách.');
      return;
    }

    final qty = double.tryParse(_qtyController.text.trim()) ?? 0.0;
    if (!qty.isFinite || qty <= 0) {
      setState(
        () => _quantityError = 'Số lượng giao phải là một số dương hợp lệ.',
      );
      return;
    }
    setState(() => _quantityError = null);

    final appState = ref.read(appStateProvider);
    final emp = appState.currentSession;

    final workerId = _selectedWorker!['id'] as String;
    final orderId = _selectedOrder!['id'] as String;
    // `to_ids` on the worker is not the SAP authorization source. The QR may
    // intentionally represent a worker unknown to this device. Keep a local
    // context only when Plant + Work Center from the operation QR identify one
    // exact manager context; SAP validates the actual write server-side.
    final scannedContext = emp == null
        ? null
        : resolveWorkContext(
            session: emp,
            plant: _selectedOrder!['plant']?.toString() ?? '',
            workCenter: _selectedOrder!['work_center']?.toString() ?? '',
          );
    final activeShift = appState.activeShift;
    final qrPlant = _selectedOrder!['plant']?.toString().trim() ?? '';
    if (activeShift == null) {
      _showAssignmentError('Chưa chọn ca làm việc.');
      return;
    }
    if (qrPlant.isNotEmpty && activeShift.plant != qrPlant) {
      _showAssignmentError(
        'Ca đang chọn thuộc nhà máy ${activeShift.plant}, '
        'nhưng mã công đoạn thuộc nhà máy $qrPlant. Hãy đổi ca đúng nhà máy.',
      );
      return;
    }
    if (scannedContext != null &&
        appState.activeWorkContext?.workId != scannedContext.workId) {
      _showAssignmentError(
        'Mã công đoạn thuộc Work Center ${scannedContext.workCenter}. '
        'Hãy đổi phạm vi làm việc trước khi giao.',
      );
      return;
    }
    // Setup is the manager's selected scope. A QR without Plant/WorkCenter
    // uses that scope; a QR carrying both keeps the exact SAP-matched context.
    final workContext = scannedContext ?? appState.activeWorkContext;
    final toId = workContext?.workId ?? '';
    final createdBy = emp?.maNv ?? '';

    // The selected shift setup is the sole source of the operation's business
    // date. SAP verifies it against ExecutedAt, including the overnight shift.
    final dateFormatted = DateFormat(
      'yyyy-MM-dd',
    ).format(appState.activeBusinessDate);
    final generation = appState.sessionGeneration;
    setState(() => _isSubmitting = true);
    _isDialogOpen = true;

    // Through the repository so the quantity check and the audit-log entry run.
    try {
      final workerPassword = await showWorkerVerificationDialog(
        context,
        workerName: _selectedWorker!['ten'] as String? ?? 'Công nhân',
        actionLabel: 'gửi phân công lên SAP',
      );
      if (!mounted || workerPassword == null) return;
      if (!appState.isSessionGenerationCurrent(generation)) {
        throw Exception(
          'Phiên đăng nhập đã thay đổi. Vui lòng mở lại thao tác.',
        );
      }
      final receipt = await appState.assignmentRepo.createAssignment(
        workerId: workerId,
        orderId: orderId,
        teamId: toId,
        assignedQuantity: qty,
        businessDate: dateFormatted,
        // Legacy field required by the current repository/SAP payload. Shift
        // selection is no longer part of the assignment workflow; keep the
        // previously used value until the backend contract makes it optional.
        shiftId:
            ref.read(appStateProvider).activeShift?.shiftId ??
            (throw StateError('Chưa chọn ca làm việc.')),
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
        createdBy: createdBy,
        workerPassword: workerPassword,
      );

      if (!mounted) return;
      final workerName = _selectedWorker!['ten'];
      // Clear before reporting: the report can open a dialog, and coming back
      // to a form still holding the submitted values invites a double send.
      _resetAfterSubmit();
      await showMutationFeedback(
        context,
        receipt: receipt,
        successMessage: 'Đã giao $qty $_selectedUom cho $workerName.',
      );
    } on Exception catch (e) {
      if (!mounted) return;
      _showAssignmentError(friendlySapErrorMessage(e));
      return;
    } finally {
      _isDialogOpen = false;
      if (mounted) setState(() => _isSubmitting = false);
    }

    if (!mounted) return;
    // A pushed instance returns to where it came from. The tab instance has
    // nothing to pop, and stays on a cleared form ready for the next scan.
    if (!_keepProductAfterSubmit && Navigator.canPop(context)) context.pop();
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final businessDate = appState.activeBusinessDate;

    return BarcodeScanListener(
      key: _scanListenerKey,
      onScan: _handleScan,
      scanner: widget.scanner,
      preferences: widget.scannerPreferences,
      enabled: !_isSubmitting && !_isDialogOpen,
      child: Scaffold(
        backgroundColor: CaslaColors.background,
        appBar: AppBar(
          leading: Navigator.canPop(context)
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => context.pop(),
                )
              : null,
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tạo phân công',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: CaslaType.title,
                ),
              ),
              Text(
                'Bóp cò để quét, không cần chạm màn hình',
                style: TextStyle(
                  fontSize: CaslaType.caption,
                  fontWeight: FontWeight.w500,
                  color: CaslaColors.identityMeta,
                ),
              ),
            ],
          ),
        ),
        body: GestureDetector(
          // Dismisses the keyboard so the reader takes over again: a wedge
          // scan lands in whichever text field holds focus, which is right for
          // the quantity box and wrong for everything else.
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.opaque,
          child: Column(
            children: [
              const ScanStatusStrip(),
              if (_scanError case final message?)
                ScanErrorBanner(
                  message: message,
                  onDismiss: () => setState(() => _scanError = null),
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(CaslaSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ActiveShiftContextCard(
                        workContext: appState.activeWorkContext,
                        shift: appState.activeShift,
                        businessDate: businessDate,
                        compact: true,
                        onEdit: () =>
                            context.push('/supervisor-setup', extra: true),
                      ),
                      const SizedBox(height: CaslaSpacing.md),

                      _ScanSlot(
                        label: 'Sản phẩm / công đoạn',
                        required: true,
                        icon: Icons.inventory_2_outlined,
                        value: _selectedOrder?['ten_sp']?.toString(),
                        detail: _selectedOrder == null
                            ? null
                            : [
                                _selectedOrder!['ma_sp'],
                                _selectedOrder!['ma_don_hang'],
                              ].whereType<Object>().join(' · '),
                        placeholder: 'Bóp cò quét nhãn công đoạn',
                        onOpenScanner: () => _openScannerRoute(
                          title: 'Quét mã sản phẩm / công đoạn',
                          subtitle:
                              'Đưa mã QR trên lô sản phẩm hoặc thẻ đơn hàng vào khung hình.',
                          onManualInput: () =>
                              _pickOrder(closeScannerRoute: true),
                        ),
                        onPickManually: _pickOrder,
                        onClear: _selectedOrder == null
                            ? null
                            : () => setState(() => _selectedOrder = null),
                      ),
                      const SizedBox(height: CaslaSpacing.sm),

                      _ScanSlot(
                        label: 'Công nhân',
                        required: true,
                        icon: Icons.badge_outlined,
                        value: _selectedWorker?['ten']?.toString(),
                        detail: _selectedWorker?['ma_nv']?.toString(),
                        placeholder: 'Bóp cò quét thẻ nhân viên',
                        onOpenScanner: () => _openScannerRoute(
                          title: 'Quét mã QR công nhân',
                          subtitle: 'Đưa thẻ nhân viên vào khung hình.',
                          onManualInput: () =>
                              _pickWorker(closeScannerRoute: true),
                        ),
                        onPickManually: _pickWorker,
                        onClear: _selectedWorker == null
                            ? null
                            : () => setState(() => _selectedWorker = null),
                      ),
                      const SizedBox(height: CaslaSpacing.md),

                      const _FieldLabel(text: 'Số lượng giao', required: true),
                      const SizedBox(height: CaslaSpacing.xs),
                      TextField(
                        controller: _qtyController,
                        focusNode: _qtyFocus,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => FocusScope.of(context).unfocus(),
                        onChanged: (_) {
                          if (_quantityError != null) {
                            setState(() => _quantityError = null);
                          }
                        },
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: CaslaType.title,
                          color: CaslaColors.primaryNavy,
                        ),
                        decoration: InputDecoration(
                          errorText: _quantityError,
                          helperText: _qtyFocus.hasFocus
                              ? 'Đang gõ số — đầu đọc tạm nghỉ.'
                              : null,
                          // suffixText fades out while an empty field is
                          // unfocused. Keep the QR unit visible before the
                          // first keystroke.
                          suffixIcon: _selectedUom.isEmpty
                              ? null
                              : Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: CaslaSpacing.sm,
                                  ),
                                  child: Center(
                                    widthFactor: 1,
                                    heightFactor: 1,
                                    child: Text(
                                      _selectedUom,
                                      key: const ValueKey(
                                        'assignment-quantity-unit',
                                      ),
                                      style: const TextStyle(
                                        fontSize: CaslaType.body,
                                        color: CaslaColors.muted,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: CaslaSpacing.md),

                      const _FieldLabel(text: 'Ngày làm việc', required: true),
                      const SizedBox(height: CaslaSpacing.xs),
                      // Opens the shift setup rather than pretending to be a
                      // date picker: the business date follows the selected
                      // shift, and a calendar icon on a dead field was a lie.
                      InkWell(
                        onTap: () =>
                            context.push('/supervisor-setup', extra: true),
                        borderRadius: BorderRadius.circular(CaslaRadius.sm),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            helperText:
                                'Ngày theo ca đang chọn. Chạm để đổi ca.',
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                DateFormat('dd/MM/yyyy').format(businessDate),
                                style: const TextStyle(
                                  fontSize: CaslaType.body,
                                  fontWeight: FontWeight.w600,
                                  color: CaslaColors.primaryNavy,
                                ),
                              ),
                              const Icon(
                                Icons.edit_calendar_outlined,
                                size: 18,
                                color: CaslaColors.primaryNavy,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: CaslaSpacing.md),

                      const _FieldLabel(text: 'Ghi chú'),
                      const SizedBox(height: CaslaSpacing.xs),
                      TextField(
                        controller: _noteController,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => FocusScope.of(context).unfocus(),
                        decoration: const InputDecoration(
                          hintText: 'Không bắt buộc',
                        ),
                      ),
                      const SizedBox(height: CaslaSpacing.md),

                      CheckboxListTile(
                        value: _keepProductAfterSubmit,
                        onChanged: (value) => setState(
                          () => _keepProductAfterSubmit = value ?? false,
                        ),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: CaslaColors.primaryNavy,
                        title: const Text(
                          'Giữ sản phẩm để giao tiếp cho công nhân khác',
                          style: TextStyle(
                            fontSize: CaslaType.body,
                            fontWeight: FontWeight.w600,
                            color: CaslaColors.primaryNavy,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(CaslaSpacing.md),
                  child: ElevatedButton(
                    onPressed: _isSubmitting ? null : _submitAssignment,
                    child: _isSubmitting
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: CaslaColors.navy900,
                            ),
                          )
                        : const Text('Xác nhận phân công'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  final bool required;

  const _FieldLabel({required this.text, this.required = false});

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: CaslaType.caption,
          fontWeight: FontWeight.w700,
          color: CaslaColors.primaryNavy,
        ),
        children: [
          if (required)
            const TextSpan(
              text: ' *',
              style: TextStyle(color: CaslaColors.danger),
            ),
        ],
      ),
    );
  }
}

/// A field that is normally filled by pulling the trigger.
///
/// Filled and empty look deliberately different: an operator glancing down
/// mid-shift has to be able to tell at arm's length which half of the
/// assignment is still missing.
class _ScanSlot extends StatelessWidget {
  final String label;
  final bool required;
  final IconData icon;
  final String? value;
  final String? detail;
  final String placeholder;
  final VoidCallback onOpenScanner;
  final Future<void> Function() onPickManually;
  final VoidCallback? onClear;

  const _ScanSlot({
    required this.label,
    required this.required,
    required this.icon,
    required this.value,
    required this.detail,
    required this.placeholder,
    required this.onOpenScanner,
    required this.onPickManually,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final filled = value != null && value!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(text: label, required: required),
        const SizedBox(height: CaslaSpacing.xs),
        Container(
          decoration: BoxDecoration(
            color: filled ? CaslaColors.successBg : CaslaColors.surface,
            border: Border.all(
              color: filled ? CaslaColors.success : CaslaColors.line,
              width: filled ? 1.5 : 1.2,
            ),
            borderRadius: BorderRadius.circular(CaslaRadius.md),
          ),
          child: Padding(
            padding: const EdgeInsets.all(CaslaSpacing.sm),
            child: Row(
              children: [
                Icon(
                  filled ? Icons.check_circle_rounded : icon,
                  size: 22,
                  color: filled ? CaslaColors.success : CaslaColors.muted,
                ),
                const SizedBox(width: CaslaSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        filled ? value! : placeholder,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: CaslaType.body,
                          fontWeight: FontWeight.w700,
                          color: filled
                              ? CaslaColors.primaryNavy
                              : CaslaColors.muted,
                        ),
                      ),
                      if (filled && detail != null && detail!.isNotEmpty)
                        Text(
                          detail!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: CaslaType.caption,
                            color: CaslaColors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
                if (onClear != null)
                  IconButton(
                    tooltip: 'Xóa lựa chọn',
                    onPressed: onClear,
                    icon: const Icon(Icons.close, size: 20),
                    color: CaslaColors.muted,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: CaslaSpacing.xxs),
        Row(
          children: [
            TextButton.icon(
              onPressed: onOpenScanner,
              icon: const Icon(Icons.photo_camera_outlined, size: 18),
              label: const Text('Camera'),
              style: TextButton.styleFrom(
                foregroundColor: CaslaColors.primaryNavy,
                minimumSize: const Size(0, 44),
                textStyle: const TextStyle(
                  fontSize: CaslaType.caption,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: CaslaSpacing.xs),
            TextButton.icon(
              onPressed: () => onPickManually(),
              icon: const Icon(Icons.list_alt_outlined, size: 18),
              label: const Text('Chọn danh sách'),
              style: TextButton.styleFrom(
                foregroundColor: CaslaColors.primaryNavy,
                minimumSize: const Size(0, 44),
                textStyle: const TextStyle(
                  fontSize: CaslaType.caption,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
