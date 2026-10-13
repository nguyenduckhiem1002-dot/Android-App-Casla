import '../../../core/utils/shift_execution_validation.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';
import '../../../core/scanner/barcode_scanner.dart';
import '../../../core/scanner/scan_intent.dart';
import '../../../core/scanner/scan_payload_logger.dart';
import '../../../core/scanner/scanner_preferences.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../core/utils/operation_qr_parser.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../core/utils/vietnamese_text_normalizer.dart';
import '../../../data/sap/odata_error.dart';
import '../../../data/sap/sap_position_gateway.dart';
import '../../../domain/entities/worker_position.dart';
import '../../../domain/entities/mutation_receipt.dart';
import '../../../domain/entities/work_history.dart';
import '../../../domain/policies/assignment_position_policy.dart';
import '../../../domain/policies/work_context_resolver.dart';
import '../../../domain/policies/worker_position_policy.dart';
import '../../../main.dart';
import '../../../presentation/widgets/account_avatar_button.dart';
import '../../../presentation/widgets/active_shift_context_card.dart';
import '../../../presentation/widgets/adaptive_barcode_scanner_view.dart';
import '../../../presentation/widgets/barcode_scan_listener.dart';
import '../../../presentation/widgets/manual_code_dialog.dart';
import '../../../presentation/widgets/mutation_feedback.dart';
import '../../../presentation/widgets/over_limit_line.dart';
import '../../../presentation/widgets/position_slot_field.dart';
import '../../../presentation/widgets/scan_slot_field.dart';
import '../../../presentation/widgets/scan_status_strip.dart';
import '../../../presentation/widgets/searchable_picker_sheet.dart';
import '../../../presentation/widgets/worker_scan_acceptance.dart';
import '../../../presentation/widgets/worker_verification_dialog.dart';

/// Assignment entry, built around the trigger rather than the touchscreen.
///
/// The reader stays armed on this form. Scanning an operation label fills the
/// selected field only. Scanning a different type never changes another field.
/// The full-screen scanner routes are still reachable from each field, but they
/// are the camera fallback now, not the main path.
class S07CreateAssignmentWizardScreen extends ConsumerStatefulWidget {
  /// Test seams, mirroring [AdaptiveBarcodeScannerView]. Production always
  /// leaves these null so the listener builds the real broadcast + wedge pair.
  @visibleForTesting
  final BarcodeScanner? scanner;

  @visibleForTesting
  final ScannerPreferences? scannerPreferences;

  /// Where the worker's current position is read from; AppState's position
  /// gateway when null.
  @visibleForTesting
  final PositionApi? positionApi;

  const S07CreateAssignmentWizardScreen({
    super.key,
    this.scanner,
    this.scannerPreferences,
    this.now,
    this.positionApi,
  });

  @visibleForTesting
  final DateTime Function()? now;

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
  bool _scanRouteOpen = false;
  bool _isProcessingScan = false;
  ScannedCodeKind _scanTarget = ScannedCodeKind.operation;

  // Further operations given to the same worker in one go. The first one
  // stays in [_selectedOrder] with everything this form already does for it;
  // these ride along with the same worker, position and quantity.
  final List<_ExtraOperation> _extraOperations = [];

  /// The (+) button is armed: the next operation label is added instead of
  /// replacing the first operation.
  bool _addOperationTarget = false;
  bool _primaryExpanded = true;

  /// Bộ phận per operation label payload, so build does not re-parse QR text.
  final Map<String, String> _operationDepartments = {};

  // Optional position the worker operates from. Filled from the worker's seat
  // on the position board; scanning a machine label overrides it for this
  // assignment only (a temporary seat).
  bool _positionTarget = false;
  String? _positionId;
  String? _machineId;
  PositionSource _positionSource = PositionSource.origin;
  PositionLookupState _positionLookup = PositionLookupState.idle;
  PositionSeat? _originSeat;
  int _positionRequest = 0;

  /// Position this worker's assignments for the selected operation were
  /// already made at in this shift. A further assignment must reuse it.
  String? _groupPositionId;
  int _groupPositionRequest = 0;

  /// SAP refused the board for this account (no PP_POS_MANAGE or no Work
  /// Center scope). Asking again for every worker would only repeat that.
  bool _positionLookupDenied = false;

  /// The work date comes from the shift setup; showing it again on this form
  /// only duplicated that choice. Flip to true to bring the field back.
  static const bool _showBusinessDateField = false;
  String? _quantityError;
  String? _scanError;
  bool _keepProductAfterSubmit = true;
  Map<String, double> _operationQuantities = const {};
  bool _quantitiesLoading = false;
  int _quantityRequest = 0;
  WorkHistoryResult? _lastOperationHistory;
  String? _lastHistoryOrderId;

  String get _selectedUom {
    return _selectedOrder?['uom']?.toString().trim() ?? '';
  }

  String _operationDisplayName(Map<String, dynamic>? order) {
    final operationName = order?['operation_name']?.toString().trim() ?? '';
    if (operationName.isNotEmpty) return operationName;
    final operationCode = order?['operation']?.toString().trim() ?? '';
    return operationCode.isEmpty
        ? 'Chưa có tên công đoạn'
        : 'Công đoạn $operationCode';
  }

  Future<void> _loadOperationQuantities(Map<String, dynamic> order) async {
    final id = order['id']?.toString().trim() ?? '';
    if (id.isEmpty) return;
    unawaited(_loadGroupPosition());
    final request = ++_quantityRequest;
    setState(() => _quantitiesLoading = true);
    final appState = ref.read(appStateProvider);
    final workId = appState.activeWorkContext?.workId;
    final generation = appState.sessionGeneration;
    bool isCurrent() =>
        mounted &&
        request == _quantityRequest &&
        identical(_selectedOrder, order) &&
        appState.sessionGeneration == generation;
    Map<String, double> localSummary = const {};
    try {
      localSummary = await appState.db.getOperationQuantitySummary(orderId: id);
    } catch (_) {
      // The history response can still populate the form if a local
      // migration/read is temporarily unavailable.
    }
    if (isCurrent() && _operationQuantities.isEmpty) {
      setState(() => _operationQuantities = localSummary);
    }

    final productionOrder = order['production_order']?.toString().trim() ?? '';
    final operation = order['operation']?.toString().trim() ?? '';
    if (productionOrder.isEmpty || operation.isEmpty) {
      if (isCurrent()) setState(() => _quantitiesLoading = false);
      return;
    }

    final selectedDate = appState.activeBusinessDate;
    final selectedShift = appState.activeShift;
    bool contextUnchanged() {
      final latest = ref.read(appStateProvider);
      return latest.activeWorkContext?.workId == workId &&
          latest.activeShift?.shiftId == selectedShift?.shiftId &&
          DateUtils.isSameDay(latest.activeBusinessDate, selectedDate);
    }

    // Preferred: SAP's live balance of the whole operation (every day, shift
    // and department), plus only the writes still queued on this device —
    // SAP's live tables already contain everything it acknowledged, so adding
    // synced rows again would double them.
    final live = await _loadLiveOperationQuantities(
      order: order,
      productionOrder: productionOrder,
      operation: operation,
      workId: workId,
      shiftId: selectedShift?.shiftId,
      fallbackOperationQuantity: localSummary['operationQuantity'] ?? 0,
    );
    if (live != null) {
      if (isCurrent() && contextUnchanged()) {
        setState(() {
          _operationQuantities = live;
          _quantitiesLoading = false;
        });
      } else if (isCurrent()) {
        setState(() => _quantitiesLoading = false);
      }
      return;
    }
    if (!isCurrent()) return;

    try {
      final remote = await appState.workHistoryRepo.getWorkHistory(
        range: HistoryRange.day,
        dateFrom: selectedDate,
        dateTo: selectedDate,
        shiftId: selectedShift?.shiftId,
        workId: workId,
        productionOrder: productionOrder,
        operation: operation,
        forceRefresh: true,
      );
      if (!isCurrent()) return;
      final remoteSummary = await _mergeOperationQuantities(
        remote,
        order: order,
        operationQuantity: localSummary['operationQuantity'] ?? 0,
        workId: workId,
        businessDate: selectedDate,
        shiftId: selectedShift?.shiftId,
      );
      if (!isCurrent()) return;
      final latestAppState = ref.read(appStateProvider);
      final sameShift =
          latestAppState.activeShift?.shiftId == selectedShift?.shiftId;
      if (isCurrent() &&
          latestAppState.activeWorkContext?.workId == workId &&
          DateUtils.isSameDay(
            latestAppState.activeBusinessDate,
            selectedDate,
          ) &&
          sameShift) {
        setState(() {
          _operationQuantities = remoteSummary;
          _lastOperationHistory = remote;
          _lastHistoryOrderId = id;
        });
      }
    } catch (_) {
      // Keep the local snapshot when SAP history is temporarily unavailable.
      // The write is still validated by SAP; showing no quantity is safer than
      // replacing a known local value with a fabricated zero.
      if (isCurrent()) {
        try {
          final latest =
              _lastHistoryOrderId == id && _lastOperationHistory != null
              ? await _mergeOperationQuantities(
                  _lastOperationHistory!,
                  order: order,
                  operationQuantity: localSummary['operationQuantity'] ?? 0,
                  workId: workId,
                  businessDate: selectedDate,
                  shiftId: selectedShift?.shiftId,
                )
              : await appState.db.getOperationQuantitySummary(orderId: id);
          if (isCurrent()) setState(() => _operationQuantities = latest);
        } catch (_) {
          /* Keep the previous snapshot if storage is unavailable. */
        }
      }
    } finally {
      if (isCurrent()) setState(() => _quantitiesLoading = false);
    }
  }

