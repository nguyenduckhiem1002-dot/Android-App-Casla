import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../main.dart';
import '../../../presentation/widgets/casla_empty_state.dart';
import '../../../presentation/widgets/casla_skeleton.dart';
import '../../../presentation/widgets/mutation_feedback.dart';
import '../../../presentation/widgets/worker_verification_dialog.dart';

class S09RecallScreen extends ConsumerStatefulWidget {
  final Assignment assignment;

  const S09RecallScreen({super.key, required this.assignment});

  @override
  ConsumerState<S09RecallScreen> createState() => _S09RecallScreenState();
}

class _S09RecallScreenState extends ConsumerState<S09RecallScreen> {
  final TextEditingController _qtyController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  /// Single source of truth for reason codes.
  ///
  /// This screen used to carry its own Vietnamese code map ('KHONG_LAM_HET',
  /// 'KHAC') while the domain layer validates against RecallReason's English
  /// codes ('NOT_FINISHED', 'OTHER'). Once writes go through RecallRepository
  /// that mismatch would silently disable the mandatory-note rule for "Khác" —
  /// no crash, no error, just a business rule that stops firing.
  RecallReason _selectedReason = RecallReason.notFinished;
  bool _isSubmitting = false;
  String? _quantityError;
  String? _noteError;
  late final Stream<Assignment?> _assignmentStream;

  @override
  void initState() {
    super.initState();
    _assignmentStream = ref
        .read(appStateProvider)
        .assignmentRepo
        .watchAssignment(widget.assignment.id);
  }

