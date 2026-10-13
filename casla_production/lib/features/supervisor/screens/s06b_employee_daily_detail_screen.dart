import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../core/auth/session_manager.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../data/sap/odata_error.dart';
import '../../../data/repositories/confirmation_targets.dart';
import '../../../presentation/widgets/confirmation_target_picker.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../domain/entities/work_history.dart';
import '../../../domain/policies/history_work_context.dart';
import '../../../domain/policies/unit_totals.dart';
import '../../../presentation/widgets/worker_totals_header.dart';
import '../../../domain/policies/local_history_overlay.dart';
import '../../../domain/policies/production_math.dart';
import '../../../main.dart';
import '../../../presentation/widgets/casla_skeleton.dart';
import '../../../presentation/widgets/stale_history_banner.dart';
import '../../../presentation/widgets/status_chip.dart';

/// SAP rejects a history window that extends beyond the current business day.
/// Keep this pure so preset ranges can be regression-tested without mounting
/// the whole detail screen.
DateTime clampHistoryDateToToday(DateTime value, {DateTime? today}) {
  final date = DateTime(value.year, value.month, value.day);
  final current = today == null
      ? DateTime.now()
      : DateTime(today.year, today.month, today.day);
  return date.isAfter(current) ? current : date;
}

class S06bEmployeeDailyDetailScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> worker;

  const S06bEmployeeDailyDetailScreen({super.key, required this.worker});

  @override
  ConsumerState<S06bEmployeeDailyDetailScreen> createState() =>
      _S06bEmployeeDailyDetailScreenState();
}