  /// Operation balance from SAP's live allocation tables, or null when SAP
  /// cannot answer (offline, outside the shift window, no work context...).
  Future<Map<String, double>?> _loadLiveOperationQuantities({
    required Map<String, dynamic> order,
    required String productionOrder,
    required String operation,
    required String? workId,
    required String? shiftId,
    required double fallbackOperationQuantity,
  }) async {
    if (workId == null ||
        workId.isEmpty ||
        shiftId == null ||
        shiftId.isEmpty) {
      return null;
    }
    try {
      final appState = ref.read(appStateProvider);
      final access = await appState.sapGateway.checkOperationAccess(
        productionOrder: productionOrder,
        operation: operation,
        workId: workId,
        shiftId: shiftId,
        executedAt: DateTime.now(),
      );
      if (!access.isAllowed) return null;
      final pending = await appState.db.getPendingOperationQuantitySummary(
        productionOrder: productionOrder,
        operation: operation,
      );
      final operationQuantity = access.operationQuantity > 0
          ? access.operationQuantity
          : fallbackOperationQuantity;
      final assigned =
          (access.currentAssignedQuantity + (pending['assignedDelta'] ?? 0))
              .clamp(0.0, double.infinity);
      return {
        'operationQuantity': operationQuantity,
        'assignedQuantity': assigned,
        'confirmedQuantity':
            (access.completedQuantity + (pending['completedQuantity'] ?? 0))
                .clamp(0.0, double.infinity),
        'defectQuantity':
            (access.defectQuantity + (pending['defectQuantity'] ?? 0)).clamp(
              0.0,
              double.infinity,
            ),
        'remaining': (operationQuantity - assigned).clamp(0.0, double.infinity),
      };
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, double>> _mergeOperationQuantities(
    WorkHistoryResult remote, {
    required Map<String, dynamic> order,
    required double operationQuantity,
    String? workId,
    DateTime? businessDate,
    String? shiftId,
  }) async {
    final productionOrder = order['production_order'].toString().trim();
    final operation = order['operation'].toString().trim();
    final summary = _summarizeRemoteOperation(
      remote,
      productionOrder: productionOrder,
      operation: operation,
      operationQuantity: operationQuantity,
    );
    final local = await ref
        .read(appStateProvider)
        .db
        .getPendingOperationQuantitySummary(
          productionOrder: productionOrder,
          operation: operation,
          // The report covers one day, shift and department; only this
          // device's rows from that same window may top it up.
          workId: workId,
          businessDate: businessDate == null
              ? null
              : DateFormat('yyyy-MM-dd').format(businessDate),
          shiftId: shiftId,
          representedTransactionIds: remote.entries
              .where(
                (entry) =>
                    entry.productionOrder.trim() == productionOrder &&
                    entry.operation.trim() == operation,
              )
              .map((entry) => entry.transactionUuid.trim())
              .toSet(),
          includeSyncedMissingFromHistory: true,
        );
    final assigned =
        (summary['assignedQuantity']! + (local['assignedDelta'] ?? 0)).clamp(
          0.0,
          double.infinity,
        );
    return {
      ...summary,
      'assignedQuantity': assigned,
      'confirmedQuantity':
          (summary['confirmedQuantity']! + (local['completedQuantity'] ?? 0))
              .clamp(0.0, double.infinity),
      'defectQuantity':
          (summary['defectQuantity']! + (local['defectQuantity'] ?? 0)).clamp(
            0.0,
            double.infinity,
          ),
      // Confirmed units are already part of effective assignments.
      'remaining': (operationQuantity - assigned).clamp(0.0, double.infinity),
    };
  }

  Map<String, double> _summarizeRemoteOperation(
    WorkHistoryResult result, {
    required String productionOrder,
    required String operation,
    required double operationQuantity,
  }) {
    // Worker totals have no order/operation key and can span other operations.
    // A partial detail response cannot establish an exact operation balance.
    if (result.isTruncated ||
        (result.entries.isEmpty &&
            result.workers.any(
              (worker) =>
                  worker.transactionCount > 0 ||
                  worker.assignedQuantity != 0 ||
                  worker.completedQuantity != 0,
            ))) {
      throw StateError('History detail is incomplete for operation quantities');
    }
    var assigned = 0.0;
    var confirmed = 0.0;
    var defect = 0.0;
    for (final entry in result.entries) {
      if (entry.productionOrder.trim() != productionOrder ||
          entry.operation.trim() != operation) {
        continue;
      }
      switch (entry.transactionType.trim().toUpperCase()) {
        case 'INITIAL_ASSIGN':
          assigned += entry.quantity;
        case 'RECALL':
          assigned -= entry.quantity;
        case 'CONFIRM':
        case 'CORRECTION':
          confirmed += entry.quantity;
          defect += entry.defectQuantity;
        case 'REVERSE':
          confirmed -= entry.quantity;
          defect -= entry.defectQuantity;
      }
    }
    assigned = assigned < 0 ? 0 : assigned;
    confirmed = confirmed < 0 ? 0 : confirmed;
    defect = defect < 0 ? 0 : defect;
    final remaining = (operationQuantity - assigned).clamp(
      0.0,
      double.infinity,
    );
    return {
      'operationQuantity': operationQuantity,
      'confirmedQuantity': confirmed,
      'defectQuantity': defect,
      'assignedQuantity': assigned,
      'remaining': remaining,
    };
  }

  @override
  void dispose() {
    _qtyController.dispose();
    _noteController.dispose();
    _qtyFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- scanning

  /// Reject mismatched input before any local data is written.
  ///
  /// Returns false for anything rejected so the listener plays the failure
  /// tone: on a shop floor the operator is looking at the pallet, not at this
  /// screen, and needs to hear that nothing was captured.
  Future<bool> _handleScan(
    String code, {
    ScannedCodeKind? expectedKind,
    bool forPosition = false,
  }) async {
    if (_isSubmitting || _isProcessingScan || !mounted) return false;
    // A warning belongs to one payload only. Clear it before any async work
    // so a new valid QR cannot appear to have the previous QR's department.
    setState(() => _scanError = null);
    // Position labels are only read when the position field is selected: a
    // short `G05@M105` would otherwise pass as a worker code.
    final wantsPosition =
        forPosition || (expectedKind == null && _positionTarget);
    if (wantsPosition) {
      final slot = parsePositionSlotQr(code);
      if (slot != null) return _applyPositionScan(slot);
    }
    final scanned = ScanClassifier.classify(code);
    // An operation label is still taken as a correction, as everywhere else.
    if (wantsPosition &&
        (forPosition || scanned.kind != ScannedCodeKind.operation)) {
      return _rejectScan(
        'Mã vừa quét không phải nhãn vị trí. Nhãn đúng có dạng G05@M105.',
      );
    }
    // The target moves to the worker on its own after an operation scan, so a
    // hardware re-scan of another operation QR is a correction, not a mistake.
    final target =
        expectedKind ??
        (scanned.kind == ScannedCodeKind.operation
            ? ScannedCodeKind.operation
            : _scanTarget);
    if (scanned.kind == ScannedCodeKind.unknown) {
      return _rejectScan(scanned.error);
    }
    if (scanned.kind != target) {
      return _rejectScan(
        target == ScannedCodeKind.worker
            ? 'Đây là QR công đoạn. Hãy quét thẻ công nhân.'
            : 'Đây là QR công nhân. Hãy quét mã công đoạn.',
      );
    }
    _isProcessingScan = true;
    try {
      if (target == ScannedCodeKind.operation) {
        return _addOperationTarget && _selectedOrder != null
            ? await _applyExtraOperationScan(scanned.operation!)
            : await _applyOperationScan(scanned.operation!);
      }
      return await _applyWorkerScan(code);
    } catch (_) {
      return _rejectScan('Không xử lý được mã vừa quét. Vui lòng thử lại.');
    } finally {
      _isProcessingScan = false;
    }
  }

  void _selectScanTarget(ScannedCodeKind target) {
    if (_isSubmitting || _isProcessingScan || _scanRouteOpen) return;
    FocusScope.of(context).unfocus();
    _scanListenerKey.currentState?.resetDeduplication();
    setState(() {
      _scanTarget = target;
      _positionTarget = false;
      _addOperationTarget = false;
      _scanError = null;
    });
  }

  // ---------------------------------------------------------------- position

  void _selectPositionTarget() {
    if (_isSubmitting || _isProcessingScan || _scanRouteOpen) return;
    if (_selectedWorker == null) return;
    FocusScope.of(context).unfocus();
    _scanListenerKey.currentState?.resetDeduplication();
    setState(() {
      _positionTarget = true;
      _addOperationTarget = false;
      _scanError = null;
    });
  }

  bool _applyPositionScan(PositionSlot slot) {
    if (_selectedWorker == null) {
      return _rejectScan('Chọn công nhân trước rồi mới quét vị trí.');
    }
    final workCenter =
        ref.read(appStateProvider).activeWorkContext?.workCenter.trim() ?? '';
    if (slot.workCenter.isNotEmpty &&
        workCenter.isNotEmpty &&
        slot.workCenter.toUpperCase() != workCenter.toUpperCase()) {
      return _rejectScan(
        'Nhãn thuộc Xưởng "${slot.workCenter}", còn ca đang chọn thuộc Xưởng '
        '"$workCenter".',
      );
    }
    final origin = _originSeat;
    setState(() {
      _positionId = slot.positionId;
      _machineId = slot.machineId;
      _positionSource =
          origin != null &&
              origin.positionId.trim().toUpperCase() == slot.positionId
          ? PositionSource.origin
          : PositionSource.temporary;
      _positionTarget = false;
      _scanError = null;
    });
    return true;
  }

  void _useOriginPosition() {
    final origin = _originSeat;
    if (origin == null) return;
    setState(() {
      _positionId = origin.positionId.trim().toUpperCase();
      _machineId = origin.machineId.trim().toUpperCase();
      _positionSource = PositionSource.origin;
    });
  }

  void _clearPosition() {
    setState(() {
      _positionId = null;
      _machineId = null;
      _positionSource = PositionSource.origin;
    });
  }

  /// Forgets everything about the previous worker's position. Call inside a
  /// setState together with the worker change.
  void _resetPositionState() {
    ++_positionRequest;
    _positionTarget = false;
    _positionId = null;
    _machineId = null;
    _positionSource = PositionSource.origin;
    _positionLookup = PositionLookupState.idle;
    _originSeat = null;
    ++_groupPositionRequest;
    _groupPositionId = null;
    for (final extra in _extraOperations) {
      extra.groupPositionId = null;
    }
  }

  /// Set while the chosen position disagrees with the one this worker's
  /// assignments for the operation already use in the shift.
  String? get _positionConflict {
    if (_selectedWorker == null) return null;
    String? conflict(Map<String, dynamic> order, String? groupPositionId) =>
        groupPositionConflict(
          groupPositionId: groupPositionId,
          selectedPositionId: _positionId,
          productionOrder: order['production_order']?.toString() ?? '',
          operation: order['operation']?.toString() ?? '',
        );
    final order = _selectedOrder;
    if (order == null) return null;
    final first = conflict(order, _groupPositionId);
    if (first != null) return first;
    for (final extra in _extraOperations) {
      final next = conflict(extra.order, extra.groupPositionId);
      if (next != null) return next;
    }
    return null;
  }

  /// Finds the position of the worker's earlier assignments for the selected
  /// operation in the active shift: this device's own rows first (they include
  /// writes SAP has not seen yet), then SAP's history for other devices.
  ///
  /// [force] asks SAP again instead of trusting a recent history cache; used
  /// right before sending.
  Future<String?> _loadGroupPosition({bool force = false}) async {
    final request = ++_groupPositionRequest;
    final worker = _selectedWorker;
    final order = _selectedOrder;
    if (worker == null || order == null) {
      if (mounted && _groupPositionId != null) {
        setState(() => _groupPositionId = null);
      }
      return null;
    }
    final found = await _fetchGroupPosition(worker, order, force: force);
    if (!mounted || request != _groupPositionRequest) return found;
    setState(() => _groupPositionId = found);
    return found;
  }

  /// The same lookup for an operation added with (+).
  Future<String?> _loadExtraGroupPosition(
    _ExtraOperation extra, {
    bool force = false,
  }) async {
    final worker = _selectedWorker;
    if (worker == null) return null;
    final found = await _fetchGroupPosition(worker, extra.order, force: force);
    if (!mounted ||
        !_extraOperations.contains(extra) ||
        !identical(_selectedWorker, worker)) {
      return found;
    }
    setState(() => extra.groupPositionId = found);
    return found;
  }

  Future<String?> _fetchGroupPosition(
    Map<String, dynamic> worker,
    Map<String, dynamic> order, {
    required bool force,
  }) async {
    final appState = ref.read(appStateProvider);
    final shift = appState.activeShift;
    if (shift == null) return null;
    final date = appState.activeBusinessDate;
    String? found;
    try {
      found = await appState.db.getGroupAssignmentPosition(
        workerId: worker['id']?.toString() ?? '',
        orderId: order['id']?.toString() ?? '',
        businessDate: DateFormat('yyyy-MM-dd').format(date),
        shiftId: shift.shiftId,
      );
    } catch (_) {
      // Fall through to SAP's history.
    }
    final workerCode = worker['ma_nv']?.toString().trim() ?? '';
    final productionOrder = order['production_order']?.toString().trim() ?? '';
    final operation = order['operation']?.toString().trim() ?? '';
    if (found == null &&
        workerCode.isNotEmpty &&
        productionOrder.isNotEmpty &&
        operation.isNotEmpty) {
      try {
        final history = await appState.workHistoryRepo
            .getWorkHistory(
              range: HistoryRange.day,
              dateFrom: date,
              dateTo: date,
              shiftId: shift.shiftId,
              workId: appState.activeWorkContext?.workId,
              productionOrder: productionOrder,
              operation: operation,
              forceRefresh: force,
            )
            // Never hold the form on a slow network; SAP stays the judge.
            .timeout(const Duration(seconds: 8));
        found = groupPositionFromHistory(history.entries, workerId: workerCode);
      } catch (_) {
        // Offline or slow: only this device's rows are known.
      }
    }
    return found?.trim().toUpperCase();
  }

  /// Reads the worker's seat from SAP and pre-fills the position. Never
  /// blocks the assignment: a failure only leaves the field for a scan.
  Future<void> _lookupWorkerPosition(Map<String, dynamic> worker) async {
    final code = (worker['ma_nv'] ?? '').toString().trim().toUpperCase();
    final appState = ref.read(appStateProvider);
    final workCenter = (appState.activeWorkContext?.workCenter ?? '')
        .trim()
        .toUpperCase();
    final request = ++_positionRequest;
    setState(() {
      _originSeat = null;
      _positionId = null;
      _machineId = null;
      _positionSource = PositionSource.origin;
      _positionLookup = code.isEmpty
          ? PositionLookupState.none
          : PositionLookupState.loading;
    });
    if (code.isEmpty) return;
    if (_positionLookupDenied) {
      setState(() => _positionLookup = PositionLookupState.failed);
      return;
    }
    try {
      final api = widget.positionApi ?? appState.positionGateway;
      final board = await api.getBoard(workCenter: workCenter);
      if (!mounted || request != _positionRequest) return;
      final seat = board.seats
          .where(
            (seat) =>
                seat.workerId.trim().toUpperCase() == code &&
                (workCenter.isEmpty ||
                    seat.workCenter.trim().toUpperCase() == workCenter),
          )
          .firstOrNull;
      setState(() {
        _originSeat = seat;
        _positionLookup = seat == null
            ? PositionLookupState.none
            : PositionLookupState.found;
        if (seat == null) return;
        final seatId = seat.positionId.trim().toUpperCase();
        if (_positionId == null) {
          _positionId = seatId;
          _machineId = seat.machineId.trim().toUpperCase();
          _positionSource = PositionSource.origin;
        } else if (_positionId == seatId) {
          _positionSource = PositionSource.origin;
        }
      });
    } catch (error) {
      if (error is SapBusinessError &&
          const {
            'MISSING_PERMISSION',
            'NO_WORK_CENTER_SCOPE',
          }.contains(error.code)) {
        _positionLookupDenied = true;
      }
      if (mounted && request == _positionRequest) {
        setState(() => _positionLookup = PositionLookupState.failed);
      }
    }
  }

  void _onWorkerSelected(Map<String, dynamic> worker) {
    unawaited(_lookupWorkerPosition(worker));
    unawaited(_loadGroupPosition());
    for (final extra in _extraOperations) {
      unawaited(_loadExtraGroupPosition(extra));
    }
  }

  Future<void> _openPositionScanner() => _openScannerRoute(
    target: _scanTarget,
    forPosition: true,
    title: 'Quét nhãn vị trí / máy',
    subtitle: 'Đưa nhãn dán trên máy vào khung hình.',
    onManualInput: _enterPositionManually,
  );

  Future<void> _enterPositionManually() async {
    setState(() => _isDialogOpen = true);
    final value = await showManualSlotDialog(context);
    if (!mounted) return;
    setState(() => _isDialogOpen = false);
    if (value == null || value.trim().isEmpty) return;
    await _handleScan(value.trim(), forPosition: true);
  }

  bool _rejectScan(String message) {
    if (mounted) setState(() => _scanError = message);
    return false;
  }

  // ------------------------------------------------------ several operations

  List<Map<String, dynamic>> get _allOrders => [
    ?_selectedOrder,
    for (final extra in _extraOperations) extra.order,
  ];

  bool get _anyQuantitiesLoading =>
      _quantitiesLoading || _extraOperations.any((extra) => extra.loading);

  /// The lowest remaining quantity among the chosen operations, with the
  /// operation it comes from. One quantity is given on every operation, so
  /// the tightest one sets the ceiling. An operation whose total is unknown
  /// (older labels) cannot set one; SAP stays the judge for it.
  ({double remaining, String orderId, String name})? get _quantityLimit {
    ({double remaining, String orderId, String name})? limit;
    void consider(Map<String, dynamic> order, Map<String, double> quantities) {
      final total = quantities['operationQuantity'] ?? 0;
      final remaining = quantities['remaining'];
      if (total <= 0 || remaining == null) return;
      if (limit == null || remaining < limit!.remaining) {
        limit = (
          remaining: remaining,
          orderId: order['id']?.toString() ?? '',
          name: _operationDisplayName(order),
        );
      }
    }

    if (_selectedOrder != null) consider(_selectedOrder!, _operationQuantities);
    for (final extra in _extraOperations) {
      consider(extra.order, extra.quantities);
    }
    return limit;
  }

  /// The warning under an operation card once the quantity typed would take
  /// what is given on that operation past the operation's own quantity. It
  /// follows the quantity field as it is edited; an operation whose total is
  /// unknown (older labels) is never warned about.
  Widget _operationOverLimitWarning(Map<String, double> quantities) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _qtyController,
      builder: (context, value, _) {
        final entered = parseLocalizedQuantity(value.text);
        final total = quantities['operationQuantity'] ?? 0;
        final remaining = quantities['remaining'];
        if (entered == null ||
            entered <= 0 ||
            total <= 0 ||
            remaining == null ||
            entered <= remaining) {
          return const SizedBox.shrink();
        }
        return const Padding(
          padding: EdgeInsets.only(top: CaslaSpacing.xs),
          child: _InlineWarning(text: _overLimitWarning),
        );
      },
    );
  }

  static const _overLimitWarning =
      'Tổng số lượng giao vượt quá số lượng công đoạn.';

  String _collapsedOperationLine(
    Map<String, double> quantities, {
    required bool loading,
  }) {
    final remaining = quantities['remaining'];
    if (remaining == null) {
      return loading ? 'Đang cập nhật số lượng…' : 'Chưa có số còn lại';
    }
    final uom = _selectedUom;
    return 'Còn lại ${formatQuantity(remaining, uom: uom)} $uom'.trim();
  }

  /// `công đoạn May thân`, or the fallback name as it is (`Công đoạn 0020`),
  /// so a sentence never reads "công đoạn Công đoạn 0020".
  String _operationPhrase(Map<String, dynamic> order, {bool capital = false}) {
    final name = _operationDisplayName(order);
    if (name.toLowerCase().startsWith('công đoạn')) return name;
    return '${capital ? 'Công đoạn' : 'công đoạn'} $name';
  }

  /// Bộ phận printed on the operation label; empty when the label has none.
  String _operationDepartment(Map<String, dynamic> order) {
    final payload = order['operation_qr_payload']?.toString() ?? '';
    return _operationDepartments.putIfAbsent(
      payload,
      () => OperationQrParser.parse(payload).boPhan.trim(),
    );
  }

  /// An operation of another department than the selected work session is
  /// allowed; the supervisor is told and confirms before sending.
  String? _sessionDepartmentWarning(Map<String, dynamic> order) {
    final selected =
        ref.read(appStateProvider).activeWorkContext?.boPhan.trim() ?? '';
    final department = _operationDepartment(order);
    if (department.isEmpty ||
        selected.isEmpty ||
        vietnameseLabelsEqual(department, selected)) {
      return null;
    }
    return '${_operationPhrase(order, capital: true)} thuộc bộ phận '
        '"$department", còn ca đang chọn thuộc bộ phận "$selected".';
  }

  void _selectAddOperationTarget() {
    if (_isSubmitting || _isProcessingScan || _scanRouteOpen) return;
    if (_selectedOrder == null) return;
    FocusScope.of(context).unfocus();
    _scanListenerKey.currentState?.resetDeduplication();
    setState(() {
      _addOperationTarget = true;
      _positionTarget = false;
      _scanTarget = ScannedCodeKind.operation;
      _scanError = null;
    });
  }

  Future<bool> _applyExtraOperationScan(OperationQrResult operationQr) async {
    final scopeMismatch = _operationScopeMismatch(operationQr);
    if (scopeMismatch != null) return _rejectScan(scopeMismatch);
    final order = await ref
        .read(appStateProvider)
        .db
        .upsertOrderFromOperationQr(operationQr);
    if (!mounted) return false;
    if (order == null) {
      return _rejectScan('Không lưu được công đoạn từ mã QR vừa quét.');
    }
    return _addExtraOrder(order);
  }

  /// Why [order] cannot be given together with [primary]; null when it can.
  String? _extraOperationRefusal(
    Map<String, dynamic> order,
    Map<String, dynamic> primary,
  ) {
    String field(Map<String, dynamic> row, String key) =>
        row[key]?.toString().trim() ?? '';
    final name = _operationPhrase(order);
    // One quantity serves every operation, so they must count in one unit.
    final uom = field(order, 'uom');
    final primaryUom = field(primary, 'uom');
    if (uom.toUpperCase() != primaryUom.toUpperCase()) {
      return 'Không thêm được: $name tính theo '
          '${uom.isEmpty ? 'đơn vị khác' : uom}, khác đơn vị '
          '${primaryUom.isEmpty ? 'của' : '$primaryUom của'} các công đoạn '
          'đã chọn.';
    }
    final workCenter = field(order, 'work_center');
    final primaryWorkCenter = field(primary, 'work_center');
    if (workCenter.isNotEmpty &&
        primaryWorkCenter.isNotEmpty &&
        workCenter.toUpperCase() != primaryWorkCenter.toUpperCase()) {
      return 'Không thêm được: $name thuộc Xưởng "$workCenter", '
          'khác Xưởng "$primaryWorkCenter" của các công đoạn đã chọn.';
    }
    return null;
  }

  bool _addExtraOrder(Map<String, dynamic> order) {
    final primary = _selectedOrder;
    if (primary == null) return false;
    final id = order['id']?.toString() ?? '';
    if (_allOrders.any((existing) => existing['id']?.toString() == id)) {
      return _rejectScan(
        '${_operationPhrase(order, capital: true)} đã có trong danh sách.',
      );
    }
    final refusal = _extraOperationRefusal(order, primary);
    if (refusal != null) return _rejectScan(refusal);

    final extra = _ExtraOperation(order);
    setState(() {
      // The card just scanned opens; the earlier ones fold so the form
      // stays short.
      _primaryExpanded = false;
      for (final other in _extraOperations) {
        other.expanded = false;
      }
      _extraOperations.add(extra);
      _scanError = null;
    });
    _scanListenerKey.currentState?.resetDeduplication();
    unawaited(_loadExtraQuantities(extra));
    unawaited(_loadExtraGroupPosition(extra));
    return true;
  }

  void _removeExtraOperation(_ExtraOperation extra) {
    setState(() {
      _extraOperations.remove(extra);
      if (_extraOperations.isEmpty) _primaryExpanded = true;
    });
  }

  /// After the first operation changed: an extra that is now that same
  /// operation, or no longer shares its unit or Work Center, cannot stay.
  /// Call inside the setState that changes [_selectedOrder].
  void _reconcileExtrasWithPrimary() {
    final primary = _selectedOrder;
    if (primary == null) return;
    final primaryId = primary['id']?.toString() ?? '';
    _extraOperations.removeWhere(
      (extra) =>
          extra.id == primaryId ||
          _extraOperationRefusal(extra.order, primary) != null,
    );
    if (_extraOperations.isEmpty) _primaryExpanded = true;
  }

  /// Removing the first operation promotes the next one, so the rest of the
  /// list is not lost with it.
  void _clearPrimaryOperation() {
    setState(() {
      ++_quantityRequest;
      _quantitiesLoading = false;
      _scanError = null;
      if (_extraOperations.isEmpty) {
        _selectedOrder = null;
        _operationQuantities = const {};
        _addOperationTarget = false;
        return;
      }
      final next = _extraOperations.removeAt(0);
      _selectedOrder = next.order;
      _operationQuantities = next.quantities;
      _groupPositionId = next.groupPositionId;
      _lastOperationHistory = null;
      _lastHistoryOrderId = null;
      _primaryExpanded = _extraOperations.isEmpty || next.expanded;
    });
    final promoted = _selectedOrder;
    if (promoted != null) unawaited(_loadOperationQuantities(promoted));
  }

  /// Quantities of an operation added with (+): SAP's live balance when it
  /// answers, the day's history otherwise, the local summary as a floor.
  Future<void> _loadExtraQuantities(_ExtraOperation extra) async {
    final order = extra.order;
    final id = extra.id;
    if (id.isEmpty) return;
    final request = ++extra.request;
    bool isCurrent() =>
        mounted && _extraOperations.contains(extra) && request == extra.request;
    if (mounted) setState(() => extra.loading = true);
    final appState = ref.read(appStateProvider);
    Map<String, double> local = const {};
    try {
      local = await appState.db.getOperationQuantitySummary(orderId: id);
    } catch (_) {
      // SAP can still fill the card.
    }
    if (isCurrent() && extra.quantities.isEmpty) {
      setState(() => extra.quantities = local);
    }
    try {
      final productionOrder =
          order['production_order']?.toString().trim() ?? '';
      final operation = order['operation']?.toString().trim() ?? '';
      if (productionOrder.isEmpty || operation.isEmpty) return;
      final workId = appState.activeWorkContext?.workId;
      final shift = appState.activeShift;
      final date = appState.activeBusinessDate;
      final live = await _loadLiveOperationQuantities(
        order: order,
        productionOrder: productionOrder,
        operation: operation,
        workId: workId,
        shiftId: shift?.shiftId,
        fallbackOperationQuantity: local['operationQuantity'] ?? 0,
      );
      if (live != null) {
        if (isCurrent()) setState(() => extra.quantities = live);
        return;
      }
      if (!isCurrent()) return;
      final remote = await appState.workHistoryRepo.getWorkHistory(
        range: HistoryRange.day,
        dateFrom: date,
        dateTo: date,
        shiftId: shift?.shiftId,
        workId: workId,
        productionOrder: productionOrder,
        operation: operation,
        forceRefresh: true,
      );
      if (!isCurrent()) return;
      final merged = await _mergeOperationQuantities(
        remote,
        order: order,
        operationQuantity: local['operationQuantity'] ?? 0,
        workId: workId,
        businessDate: date,
        shiftId: shift?.shiftId,
      );
      if (isCurrent()) setState(() => extra.quantities = merged);
    } catch (_) {
      // Keep the local snapshot; SAP validates the write either way.
    } finally {
      if (isCurrent()) setState(() => extra.loading = false);
    }
  }

  Future<void> _openAddOperationScanner() => _openScannerRoute(
    target: ScannedCodeKind.operation,
    addOperation: true,
    title: 'Quét thêm công đoạn',
    subtitle: 'Đưa mã QR của công đoạn cần giao thêm vào khung hình.',
    onManualInput: () => _pickOrder(asExtra: true),
  );

  /// One assignment per operation behind a single password prompt. SAP takes
  /// them one at a time, so each gets its own outcome. Returns true when at
  /// least one was saved.
  Future<bool> _submitSeveral({
    required List<Map<String, dynamic>> orders,
    required double quantity,
    required Future<MutationReceipt> Function(
      Map<String, dynamic> order,
      String workerPassword,
    )
    create,
  }) async {
    final workerName = _selectedWorker!['ten'] as String? ?? 'Công nhân';
    final uom = _selectedUom;
    final run = await runWithWorkerPassword<List<_OperationOutcome>>(
      context,
      workerName: workerName,
      actionLabel: 'gửi ${orders.length} phân công lên SAP',
      // Only the first write can prove the password wrong. Once one is saved,
      // asking again would post it a second time.
      isWrongPassword: (outcomes) =>
          outcomes.length == 1 &&
          outcomes.single.receipt?.isWrongWorkerPassword == true,
      submit: (workerPassword) async {
        final outcomes = <_OperationOutcome>[];
        for (final order in orders) {
          try {
            final receipt = await create(order, workerPassword);
            outcomes.add(_OperationOutcome(order, receipt: receipt));
            if (receipt.isWrongWorkerPassword) break;
          } on Exception catch (error) {
            // Nothing saved yet: let the form report it as it always has.
            if (outcomes.every((outcome) => !outcome.saved)) rethrow;
            outcomes.add(
              _OperationOutcome(order, error: friendlySapErrorMessage(error)),
            );
          }
        }
        return outcomes;
      },
    );
    if (!mounted || run.cancelled) return false;
    if (run.exhausted) {
      setState(() {
        _selectedWorker = null;
        _resetPositionState();
        _scanTarget = ScannedCodeKind.worker;
        _addOperationTarget = false;
      });
      _scanListenerKey.currentState?.resetDeduplication();
      return false;
    }
    final outcomes = run.result!;
    final savedAny = outcomes.any((outcome) => outcome.saved);
    final names = {
      for (final outcome in outcomes)
        outcome: _operationDisplayName(outcome.order),
    };
    // Clear before reporting, as for a single assignment: a form still
    // holding the sent values invites a double send.
    if (savedAny) _resetAfterSubmit();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _BatchResultDialog(
        outcomes: outcomes,
        names: names,
        summary:
            'Mỗi công đoạn ${formatQuantity(quantity, uom: uom)} $uom cho '
            '$workerName.',
      ),
    );
    return savedAny;
  }