  @override
  void dispose() {
    _qtyController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submitRecall(double maxRecall) async {
    final qty = double.tryParse(_qtyController.text) ?? 0.0;
    if (!qty.isFinite || qty <= 0 || qty > maxRecall) {
      setState(() {
        _quantityError =
            'Nhập số lượng lớn hơn 0 và không quá ${maxRecall.toStringAsFixed(0)}.';
      });
      return;
    }

    if (_selectedReason == RecallReason.other &&
        _noteController.text.trim().isEmpty) {
      setState(() => _noteError = 'Vui lòng nhập lý do cụ thể.');
      return;
    }

    setState(() {
      _quantityError = null;
      _noteError = null;
    });

    final appState = ref.read(appStateProvider);
    final emp = appState.currentSession;
    final supervisorMaNv = emp?.maNv ?? '';
    final workerPassword = await showWorkerVerificationDialog(
      context,
      workerName: widget.assignment.workerName,
      actionLabel: 'gửi thu hồi lên SAP',
    );
    if (!mounted || workerPassword == null) return;

    setState(() => _isSubmitting = true);

    // Through the repository so ProductionMath.validateRecallEntry runs — the
    // max-recall ceiling and the mandatory note for "Khác" live there.
    try {
      final receipt = await appState.recallRepo.recallAssignment(
        assignmentId: widget.assignment.id,
        quantity: qty,
        reasonCode: _selectedReason.code,
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
        businessDate: DateFormat('yyyy-MM-dd').format(DateTime.now()),
        shiftId: widget.assignment.shiftId,
        createdBy: supervisorMaNv,
        workerPassword: workerPassword,
      );
      if (!mounted) return;
      showMutationFeedback(
        context,
        receipt: receipt,
        successMessage: 'Đã thu hồi ${qty.toStringAsFixed(0)} cái.',
      );
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst(RegExp(r'^Exception:\s*'), ''),
          ),
          backgroundColor: CaslaColors.danger,
        ),
      );
      return;
    }

    if (!mounted) return;

    context.pop();
  }

  @override
  Widget build(BuildContext context) {
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
            const Text(
              'Thu hồi phân công',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${widget.assignment.orderCode} · ${widget.assignment.workerName}',
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
      body: StreamBuilder<Assignment?>(
        stream: _assignmentStream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const _RecallSkeleton();
          }
          if (snapshot.hasError) {
            return const CaslaEmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'Không tải được số lượng thu hồi',
              message:
                  'Dữ liệu chưa bị thay đổi. Hãy quay lại và mở màn hình lần nữa.',
            );
          }
          final assignment = snapshot.data;
          if (assignment == null) {
            return const CaslaEmptyState(
              icon: Icons.assignment_late_outlined,
              title: 'Không tìm thấy phân công',
              message: 'Phân công có thể đã được thay đổi trên thiết bị.',
            );
          }

          final effective = assignment.effectiveAssigned;
          final completed = assignment.completedQuantity;
          final maxRecall = assignment.maxRecall;

          final qtyInput = double.tryParse(_qtyController.text) ?? 0.0;
          final afterEffective = effective - qtyInput;
          final afterRemaining = maxRecall - qtyInput;

          return Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Quick Stats Row
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: CaslaColors.surface,
                          border: Border.all(color: CaslaColors.line),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildStatCol(
                              'Giao ban đầu',
                              effective.toStringAsFixed(0),
                            ),
                            _buildStatCol(
                              'Đã hoàn thành',
                              completed.toStringAsFixed(0),
                            ),
                            _buildStatCol(
                              'Có thể thu hồi',
                              maxRecall.toStringAsFixed(0),
                              color: CaslaColors.gold700,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Quantity input
                      const Text(
                        'Số lượng thu hồi *',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: CaslaColors.primaryNavy,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _qtyController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (value) => setState(() {
                          _quantityError = null;
                        }),
                        decoration: InputDecoration(
                          errorText: _quantityError,
                          suffixText: '/ ${maxRecall.toStringAsFixed(0)} cái',
                          suffixStyle: const TextStyle(
                            color: CaslaColors.muted,
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Reason Radio options
                      const Text(
                        'Lý do thu hồi *',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: CaslaColors.primaryNavy,
                        ),
                      ),
                      const SizedBox(height: 8),

                      RadioGroup<RecallReason>(
                        groupValue: _selectedReason,
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _selectedReason = value;
                              if (value != RecallReason.other) {
                                _noteError = null;
                              }
                            });
                          }
                        },
                        child: Column(
                          children: RecallReason.values.map((reason) {
                            final isSelected = _selectedReason == reason;
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? CaslaColors.gold100
                                    : CaslaColors.surface,
                                border: Border.all(
                                  color: isSelected
                                      ? CaslaColors.gold700
                                      : CaslaColors.line,
                                  width: 1.5,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: RadioListTile<RecallReason>(
                                value: reason,
                                activeColor: CaslaColors.gold700,
                                title: Text(
                                  reason.title,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: CaslaColors.primaryNavy,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),

                      if (_selectedReason == RecallReason.other) ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: _noteController,
                          onChanged: (_) {
                            if (_noteError != null) {
                              setState(() => _noteError = null);
                            }
                          },
                          decoration: InputDecoration(
                            hintText: 'Nhập lý do cụ thể...',
                            errorText: _noteError,
                          ),
                        ),
                      ],

                      const SizedBox(height: 16),

                      // Impact Preview Box
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: CaslaColors.dangerBg,
                          border: Border.all(color: const Color(0xFFF0C6C6)),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Giao hiệu lực',
                                  style: TextStyle(
                                    color: Color(0xFF7A1F1F),
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  '${effective.toStringAsFixed(0)} → ${afterEffective < 0 ? 0 : afterEffective.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF7A1F1F),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Còn lại sau thu hồi',
                                  style: TextStyle(
                                    color: Color(0xFF7A1F1F),
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  '${maxRecall.toStringAsFixed(0)} → ${afterRemaining < 0 ? 0 : afterRemaining.toStringAsFixed(0)}',
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF7A1F1F),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.all(18),
                child: ElevatedButton(
                  onPressed: _isSubmitting || maxRecall <= 0
                      ? null
                      : () => _submitRecall(maxRecall),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: CaslaColors.danger,
                    foregroundColor: Colors.white,
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Xác nhận thu hồi'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatCol(String label, String value, {Color? color}) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: CaslaColors.muted),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontFamily: 'Manrope',
            fontWeight: FontWeight.w800,
            fontSize: 16,
            color: color ?? CaslaColors.primaryNavy,
          ),
        ),
      ],
    );
  }
}

class _RecallSkeleton extends StatelessWidget {
  const _RecallSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: const [
        CaslaSkeleton(height: 76, radius: 14),
        SizedBox(height: 16),
        CaslaSkeleton(width: 150, height: 16, radius: 6),
        SizedBox(height: 8),
        CaslaSkeleton(height: 54, radius: 8),
        SizedBox(height: 20),
        CaslaSkeleton(width: 120, height: 16, radius: 6),
        SizedBox(height: 8),
        CaslaSkeleton(height: 156, radius: 12),
      ],
    );
  }
}