class _EmployeeDetailSkeleton extends StatelessWidget {
  const _EmployeeDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const CaslaSkeleton(width: 170, height: 18, radius: 6),
        const SizedBox(height: 12),
        const CaslaSkeleton(height: 94, radius: 14),
        const SizedBox(height: 20),
        const CaslaSkeleton(width: 210, height: 18, radius: 6),
        const SizedBox(height: 12),
        for (var index = 0; index < 3; index++) ...[
          const CaslaSkeleton(height: 68, radius: 12),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _DailyAssignmentChild {
  final double quantity;
  final double defectQuantity;
  final String uom;
  final String status;
  final DateTime occurredAt;
  final String transactionType;
  final Assignment? localAssignment;

  const _DailyAssignmentChild({
    required this.quantity,
    this.defectQuantity = 0,
    required this.uom,
    required this.status,
    required this.occurredAt,
    this.transactionType = 'INITIAL_ASSIGN',
    this.localAssignment,
  });
}

class _DailyAssignmentGroup {
  final String key;
  final DateTime date;
  final String productionOrder;
  final String operation;
  final String operationName;
  final String productName;
  final String productCode;
  final String salesOrder;
  final String salesOrderItem;
  final List<_DailyAssignmentChild> children;

  const _DailyAssignmentGroup({
    required this.key,
    required this.date,
    required this.productionOrder,
    required this.operation,
    required this.operationName,
    required this.productName,
    required this.productCode,
    required this.salesOrder,
    required this.salesOrderItem,
    required this.children,
  });
}

class _DailyAssignmentGroupData {
  final String key;
  DateTime date;
  String productionOrder;
  String operation;
  String operationName;
  String productName;
  String productCode;
  String salesOrder;
  String salesOrderItem;
  final List<_DailyAssignmentChild> children = [];

  _DailyAssignmentGroupData({
    required this.key,
    required this.date,
    required this.productionOrder,
    required this.operation,
    required this.operationName,
    required this.productName,
    required this.productCode,
    required this.salesOrder,
    required this.salesOrderItem,
  });

  _DailyAssignmentGroup freeze() => _DailyAssignmentGroup(
    key: key,
    date: date,
    productionOrder: productionOrder,
    operation: operation,
    operationName: operationName,
    productName: productName,
    productCode: productCode,
    salesOrder: salesOrder,
    salesOrderItem: salesOrderItem,
    children: List.unmodifiable(children),
  );
}

class _S06bEmployeeDailyDetailScreenState
    extends ConsumerState<S06bEmployeeDailyDetailScreen> {
  bool get _showLegacySplitActivitySections => false;

  late DateTime _dateFrom;
  late DateTime _dateTo;
  late Stream<WorkHistoryResult> _historyStream;
  late Stream<List<Assignment>> _assignmentStream;
  late Stream<List<Map<String, dynamic>>> _productionStream;
  late Stream<List<Map<String, dynamic>>> _recallStream;
  bool _historyDataReady = false;
  WorkHistoryResult? _lastHistoryResult;
  String? _openingConfirmationGroup;
  StreamSubscription<List<Map<String, dynamic>>>? _ledgerSubscription;
  List<LocalLedgerRow> _ledgerRows = const [];

  String _dateStr(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
  String _normalizeHistoryId(Object? id) =>
      (id?.toString() ?? '').replaceAll('-', '').toLowerCase();

  DateTime _notAfterToday(DateTime value) {
    return clampHistoryDateToToday(value);
  }

  bool get _isSameDay =>
      _dateOnly(_dateFrom).isAtSameMomentAs(_dateOnly(_dateTo));

  String get _dateHeaderLabel {
    final df = DateFormat('dd/MM/yyyy');
    if (_isSameDay) {
      return 'Ngày: ${df.format(_dateFrom)}';
    }
    return 'Kỳ: ${DateFormat('dd/MM').format(_dateFrom)} - ${df.format(_dateTo)}';
  }

  @override
  void initState() {
    super.initState();
    final initialDate = (widget.worker['date'] as DateTime?) ?? DateTime.now();
    _dateFrom = clampHistoryDateToToday(
      (widget.worker['date_from'] as DateTime?) ?? initialDate,
    );
    _dateTo = clampHistoryDateToToday(
      (widget.worker['date_to'] as DateTime?) ?? initialDate,
    );
    if (_dateTo.isBefore(_dateFrom)) _dateTo = _dateFrom;
    _resetDataStreams();
    unawaited(_resolveLocalWorkerId());
  }

  // The overview may pass the SAP code as `id` when the employee is not in
  // the selected team's list. Local assignments are filed under the local
  // employee id, so resolve it once and read everything by that id.
  String? _localWorkerId;

  /// Whether a local row belongs to the department this screen shows.
  ///
  /// Several departments share one SAP Work Center (XM2.001 and XM2.002 both
  /// post to CL100077), so a row that records its department is matched on
  /// that alone. Plant + Work Center is only a fallback for older rows saved
  /// without one.
  bool _inWorkScope(Object? rowWorkId, {Object? plant, Object? workCenter}) {
    final workId = widget.worker['work_context_id']?.toString().trim() ?? '';
    if (workId.isEmpty) return true;
    final rowWork = rowWorkId?.toString().trim() ?? '';
    if (rowWork.isNotEmpty) return rowWork == workId;
    final selected = ref
        .read(appStateProvider)
        .currentSession
        ?.workContexts
        .where((c) => c.workId == workId)
        .firstOrNull;
    return selected != null &&
        plant?.toString() == selected.plant &&
        workCenter?.toString() == selected.workCenter;
  }

  String get _workerId =>
      _localWorkerId ?? widget.worker['id']?.toString() ?? '';

  Future<void> _resolveLocalWorkerId() async {
    final db = ref.read(appStateProvider).db;
    final code = widget.worker['ma_nv']?.toString().trim() ?? '';
    final employee =
        (code.isEmpty ? null : await db.getEmployeeByCode(code)) ??
        await db.getEmployeeById(widget.worker['id']?.toString() ?? '');
    final id = employee?['id']?.toString().trim() ?? '';
    if (!mounted || id.isEmpty || id == _workerId) return;
    setState(() {
      _localWorkerId = id;
      _resetDataStreams();
    });
  }

  void _resetDataStreams() {
    final appState = ref.read(appStateProvider);
    _dateFrom = _notAfterToday(_dateFrom);
    _dateTo = _notAfterToday(_dateTo);
    if (_dateTo.isBefore(_dateFrom)) _dateTo = _dateFrom;
    _historyDataReady = false;
    _lastHistoryResult = null;
    final fromStr = _dateStr(_dateFrom);
    final toStr = _dateStr(_dateTo);
    _recallStream = appState.db.watchRecallHistory(
      _workerId,
      fromBusinessDate: fromStr,
      toBusinessDate: toStr,
      shiftId: _selectedShiftId,
    );
    _historyStream = appState.workHistoryRepo.watchWorkHistory(
      range: HistoryRange.custom,
      dateFrom: _dateFrom,
      dateTo: _dateTo,
      shiftId: _selectedShiftId,
      workId: widget.worker['work_context_id']?.toString(),
    );
    _assignmentStream = appState.assignmentRepo.watchWorkerAssignments(
      _workerId,
      fromBusinessDate: fromStr,
      toBusinessDate: toStr,
      shiftId: _selectedShiftId,
    );
    _productionStream = appState.db.watchProductionHistory(
      _workerId,
      fromBusinessDate: fromStr,
      toBusinessDate: toStr,
      shiftId: _selectedShiftId,
    );
    _watchLocalLedger(appState, fromStr, toStr);
  }

  /// Local writes SAP has not reported yet — applied on top of the SAP summary
  /// so the KPI card matches the transaction list below it, offline too.
  void _watchLocalLedger(AppState appState, String fromStr, String toStr) {
    unawaited(_ledgerSubscription?.cancel());
    _ledgerRows = const [];
    final workId = widget.worker['work_context_id']?.toString().trim() ?? '';
    final teamIds = workId.isNotEmpty
        ? [workId]
        : appState.currentSession?.toIds ?? const <String>[];
    _ledgerSubscription = appState.db
        .watchLocalLedgerRows(
          teamIds: teamIds,
          fromBusinessDate: fromStr,
          toBusinessDate: toStr,
          shiftId: _selectedShiftId,
        )
        .listen(
          (rows) {
            if (!mounted) return;
            setState(() {
              _ledgerRows = rows.map(LocalLedgerRow.fromMap).toList();
            });
          },
          onError: (Object _) {
            // SAP totals remain correct on their own; only the overlay is lost.
          },
        );
  }

  @override
  void dispose() {
    unawaited(_ledgerSubscription?.cancel());
    super.dispose();
  }

  String? get _selectedShiftId {
    final value = widget.worker['shift_id']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<WorkHistoryResult> _fetchHistory({bool forceRefresh = false}) {
    return ref
        .read(appStateProvider)
        .workHistoryRepo
        .getWorkHistory(
          range: HistoryRange.custom,
          dateFrom: _dateFrom,
          dateTo: _dateTo,
          shiftId: _selectedShiftId,
          workId: widget.worker['work_context_id']?.toString(),
          forceRefresh: forceRefresh,
        );
  }

  Future<void> _refresh() async {
    try {
      await _fetchHistory(forceRefresh: true);
    } catch (_) {
      if (!mounted || _lastHistoryResult == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(StaleHistoryBanner.message),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final today = _dateOnly(now);
    DateTime start = today.subtract(const Duration(days: 6));
    DateTime end = today;
    if (!_dateFrom.isAfter(_dateTo)) {
      start = _dateOnly(_dateFrom);
      end = _dateOnly(_dateTo);
    }

    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: start, end: end),
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: today,
      helpText: 'CHỌN KHOẢNG NGÀY (NHIỀU NGÀY)',
      cancelText: 'HỦY',
      confirmText: 'ÁP DỤNG',
      saveText: 'ÁP DỤNG',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: CaslaColors.primaryNavy,
              onPrimary: Colors.white,
              surface: CaslaColors.surface,
              onSurface: CaslaColors.navy900,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null || !mounted) return;
    final from = _dateOnly(picked.start);
    final to = _dateOnly(picked.end);
    if (to.difference(from).inDays > 31) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Khoảng thời gian tối đa là 31 ngày'),
          backgroundColor: CaslaColors.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() {
      _dateFrom = from;
      _dateTo = to;
      _resetDataStreams();
    });
  }

  Future<void> _pickSingleDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dateFrom.isAfter(_dateOnly(now))
          ? _dateOnly(now)
          : _dateFrom,
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: _dateOnly(now),
      helpText: 'CHỌN NGÀY',
      cancelText: 'HỦY',
      confirmText: 'CHỌN',
    );
    if (picked != null && mounted) {
      setState(() {
        _dateFrom = _dateOnly(picked);
        _dateTo = _dateOnly(picked);
        _resetDataStreams();
      });
    }
  }

  Future<void> _showDateRangeSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: CaslaColors.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Thời gian xem dữ liệu',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Đang xem: $_dateHeaderLabel',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: CaslaColors.muted,
                ),
              ),
              const SizedBox(height: 16),

              // CARD 1: CHỌN KHOẢNG NGÀY (NHIỀU NGÀY)
              Material(
                color: CaslaColors.accentGold.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickDateRange();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: CaslaColors.accentGold.withValues(alpha: 0.6),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: CaslaColors.accentGold,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.date_range_rounded,
                            color: CaslaColors.navy900,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  const Text(
                                    'Chọn khoảng ngày',
                                    style: TextStyle(
                                      fontFamily: 'Manrope',
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                      color: CaslaColors.navy900,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: CaslaColors.primaryNavy,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      'Nhiều ngày',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              const Text(
                                'Chọn từ ngày đến ngày (tối đa 31 ngày)',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: CaslaColors.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          color: CaslaColors.primaryNavy,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 10),

              // CARD 2: CHỌN 1 NGÀY CỤ THỂ
              Material(
                color: CaslaColors.surface,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickSingleDate();
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: CaslaColors.line, width: 1.2),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: CaslaColors.primaryNavy.withValues(
                              alpha: 0.08,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.calendar_today_rounded,
                            color: CaslaColors.primaryNavy,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Chọn 1 ngày cụ thể',
                                style: TextStyle(
                                  fontFamily: 'Manrope',
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                  color: CaslaColors.primaryNavy,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'Xem dữ liệu chi tiết của 1 ngày bất kỳ',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: CaslaColors.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          color: CaslaColors.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              const Text(
                'MỐC CHỌN NHANH',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: CaslaColors.muted,
                ),
              ),
              const SizedBox(height: 10),

              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildQuickPresetChip(
                    sheetContext,
                    label: 'Hôm nay',
                    sublabel: DateFormat('dd/MM').format(DateTime.now()),
                    isSelected:
                        _isSameDay &&
                        _dateOnly(
                          _dateFrom,
                        ).isAtSameMomentAs(_dateOnly(DateTime.now())),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      final today = _dateOnly(DateTime.now());
                      setState(() {
                        _dateFrom = today;
                        _dateTo = today;
                        _resetDataStreams();
                      });
                    },
                  ),
                  _buildQuickPresetChip(
                    sheetContext,
                    label: 'Hôm qua',
                    sublabel: DateFormat(
                      'dd/MM',
                    ).format(DateTime.now().subtract(const Duration(days: 1))),
                    isSelected:
                        _isSameDay &&
                        _dateOnly(_dateFrom).isAtSameMomentAs(
                          _dateOnly(
                            DateTime.now().subtract(const Duration(days: 1)),
                          ),
                        ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      final yest = _dateOnly(
                        DateTime.now().subtract(const Duration(days: 1)),
                      );
                      setState(() {
                        _dateFrom = yest;
                        _dateTo = yest;
                        _resetDataStreams();
                      });
                    },
                  ),
                  _buildQuickPresetChip(
                    sheetContext,
                    label: 'Tuần này',
                    sublabel: 'T2 - CN',
                    isSelected: !_isSameDay,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      final now = DateTime.now();
                      final start = _dateOnly(
                        now.subtract(Duration(days: now.weekday - 1)),
                      );
                      final end = _dateOnly(start.add(const Duration(days: 6)));
                      setState(() {
                        _dateFrom = start;
                        _dateTo = _notAfterToday(end);
                        _resetDataStreams();
                      });
                    },
                  ),
                  _buildQuickPresetChip(
                    sheetContext,
                    label: 'Tháng này',
                    sublabel: 'Tháng ${DateTime.now().month}',
                    isSelected: false,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      final now = DateTime.now();
                      final start = DateTime(now.year, now.month, 1);
                      final end = DateTime(now.year, now.month + 1, 0);
                      setState(() {
                        _dateFrom = start;
                        _dateTo = _notAfterToday(end);
                        _resetDataStreams();
                      });
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickPresetChip(
    BuildContext sheetContext, {
    required String label,
    required String sublabel,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? CaslaColors.primaryNavy : CaslaColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? CaslaColors.primaryNavy : CaslaColors.line,
            width: 1.2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: isSelected ? Colors.white : CaslaColors.primaryNavy,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              sublabel,
              style: TextStyle(
                fontSize: 11,
                color: isSelected
                    ? Colors.white.withValues(alpha: 0.75)
                    : CaslaColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final workerName = widget.worker['ten']?.toString() ?? 'Nhân viên';
    final workerCode = widget.worker['ma_nv']?.toString() ?? 'Chưa có mã';
    final rawDept = _firstRealDepartment([
      widget.worker['bo_phan'],
      widget.worker['department'],
      widget.worker['team'],
    ]);
    final workerTeam = rawDept ?? 'Chưa xác định tổ';
    final workerId = widget.worker['id']?.toString() ?? '';

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nhân viên: $workerName · $workerCode',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Bộ phận: $workerTeam',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: CaslaColors.identityMeta,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Date Selector Header
          Container(
            width: double.infinity,
            color: CaslaColors.background,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.calendar_month_outlined,
                      size: 18,
                      color: CaslaColors.primaryNavy,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _dateHeaderLabel,
                        style: const TextStyle(
                          fontFamily: 'Manrope',
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: CaslaColors.primaryNavy,
                        ),
                      ),
                    ),
                  ],
                ),
                OutlinedButton.icon(
                  onPressed: _showDateRangeSheet,
                  icon: const Icon(Icons.tune_rounded, size: 16),
                  label: const Text('Đổi ngày ▾'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    foregroundColor: CaslaColors.primaryNavy,
                    side: const BorderSide(color: CaslaColors.line, width: 1.3),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: StreamBuilder<WorkHistoryResult>(
                stream: _historyStream,
                builder: (context, sapSnapshot) {
                  // Preserve the last SAP result while a background refresh
                  // is failing; otherwise StreamBuilder exposes an error-only
                  // snapshot and the detail page loses its cached content.
                  if (sapSnapshot.hasData &&
                      sapSnapshot.connectionState != ConnectionState.waiting) {
                    _lastHistoryResult = sapSnapshot.data;
                    _historyDataReady = true;
                  }
                  final sapResult = _historyDataReady
                      ? sapSnapshot.data ?? _lastHistoryResult
                      : null;

                  return StreamBuilder<List<Assignment>>(
                    stream: _assignmentStream,
                    builder: (context, assignmentSnapshot) {
                      return StreamBuilder<List<Map<String, dynamic>>>(
                        stream: _productionStream,
                        builder: (context, prodSnapshot) {
                          final isSapLoading =
                              sapSnapshot.connectionState ==
                                  ConnectionState.waiting &&
                              !sapSnapshot.hasData;
                          final isAssignLoading =
                              assignmentSnapshot.connectionState ==
                                  ConnectionState.waiting &&
                              !assignmentSnapshot.hasData;
                          final isProdLoading =
                              prodSnapshot.connectionState ==
                                  ConnectionState.waiting &&
                              !prodSnapshot.hasData;

                          if (isSapLoading ||
                              isAssignLoading ||
                              isProdLoading) {
                            return const _EmployeeDetailSkeleton();
                          }

                          // 1. Process SAP Data
                          var scopedResult = sapResult;
                          final workId = widget.worker['work_context_id'];
                          final selectedContext = ref
                              .read(appStateProvider)
                              .currentSession
                              ?.workContexts
                              .where((c) => c.workId == workId)
                              .firstOrNull;
                          if (sapResult != null && workId != null) {
                            try {
                              scopedResult = historyForWorkContext(
                                sapResult,
                                plant: selectedContext?.plant ?? '',
                                workCenter: selectedContext?.workCenter ?? '',
                                workId: selectedContext?.workId,
                              );
                            } on FormatException catch (error) {
                              return ListView(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Text(error.message),
                                  ),
                                ],
                              );
                            }
                          }
                          final allSapEntries =
                              scopedResult?.entries ??
                              const <WorkHistoryEntry>[];
                          final workerSapEntries = allSapEntries
                              .where(
                                (e) =>
                                    e.workerId == workerCode ||
                                    e.workerId == workerId ||
                                    (workerId.isNotEmpty &&
                                        e.workerId.toLowerCase() ==
                                            workerId.toLowerCase()) ||
                                    (workerCode.isNotEmpty &&
                                        e.workerId.toLowerCase() ==
                                            workerCode.toLowerCase()),
                              )
                              .toList();

                          final sapInitialAssigns = workerSapEntries
                              .where(
                                (e) => e.transactionType == 'INITIAL_ASSIGN',
                              )
                              .toList();

                          // Opening balance carried from the previous day by
                          // SAP's 04:00 job (zcl_pp_reassign_job). A snapshot,
                          // not a new allocation: confirmations still consume
                          // the original INITIAL_ASSIGN.
                          final sapReassigns = workerSapEntries
                              .where((e) => e.transactionType == 'REASSIGN')
                              .toList();
                          final sapConfirms = workerSapEntries
                              .where((e) => e.transactionType == 'CONFIRM')
                              .toList();
                          final sapRecalls =
                              workerSapEntries
                                  .where((e) => e.transactionType == 'RECALL')
                                  .toList()
                                ..sort(
                                  (a, b) => b.executionDate.compareTo(
                                    a.executionDate,
                                  ),
                                );

                          // SAP returns one row per WorkID × unit.
                          final workerKeys = {
                            workerCode.trim().toUpperCase(),
                            workerId.trim().toUpperCase(),
                          }..remove('');
                          final sapWorkerRows =
                              (scopedResult?.workers ??
                                      const <WorkHistorySummary>[])
                                  .where(
                                    (w) => workerKeys.contains(
                                      w.workerId.trim().toUpperCase(),
                                    ),
                                  )
                                  .toList();

                          // 2. Process Local Data
                          final allAssignments =
                              assignmentSnapshot.data ?? const <Assignment>[];
                          final filteredAssignments = allAssignments
                              .where(
                                (a) =>
                                    a.note != historyImportedAssignmentNote &&
                                    _inWorkScope(
                                      a.teamId,
                                      plant: a.plant,
                                      workCenter: a.workCenter,
                                    ),
                              )
                              .toList();
                          // A successful SAP post is returned by both sources:
                          // WorkHistoryEntry and its still-open local assignment.
                          // Keep SAP as the canonical display row once its UUID
                          // is stamped onto the local source record.
                          final sapAssignmentIds = sapInitialAssigns
                              .map(
                                (entry) =>
                                    _normalizeHistoryId(entry.transactionUuid),
                              )
                              .where((id) => id.isNotEmpty)
                              .toSet();
                          final visibleLocalAssignments = filteredAssignments
                              .where((assignment) {
                                final sapId = _normalizeHistoryId(
                                  assignment.sapId,
                                );
                                final idempotencyId = _normalizeHistoryId(
                                  assignment.idempotencyKey,
                                );
                                return !sapAssignmentIds.contains(sapId) &&
                                    !sapAssignmentIds.contains(idempotencyId);
                              })
                              .toList();
                          final sapConfirmIds = sapConfirms
                              .map(
                                (e) => _normalizeHistoryId(e.transactionUuid),
                              )
                              .where((id) => id.isNotEmpty)
                              .toSet();
                          final productionRecords = (prodSnapshot.data ?? [])
                              .where((r) {
                                final inScope = _inWorkScope(
                                  r['work_context_id'],
                                  plant: r['plant'],
                                  workCenter: r['work_center'],
                                );
                                if (!inScope) return false;
                                final sapId = _normalizeHistoryId(r['sap_id']);
                                final idempotency = _normalizeHistoryId(
                                  r['idempotency_key'],
                                );
                                return !sapConfirmIds.contains(sapId) &&
                                    !sapConfirmIds.contains(idempotency);
                              })
                              .toList();

                          // 3. Figures per unit. "Tất cả" in the header is
                          // their sum, whatever the unit.
                          final List<UnitTotals> unitTotals;
                          if (sapWorkerRows.isNotEmpty) {
                            unitTotals = workerUnitTotalsFromSap(
                              sapRows: sapWorkerRows,
                              workerKeys: [workerId, workerCode],
                              pending: buildLocalPendingLedger(
                                sap: scopedResult,
                                rows: _ledgerRows,
                              ),
                            );
                          } else {
                            // No SAP summary: add up the rows themselves.
                            final byUnit = <String, List<double>>{};
                            List<double> acc(String unit) =>
                                byUnit[unit.trim()] ??= [0, 0, 0, 0];
                            for (final a in [
                              ...sapInitialAssigns,
                              // Opening balance: only the From day's.
                              ...sapReassigns.where(
                                (e) =>
                                    isOpeningBalanceDay(e.workDate, _dateFrom),
                              ),
                            ]) {
                              acc(a.unitOfMeasure)[0] += a.quantity;
                            }
                            for (final c in sapConfirms) {
                              acc(c.unitOfMeasure)[1] += c.quantity;
                              acc(c.unitOfMeasure)[3] += c.defectQuantity;
                            }
                            for (final recall in sapRecalls) {
                              acc(recall.unitOfMeasure)[2] += recall.quantity;
                            }
                            for (final a in visibleLocalAssignments) {
                              final t = acc(a.uom);
                              t[0] += a.assignedQuantity;
                              t[1] += a.completedQuantity;
                              t[2] += a.recalledQuantity;
                              t[3] += a.defectQuantity;
                            }
                            // Local production records if not already counted.
                            if (sapConfirms.isEmpty &&
                                visibleLocalAssignments.isEmpty) {
                              for (final r in productionRecords) {
                                acc(
                                      r['unit_of_measure']?.toString() ?? '',
                                    )[1] +=
                                    (r['quantity'] as num?)?.toDouble() ?? 0.0;
                                acc(
                                  r['unit_of_measure']?.toString() ?? '',
                                )[3] += (r['defect_quantity'] as num?)
                                        ?.toDouble() ??
                                    0.0;
                              }
                            }
                            unitTotals = [
                              for (final MapEntry(key: unit, value: t)
                                  in byUnit.entries)
                                UnitTotals(
                                  unit: unit,
                                  given: t[0],
                                  completed: t[1],
                                  defect: t[3],
                                  recalled: t[2],
                                  remaining: t[0] - t[2] - t[1] - t[3],
                                ),
                            ]..sort((a, b) => b.given.compareTo(a.given));
                          }
                          // The legacy sections below show one unit.
                          final uom =
                              unitTotals.isNotEmpty &&
                                  unitTotals.first.unit.isNotEmpty
                              ? unitTotals.first.unit
                              : (widget.worker['uom'] as String?) ?? 'cái';

                          final hasNoAssignments =
                              visibleLocalAssignments.isEmpty &&
                              sapInitialAssigns.isEmpty &&
                              sapReassigns.isEmpty;
                          final assignmentGroups = _groupAssignments(
                            sapInitialAssigns,
                            visibleLocalAssignments,
                          );
                          final confirmationGroups = _groupHistoryRows(
                            sapConfirms,
                            productionRecords,
                            isRecall: false,
                          );
                          final hasNoConfirms =
                              productionRecords.isEmpty && sapConfirms.isEmpty;

                          return ListView(
                            padding: const EdgeInsets.all(18),
                            children: [
                              if (sapSnapshot.hasError && sapResult != null)
                                const StaleHistoryBanner(),
                              WorkerTotalsHeader(
                                key: const ValueKey('worker-totals-header'),
                                units: unitTotals,
                              ),

                              _buildUnifiedActivityHistory(
                                sapInitialAssigns: sapInitialAssigns,
                                localAssignments: visibleLocalAssignments,
                                sapConfirms: sapConfirms,
                                productionRecords: productionRecords,
                                sapRecalls: sapRecalls,
                                sapReassigns: sapReassigns,
                                historyError:
                                    sapSnapshot.hasError && sapResult == null,
                                productionError: prodSnapshot.hasError,
                              ),
                              if (_showLegacySplitActivitySections) ...[
                                // Legacy split sections kept below temporarily
                                // for reference while the unified card is rolled out.
                                // Section: Phân công
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      _isSameDay
                                          ? 'Phân công trong ngày'
                                          : 'Phân công theo kỳ',
                                      style: const TextStyle(
                                        fontFamily: 'Manrope',
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                        color: CaslaColors.primaryNavy,
                                      ),
                                    ),
                                    Text(
                                      '(${visibleLocalAssignments.length + sapInitialAssigns.length})',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: CaslaColors.muted,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),

                                if (hasNoAssignments)
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: CaslaColors.surface,
                                      border: Border.all(
                                        color: CaslaColors.line,
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Center(
                                      child: Text(
                                        _isSameDay
                                            ? 'Không có phân công nào trong ngày này.'
                                            : 'Không có phân công nào trong khoảng thời gian này.',
                                        style: const TextStyle(
                                          color: CaslaColors.muted,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  )
                                else ...[
                                  _buildAssignmentGroups(assignmentGroups),
                                ],

                                const SizedBox(height: 20),

                                // Section: Lịch sử xác nhận hoàn thành
                                _buildRecallHistory(sapRecalls),
                                const SizedBox(height: 20),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'Lịch sử xác nhận hoàn thành',
                                      style: TextStyle(
                                        fontFamily: 'Manrope',
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14,
                                        color: CaslaColors.primaryNavy,
                                      ),
                                    ),
                                    Text(
                                      '(${productionRecords.length + sapConfirms.length})',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: CaslaColors.muted,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),

                                if ((sapSnapshot.hasError &&
                                        sapResult == null) ||
                                    (prodSnapshot.hasError &&
                                        sapSnapshot.hasError))
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: CaslaColors.dangerBg,
                                      border: Border.all(
                                        color: CaslaColors.danger.withValues(
                                          alpha: 0.35,
                                        ),
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.history_toggle_off_outlined,
                                          color: CaslaColors.danger,
                                        ),
                                        SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Text(
                                                'Chưa tải được lịch sử sản lượng. Danh sách phân công phía trên vẫn dùng được.',
                                                style: TextStyle(
                                                  color: CaslaColors.danger,
                                                  fontSize: 12.5,
                                                  height: 1.4,
                                                ),
                                              ),
                                              if (sapSnapshot.error
                                                  is SapBusinessError) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  'Mã lỗi: ${(sapSnapshot.error! as SapBusinessError).code}',
                                                  style: const TextStyle(
                                                    color: CaslaColors.danger,
                                                    fontFamily: 'monospace',
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  friendlySapErrorMessage(
                                                    sapSnapshot.error!,
                                                  ),
                                                  style: const TextStyle(
                                                    color: CaslaColors.danger,
                                                    fontSize: 12,
                                                    height: 1.35,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                else if (hasNoConfirms)
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: CaslaColors.surface,
                                      border: Border.all(
                                        color: CaslaColors.line,
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: const Center(
                                      child: Text(
                                        'Chưa có lượt xác nhận sản lượng nào.',
                                        style: TextStyle(
                                          color: CaslaColors.muted,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  )
                                else ...[
                                  _buildTransactionGroups(
                                    confirmationGroups,
                                    isRecall: false,
                                  ),
                                  if (confirmationGroups.isEmpty) ...[
                                    // SAP Confirmations
                                    for (final e in sapConfirms)
                                      Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: CaslaColors.surface,
                                          border: Border.all(
                                            color: CaslaColors.line,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    '${e.productionOrder} · CĐ: ${e.operation}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      fontSize: 13,
                                                      color: CaslaColors
                                                          .primaryNavy,
                                                    ),
                                                  ),
                                                  Text(
                                                    '${DateFormat('dd/MM HH:mm').format(e.executionDate)} · Trạng thái: ${e.transactionStatus}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontFamily: 'monospace',
                                                      fontSize: 11,
                                                      color: CaslaColors.muted,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.end,
                                              children: [
                                                _buildHistoryStatusBadge(
                                                  label:
                                                      e.transactionStatus ==
                                                          'POSTED'
                                                      ? 'ĐÃ GHI SỔ'
                                                      : _historyStatusLabel(
                                                          e.transactionStatus,
                                                        ),
                                                  isRecall: false,
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  '+${formatQuantity(e.quantity, uom: e.unitOfMeasure)} ${e.unitOfMeasure}',
                                                  style: const TextStyle(
                                                    fontFamily: 'monospace',
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 14,
                                                    color: CaslaColors.success,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    // Local production records
                                    for (final r in productionRecords)
                                      Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: CaslaColors.surface,
                                          border: Border.all(
                                            color: CaslaColors.line,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    r['ten_sp'] ?? '',
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      fontSize: 13,
                                                      color: CaslaColors
                                                          .primaryNavy,
                                                    ),
                                                  ),
                                                  Text(
                                                    '${DateFormat('dd/MM HH:mm').format(DateTime.fromMillisecondsSinceEpoch(r['occurred_at_utc'] ?? 0))} · Người xác nhận: ${r['nguoi_xac_nhan']}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      fontFamily: 'monospace',
                                                      fontSize: 11,
                                                      color: CaslaColors.muted,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.end,
                                              children: [
                                                _buildHistoryStatusBadge(
                                                  label: 'ĐÃ GHI SỔ',
                                                  isRecall: false,
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  '+${formatQuantity((r['quantity'] as num).toDouble(), uom: uom)} $uom',
                                                  style: const TextStyle(
                                                    fontFamily: 'monospace',
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 14,
                                                    color: CaslaColors.success,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ],
                              ],
                            ],
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryStatusBadge({
    required String label,
    required bool isRecall,
    bool isCarryOver = false,
  }) {
    final held = _heldStatusLabels.contains(label);
    final rejected = label == _rejectedStatusLabel;
    final foreground = isCarryOver
        ? CaslaColors.carryOver
        : held
        ? CaslaColors.awaiting
        : isRecall || rejected
        ? CaslaColors.danger
        : CaslaColors.success;
    final background = isCarryOver
        ? CaslaColors.carryOverBg
        : held
        ? CaslaColors.awaitingBg
        : isRecall || rejected
        ? CaslaColors.dangerBg
        : CaslaColors.successBg;
    final border = foreground.withValues(alpha: 0.25);
    return Semantics(
      label: label,
      child: Container(
        constraints: const BoxConstraints(minHeight: 28),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 6, color: foreground),
            const SizedBox(width: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _historyStatusLabel(String status) {
    return switch (status) {
      'POSTED' => 'ĐÃ GHI SỔ',
      'SYNCED' => 'ĐÃ GHI SỔ',
      'PENDING' => 'CHỜ ĐỒNG BỘ',
      'NEEDS_VERIFICATION' => 'CẦN XÁC MINH',
      'SYNCING' => 'ĐANG GỬI',
      'FAILED' => 'SAP TỪ CHỐI',
      _ => status.isEmpty ? 'HOÀN THÀNH' : status,
    };
  }

  List<_DailyAssignmentGroup> _groupAssignments(
    List<WorkHistoryEntry> sapInitialAssigns,
    List<Assignment> localAssignments,
  ) {
    final grouped = <String, _DailyAssignmentGroupData>{};

    void add({
      required DateTime date,
      required String productionOrder,
      required String operation,
      String operationName = '',
      String productName = '',
      String productCode = '',
      String salesOrder = '',
      String salesOrderItem = '',
      required _DailyAssignmentChild child,
    }) {
      final order = productionOrder.trim().isEmpty
          ? 'Chưa có LSX'
          : productionOrder.trim();
      final operationCode = operation.trim().isEmpty
          ? 'Chưa có mã CĐ'
          : operation.trim();
      final dayKey = DateFormat('yyyy-MM-dd').format(date);
      final key = '$dayKey|$order|$operationCode';
      final group = grouped.putIfAbsent(
        key,
        () => _DailyAssignmentGroupData(
          key: key,
          date: date,
          productionOrder: order,
          operation: operationCode,
          operationName: operationName.trim(),
          productName: productName.trim(),
          productCode: productCode.trim(),
          salesOrder: salesOrder.trim(),
          salesOrderItem: salesOrderItem.trim(),
        ),
      );
      if (group.operationName.isEmpty && operationName.trim().isNotEmpty) {
        group.operationName = operationName.trim();
      }
      if (group.productName.isEmpty && productName.trim().isNotEmpty) {
        group.productName = productName.trim();
      }
      if (group.productCode.isEmpty && productCode.trim().isNotEmpty) {
        group.productCode = productCode.trim();
      }
      if (group.salesOrder.isEmpty && salesOrder.trim().isNotEmpty) {
        group.salesOrder = salesOrder.trim();
      }
      if (group.salesOrderItem.isEmpty && salesOrderItem.trim().isNotEmpty) {
        group.salesOrderItem = salesOrderItem.trim();
      }
      group.children.add(child);
    }

    for (final entry in sapInitialAssigns) {
      add(
        // Grouped by the shift's business day; the time shown is when it
        // was posted.
        date: entry.workDate,
        productionOrder: entry.productionOrder,
        operation: entry.operation,
        operationName: entry.operationName,
        productName: entry.productName,
        productCode: entry.productCode,
        salesOrder: entry.salesOrder,
        salesOrderItem: entry.salesOrderItem,
        child: _DailyAssignmentChild(
          quantity: entry.quantity,
          defectQuantity: entry.defectQuantity,
          uom: entry.unitOfMeasure,
          status: entry.transactionStatus,
          occurredAt: entry.executionDate,
          transactionType: 'INITIAL_ASSIGN',
        ),
      );
    }

    for (final assignment in localAssignments) {
      final businessDate = DateTime.tryParse(assignment.businessDate);
      final occurredAt = assignment.createdAtUtc > 0
          ? DateTime.fromMillisecondsSinceEpoch(
              assignment.createdAtUtc,
            ).toLocal()
          : (businessDate ?? DateTime.now());
      add(
        date: businessDate ?? occurredAt,
        productionOrder: assignment.productionOrder.isNotEmpty
            ? assignment.productionOrder
            : assignment.orderCode,
        operation: assignment.operation,
        operationName: assignment.operationName,
        productName: assignment.productName,
        productCode: assignment.productCode,
        child: _DailyAssignmentChild(
          quantity: assignment.effectiveAssigned,
          uom: assignment.uom,
          // Until SAP posts it, the sync state is what matters (held in the
          // sync tab or not); afterwards the allocation's own status.
          status: assignment.syncStatus == SyncStatus.synced
              ? assignment.status.label
              : assignment.syncStatus.label,
          occurredAt: occurredAt,
          transactionType: 'INITIAL_ASSIGN',
          localAssignment: assignment,
        ),
      );
    }

    final result = grouped.values.map((group) {
      group.children.sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
      return group.freeze();
    }).toList();
    result.sort((a, b) => b.date.compareTo(a.date));
    return result;
  }

  List<_DailyAssignmentGroup> _groupHistoryRows(
    List<WorkHistoryEntry> sapEntries,
    List<Map<String, dynamic>> localRows, {
    required bool isRecall,
    String? transactionType,
  }) {
    final type = transactionType ?? (isRecall ? 'RECALL' : 'CONFIRM');
    final grouped = <String, _DailyAssignmentGroupData>{};

    void add({
      required DateTime date,
      required String productionOrder,
      required String operation,
      String operationName = '',
      String productName = '',
      String productCode = '',
      String salesOrder = '',
      String salesOrderItem = '',
      required _DailyAssignmentChild child,
    }) {
      final order = productionOrder.trim().isEmpty
          ? 'Chưa có LSX'
          : productionOrder.trim();
      final operationCode = operation.trim().isEmpty
          ? 'Chưa có mã CĐ'
          : operation.trim();
      final dayKey = DateFormat('yyyy-MM-dd').format(date);
      final key = '$dayKey|$order|$operationCode';
      final group = grouped.putIfAbsent(
        key,
        () => _DailyAssignmentGroupData(
          key: key,
          date: date,
          productionOrder: order,
          operation: operationCode,
          operationName: operationName.trim(),
          productName: productName.trim(),
          productCode: productCode.trim(),
          salesOrder: salesOrder.trim(),
          salesOrderItem: salesOrderItem.trim(),
        ),
      );
      if (group.operationName.isEmpty && operationName.trim().isNotEmpty) {
        group.operationName = operationName.trim();
      }
      if (group.productName.isEmpty && productName.trim().isNotEmpty) {
        group.productName = productName.trim();
      }
      if (group.productCode.isEmpty && productCode.trim().isNotEmpty) {
        group.productCode = productCode.trim();
      }
      if (group.salesOrder.isEmpty && salesOrder.trim().isNotEmpty) {
        group.salesOrder = salesOrder.trim();
      }
      if (group.salesOrderItem.isEmpty && salesOrderItem.trim().isNotEmpty) {
        group.salesOrderItem = salesOrderItem.trim();
      }
      group.children.add(child);
    }

    for (final entry in sapEntries) {
      add(
        // Grouped by the shift's business day; the time shown is when it
        // was posted.
        date: entry.workDate,
        productionOrder: entry.productionOrder,
        operation: entry.operation,
        operationName: entry.operationName,
        productName: entry.productName,
        productCode: entry.productCode,
        salesOrder: entry.salesOrder,
        salesOrderItem: entry.salesOrderItem,
        child: _DailyAssignmentChild(
          quantity: entry.quantity,
          defectQuantity: entry.defectQuantity,
          uom: entry.unitOfMeasure,
          status: entry.transactionStatus,
          occurredAt: entry.executionDate,
          transactionType: type,
        ),
      );
    }

    for (final row in localRows) {
      final occurredAt = DateTime.fromMillisecondsSinceEpoch(
        (row['occurred_at_utc'] as num?)?.toInt() ?? 0,
      ).toLocal();
      final businessDate = DateTime.tryParse(
        row['business_date']?.toString() ?? '',
      );
      add(
        date: businessDate ?? occurredAt,
        productionOrder: row['production_order']?.toString() ?? '',
        operation: row['operation']?.toString() ?? '',
        operationName: row['operation_name']?.toString() ?? '',
        productName: row['ten_sp']?.toString() ?? '',
        productCode: row['ma_sp']?.toString() ?? '',
        salesOrder: row['sales_order']?.toString() ?? '',
        salesOrderItem: row['sales_order_item']?.toString() ?? '',
        child: _DailyAssignmentChild(
          quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
          defectQuantity: (row['defect_quantity'] as num?)?.toDouble() ?? 0,
          uom: row['unit_of_measure']?.toString() ?? '',
          status: _historyStatusLabel(row['sync_status']?.toString() ?? ''),
          occurredAt: occurredAt,
          transactionType: type,
        ),
      );
    }

    final result = grouped.values.map((group) {
      group.children.sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
      return group.freeze();
    }).toList();
    result.sort((a, b) => b.date.compareTo(a.date));
    return result;
  }

  Widget _buildUnifiedActivityHistory({
    required List<WorkHistoryEntry> sapInitialAssigns,
    required List<Assignment> localAssignments,
    required List<WorkHistoryEntry> sapConfirms,
    required List<Map<String, dynamic>> productionRecords,
    required List<WorkHistoryEntry> sapRecalls,
    List<WorkHistoryEntry> sapReassigns = const [],
    required bool historyError,
    required bool productionError,
  }) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _recallStream,
      builder: (context, recallSnapshot) {
        final sapRecallIds =
            sapRecalls
                .map((entry) => _normalizeHistoryId(entry.transactionUuid))
                .toSet()
              ..remove('');
        final localRecalls = (recallSnapshot.data ?? []).where((row) {
          final inScope = _inWorkScope(
            row['work_context_id'],
            plant: row['plant'],
            workCenter: row['work_center'],
          );
          return inScope &&
              !sapRecallIds.contains(_normalizeHistoryId(row['sap_id'])) &&
              !sapRecallIds.contains(
                _normalizeHistoryId(row['idempotency_key']),
              );
        }).toList();

        final groups = _mergeTransactionGroups([
          _groupAssignments(sapInitialAssigns, localAssignments),
          _groupHistoryRows(sapConfirms, productionRecords, isRecall: false),
          _groupHistoryRows(sapRecalls, localRecalls, isRecall: true),
          _groupHistoryRows(
            sapReassigns,
            const [],
            isRecall: false,
            transactionType: 'REASSIGN',
          ),
        ]);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'Hoạt động sản lượng',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '(${groups.length})',
                  style: const TextStyle(
                    fontSize: 12,
                    color: CaslaColors.muted,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (historyError || productionError) _buildHistoryLoadError(),
            if (groups.isEmpty && !historyError && !productionError)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Chưa có giao dịch sản lượng trong kỳ này.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: CaslaColors.muted, fontSize: 13),
                ),
              )
            else
              _buildUnifiedTransactionGroups(groups),
          ],
        );
      },
    );
  }

  Widget _buildHistoryLoadError() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CaslaColors.dangerBg,
        border: Border.all(color: CaslaColors.danger.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Row(
        children: [
          Icon(Icons.history_toggle_off_outlined, color: CaslaColors.danger),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Chưa tải đủ lịch sử sản lượng. Các giao dịch đã có vẫn được hiển thị.',
              style: TextStyle(
                color: CaslaColors.danger,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_DailyAssignmentGroup> _mergeTransactionGroups(
    List<List<_DailyAssignmentGroup>> sources,
  ) {
    final grouped = <String, _DailyAssignmentGroupData>{};
    for (final source in sources) {
      for (final group in source) {
        final target = grouped.putIfAbsent(
          group.key,
          () => _DailyAssignmentGroupData(
            key: group.key,
            date: group.date,
            productionOrder: group.productionOrder,
            operation: group.operation,
            operationName: group.operationName,
            productName: group.productName,
            productCode: group.productCode,
            salesOrder: group.salesOrder,
            salesOrderItem: group.salesOrderItem,
          ),
        );
        if (target.operationName.isEmpty) {
          target.operationName = group.operationName;
        }
        if (target.productName.isEmpty) target.productName = group.productName;
        if (target.productCode.isEmpty) target.productCode = group.productCode;
        if (target.salesOrder.isEmpty) target.salesOrder = group.salesOrder;
        if (target.salesOrderItem.isEmpty) {
          target.salesOrderItem = group.salesOrderItem;
        }
        target.children.addAll(group.children);
      }
    }
    final result = grouped.values.map((group) {
      group.children.sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
      return group.freeze();
    }).toList();
    result.sort((a, b) => b.date.compareTo(a.date));
    return result;
  }

  Widget _buildUnifiedTransactionGroups(List<_DailyAssignmentGroup> groups) {
    final children = <Widget>[];
    DateTime? lastDate;
    for (final group in groups) {
      final date = _dateOnly(group.date);
      if (lastDate == null || !date.isAtSameMomentAs(lastDate)) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              DateFormat('dd/MM/yyyy').format(group.date),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
        );
        lastDate = date;
      }
      children.add(
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: CaslaColors.surface,
            border: Border.all(color: CaslaColors.line),
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: CaslaColors.surface,
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
                splashColor: CaslaColors.navy100,
              ),
              child: ExpansionTile(
                initiallyExpanded: false,
                tilePadding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
                childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                leading: const Icon(
                  Icons.account_tree_outlined,
                  color: CaslaColors.primaryNavy,
                  size: 20,
                ),
                title: _buildActivityGroupSummary(group),
                children: [
                  for (final child in group.children)
                    _buildUnifiedTransactionChild(child),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Column(children: children);
  }

  /// Local rows SAP has not posted yet (queued, sending or awaiting the
  /// worker's password), as labelled by [_historyStatusLabel].
  static const _heldStatusLabels = {'CHỜ ĐỒNG BỘ', 'CẦN XÁC MINH', 'ĐANG GỬI'};
  static const _rejectedStatusLabel = 'SAP TỪ CHỐI';

  bool _isHeld(_DailyAssignmentChild child) => _heldStatusLabels.contains(
    _historyStatusLabel(child.status.toUpperCase()),
  );

  Widget _buildActivityGroupSummary(_DailyAssignmentGroup group) {
    final totals = <String, double>{};
    for (final child in group.children) {
      final label = _historyStatusLabel(child.status.toUpperCase());
      // A rejected row never reached SAP and holds nothing.
      if (label == _rejectedStatusLabel) continue;
      // Work still held on this device is shown on its own, so a supervisor
      // sees at once that something is waiting in the sync tab.
      final type = _isHeld(child)
          ? '${child.transactionType}_HELD'
          : child.transactionType;
      totals[type] = (totals[type] ?? 0) + child.quantity;
      final defectType = _isHeld(child)
          ? '${child.transactionType}_DEFECT_HELD'
          : '${child.transactionType}_DEFECT';
      totals[defectType] = (totals[defectType] ?? 0) + child.defectQuantity;
    }
    final badges = <Widget>[];
    void badge(String type, String label, Color color, Color background) {
      final quantity = totals[type];
      if (quantity == null || quantity == 0) return;
      badges.add(
        _activityQuantityBadge(
          label,
          quantity,
          group.children.first.uom,
          color,
          background,
        ),
      );
    }

    badge(
      'INITIAL_ASSIGN',
      'Giao',
      CaslaColors.primaryNavy,
      CaslaColors.navy100,
    );
    badge(
      'REASSIGN',
      'Tồn từ ngày trước',
      CaslaColors.carryOver,
      CaslaColors.carryOverBg,
    );
    badge(
      'INITIAL_ASSIGN_HELD',
      'Chờ xác nhận',
      CaslaColors.awaiting,
      CaslaColors.awaitingBg,
    );
    badge('CONFIRM', 'Xác nhận', CaslaColors.success, CaslaColors.successBg);
    final defectTotal =
        (totals['CONFIRM_DEFECT'] ?? 0) + (totals['CONFIRM_DEFECT_HELD'] ?? 0);
    if (defectTotal > 0) {
      badges.add(
        _activityQuantityBadge(
          'Số phế',
          defectTotal,
          group.children.first.uom,
          CaslaColors.scrap,
          CaslaColors.scrapBg,
        ),
      );
    }
    badge(
      'CONFIRM_HELD',
      'Chờ xác nhận',
      CaslaColors.awaiting,
      CaslaColors.awaitingBg,
    );
    badge('RECALL', 'Thu hồi', CaslaColors.danger, CaslaColors.dangerBg);
    badge(
      'RECALL_HELD',
      'Chờ thu hồi',
      CaslaColors.awaiting,
      CaslaColors.awaitingBg,
    );
    if (group.children.isNotEmpty) {
      // Only posted allocations can be worked off; held confirmations and
      // recalls already reserve their quantity.
      final remaining = ProductionMath.calculateRemaining(
        ProductionMath.calculateEffectiveAssigned(
          (totals['INITIAL_ASSIGN'] ?? 0) + (totals['REASSIGN'] ?? 0),
          (totals['RECALL'] ?? 0) + (totals['RECALL_HELD'] ?? 0),
        ),
        (totals['CONFIRM'] ?? 0) +
            (totals['CONFIRM_HELD'] ?? 0) +
            (totals['CONFIRM_DEFECT'] ?? 0) +
            (totals['CONFIRM_DEFECT_HELD'] ?? 0),
      );
      badges.add(
        _activityQuantityBadge(
          'Còn lại',
          remaining,
          group.children.first.uom,
          CaslaColors.pending,
          CaslaColors.pendingBg,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 5, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (group.children.any((c) => c.transactionType == 'REASSIGN')) ...[
            const _CarryOverPin(),
            const SizedBox(height: 6),
          ],
          Text(
            group.operationName.isEmpty
                ? 'Chưa có tên công đoạn'
                : group.operationName,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: CaslaColors.primaryNavy,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'LSX ${group.productionOrder}  ·  CĐ ${group.operation}',
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: CaslaColors.muted,
            ),
          ),
          if (group.productName.isNotEmpty ||
              group.productCode.isNotEmpty ||
              group.salesOrder.isNotEmpty ||
              group.salesOrderItem.isNotEmpty) ...[
            const SizedBox(height: 9),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: CaslaColors.navy100,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: CaslaColors.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (group.productName.isNotEmpty)
                    _buildActivityInfoLine('Tên hàng', group.productName),
                  if (group.productName.isNotEmpty &&
                      group.productCode.isNotEmpty)
                    const SizedBox(height: 5),
                  if (group.productCode.isNotEmpty)
                    _buildActivityInfoLine(
                      'Mã hàng',
                      group.productCode,
                      monospace: true,
                    ),
                  if ((group.productName.isNotEmpty ||
                          group.productCode.isNotEmpty) &&
                      (group.salesOrder.isNotEmpty ||
                          group.salesOrderItem.isNotEmpty))
                    const SizedBox(height: 5),
                  if (group.salesOrder.isNotEmpty ||
                      group.salesOrderItem.isNotEmpty)
                    _buildActivitySalesOrderLine(group),
                ],
              ),
            ),
          ],
          if (badges.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: badges),
          ],
          _buildActivityConfirmAction(group),
        ],
      ),
    );
  }

  /// The QR confirmation flow lands on the employee activity view. Keep the
  /// primary action visible on the group card so the supervisor does not have
  /// to expand a card and discover an assignment row before confirming.
  ///
  /// Resolve the durable target from the scoped ledger before navigating.
  Widget _buildActivityConfirmAction(_DailyAssignmentGroup group) {
    // Carried-over work (REASSIGN) is confirmable as well: SAP counts it and
    // today's top-ups as one group.
    if (!group.children.any(
      (child) =>
          child.transactionType == 'INITIAL_ASSIGN' ||
          (child.transactionType == 'REASSIGN' && child.quantity > 0),
    )) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: OutlinedButton.icon(
          onPressed: _openingConfirmationGroup != null
              ? null
              : () => _openGroupConfirmation(group),
          icon: _openingConfirmationGroup == group.key
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_circle_outline, size: 17),
          label: const Text('Xác nhận'),
          style: OutlinedButton.styleFrom(
            foregroundColor: CaslaColors.primaryNavy,
            side: BorderSide(
              color: CaslaColors.primaryNavy.withValues(alpha: 0.28),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openGroupConfirmation(_DailyAssignmentGroup group) async {
    if (_openingConfirmationGroup != null) return;
    setState(() => _openingConfirmationGroup = group.key);
    try {
      final appState = ref.read(appStateProvider);
      final work = appState.activeWorkContext;
      final shift = appState.activeShift;
      final date = appState.activeBusinessDate;
      final session = appState.sessionGeneration;
      bool scopeCurrent() =>
          appState.sessionGeneration == session &&
          appState.activeWorkContext?.workId == work?.workId &&
          appState.activeShift?.shiftId == shift?.shiftId &&
          _dateStr(appState.activeBusinessDate) == _dateStr(date);
      if (work == null ||
          shift == null ||
          _dateStr(group.date) != _dateStr(date) ||
          (widget.worker['work_context_id'] != null &&
              widget.worker['work_context_id'] != work.workId)) {
        throw const FormatException(
          'Chọn đúng ngày, ca và bộ phận của phân công trước khi xác nhận.',
        );
      }
      final history = await loadConfirmationHistory(
        appState.workHistoryRepo,
        range: HistoryRange.day,
        dateFrom: date,
        dateTo: date,
        shiftId: shift.shiftId,
        workId: work.workId,
      );
      if (!mounted || !scopeCurrent()) return;
      final targets = await resolveConfirmationTargets(
        db: appState.db,
        assignments: appState.assignmentRepo,
        history: history,
        workerId: _workerId,
        workerCode: widget.worker['ma_nv']?.toString() ?? '',
        businessDate: _dateStr(date),
        shiftId: shift.shiftId,
        workId: work.workId,
        workCenter: work.workCenter,
        productionOrder: group.productionOrder,
        operation: group.operation,
        includeSettled: true,
      );
      if (!mounted || !scopeCurrent()) return;
      if (!targets.any((target) => target.canRecord)) {
        throw const FormatException(
          'Phân công không còn sản lượng cần xác nhận trong ca đang chọn.',
        );
      }
      final allocations = await pickConfirmationGroup(context, targets);
      if (!mounted || !scopeCurrent() || allocations == null) return;
      await context.push(
        '/supervisor/assignment_detail',
        extra: <String, dynamic>{
          'assignment': allocations.first,
          'group': allocations,
          'openConfirmation': true,
        },
      );
    } catch (error, stackTrace) {
      if (error is! FormatException) {
        // The generic message below hides the cause; keep it for support.
        debugPrint('Mở xác nhận từ chi tiết nhân viên thất bại: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is FormatException
                ? error.message
                : error is SapBusinessError
                ? 'Không tải được lịch sử từ SAP: ${friendlySapErrorMessage(error)}'
                : 'Chưa đối chiếu được số lượng với SAP. Vui lòng thử lại.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingConfirmationGroup = null);
    }
  }

  Widget _buildActivityInfoLine(
    String label,
    String value, {
    bool monospace = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 58,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 10.5,
              color: CaslaColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontFamily: monospace ? 'monospace' : 'Manrope',
              fontSize: 11,
              height: 1.25,
              color: CaslaColors.navy900,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActivitySalesOrderLine(_DailyAssignmentGroup group) {
    final salesOrder = group.salesOrder.isEmpty ? '—' : group.salesOrder;
    final item = group.salesOrderItem.isEmpty ? '—' : group.salesOrderItem;
    return Text(
      'SO $salesOrder  ·  Item $item',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        color: CaslaColors.muted,
      ),
    );
  }

  Widget _activityQuantityBadge(
    String label,
    double quantity,
    String uom,
    Color color,
    Color background,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        '$label ${formatQuantity(quantity, uom: uom)}${uom.isEmpty ? '' : ' $uom'}',
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildUnifiedTransactionChild(_DailyAssignmentChild child) {
    final type = child.transactionType;
    final isRecall = type == 'RECALL' || type == 'REVERSE';
    final label = switch (type) {
      'INITIAL_ASSIGN' => 'Giao',
      'REASSIGN' => 'Tồn chuyển từ ngày trước',
      'CONFIRM' => 'Xác nhận',
      'RECALL' => 'Thu hồi',
      'REVERSE' => 'Đảo giao dịch',
      _ => type,
    };
    final status = _historyStatusLabel(child.status.toUpperCase());
    // Carried-over balance reads in gold, apart from work given today.
    final isCarryOver = type == 'REASSIGN';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          if (isCarryOver) ...[
            const Icon(Icons.push_pin, size: 13, color: CaslaColors.carryOver),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              '$label: ${formatQuantity(child.quantity, uom: child.uom)} ${child.uom}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: isCarryOver
                    ? CaslaColors.carryOver
                    : isRecall
                    ? CaslaColors.danger
                    : CaslaColors.primaryNavy,
              ),
            ),
          ),
          _buildHistoryStatusBadge(
            label: status,
            isRecall: isRecall,
            isCarryOver: isCarryOver,
          ),
          const SizedBox(width: 8),
          Text(
            DateFormat('HH:mm').format(child.occurredAt),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: CaslaColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssignmentGroups(List<_DailyAssignmentGroup> groups) {
    final children = <Widget>[];
    DateTime? lastDate;
    for (final group in groups) {
      final date = _dateOnly(group.date);
      if (lastDate == null || !date.isAtSameMomentAs(lastDate)) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              DateFormat('dd/MM/yyyy').format(group.date),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
        );
        lastDate = date;
      }
      children.add(
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: CaslaColors.surface,
            border: Border.all(color: CaslaColors.line),
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          // ExpansionTile's ListTile paints its ink on a Material surface;
          // keep that surface inside the rounded card so taps remain visible.
          child: Material(
            color: CaslaColors.surface,
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
                splashColor: CaslaColors.navy100,
              ),
              child: ExpansionTile(
                initiallyExpanded: true,
                tilePadding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
                childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                leading: const Icon(
                  Icons.account_tree_outlined,
                  color: CaslaColors.primaryNavy,
                  size: 20,
                ),
                title: _buildAssignmentGroupSummary(group),
                children: [
                  for (final child in group.children)
                    _buildAssignmentChild(group, child),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Column(children: children);
  }

  Widget _buildTransactionGroups(
    List<_DailyAssignmentGroup> groups, {
    required bool isRecall,
  }) {
    final children = <Widget>[];
    DateTime? lastDate;
    for (final group in groups) {
      final date = _dateOnly(group.date);
      if (lastDate == null || !date.isAtSameMomentAs(lastDate)) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              DateFormat('dd/MM/yyyy').format(group.date),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
        );
        lastDate = date;
      }
      children.add(
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: CaslaColors.surface,
            border: Border.all(color: CaslaColors.line),
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: CaslaColors.surface,
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
                splashColor: isRecall
                    ? CaslaColors.dangerBg
                    : CaslaColors.navy100,
              ),
              child: ExpansionTile(
                initiallyExpanded: true,
                tilePadding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
                childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                leading: Icon(
                  isRecall ? Icons.undo_rounded : Icons.task_alt_outlined,
                  color: isRecall
                      ? CaslaColors.danger
                      : CaslaColors.primaryNavy,
                  size: 20,
                ),
                title: _buildAssignmentGroupSummary(group),
                children: [
                  for (final child in group.children)
                    _buildTransactionChild(child, isRecall: isRecall),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Column(children: children);
  }

  Widget _buildTransactionChild(
    _DailyAssignmentChild child, {
    required bool isRecall,
  }) {
    final status = child.status.toUpperCase();
    final statusLabel = isRecall
        ? switch (status) {
            'ĐÃ GHI SỔ' || 'SYNCED' || 'POSTED' => 'ĐÃ THU HỒI',
            'CẦN XÁC MINH' || 'NEEDS_VERIFICATION' => 'CẦN XÁC MINH',
            'SAP TỪ CHỐI' || 'FAILED' => 'SAP TỪ CHỐI',
            _ => 'THU HỒI',
          }
        : _historyStatusLabel(status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${isRecall ? 'Thu hồi' : 'Hoàn thành'}: '
              '${formatQuantity(child.quantity, uom: child.uom)} ${child.uom}',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: isRecall ? CaslaColors.danger : CaslaColors.primaryNavy,
              ),
            ),
          ),
          _buildHistoryStatusBadge(label: statusLabel, isRecall: isRecall),
          const SizedBox(width: 8),
          Text(
            DateFormat('HH:mm').format(child.occurredAt),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: CaslaColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssignmentGroupSummary(_DailyAssignmentGroup group) {
    final operationName = group.operationName.isEmpty
        ? 'Chưa có tên công đoạn'
        : group.operationName;
    final product = group.productName.isEmpty
        ? 'Chưa có tên hàng'
        : group.productName;
    final productCode = group.productCode.isEmpty ? '—' : group.productCode;
    return Padding(
      padding: const EdgeInsets.only(top: 5, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            operationName,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: CaslaColors.primaryNavy,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'LSX ${group.productionOrder}  ·  CĐ ${group.operation}',
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: CaslaColors.muted,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: CaslaColors.navy100,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: CaslaColors.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildAssignmentInfoLine('Tên hàng', product),
                const SizedBox(height: 5),
                _buildAssignmentInfoLine(
                  'Mã hàng',
                  productCode,
                  monospace: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssignmentInfoLine(
    String label,
    String value, {
    bool monospace = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 58,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: CaslaColors.muted,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontFamily: monospace ? 'monospace' : null,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: CaslaColors.navy900,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAssignmentChild(
    _DailyAssignmentGroup group,
    _DailyAssignmentChild child,
  ) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Giao: ${formatQuantity(child.quantity, uom: child.uom)} ${child.uom}',
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
          StatusChip(
            status: child.status == 'POSTED' ? 'SYNCED' : child.status,
            label: child.status == 'POSTED' ? 'ĐÃ GHI SỔ' : null,
          ),
          const SizedBox(width: 8),
          Text(
            DateFormat('HH:mm').format(child.occurredAt),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: CaslaColors.muted,
            ),
          ),
        ],
      ),
    );
    final assignment = child.localAssignment;
    if (assignment == null) return content;
    return InkWell(
      onTap: () =>
          context.push('/supervisor/assignment_detail', extra: assignment),
      child: content,
    );
  }

  Widget _buildRecallHistory(List<WorkHistoryEntry> sapRecalls) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _recallStream,
      builder: (context, snapshot) {
        final ids =
            sapRecalls
                .map((e) => _normalizeHistoryId(e.transactionUuid))
                .toSet()
              ..remove('');
        final local = (snapshot.data ?? []).where((r) {
          final inScope = _inWorkScope(
            r['work_context_id'],
            plant: r['plant'],
            workCenter: r['work_center'],
          );
          return inScope &&
              !ids.contains(_normalizeHistoryId(r['sap_id'])) &&
              !ids.contains(_normalizeHistoryId(r['idempotency_key']));
        }).toList();
        final recallGroups = _groupHistoryRows(
          sapRecalls,
          local,
          isRecall: true,
        );
        Widget tile(
          String order,
          String operation,
          double quantity,
          String unit,
          DateTime time,
          String status,
        ) {
          final normalizedStatus = status.toUpperCase();
          final badgeLabel = switch (normalizedStatus) {
            'ĐÃ GHI SỔ' || 'SYNCED' || 'POSTED' => 'ĐÃ THU HỒI',
            'CẦN XÁC MINH' || 'NEEDS_VERIFICATION' => 'CẦN XÁC MINH',
            'SAP TỪ CHỐI · KHÔNG TÍNH VÀO SẢN LƯỢNG' ||
            'FAILED' => 'SAP TỪ CHỐI',
            _ => 'THU HỒI',
          };
          return Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CaslaColors.surface,
              border: Border.all(color: CaslaColors.line),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$order · CĐ: $operation',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: CaslaColors.primaryNavy,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${DateFormat('dd/MM HH:mm').format(time)} · $status',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: CaslaColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _buildHistoryStatusBadge(label: badgeLabel, isRecall: true),
                    const SizedBox(height: 6),
                    Text(
                      '−${formatQuantity(quantity, uom: unit)} $unit',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: CaslaColors.danger,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Lịch sử thu hồi (${sapRecalls.length + local.length})',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: CaslaColors.primaryNavy,
              ),
            ),
            if (snapshot.connectionState == ConnectionState.waiting &&
                !snapshot.hasData)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: CaslaSkeleton(height: 68, radius: 12),
              ),
            if (snapshot.hasError)
              TextButton(
                onPressed: () => setState(_resetDataStreams),
                child: const Text(
                  'Chưa tải được thu hồi trên thiết bị. Thử lại',
                ),
              ),
            if (sapRecalls.isEmpty &&
                local.isEmpty &&
                !snapshot.hasError &&
                snapshot.connectionState != ConnectionState.waiting)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Chưa có giao dịch thu hồi trong kỳ này.'),
              ),
            _buildTransactionGroups(recallGroups, isRecall: true),
            if (recallGroups.isEmpty) ...[
              for (final e in sapRecalls)
                tile(
                  e.productionOrder,
                  e.operation,
                  e.quantity,
                  e.unitOfMeasure,
                  e.executionDate,
                  e.transactionStatus == 'POSTED'
                      ? 'Đã ghi sổ'
                      : e.transactionStatus,
                ),
              for (final r in local)
                tile(
                  r['production_order']?.toString() ?? '',
                  r['operation']?.toString() ?? '',
                  (r['quantity'] as num).toDouble(),
                  r['unit_of_measure']?.toString() ?? '',
                  DateTime.fromMillisecondsSinceEpoch(
                    (r['occurred_at_utc'] as num).toInt(),
                  ),
                  switch (r['sync_status']) {
                    'SYNCED' => 'Đã đồng bộ',
                    'FAILED' => 'SAP từ chối · Không tính vào sản lượng',
                    'NEEDS_VERIFICATION' => 'Cần xác minh',
                    _ => 'Chờ đồng bộ',
                  },
                ),
            ],
          ],
        );
      },
    );
  }

  String? _firstRealDepartment(List<Object?> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty && text != 'Công nhân sản xuất') return text;
    }
    return null;
  }
}

/// Marks an activity card whose balance was carried over from the previous
/// working day by SAP's overnight REASSIGN job.
class _CarryOverPin extends StatelessWidget {
  const _CarryOverPin();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Số lượng chuyển tồn từ ngày làm việc trước',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: CaslaColors.carryOverBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: CaslaColors.carryOver.withValues(alpha: 0.35),
          ),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.push_pin, size: 12, color: CaslaColors.carryOver),
            SizedBox(width: 4),
            Flexible(
              child: Text(
                'TỒN TỪ NGÀY TRƯỚC',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: CaslaColors.carryOver,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