  String? _operationScopeMismatch(
    OperationQrResult qr, {
    String source = 'scan',
  }) {
    final selected = ref.read(appStateProvider).activeWorkContext;
    logScanPayload(
      jsonEncode({
        'production_order': qr.productionOrder,
        'operation': qr.operation,
        'qr': {'work_center': qr.workCenter, 'bo_phan': qr.boPhan},
        'selected': {
          'work_id': selected?.workId,
          'work_center': selected?.workCenter,
          'bo_phan': selected?.boPhan,
        },
      }),
      source: 'assignment-scope-$source',
    );
    if (selected == null) return null;

    final qrWorkCenter = qr.workCenter.trim();
    final selectedWorkCenter = selected.workCenter.trim();
    if (qrWorkCenter.isNotEmpty && selectedWorkCenter.isNotEmpty) {
      if (qrWorkCenter.toLowerCase() != selectedWorkCenter.toLowerCase()) {
        return 'QR thuộc Xưởng "$qrWorkCenter", còn ca đang chọn thuộc Xưởng "$selectedWorkCenter".';
      }
    }
    // Another department within the same Work Center no longer stops the
    // scan: it is shown as a warning and confirmed before sending, see
    // [_sessionDepartmentWarning].
    return null;
  }

  String? _savedOperationScopeMismatch(Map<String, dynamic> order) =>
      _operationScopeMismatch(
        OperationQrParser.parse(
          order['operation_qr_payload']?.toString() ?? '',
        ),
        source: 'selected-cache',
      );

