import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../main.dart';
import '../../../presentation/widgets/mutation_feedback.dart';
import '../../../presentation/widgets/worker_verification_dialog.dart';
import '../../../presentation/widgets/casla_empty_state.dart';
import '../../../presentation/widgets/casla_skeleton.dart';
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
  bool _isSubmitting = false;
  bool _isCompletionSheetOpen = false;
  late final Stream<Assignment?> _assignmentStream;
  late final Stream<List<Map<String, dynamic>>> _recordsStream;

  @override
  void initState() {
    super.initState();
    final appState = ref.read(appStateProvider);
    _assignmentStream = appState.assignmentRepo.watchAssignment(
      widget.assignment.id,
    );
    _recordsStream = appState.db.watchRecordsByAssignment(widget.assignment.id);
  }

  Future<void> _openConfirmCompletionSheet(double remainingMax) async {
    if (_isCompletionSheetOpen || _isSubmitting) return;
    _isCompletionSheetOpen = true;
    String qtyInput = '';
    try {
      final quantity = await showModalBottomSheet<double>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setSheetState) {
              final qtyNum = double.tryParse(qtyInput) ?? 0.0;
              final isOverflow = !qtyNum.isFinite || qtyNum > remainingMax;

              return SafeArea(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.viewInsetsOf(context).bottom + 18,
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
                            'Vượt quá số lượng còn lại cho phép.',
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
                        onPressed:
                            (!qtyNum.isFinite || qtyNum <= 0 || isOverflow)
                            ? null
                            : () => Navigator.pop(context, qtyNum),
                        child: const Text('Lưu xác nhận'),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
      if (mounted && quantity != null) await _confirmProduction(quantity);
    } finally {
      _isCompletionSheetOpen = false;
    }
  }

  Future<void> _confirmProduction(double qty) async {
    if (_isSubmitting) return;
    final appState = ref.read(appStateProvider);
    final emp = appState.currentSession;
    final supervisorMaNv = emp?.maNv ?? '';

    final asgId = widget.assignment.id;
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final generation = appState.sessionGeneration;
    setState(() => _isSubmitting = true);

    // Goes through the repository, not the raw store: this is where the
    // assignment-status check and ProductionMath.validateProductionEntry run.
    // The repository throws on a business-rule violation, so the supervisor has
    // to see that as a message rather than an unhandled crash.
    try {
      final workerPassword = await showWorkerVerificationDialog(
        context,
        workerName: widget.assignment.workerName,
        actionLabel: 'xác nhận sản lượng lên SAP',
      );
      if (!mounted || workerPassword == null) return;
      if (!appState.isSessionGenerationCurrent(generation) ||
          appState.currentSession?.toIds.contains(widget.assignment.teamId) !=
              true) {
        throw Exception(
          'Phiên hoặc quyền đã thay đổi. Vui lòng mở lại thao tác.',
        );
      }
      final receipt = await appState.productionRepo.recordProduction(
        assignmentId: asgId,
        quantity: qty,
        businessDate: today,
        shiftId: widget.assignment.shiftId,
        createdBy: supervisorMaNv,
        workerPassword: workerPassword,
      );
      if (!mounted) return;
      showMutationFeedback(
        context,
        receipt: receipt,
        successMessage: 'Đã ghi nhận +${qty.toStringAsFixed(0)} cái.',
      );
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_errorText(e)),
          backgroundColor: CaslaColors.danger,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// Strips Dart's "Exception: " prefix so the supervisor reads the business
  /// message, not the wrapper.
  String _errorText(Exception e) =>
      e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final canRecall =
        appState.currentSession?.hasPermission(Permission.recallAssignment) ==
        true;

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
              '${widget.assignment.productName} · ${widget.assignment.workerName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
      body: StreamBuilder<Assignment?>(
        stream: _assignmentStream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const _AssignmentDetailSkeleton();
          }
          if (snapshot.hasError) {
            return const CaslaEmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'Không tải được phân công',
              message:
                  'Dữ liệu trên thiết bị chưa bị thay đổi. Hãy quay lại và thử lần nữa.',
            );
          }
          final assignment = snapshot.data;
          if (assignment == null) {
            return const CaslaEmptyState(
              icon: Icons.assignment_late_outlined,
              title: 'Không tìm thấy phân công',
              message:
                  'Phân công có thể đã được thay đổi hoặc không còn tồn tại.',
            );
          }

          final effective = assignment.effectiveAssigned;
          final completed = assignment.completedQuantity;
          final remaining = assignment.remaining;
          final recalled = assignment.recalledQuantity;
          final initialAssigned = assignment.assignedQuantity;
          final pct = effective > 0 ? (completed / effective) : 0.0;

          return Column(
            children: [
              Expanded(
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: _recordsStream,
                  builder: (context, recordsSnapshot) {
                    if (recordsSnapshot.connectionState ==
                            ConnectionState.waiting &&
                        !recordsSnapshot.hasData) {
                      return const _AssignmentDetailSkeleton();
                    }
                    final recordsLoadFailed = recordsSnapshot.hasError;
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
                                  value: formatQuantity(initialAssigned),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: KpiCard(
                                  label: 'Đã thu hồi',
                                  value: formatQuantity(recalled),
                                  valueColor: CaslaColors.danger,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          // Ring progress card
                          RingProgressCard(
                            percentage: pct,
                            remainingValue: formatQuantity(remaining),
                            detailText:
                                'Giao hiệu lực ${formatQuantity(effective)} · Hoàn thành lũy kế ${formatQuantity(completed)}',
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

                          if (recordsLoadFailed)
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
                                      'Chưa tải được lịch sử. Số liệu phân công phía trên vẫn dùng được.',
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
                          else if (records.isEmpty)
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
                                            '+${formatQuantity((r['quantity'] as num).toDouble())}',
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
                      onPressed: remaining <= 0 || _isSubmitting
                          ? null
                          : () => _openConfirmCompletionSheet(remaining),
                      icon: _isSubmitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: CaslaColors.navy900,
                              ),
                            )
                          : const Icon(Icons.check_circle_outline),
                      label: Text(
                        _isSubmitting
                            ? 'Đang gửi giao dịch'
                            : 'Xác nhận hoàn thành',
                      ),
                    ),
                    if (canRecall) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: remaining <= 0 || _isSubmitting
                            ? null
                            : () {
                                context.push(
                                  '/supervisor/recall_assignment',
                                  extra: assignment,
                                );
                              },
                        icon: const Icon(Icons.undo),
                        label: const Text('Thu hồi phần chưa làm'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: CaslaColors.danger,
                          side: const BorderSide(color: CaslaColors.danger),
                        ),
                      ),
                    ],
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

class _AssignmentDetailSkeleton extends StatelessWidget {
  const _AssignmentDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: const [
        Row(
          children: [
            Expanded(child: CaslaSkeleton(height: 84, radius: 12)),
            SizedBox(width: 10),
            Expanded(child: CaslaSkeleton(height: 84, radius: 12)),
          ],
        ),
        SizedBox(height: 12),
        CaslaSkeleton(height: 148, radius: 14),
        SizedBox(height: 20),
        CaslaSkeleton(width: 160, height: 18, radius: 6),
        SizedBox(height: 10),
        CaslaSkeleton(height: 68, radius: 12),
        SizedBox(height: 8),
        CaslaSkeleton(height: 68, radius: 12),
      ],
    );
  }
}
