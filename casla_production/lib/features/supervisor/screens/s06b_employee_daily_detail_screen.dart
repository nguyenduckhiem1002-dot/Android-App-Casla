import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/work_history.dart';
import '../../../main.dart';
import '../../../presentation/widgets/casla_skeleton.dart';
import '../../../presentation/widgets/status_chip.dart';

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

class _S06bEmployeeDailyDetailScreenState
    extends ConsumerState<S06bEmployeeDailyDetailScreen> {
  late DateTime _dateFrom;
  late DateTime _dateTo;
  late Stream<WorkHistoryResult> _historyStream;
  late Stream<List<Assignment>> _assignmentStream;
  late Stream<List<Map<String, dynamic>>> _productionStream;

  String _dateStr(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  bool get _isSameDay =>
      _dateOnly(_dateFrom).isAtSameMomentAs(_dateOnly(_dateTo));

  bool _isInRange(String businessDate) {
    final parsed = DateTime.tryParse(businessDate);
    if (parsed == null) return false;
    final d = _dateOnly(parsed);
    return !d.isBefore(_dateOnly(_dateFrom)) && !d.isAfter(_dateOnly(_dateTo));
  }

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
    _dateFrom = (widget.worker['date_from'] as DateTime?) ?? initialDate;
    _dateTo = (widget.worker['date_to'] as DateTime?) ?? initialDate;
    _resetDataStreams();
  }

  String get _workerId => widget.worker['id']?.toString() ?? '';

  void _resetDataStreams() {
    final appState = ref.read(appStateProvider);
    final fromStr = _dateStr(_dateFrom);
    final toStr = _dateStr(_dateTo);
    _historyStream = appState.workHistoryRepo.watchWorkHistory(
      range: HistoryRange.custom,
      dateFrom: _dateFrom,
      dateTo: _dateTo,
    );
    _assignmentStream = appState.assignmentRepo.watchWorkerAssignments(
      _workerId,
    );
    _productionStream = appState.db.watchProductionHistory(
      _workerId,
      fromBusinessDate: fromStr,
      toBusinessDate: toStr,
    );
  }

  Future<WorkHistoryResult> _fetchHistory({bool forceRefresh = false}) {
    return ref
        .read(appStateProvider)
        .workHistoryRepo
        .getWorkHistory(
          range: HistoryRange.custom,
          dateFrom: _dateFrom,
          dateTo: _dateTo,
          forceRefresh: forceRefresh,
        );
  }

  Future<void> _refresh() async {
    try {
      await _fetchHistory(forceRefresh: true);
    } catch (_) {}
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
      lastDate: DateTime(now.year + 2, 12, 31),
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
      initialDate: _dateFrom,
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: DateTime(now.year + 2, 12, 31),
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
                              Row(
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
                                  const SizedBox(width: 6),
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
                        _dateTo = end;
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
                        _dateTo = end;
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
    final workerTeam =
        widget.worker['bo_phan']?.toString() ?? 'Chưa xác định tổ';
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
              workerName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$workerCode · $workerTeam',
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
            color: CaslaColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                    Text(
                      _dateHeaderLabel,
                      style: const TextStyle(
                        fontFamily: 'Manrope',
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                  ],
                ),
                OutlinedButton.icon(
                  onPressed: _showDateRangeSheet,
                  icon: const Icon(Icons.tune_rounded, size: 16),
                  label: const Text('Đổi ngày ▾'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: CaslaColors.primaryNavy,
                    side: const BorderSide(
                      color: CaslaColors.accentGold,
                      width: 1.3,
                    ),
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

                          if (isSapLoading &&
                              isAssignLoading &&
                              isProdLoading) {
                            return const _EmployeeDetailSkeleton();
                          }

                          // 1. Process SAP Data
                          final sapResult = sapSnapshot.data;
                          final allSapEntries =
                              sapResult?.entries ?? const <WorkHistoryEntry>[];
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

                          final sapConfirms = workerSapEntries
                              .where((e) => e.transactionType == 'CONFIRM')
                              .toList();

                          final sapSummary = sapResult?.workers
                              .where(
                                (w) =>
                                    w.workerId == workerCode ||
                                    w.workerId == workerId ||
                                    (workerId.isNotEmpty &&
                                        w.workerId.toLowerCase() ==
                                            workerId.toLowerCase()) ||
                                    (workerCode.isNotEmpty &&
                                        w.workerId.toLowerCase() ==
                                            workerCode.toLowerCase()),
                              )
                              .firstOrNull;

                          // 2. Process Local Data
                          final allAssignments =
                              assignmentSnapshot.data ?? const <Assignment>[];
                          final filteredAssignments = allAssignments
                              .where((a) => _isInRange(a.businessDate))
                              .toList();
                          final productionRecords = prodSnapshot.data ?? [];

                          // 3. Compute Totals
                          double totalAssigned = 0.0;
                          double totalCompleted = 0.0;
                          double totalRemaining = 0.0;
                          String uom =
                              (widget.worker['uom'] as String?) ?? 'cái';

                          if (sapSummary != null) {
                            totalAssigned = sapSummary.assignedQuantity;
                            totalCompleted = sapSummary.completedQuantity;
                            totalRemaining = sapSummary.remainingQuantity;
                            if (sapSummary.unitOfMeasure.isNotEmpty) {
                              uom = sapSummary.unitOfMeasure;
                            }
                          } else {
                            // Sum from SAP entries if no summary
                            for (final a in sapInitialAssigns) {
                              totalAssigned += a.quantity;
                              if (a.unitOfMeasure.isNotEmpty) {
                                uom = a.unitOfMeasure;
                              }
                            }
                            for (final c in sapConfirms) {
                              totalCompleted += c.quantity;
                            }
                            // Sum local assignments
                            for (final a in filteredAssignments) {
                              totalAssigned += a.effectiveAssigned;
                              totalCompleted += a.completedQuantity;
                            }
                            // Local production records if not already in completed
                            if (sapConfirms.isEmpty &&
                                filteredAssignments.isEmpty) {
                              for (final r in productionRecords) {
                                totalCompleted +=
                                    (r['quantity'] as num?)?.toDouble() ?? 0.0;
                              }
                            }
                            totalRemaining = (totalAssigned - totalCompleted)
                                .clamp(0.0, double.infinity);
                          }

                          // Fallback to widget extra if 0
                          if (totalAssigned == 0 &&
                              widget.worker['assigned_qty'] != null) {
                            totalAssigned =
                                (widget.worker['assigned_qty'] as num)
                                    .toDouble();
                            totalCompleted =
                                (widget.worker['completed_qty'] as num?)
                                    ?.toDouble() ??
                                0.0;
                            totalRemaining =
                                (widget.worker['remaining_qty'] as num?)
                                    ?.toDouble() ??
                                0.0;
                          }

                          final completionRate = totalAssigned > 0
                              ? (totalCompleted / totalAssigned).clamp(0.0, 1.0)
                              : 0.0;

                          final hasNoAssignments =
                              filteredAssignments.isEmpty &&
                              sapInitialAssigns.isEmpty;
                          final hasNoConfirms =
                              productionRecords.isEmpty && sapConfirms.isEmpty;

                          return ListView(
                            padding: const EdgeInsets.all(18),
                            children: [
                              // KPI Summary Card
                              Container(
                                margin: const EdgeInsets.only(bottom: 20),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: CaslaColors.surface,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: CaslaColors.line),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceAround,
                                      children: [
                                        _buildSummaryColumn(
                                          'Tổng giao',
                                          formatQuantity(totalAssigned),
                                          uom,
                                        ),
                                        Container(
                                          width: 1,
                                          height: 36,
                                          color: CaslaColors.line,
                                        ),
                                        _buildSummaryColumn(
                                          'Hoàn thành',
                                          formatQuantity(totalCompleted),
                                          uom,
                                          color: CaslaColors.success,
                                        ),
                                        Container(
                                          width: 1,
                                          height: 36,
                                          color: CaslaColors.line,
                                        ),
                                        _buildSummaryColumn(
                                          'Còn lại',
                                          formatQuantity(totalRemaining),
                                          uom,
                                          color: CaslaColors.accentGold,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 14),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: LinearProgressIndicator(
                                        value: completionRate,
                                        minHeight: 8,
                                        backgroundColor: CaslaColors.muted100,
                                        valueColor:
                                            const AlwaysStoppedAnimation<Color>(
                                              CaslaColors.accentGold,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text(
                                          'Tiến độ hoàn thành',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: CaslaColors.muted,
                                          ),
                                        ),
                                        Text(
                                          '${(completionRate * 100).toStringAsFixed(0)}%',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            fontFamily: 'monospace',
                                            color: CaslaColors.primaryNavy,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),

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
                                    '(${filteredAssignments.length + sapInitialAssigns.length})',
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
                                    border: Border.all(color: CaslaColors.line),
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
                                // SAP Assignments
                                for (final e in sapInitialAssigns)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: CaslaColors.surface,
                                      border: Border.all(
                                        color: CaslaColors.line,
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              '${e.productionOrder} · CĐ: ${e.operation}',
                                              style: const TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: CaslaColors.primaryNavy,
                                              ),
                                            ),
                                            StatusChip(
                                              status:
                                                  e.transactionStatus ==
                                                      'POSTED'
                                                  ? 'SYNCED'
                                                  : e.transactionStatus,
                                              label:
                                                  e.transactionStatus ==
                                                      'POSTED'
                                                  ? 'ĐÃ GHI SỔ'
                                                  : null,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              'Giao: ${formatQuantity(e.quantity)} ${e.unitOfMeasure}',
                                              style: const TextStyle(
                                                fontFamily: 'Manrope',
                                                fontWeight: FontWeight.w700,
                                                fontSize: 14,
                                                color: CaslaColors.primaryNavy,
                                              ),
                                            ),
                                            Text(
                                              DateFormat(
                                                'dd/MM HH:mm',
                                              ).format(e.executionDate),
                                              style: const TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 11,
                                                color: CaslaColors.muted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),

                                // Local Assignments
                                for (final asg in filteredAssignments)
                                  Material(
                                    color: CaslaColors.surface,
                                    borderRadius: BorderRadius.circular(14),
                                    child: InkWell(
                                      onTap: () {
                                        context.push(
                                          '/supervisor/assignment_detail',
                                          extra: asg,
                                        );
                                      },
                                      borderRadius: BorderRadius.circular(14),
                                      child: Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 10,
                                        ),
                                        padding: const EdgeInsets.all(14),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: CaslaColors.line,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                Text(
                                                  asg.orderCode,
                                                  style: const TextStyle(
                                                    fontFamily: 'monospace',
                                                    fontSize: 11.5,
                                                    fontWeight: FontWeight.w600,
                                                    color: CaslaColors.muted,
                                                  ),
                                                ),
                                                StatusChip(
                                                  status: asg.status.label,
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                Text(
                                                  'Giao: ${formatQuantity(asg.effectiveAssigned)} ${asg.uom}',
                                                  style: const TextStyle(
                                                    fontFamily: 'Manrope',
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: 14,
                                                    color:
                                                        CaslaColors.primaryNavy,
                                                  ),
                                                ),
                                                const Icon(
                                                  Icons.chevron_right,
                                                  color: CaslaColors.muted,
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                              ],

                              const SizedBox(height: 20),

                              // Section: Lịch sử xác nhận hoàn thành
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

                              if (prodSnapshot.hasError && sapSnapshot.hasError)
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
                                  child: const Row(
                                    children: [
                                      Icon(
                                        Icons.history_toggle_off_outlined,
                                        color: CaslaColors.danger,
                                      ),
                                      SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          'Chưa tải được lịch sử sản lượng. Danh sách phân công phía trên vẫn dùng được.',
                                          style: TextStyle(
                                            color: CaslaColors.danger,
                                            fontSize: 12.5,
                                            height: 1.4,
                                          ),
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
                                    border: Border.all(color: CaslaColors.line),
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
                                // SAP Confirmations
                                for (final e in sapConfirms)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: CaslaColors.surface,
                                      border: Border.all(
                                        color: CaslaColors.line,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
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
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13,
                                                  color:
                                                      CaslaColors.primaryNavy,
                                                ),
                                              ),
                                              Text(
                                                '${DateFormat('HH:mm').format(e.executionDate)} · Trạng thái: ${e.transactionStatus}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
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
                                        Text(
                                          '+${formatQuantity(e.quantity)} ${e.unitOfMeasure}',
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                            color: CaslaColors.success,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                // Local production records
                                for (final r in productionRecords)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: CaslaColors.surface,
                                      border: Border.all(
                                        color: CaslaColors.line,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
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
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13,
                                                  color:
                                                      CaslaColors.primaryNavy,
                                                ),
                                              ),
                                              Text(
                                                '${DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(r['occurred_at_utc'] ?? 0))} · Người xác nhận: ${r['nguoi_xac_nhan']}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
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
                                        Text(
                                          '+${formatQuantity((r['quantity'] as num).toDouble())} $uom',
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                            color: CaslaColors.success,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
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

  Widget _buildSummaryColumn(
    String label,
    String value,
    String uom, {
    Color color = CaslaColors.primaryNavy,
  }) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: CaslaColors.muted,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              uom,
              style: const TextStyle(
                fontSize: 11,
                color: CaslaColors.muted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