  Future<void> _changeShift() async {
    await context.push('/supervisor-setup', extra: true);
    if (!mounted || _selectedOrder == null) return;
    final scopeMismatch = _savedOperationScopeMismatch(_selectedOrder!);
    if (scopeMismatch != null) {
      ++_quantityRequest;
      setState(() {
        _selectedOrder = null;
        // Extras share the first operation's Work Center, so they go too.
        _extraOperations.clear();
        _primaryExpanded = true;
        _addOperationTarget = false;
        _operationQuantities = const {};
        _quantitiesLoading = false;
        _scanError = scopeMismatch;
      });
      return;
    }
    unawaited(_loadOperationQuantities(_selectedOrder!));
    for (final extra in _extraOperations) {
      unawaited(_loadExtraQuantities(extra));
    }
  }

  Future<bool> _applyOperationScan(OperationQrResult operationQr) async {
    final scopeMismatch = _operationScopeMismatch(operationQr);
    if (scopeMismatch != null) return _rejectScan(scopeMismatch);

    final order = await ref
        .read(appStateProvider)
        .db
        .upsertOrderFromOperationQr(operationQr);
    if (!mounted) return false;
    if (order == null) {
      return _rejectScan('Không lưu được công đoạn từ mã QR vừa quét.');
    }

    // The operation is on screen: move straight on to the worker card so the
    // next scan needs no tap. With a worker already chosen, leave the target
    // alone — the operator is likely correcting the operation.
    final moveToWorker = _selectedWorker == null;
    setState(() {
      _selectedOrder = order;
      _reconcileExtrasWithPrimary();
      _lastOperationHistory = null;
      _lastHistoryOrderId = null;
      _operationQuantities = const {};
      _scanError = null;
      if (moveToWorker) _scanTarget = ScannedCodeKind.worker;
    });
    if (moveToWorker) _scanListenerKey.currentState?.resetDeduplication();
    unawaited(_loadOperationQuantities(order));
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
          _onWorkerSelected(worker);
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
    required ScannedCodeKind target,
    required String title,
    required String subtitle,
    required Future<void> Function() onManualInput,
    bool forPosition = false,
    bool addOperation = false,
  }) async {
    if (_scanRouteOpen || _isSubmitting || _isProcessingScan) return;
    if (forPosition) {
      _selectPositionTarget();
    } else if (addOperation) {
      _selectAddOperationTarget();
    } else {
      _selectScanTarget(target);
    }
    setState(() => _scanRouteOpen = true);
    String? routeError;
    try {
      final route = MaterialPageRoute<bool>(
        builder: (routeContext) => StatefulBuilder(
          builder: (routeContext, setRouteState) => Scaffold(
            body: Stack(
              children: [
                AdaptiveBarcodeScannerView(
                  title: title,
                  subtitle: subtitle,
                  hardwareScanner: widget.scanner,
                  preferences: widget.scannerPreferences,
                  onManualInput: () {
                    if (ModalRoute.of(routeContext)?.isCurrent != true ||
                        _isProcessingScan) {
                      return;
                    }
                    Navigator.of(routeContext).pop(true);
                  },
                  onScan: (code) async {
                    if (!routeContext.mounted ||
                        ModalRoute.of(routeContext)?.isCurrent != true ||
                        _isSubmitting ||
                        _isProcessingScan) {
                      return false;
                    }
                    setRouteState(() => routeError = null);
                    final accepted = await _handleScan(
                      code,
                      expectedKind: forPosition ? null : target,
                      forPosition: forPosition,
                    );
                    if (!routeContext.mounted ||
                        ModalRoute.of(routeContext)?.isCurrent != true) {
                      return accepted;
                    }
                    if (accepted) {
                      Navigator.pop(routeContext);
                    } else {
                      setRouteState(
                        () => routeError =
                            _scanError ?? 'Chưa nhận được mã. Hãy quét lại.',
                      );
                    }
                    return accepted;
                  },
                ),
                if (routeError != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    top: MediaQuery.paddingOf(routeContext).top + 64,
                    child: ScanErrorBanner(
                      message: routeError!,
                      onDismiss: () => setRouteState(() => routeError = null),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      final openManual = await Navigator.of(context).push(route);
      // Release the camera route before showing a keyboard or another camera.
      await route.completed;
      if (mounted && openManual == true) await onManualInput();
    } catch (_) {
      if (mounted) {
        await _showAssignmentError(
          'Chưa mở được danh sách trên thiết bị. Vui lòng thử lại.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _scanRouteOpen = false);
        _scanListenerKey.currentState?.resetDeduplication();
      }
    }
  }

  Future<void> _openWorkerScanner() => _openScannerRoute(
    target: ScannedCodeKind.worker,
    title: 'Quét mã QR công nhân',
    subtitle: 'Đưa thẻ nhân viên vào khung hình.',
    onManualInput: _pickWorker,
  );

  Future<void> _pickWorker() async {
    final appState = ref.read(appStateProvider);
    final workers = await appState.db.getWorkersForManualSelection(
      appState.currentSession?.toIds ?? const <String>[],
    );
    if (!mounted) return;

    final worker = await showSearchablePicker(
      context,
      title: 'Chọn công nhân',
      searchHint: 'Tìm theo tên hoặc mã nhân viên',
      emptyMessage:
          'Chưa có nhân viên đã lưu trên máy. Hãy quét thẻ nhân viên để lưu và chọn lại lần sau.',
      items: workers,
      itemTitle: (item) => item['ten']?.toString() ?? 'Công nhân',
      itemSubtitle: (item) {
        final boPhan = item['bo_phan']?.toString().trim();
        final team =
            (boPhan != null &&
                boPhan.isNotEmpty &&
                boPhan != 'Công nhân sản xuất')
            ? boPhan
            : (appState.activeWorkContext?.workName.trim().isNotEmpty == true
                  ? appState.activeWorkContext!.workName.trim()
                  : (appState.activeWorkContext?.boPhan.trim().isNotEmpty ==
                            true
                        ? appState.activeWorkContext!.boPhan.trim()
                        : 'Tổ làm việc'));
        return [item['ma_nv'], team].whereType<Object>().join(' · ');
      },
      searchableText: (item) {
        final boPhan = item['bo_phan']?.toString().trim();
        final team =
            (boPhan != null &&
                boPhan.isNotEmpty &&
                boPhan != 'Công nhân sản xuất')
            ? boPhan
            : (appState.activeWorkContext?.workName.trim().isNotEmpty == true
                  ? appState.activeWorkContext!.workName.trim()
                  : (appState.activeWorkContext?.boPhan.trim().isNotEmpty ==
                            true
                        ? appState.activeWorkContext!.boPhan.trim()
                        : ''));
        return [item['ten'], item['ma_nv'], team].whereType<Object>().join(' ');
      },
    );
    if (!mounted || worker == null) return;

    setState(() {
      _selectedWorker = worker;
      _scanError = null;
    });
    _onWorkerSelected(worker);
  }

  /// `LSX 010140000365 · CĐ 0100` over `200009410 · Xưởng May 2 viền Casla`:
  /// the same product can sit on several orders/operations, so the SAP keys
  /// tell the rows apart. Blank fields are dropped instead of leaving a `·`.
  static String _orderPickerSubtitle(Map<String, dynamic> item) {
    String field(String key) => item[key]?.toString().trim() ?? '';
    final order = field('production_order');
    final operation = field('operation');
    final keys = [
      if (order.isNotEmpty) 'LSX $order',
      if (operation.isNotEmpty) 'CĐ $operation',
    ].join(' · ');
    final product = [
      field('ma_sp'),
      field('dac_tinh'),
    ].where((value) => value.isNotEmpty).join(' · ');
    return [keys, product].where((line) => line.isNotEmpty).join('\n');
  }

  Future<void> _pickOrder({bool asExtra = false}) async {
    final openOrders = await ref.read(appStateProvider).db.getOpenOrders();
    if (!mounted) return;

    final order = await showSearchablePicker(
      context,
      title: 'Chọn sản phẩm',
      searchHint: 'Tìm theo sản phẩm hoặc mã hàng',
      emptyMessage:
          'Chưa có đơn hàng mở trên thiết bị. Ứng dụng cần dịch vụ danh mục SAP để tải dữ liệu mới.',
      items: openOrders,
      itemTitle: (item) => item['ten_sp']?.toString() ?? 'Sản phẩm',
      itemSubtitle: _orderPickerSubtitle,
      searchableText: (item) => [
        item['ten_sp'],
        item['ma_sp'],
        item['ma_qr'],
        item['dac_tinh'],
        item['production_order'],
        item['operation'],
      ].whereType<Object>().join(' '),
    );
    if (!mounted || order == null) return;
    final scopeMismatch = _savedOperationScopeMismatch(order);
    if (scopeMismatch != null) {
      _rejectScan(scopeMismatch);
      return;
    }
    if (asExtra) {
      _addExtraOrder(order);
      return;
    }

    setState(() {
      _selectedOrder = order;
      _reconcileExtrasWithPrimary();
      _lastOperationHistory = null;
      _lastHistoryOrderId = null;
      _operationQuantities = const {};
      _scanError = null;
    });
    unawaited(_loadOperationQuantities(order));
  }

  // -------------------------------------------------------------- submission

  Future<void> _showAssignmentError(String message) async {
    if (!mounted) return;
    final wasDialogOpen = _isDialogOpen;
    setState(() => _isDialogOpen = true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Chưa thể phân công'),
          content: SingleChildScrollView(child: Text(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Đã hiểu'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _isDialogOpen = wasDialogOpen);
    }
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
      _resetPositionState();
      _qtyController.clear();
      _noteController.clear();
      _quantityError = null;
      _scanError = null;
      if (!_keepProductAfterSubmit) {
        _selectedOrder = null;
        _extraOperations.clear();
        _primaryExpanded = true;
      }
      _addOperationTarget = false;
      // Kept product: the next card to scan is the next worker's.
      _scanTarget = _selectedOrder == null
          ? ScannedCodeKind.operation
          : ScannedCodeKind.worker;
    });
    _scanListenerKey.currentState?.resetDeduplication();
    if (_selectedOrder != null) {
      unawaited(_loadOperationQuantities(_selectedOrder!));
    }
    for (final extra in _extraOperations) {
      unawaited(_loadExtraQuantities(extra));
    }
  }

  Future<void> _submitAssignment() =>
      ref.read(appStateProvider).runCriticalOperation(_submitAssignmentNow);

  Future<void> _submitAssignmentNow() async {
    if (_isSubmitting || _isDialogOpen || _anyQuantitiesLoading) return;
    FocusScope.of(context).unfocus();

    if (_selectedOrder == null) {
      await _showAssignmentError('Hãy quét hoặc chọn mã công đoạn / sản phẩm.');
      return;
    }
    for (final order in _allOrders) {
      final scopeMismatch = _savedOperationScopeMismatch(order);
      if (scopeMismatch != null) {
        await _showAssignmentError(scopeMismatch);
        return;
      }
    }
    if (_selectedWorker == null) {
      await _showAssignmentError(
        'Hãy quét thẻ công nhân hoặc chọn trong danh sách.',
      );
      return;
    }

    final qty = parseLocalizedQuantity(_qtyController.text) ?? 0.0;
    if (!qty.isFinite || qty <= 0) {
      setState(
        () => _quantityError = 'Số lượng giao phải là một số dương hợp lệ.',
      );
      await _showAssignmentError(_quantityError!);
      return;
    }
    final wholeError = wholeQuantityInputError(
      _qtyController.text,
      _selectedUom,
    );
    if (wholeError != null) {
      setState(() => _quantityError = wholeError);
      await _showAssignmentError(wholeError);
      return;
    }
    // More than what is left on the operation may be given: the form warns
    // under the field and SAP stays the judge of the total.
    setState(() => _quantityError = null);

    // One position per assignment group: checked against SAP again now, so a
    // top-up cannot move the work to another machine or drop its position.
    setState(() => _isSubmitting = true);
    String? positionConflict;
    try {
      String? conflict(Map<String, dynamic> order, String? groupPosition) =>
          groupPositionConflict(
            groupPositionId: groupPosition,
            selectedPositionId: _positionId,
            productionOrder: order['production_order']?.toString() ?? '',
            operation: order['operation']?.toString() ?? '',
          );
      final primary = _selectedOrder!;
      positionConflict = conflict(
        primary,
        await _loadGroupPosition(force: true),
      );
      for (final extra in List.of(_extraOperations)) {
        if (positionConflict != null) break;
        positionConflict = conflict(
          extra.order,
          await _loadExtraGroupPosition(extra, force: true),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
    if (!mounted || _selectedOrder == null || _selectedWorker == null) return;
    if (positionConflict != null) {
      await _showAssignmentError(positionConflict);
      return;
    }

    // Department differences only warn, on the form itself: the lines under
    // the operation and the worker. Sending is not interrupted for them.
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
    final qrWorkCenter =
        _selectedOrder!['work_center']?.toString().trim() ?? '';
    if (activeShift == null) {
      await _showAssignmentError('Chưa chọn ca làm việc.');
      return;
    }
    // SAP resolves the shift by the operation's Work Center + ShiftID.
    if (qrWorkCenter.isNotEmpty && activeShift.workCenter != qrWorkCenter) {
      await _showAssignmentError(
        'Ca đang chọn thuộc Xưởng ${activeShift.workCenter}, '
        'nhưng mã công đoạn thuộc Xưởng $qrWorkCenter. '
        'Hãy đổi Xưởng và ca cho đúng.',
      );
      return;
    }
    if (scannedContext != null &&
        appState.activeWorkContext?.workId != scannedContext.workId) {
      await _showAssignmentError(
        'Mã công đoạn thuộc Xưởng ${scannedContext.workCenter}. '
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
      final shiftError = validateShiftExecution(
        shift: activeShift,
        businessDate: DateTime.parse(dateFormatted),
        executedAt: widget.now?.call() ?? DateTime.now(),
      );
      if (shiftError != null) throw Exception(shiftError);
      if (_extraOperations.isNotEmpty) {
        final note = _noteController.text.trim();
        final saved = await _submitSeveral(
          orders: _allOrders,
          quantity: qty,
          create: (order, workerPassword) {
            final latestShiftError = validateShiftExecution(
              shift: activeShift,
              businessDate: DateTime.parse(dateFormatted),
              executedAt: widget.now?.call() ?? DateTime.now(),
            );
            if (latestShiftError != null) throw Exception(latestShiftError);
            if (!appState.isSessionGenerationCurrent(generation)) {
              throw Exception(
                'Phiên đăng nhập đã thay đổi. Vui lòng mở lại thao tác.',
              );
            }
            return appState.assignmentRepo.createAssignment(
              workerId: workerId,
              orderId: order['id'] as String,
              teamId: toId,
              assignedQuantity: qty,
              businessDate: dateFormatted,
              shiftId: activeShift.shiftId,
              note: note.isEmpty ? null : note,
              createdBy: createdBy,
              workerPassword: workerPassword,
              positionId: _positionId,
              machineId: _machineId,
            );
          },
        );
        if (!saved) return;
      } else {
        final run = await runWithWorkerPassword<MutationReceipt>(
          context,
          workerName: _selectedWorker!['ten'] as String? ?? 'Công nhân',
          actionLabel: 'gửi phân công lên SAP',
          isWrongPassword: (receipt) => receipt.isWrongWorkerPassword,
          submit: (workerPassword) {
            final latestShiftError = validateShiftExecution(
              shift: activeShift,
              businessDate: DateTime.parse(dateFormatted),
              executedAt: widget.now?.call() ?? DateTime.now(),
            );
            if (latestShiftError != null) throw Exception(latestShiftError);
            if (!appState.isSessionGenerationCurrent(generation)) {
              throw Exception(
                'Phiên đăng nhập đã thay đổi. Vui lòng mở lại thao tác.',
              );
            }
            return appState.assignmentRepo.createAssignment(
              workerId: workerId,
              orderId: orderId,
              teamId: toId,
              assignedQuantity: qty,
              businessDate: dateFormatted,
              shiftId: activeShift.shiftId,
              note: _noteController.text.trim().isEmpty
                  ? null
                  : _noteController.text.trim(),
              createdBy: createdBy,
              workerPassword: workerPassword,
              positionId: _positionId,
              machineId: _machineId,
            );
          },
        );

        if (!mounted || run.cancelled) return;
        if (run.exhausted) {
          // Three wrong passwords: the notice is up and the popup has closed.
          // Drop the scanned worker so the next attempt starts from the card.
          setState(() {
            _selectedWorker = null;
            _resetPositionState();
            _scanTarget = ScannedCodeKind.worker;
          });
          _scanListenerKey.currentState?.resetDeduplication();
          return;
        }
        final receipt = run.result!;
        if (receipt.state == MutationDeliveryState.discarded) {
          // SAP answered with an error and nothing was saved, so keep the form
          // for a correction instead of re-typing the whole assignment.
          await showMutationFeedback(
            context,
            receipt: receipt,
            persistNonSuccess: true,
            successMessage: '',
          );
          return;
        }
        final workerName = _selectedWorker!['ten'];
        final submittedUom = _selectedUom;
        // Clear before reporting: the report can open a dialog, and coming back
        // to a form still holding the submitted values invites a double send.
        _resetAfterSubmit();
        await showMutationFeedback(
          context,
          receipt: receipt,
          persistNonSuccess: true,
          successMessage: 'Đã giao $qty $submittedUom cho $workerName.',
        );
      }
    } on Exception catch (e) {
      if (!mounted) return;
      await _showAssignmentError(friendlySapErrorMessage(e));
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
      enabled: !_isSubmitting && !_isDialogOpen && !_scanRouteOpen,
      child: Scaffold(
        backgroundColor: CaslaColors.background,
        appBar: AppBar(
          actions: const [AccountAvatarButton()],
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
                'Chọn đúng ô rồi bấm quét',
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
              if (!_scanRouteOpen && _scanError != null)
                ScanErrorBanner(
                  message: _scanError!,
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
                        dense: true,
                        onEdit: _changeShift,
                      ),
                      const SizedBox(height: CaslaSpacing.md),

                      ScanSlotField(
                        isScanTarget:
                            !_positionTarget &&
                            !_addOperationTarget &&
                            _scanTarget == ScannedCodeKind.operation,
                        onSelect: () =>
                            _selectScanTarget(ScannedCodeKind.operation),
                        label: 'Sản phẩm / công đoạn',
                        required: true,
                        icon: Icons.inventory_2_outlined,
                        value: _selectedOrder == null
                            ? null
                            : _operationDisplayName(_selectedOrder),
                        // One operation looks exactly as before. With several,
                        // the card can fold down to its remaining quantity.
                        detail:
                            _selectedOrder != null &&
                                _extraOperations.isNotEmpty &&
                                !_primaryExpanded
                            ? _collapsedOperationLine(
                                _operationQuantities,
                                loading: _quantitiesLoading,
                              )
                            : null,
                        detailLines: null,
                        trailing:
                            _selectedOrder == null || _extraOperations.isEmpty
                            ? null
                            : _OperationCardTrailing(
                                isLimit:
                                    _quantityLimit?.orderId ==
                                    _selectedOrder!['id']?.toString(),
                                expanded: _primaryExpanded,
                                onToggle: () => setState(
                                  () => _primaryExpanded = !_primaryExpanded,
                                ),
                              ),
                        filledContent:
                            _selectedOrder == null ||
                                (_extraOperations.isNotEmpty &&
                                    !_primaryExpanded)
                            ? null
                            : _OperationSummary(
                                order: _selectedOrder!,
                                quantities: _operationQuantities,
                                loading: _quantitiesLoading,
                                uom: _selectedUom,
                              ),
                        placeholder: 'Chưa chọn công đoạn',
                        onOpenScanner: () => _openScannerRoute(
                          target: ScannedCodeKind.operation,
                          title: 'Quét mã sản phẩm / công đoạn',
                          subtitle:
                              'Đưa mã QR trên lô sản phẩm hoặc thẻ đơn hàng vào khung hình.',
                          onManualInput: _pickOrder,
                        ),
                        onClear: _selectedOrder == null
                            ? null
                            : _clearPrimaryOperation,
                      ),
                      if (_selectedOrder != null) ...[
                        _operationOverLimitWarning(_operationQuantities),
                        if (_sessionDepartmentWarning(_selectedOrder!)
                            case final warning?)
                          Padding(
                            padding: const EdgeInsets.only(
                              top: CaslaSpacing.xs,
                            ),
                            child: _InlineWarning(
                              text: '$warning Vẫn giao được.',
                            ),
                          ),
                        for (final extra in _extraOperations) ...[
                          const SizedBox(height: CaslaSpacing.xs),
                          _ExtraOperationCard(
                            name: _operationDisplayName(extra.order),
                            expanded: extra.expanded,
                            isLimit: _quantityLimit?.orderId == extra.id,
                            collapsedLine: _collapsedOperationLine(
                              extra.quantities,
                              loading: extra.loading,
                            ),
                            summary: _OperationSummary(
                              order: extra.order,
                              quantities: extra.quantities,
                              loading: extra.loading,
                              uom: _selectedUom,
                            ),
                            onToggle: () => setState(
                              () => extra.expanded = !extra.expanded,
                            ),
                            onRemove: () => _removeExtraOperation(extra),
                          ),
                          _operationOverLimitWarning(extra.quantities),
                          if (_sessionDepartmentWarning(extra.order)
                              case final warning?)
                            Padding(
                              padding: const EdgeInsets.only(
                                top: CaslaSpacing.xs,
                              ),
                              child: _InlineWarning(
                                text: '$warning Vẫn giao được.',
                              ),
                            ),
                        ],
                        const SizedBox(height: CaslaSpacing.xs),
                        _AddOperationButton(
                          isTarget: _addOperationTarget,
                          onTap: _selectAddOperationTarget,
                          onOpenScanner: _openAddOperationScanner,
                        ),
                      ],
                      const SizedBox(height: CaslaSpacing.sm),

                      ScanSlotField(
                        isScanTarget:
                            !_positionTarget &&
                            _scanTarget == ScannedCodeKind.worker,
                        onSelect: () =>
                            _selectScanTarget(ScannedCodeKind.worker),
                        label: 'Công nhân',
                        required: true,
                        icon: Icons.badge_outlined,
                        value: _selectedWorker?['ten']?.toString(),
                        detail: null,
                        detailLines: null,
                        filledContent: _selectedWorker == null
                            ? null
                            : _WorkerSummary(worker: _selectedWorker!),
                        placeholder: 'Chưa chọn công nhân',
                        onOpenScanner: _openWorkerScanner,
                        onClear: _selectedWorker == null
                            ? null
                            : () => setState(() {
                                _selectedWorker = null;
                                _resetPositionState();
                              }),
                      ),
                      const SizedBox(height: CaslaSpacing.sm),

                      PositionSlotField(
                        enabled: _selectedWorker != null,
                        isScanTarget: _positionTarget,
                        onSelect: _selectPositionTarget,
                        onOpenScanner: _openPositionScanner,
                        onClear: _positionId == null ? null : _clearPosition,
                        positionId: _positionId,
                        machineId: _machineId,
                        source: _positionSource,
                        lookup: _positionLookup,
                        originPositionId: _originSeat?.positionId,
                        onUseOrigin: _originSeat == null
                            ? null
                            : _useOriginPosition,
                        errorText: _positionConflict,
                      ),
                      const SizedBox(height: CaslaSpacing.md),

                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _qtyController,
                        builder: (context, value, _) {
                          final entered = parseLocalizedQuantity(value.text);
                          final several = _extraOperations.isNotEmpty;
                          final limit = _quantityLimit;
                          // One operation shows its own remaining as before;
                          // several show the tightest one.
                          final remaining = several
                              ? limit?.remaining
                              : _operationQuantities['remaining'];
                          final isOverflow =
                              entered != null &&
                              entered > 0 &&
                              limit != null &&
                              entered > limit.remaining;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: CaslaSpacing.xs),
                              const ScanFieldLabel(
                                text: 'Số lượng giao',
                                required: true,
                              ),
                              const SizedBox(height: CaslaSpacing.xs),
                              _RemainingQuantityInline(
                                remaining: remaining,
                                uom: _selectedUom,
                              ),
                              if (several && limit != null)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: CaslaSpacing.xxs,
                                  ),
                                  child: Text(
                                    'Theo công đoạn còn ít nhất: ${limit.name}',
                                    style: const TextStyle(
                                      fontSize: CaslaType.caption,
                                      fontWeight: FontWeight.w600,
                                      color: CaslaColors.pending,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: CaslaSpacing.xs),
                              TextField(
                                controller: _qtyController,
                                focusNode: _qtyFocus,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) =>
                                    FocusScope.of(context).unfocus(),
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
                                  enabledBorder: isOverflow
                                      ? overLimitBorder()
                                      : null,
                                  focusedBorder: isOverflow
                                      ? overLimitBorder(width: 2)
                                      : null,
                                  errorText:
                                      _quantityError ??
                                      wholeQuantityInputError(
                                        value.text,
                                        _selectedUom,
                                      ),
                                  helperText: _qtyFocus.hasFocus
                                      ? 'Đang gõ số — đầu đọc tạm nghỉ.'
                                      : null,
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
                              if (isOverflow)
                                const OverLimitLine(_overLimitWarning),
                              if (several &&
                                  entered != null &&
                                  entered > 0 &&
                                  !isOverflow)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: CaslaSpacing.xxs,
                                  ),
                                  child: Text(
                                    'Mỗi công đoạn giao '
                                    '${formatQuantity(entered, uom: _selectedUom)} '
                                    '$_selectedUom · ${_extraOperations.length + 1} '
                                    'công đoạn.',
                                    style: const TextStyle(
                                      fontSize: CaslaType.caption,
                                      color: CaslaColors.muted,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: CaslaSpacing.md),

                      // Hidden: the business date always follows the shift
                      // setup (activeBusinessDate), which is what submit uses.
                      // Kept behind a flag instead of deleted.
                      if (_showBusinessDateField) ...[
                        const ScanFieldLabel(
                          text: 'Ngày làm việc',
                          required: true,
                        ),
                        const SizedBox(height: CaslaSpacing.xs),
                        // Opens the shift setup rather than pretending to be a
                        // date picker: the business date follows the selected
                        // shift, and a calendar icon on a dead field was a lie.
                        InkWell(
                          onTap: _changeShift,
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
                      ],

                      const ScanFieldLabel(text: 'Ghi chú'),
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
                    onPressed: _isSubmitting || _anyQuantitiesLoading
                        ? null
                        : _submitAssignment,
                    child: _isSubmitting
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: CaslaColors.navy900,
                            ),
                          )
                        : Text(
                            _extraOperations.isEmpty
                                ? 'Xác nhận phân công'
                                : 'Xác nhận phân công · '
                                      '${_extraOperations.length + 1} công đoạn',
                          ),
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

/// A further operation given in the same assignment as the first one.
class _ExtraOperation {
  _ExtraOperation(this.order);

  final Map<String, dynamic> order;
  Map<String, double> quantities = const {};
  bool loading = true;
  bool expanded = true;
  int request = 0;

  /// Where this worker's earlier assignments for the operation were made.
  String? groupPositionId;

  String get id => order['id']?.toString() ?? '';
}

/// What became of one operation of a several-operation assignment.
class _OperationOutcome {
  const _OperationOutcome(this.order, {this.receipt, this.error});

  final Map<String, dynamic> order;
  final MutationReceipt? receipt;
  final String? error;

  /// On the device (and maybe on SAP already). A rolled-back refusal is not.
  bool get saved =>
      receipt != null && receipt!.state != MutationDeliveryState.discarded;

  String get statusText => switch (receipt?.state) {
    null => 'Chưa giao: ${error ?? 'không gửi được.'}',
    MutationDeliveryState.synced => 'Đã gửi SAP',
    MutationDeliveryState.queued => 'Đã lưu, chờ đồng bộ',
    MutationDeliveryState.needsVerification =>
      'Đã lưu, cần xác minh ở mục Đồng bộ',
    MutationDeliveryState.rejected =>
      'SAP từ chối, xem mục Đồng bộ'
          '${receipt!.message == null ? '' : ': ${receipt!.message}'}',
    MutationDeliveryState.discarded =>
      'Chưa giao: ${receipt!.message ?? 'SAP chưa chấp nhận.'}',
  };
}

class _BatchResultDialog extends StatelessWidget {
  final List<_OperationOutcome> outcomes;
  final Map<_OperationOutcome, String> names;
  final String summary;

  const _BatchResultDialog({
    required this.outcomes,
    required this.names,
    required this.summary,
  });

  @override
  Widget build(BuildContext context) {
    final saved = outcomes.where((outcome) => outcome.saved).length;
    final title = saved == outcomes.length
        ? 'Đã giao $saved công đoạn'
        : saved == 0
        ? 'Chưa giao được công đoạn nào'
        : 'Đã giao $saved/${outcomes.length} công đoạn';
    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(summary, style: const TextStyle(color: CaslaColors.muted)),
            const SizedBox(height: CaslaSpacing.sm),
            for (final outcome in outcomes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: CaslaSpacing.xxs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      outcome.saved
                          ? Icons.check_circle_rounded
                          : Icons.cancel_rounded,
                      size: 20,
                      color: outcome.saved
                          ? CaslaColors.success
                          : CaslaColors.danger,
                    ),
                    const SizedBox(width: CaslaSpacing.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            names[outcome] ?? '',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          Text(
                            outcome.statusText,
                            style: TextStyle(
                              fontSize: CaslaType.caption,
                              color: outcome.saved
                                  ? CaslaColors.muted
                                  : CaslaColors.danger,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Đã hiểu'),
        ),
      ],
    );
  }
}

/// "Ít nhất" tag and fold arrow on an operation card.
class _OperationCardTrailing extends StatelessWidget {
  final bool isLimit;
  final bool expanded;
  final VoidCallback onToggle;

  const _OperationCardTrailing({
    required this.isLimit,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isLimit)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            decoration: BoxDecoration(
              color: CaslaColors.surface,
              borderRadius: BorderRadius.circular(CaslaRadius.pill),
              border: Border.all(color: CaslaColors.gold700),
            ),
            child: const Text(
              'Ít nhất',
              style: TextStyle(
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w800,
                color: CaslaColors.gold700,
              ),
            ),
          ),
        IconButton(
          tooltip: expanded ? 'Thu gọn' : 'Mở rộng',
          onPressed: onToggle,
          icon: Icon(
            expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
          ),
          color: CaslaColors.primaryNavy,
        ),
      ],
    );
  }
}

/// An operation added with (+): the same card as the first operation, with a
/// fold arrow and a remove button instead of the camera.
class _ExtraOperationCard extends StatelessWidget {
  final String name;
  final bool expanded;
  final bool isLimit;
  final String collapsedLine;
  final Widget summary;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  const _ExtraOperationCard({
    required this.name,
    required this.expanded,
    required this.isLimit,
    required this.collapsedLine,
    required this.summary,
    required this.onToggle,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CaslaColors.successBg,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: CaslaColors.success, width: 1.2),
        borderRadius: BorderRadius.circular(CaslaRadius.md),
      ),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(CaslaRadius.md),
        child: Padding(
          padding: const EdgeInsets.all(CaslaSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.check_circle_rounded,
                    size: 22,
                    color: CaslaColors.success,
                  ),
                  const SizedBox(width: CaslaSpacing.sm),
                  Expanded(
                    child: Text(
                      name,
                      softWrap: true,
                      style: const TextStyle(
                        fontSize: CaslaType.body,
                        fontWeight: FontWeight.w700,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                  ),
                  _OperationCardTrailing(
                    isLimit: isLimit,
                    expanded: expanded,
                    onToggle: onToggle,
                  ),
                  IconButton(
                    tooltip: 'Bỏ công đoạn',
                    onPressed: onRemove,
                    icon: const Icon(Icons.close, size: 20),
                    color: CaslaColors.muted,
                  ),
                ],
              ),
              if (expanded)
                summary
              else
                Text(
                  collapsedLine,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: CaslaType.caption,
                    color: CaslaColors.muted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The (+) under the operation cards. Tapping it arms the reader for another
/// operation label; the camera icon opens the camera for the same purpose.
class _AddOperationButton extends StatelessWidget {
  final bool isTarget;
  final VoidCallback onTap;
  final VoidCallback onOpenScanner;

  const _AddOperationButton({
    required this.isTarget,
    required this.onTap,
    required this.onOpenScanner,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CaslaColors.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: CaslaColors.primaryNavy,
          width: isTarget ? 2 : 1.2,
        ),
        borderRadius: BorderRadius.circular(CaslaRadius.md),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CaslaRadius.md),
        child: Padding(
          padding: const EdgeInsets.only(left: CaslaSpacing.sm),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: const BoxDecoration(
                  color: CaslaColors.primaryNavy,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add, size: 18, color: Colors.white),
              ),
              const SizedBox(width: CaslaSpacing.sm),
              Expanded(
                child: Text(
                  isTarget
                      ? 'Đang chờ quét công đoạn thêm…'
                      : 'Quét thêm công đoạn',
                  style: const TextStyle(
                    fontSize: CaslaType.body,
                    fontWeight: FontWeight.w700,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Quét thêm công đoạn bằng camera',
                onPressed: onOpenScanner,
                icon: const Icon(Icons.photo_camera_outlined, size: 22),
                color: CaslaColors.primaryNavy,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A check that used to stop the form and now only warns.
class _InlineWarning extends StatelessWidget {
  final String text;

  const _InlineWarning({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: CaslaSpacing.sm,
        vertical: CaslaSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: CaslaColors.pendingBg,
        borderRadius: BorderRadius.circular(CaslaRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: CaslaColors.pending,
          ),
          const SizedBox(width: CaslaSpacing.xs),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w600,
                height: 1.35,
                color: CaslaColors.pending,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OperationSummary extends StatelessWidget {
  final Map<String, dynamic> order;
  final Map<String, double> quantities;
  final bool loading;
  final String uom;

  const _OperationSummary({
    required this.order,
    required this.quantities,
    required this.loading,
    required this.uom,
  });

  String _text(String key, String unavailable) {
    final value = order[key]?.toString().trim() ?? '';
    return value.isEmpty ? unavailable : value;
  }

  @override
  Widget build(BuildContext context) {
    final productionOrder = _text('production_order', 'Chưa có mã LSX');
    final salesOrder = order['sales_order']?.toString().trim() ?? '';
    final salesOrderItem = order['sales_order_item']?.toString().trim() ?? '';
    final salesOrderLine = [
      salesOrder,
      salesOrderItem,
    ].where((value) => value.isNotEmpty).join('  ·  ');
    return Padding(
      padding: const EdgeInsets.only(top: CaslaSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SummarySectionLabel(
            icon: Icons.account_tree_outlined,
            text: 'Thông tin sản phẩm / công đoạn',
          ),
          const SizedBox(height: CaslaSpacing.xs),
          _OperationIdentityRow(
            productionOrder: productionOrder,
            operation: _text('operation', 'Chưa có mã công đoạn'),
          ),
          _InfoRow(
            label: 'Tên hàng',
            value: _text('ten_sp', 'Chưa có tên hàng'),
          ),
          _InfoRow(label: 'Mã hàng', value: _text('ma_sp', 'Chưa có mã hàng')),
          if (salesOrderLine.isNotEmpty)
            _InfoRow(label: 'SO / Item', value: salesOrderLine, maxLines: 1),
          const SizedBox(height: CaslaSpacing.sm),
          _SummarySectionLabel(
            icon: Icons.stacked_bar_chart_outlined,
            text: 'Số lượng công đoạn',
          ),
          const SizedBox(height: CaslaSpacing.xs),
          _QuantitySummaryGrid(quantities: quantities, uom: uom),
          const SizedBox(height: CaslaSpacing.xs),
          Text(
            loading
                ? 'Đang cập nhật số lượng…'
                : 'Số liệu gần nhất và giao dịch trên thiết bị',
            style: TextStyle(
              color: CaslaColors.muted,
              fontSize: CaslaType.caption,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkerSummary extends StatelessWidget {
  final Map<String, dynamic> worker;

  const _WorkerSummary({required this.worker});

  String _text(String key, String unavailable) {
    final value = worker[key]?.toString().trim() ?? '';
    return value.isEmpty ? unavailable : value;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: CaslaSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(label: 'Mã NV', value: _text('ma_nv', 'Chưa có mã NV')),
          _InfoRow(
            label: 'Bộ phận',
            value: _text('bo_phan', 'Chưa có bộ phận'),
          ),
        ],
      ),
    );
  }
}

class _SummarySectionLabel extends StatelessWidget {
  final IconData icon;
  final String text;

  const _SummarySectionLabel({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: CaslaColors.primaryNavy),
        const SizedBox(width: CaslaSpacing.xs),
        Expanded(
          child: Text(
            text,
            softWrap: true,
            style: const TextStyle(
              color: CaslaColors.primaryNavy,
              fontSize: CaslaType.caption,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final int? maxLines;

  const _InfoRow({required this.label, required this.value, this.maxLines});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: const TextStyle(
                color: CaslaColors.muted,
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: maxLines,
              overflow: maxLines == null ? null : TextOverflow.ellipsis,
              softWrap: true,
              style: TextStyle(
                color: CaslaColors.primaryNavy,
                fontSize: CaslaType.body,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OperationIdentityRow extends StatelessWidget {
  final String productionOrder;
  final String operation;

  const _OperationIdentityRow({
    required this.productionOrder,
    required this.operation,
  });

  @override
  Widget build(BuildContext context) {
    const valueStyle = TextStyle(
      color: CaslaColors.primaryNavy,
      fontSize: CaslaType.body,
      fontWeight: FontWeight.w700,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 108,
            child: Text(
              'LSX / công đoạn',
              style: TextStyle(
                color: CaslaColors.muted,
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 4,
              runSpacing: 0,
              children: [
                Text(productionOrder, style: valueStyle),
                const Text('·', style: valueStyle),
                Text(operation, style: valueStyle),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuantitySummaryGrid extends StatelessWidget {
  final Map<String, double> quantities;
  final String uom;

  const _QuantitySummaryGrid({required this.quantities, required this.uom});

  String _value(String key) {
    final value = quantities[key];
    return value == null ? 'Chưa có dữ liệu' : formatQuantity(value, uom: uom);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 340 ? 2 : 1;
        final itemWidth = columns == 2
            ? (constraints.maxWidth - CaslaSpacing.xs) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: CaslaSpacing.xs,
          runSpacing: CaslaSpacing.xs,
          children: [
            _MetricCard(
              width: itemWidth,
              label: 'SL công đoạn',
              value: _value('operationQuantity'),
              uom: uom,
            ),
            _MetricCard(
              width: itemWidth,
              label: 'Đã xác nhận',
              value: _value('confirmedQuantity'),
              uom: uom,
            ),
            _MetricCard(
              width: itemWidth,
              label: 'Số lượng phế',
              value: _value('defectQuantity'),
              uom: uom,
            ),
            _MetricCard(
              width: itemWidth,
              label: 'Số lượng đã giao',
              value: _value('assignedQuantity'),
              uom: uom,
            ),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  final double width;
  final String label;
  final String value;
  final String uom;

  const _MetricCard({
    required this.width,
    required this.label,
    required this.value,
    required this.uom,
  });

  @override
  Widget build(BuildContext context) {
    final isUnavailable = value == 'Chưa có dữ liệu';
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(
        horizontal: CaslaSpacing.sm,
        vertical: CaslaSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        borderRadius: BorderRadius.circular(CaslaRadius.sm),
        border: Border.all(color: CaslaColors.line, width: 1),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text(
              label,
              softWrap: true,
              style: TextStyle(
                color: CaslaColors.muted,
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: CaslaSpacing.xs),
          Flexible(
            child: Text(
              '$value${uom.isEmpty || isUnavailable ? '' : ' $uom'}',
              textAlign: TextAlign.end,
              softWrap: true,
              style: TextStyle(
                color: CaslaColors.primaryNavy,
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RemainingQuantityInline extends StatelessWidget {
  final double? remaining;
  final String uom;

  const _RemainingQuantityInline({required this.remaining, required this.uom});

  @override
  Widget build(BuildContext context) {
    final value = remaining == null
        ? 'Chưa có dữ liệu'
        : formatQuantity(remaining!, uom: uom);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: CaslaSpacing.sm,
        vertical: CaslaSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: CaslaColors.pendingBg,
        borderRadius: BorderRadius.circular(CaslaRadius.sm),
        border: Border.all(color: CaslaColors.gold100),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.inventory_2_outlined,
            size: 17,
            color: CaslaColors.primaryNavy,
          ),
          const SizedBox(width: CaslaSpacing.xs),
          const Text(
            'Còn lại',
            style: TextStyle(
              color: CaslaColors.muted,
              fontSize: CaslaType.caption,
              fontWeight: FontWeight.w700,
            ),
          ),
          Expanded(
            child: Text(
              '$value${uom.isEmpty || remaining == null ? '' : ' $uom'}',
              textAlign: TextAlign.end,
              softWrap: true,
              style: const TextStyle(
                color: CaslaColors.primaryNavy,
                fontSize: CaslaType.body,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
