import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/entities.dart';
import '../../../main.dart';
import '../../../presentation/widgets/kpi_card.dart';
import '../../../presentation/widgets/num_pad.dart';
import '../../../presentation/widgets/ring_progress_card.dart';
import '../../../presentation/widgets/status_chip.dart';

class S08AssignmentDetailScreen extends ConsumerStatefulWidget {
  final Assignment assignment;

  const S08AssignmentDetailScreen({super.key, required this.assignment});

  @override
  ConsumerState<S08AssignmentDetailScreen> createState() =>
      _S08AssignmentDetailScreenState();
}

class _S08AssignmentDetailScreenState
    extends ConsumerState<S08AssignmentDetailScreen> {
  void _openConfirmCompletionSheet(double remainingMax) {
    String qtyInput = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final qtyNum = double.tryParse(qtyInput) ?? 0.0;
            final isOverflow = qtyNum > remainingMax;

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 18,
                top: 18,
                left: 18,
                right: 18,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: CaslaColors.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Xác nhận hoàn thành',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                  Text(
                    'Nhập số lượng công nhân vừa hoàn thành (Tối đa: ${remainingMax.toStringAsFixed(0)} cái)',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      color: CaslaColors.muted,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Qty display
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        qtyInput.isEmpty ? '0' : qtyInput,
                        style: TextStyle(
                          fontFamily: 'Manrope',
                          fontWeight: FontWeight.w800,
                          fontSize: 42,
                          color: isOverflow
                              ? CaslaColors.danger
                              : CaslaColors.primaryNavy,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        'cái',
                        style: TextStyle(
                          fontSize: 14,
                          color: CaslaColors.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),

                  if (isOverflow)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Vượt quá số lượng còn lại cho phép!',
                        style: TextStyle(
                          color: CaslaColors.danger,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),

                  const SizedBox(height: 16),

                  NumPad(
                    value: qtyInput,
                    onChanged: (val) {
                      setSheetState(() {
                        qtyInput = val;
                      });
                    },
                  ),

                  const SizedBox(height: 16),

                  ElevatedButton(
                    onPressed: (qtyNum <= 0 || isOverflow)
                        ? null
                        : () async {
                            Navigator.pop(context);
                            await _confirmProduction(qtyNum);
                          },
                    child: const Text('Lưu xác nhận'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _confirmProduction(double qty) async {
    final appState = ref.read(appStateProvider);
    final emp = appState.currentSession;
    final supervisorMaNv = emp?.maNv ?? '';

    final asgId = widget.assignment.id;
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

    // Goes through the repository, not the raw store: this is where the
    // assignment-status check and ProductionMath.validateProductionEntry run.
    // The repository throws on a business-rule violation, so the supervisor has
    // to see that as a message rather than an unhandled crash.
    try {
      await appState.productionRepo.recordProduction(
        assignmentId: asgId,
        quantity: qty,
        businessDate: today,
        shiftId: widget.assignment.shiftId,
        createdBy: supervisorMaNv,
      );
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_errorText(e)),
          backgroundColor: CaslaColors.danger,
        ),
      );
      return;
    }

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã xác nhận hoàn thành +${qty.toStringAsFixed(0)} cái'),
        backgroundColor: CaslaColors.success,
      ),
    );
  }

  /// Strips Dart's "Exception: " prefix so the supervisor reads the business
  /// message, not the wrapper.
  String _errorText(Exception e) =>
      e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final asgId = widget.assignment.id;

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
              widget.assignment.orderCode,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'Áo khoác gió L · Nguyễn Văn A',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: CaslaColors.identityMeta,
              ),
            ),
          ],
        ),
      ),
      body: FutureBuilder<List<dynamic>>(
        future: Future.wait([
          appState.db.getEffectiveAssigned(asgId),
          appState.db.getCompletedQuantity(asgId),
          appState.db.getRemaining(asgId),
          appState.db.getRecalledQuantity(asgId),
        ]),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final effective = snapshot.data![0] as double;
          final completed = snapshot.data![1] as double;
          final remaining = snapshot.data![2] as double;
          final recalled = snapshot.data![3] as double;

          final initialAssigned = widget.assignment.assignedQuantity;
          final pct = effective > 0 ? (completed / effective) : 0.0;

          return Column(
            children: [
              Expanded(
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: appState.db.watchRecordsByAssignment(asgId),
                  builder: (context, recordsSnapshot) {
                    final records = recordsSnapshot.data ?? [];

                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // KPI 2 cards
                          Row(
                            children: [
                              Expanded(
                                child: KpiCard(
                                  label: 'Giao ban đầu',
                                  value: initialAssigned.toStringAsFixed(0),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: KpiCard(
                                  label: 'Đã thu hồi',
                                  value: recalled.toStringAsFixed(0),
                                  valueColor: CaslaColors.danger,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          // Ring progress card
                          RingProgressCard(
                            percentage: pct,
                            remainingValue: remaining.toStringAsFixed(0),
                            detailText:
                                'Giao hiệu lực ${effective.toStringAsFixed(0)} · Hoàn thành lũy kế ${completed.toStringAsFixed(0)}',
                          ),

                          const SizedBox(height: 20),

                          const Text(
                            'Lịch sử giao dịch',
                            style: TextStyle(
                              fontFamily: 'Manrope',
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          const SizedBox(height: 10),

                          if (records.isEmpty)
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: CaslaColors.surface,
                                border: Border.all(color: CaslaColors.line),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Center(
                                child: Text(
                                  'Chưa có giao dịch nào được ghi nhận.',
                                  style: TextStyle(
                                    color: CaslaColors.muted,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            )
                          else
                            ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: records.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final r = records[index];
                                final timeStr = DateFormat('HH:mm').format(
                                  DateTime.fromMillisecondsSinceEpoch(
                                    r['occurred_at_utc'] ?? 0,
                                  ),
                                );

                                return Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: CaslaColors.surface,
                                    border: Border.all(color: CaslaColors.line),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: const BoxDecoration(
                                          color: CaslaColors.success,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Xác nhận hoàn thành',
                                              style: TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13,
                                                color: CaslaColors.primaryNavy,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '$timeStr · Xác nhận bởi ${r['created_by']}',
                                              style: const TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 11,
                                                color: CaslaColors.muted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            '+${(r['quantity'] as double).toStringAsFixed(0)}',
                                            style: const TextStyle(
                                              fontFamily: 'monospace',
                                              fontWeight: FontWeight.w700,
                                              fontSize: 14,
                                              color: CaslaColors.success,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          StatusChip(
                                            status:
                                                r['sync_status'] ?? 'SYNCED',
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),

              // Bottom Action Buttons
              Container(
                padding: const EdgeInsets.all(18),
                decoration: const BoxDecoration(
                  color: CaslaColors.surface,
                  border: Border(top: BorderSide(color: CaslaColors.line)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton.icon(
                      onPressed: remaining <= 0
                          ? null
                          : () => _openConfirmCompletionSheet(remaining),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Xác nhận hoàn thành'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: remaining <= 0
                          ? null
                          : () {
                              context.push(
                                '/supervisor/recall_assignment',
                                extra: widget.assignment,
                              );
                            },
                      icon: const Icon(Icons.undo, color: CaslaColors.danger),
                      label: const Text(
                        'Thu hồi phần chưa làm',
                        style: TextStyle(color: CaslaColors.danger),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: CaslaColors.danger),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
