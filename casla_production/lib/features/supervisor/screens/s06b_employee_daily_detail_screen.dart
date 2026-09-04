import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
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
  late DateTime _selectedDate;
  Future<WorkHistoryResult>? _historyFuture;

  String _dateStr(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  @override
  void initState() {
    super.initState();
    _selectedDate = (widget.worker['date'] as DateTime?) ?? DateTime.now();
    _historyFuture = _fetchHistory();
  }

  Future<WorkHistoryResult> _fetchHistory() {
    return ref
        .read(appStateProvider)
        .workHistoryRepo
        .getWorkHistory(
          range: HistoryRange.custom,
          dateFrom: _selectedDate,
          dateTo: _selectedDate,
        );
  }

  Future<void> _refresh() async {
    final next = _fetchHistory();
    setState(() => _historyFuture = next);
    try {
      await next;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
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
                Text(
                  'Ngày: ${DateFormat('dd/MM/yyyy').format(_selectedDate)}',
                  style: const TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _selectedDate,
                      firstDate: DateTime(now.year - 2, 1, 1),
                      lastDate: DateTime(now.year + 2, 12, 31),
                    );
                    if (picked != null) {
                      setState(() {
                        _selectedDate = picked;
                        _historyFuture = _fetchHistory();
                      });
                    }
                  },
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: const Text('Chọn ngày'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(110, 36),
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
              child: FutureBuilder<WorkHistoryResult>(
                future: _historyFuture,
                builder: (context, sapSnapshot) {
                  return StreamBuilder<List<Assignment>>(
                    stream: appState.assignmentRepo.watchWorkerAssignments(
                      workerId,
                    ),
                    builder: (context, assignmentSnapshot) {
                      final dateFormatted = _dateStr(_selectedDate);

                      return StreamBuilder<List<Map<String, dynamic>>>(
                        stream: appState.db.watchProductionHistory(
                          workerId,
                          fromBusinessDate: dateFormatted,
                          toBusinessDate: dateFormatted,
                        ),
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
                              .where((a) => a.businessDate == dateFormatted)
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
                                          totalAssigned.toStringAsFixed(0),
                                          uom,
                                        ),
                                        Container(
                                          width: 1,
                                          height: 36,
                                          color: CaslaColors.line,
                                        ),
                                        _buildSummaryColumn(
                                          'Hoàn thành',
                                          totalCompleted.toStringAsFixed(0),
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
                                          totalRemaining.toStringAsFixed(0),
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

                              // Section: Phân công trong ngày
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'Phân công trong ngày',
                                    style: TextStyle(
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
                                  child: const Center(
                                    child: Text(
                                      'Không có phân công nào trong ngày này.',
                                      style: TextStyle(
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
                                              'Giao: ${e.quantity.toStringAsFixed(0)} ${e.unitOfMeasure}',
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
                                                  'Giao: ${asg.effectiveAssigned.toStringAsFixed(0)} ${asg.uom}',
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
                                          '+${e.quantity.toStringAsFixed(0)} ${e.unitOfMeasure}',
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
                                          '+${(r['quantity'] as double).toStringAsFixed(0)} cái',
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
