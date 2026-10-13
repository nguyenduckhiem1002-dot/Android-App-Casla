import 'dart:async';

import '../../../core/auth/session_manager.dart';
import '../../../core/utils/shift_execution_validation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../domain/entities/mutation_receipt.dart';
import '../../../main.dart';
import '../../../presentation/widgets/mutation_feedback.dart';
import '../../../presentation/widgets/over_limit_line.dart';
import '../../../presentation/widgets/worker_verification_dialog.dart';
import '../../../presentation/widgets/casla_empty_state.dart';
import '../../../presentation/widgets/casla_skeleton.dart';
import '../../../presentation/widgets/kpi_card.dart';
import '../../../presentation/widgets/ring_progress_card.dart';
import '../../../presentation/widgets/status_chip.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../domain/policies/grouped_confirmation.dart';
import '../../../domain/policies/production_math.dart';

class S08AssignmentDetailScreen extends ConsumerStatefulWidget {
  final Assignment assignment;
  final bool openConfirmation;

  /// Allocations of the same order/operation confirmed together (see
  /// grouped_confirmation.dart). Empty or single means just [assignment].
  final List<Assignment> confirmationGroup;

  const S08AssignmentDetailScreen({
    super.key,
    required this.assignment,
    this.openConfirmation = false,
    this.confirmationGroup = const [],
  });

  @override
  ConsumerState<S08AssignmentDetailScreen> createState() =>
      _S08AssignmentDetailScreenState();
}

enum _CompletionEntryMode { completed, remaining }

class _ConfirmationDraft {
  final double completed;
  final double defect;
  final double recalled;
  final double? expectedRemaining;

  const _ConfirmationDraft({
    required this.completed,
    required this.defect,
    required this.recalled,
    required this.expectedRemaining,
  });
}

class _S08AssignmentDetailScreenState
    extends ConsumerState<S08AssignmentDetailScreen> {
  bool _isSubmitting = false;
  late final Stream<Assignment?> _assignmentStream;
  late final Stream<List<Map<String, dynamic>>> _recordsStream;
  late Assignment _currentAssignment;
  // Latest balances of every allocation in a grouped confirmation, and the
  // snapshot the open form was validated against (frozen while submitting).
  List<Assignment> _latestGroupMembers = const [];
  List<Assignment> _groupMembers = const [];

  bool get _isGroup =>
      widget.openConfirmation && widget.confirmationGroup.length > 1;

  @override
  void initState() {
    super.initState();
    final appState = ref.read(appStateProvider);
    _currentAssignment = _isGroup
        ? aggregateConfirmationGroup(widget.confirmationGroup)
        : widget.assignment;
    _groupMembers = _latestGroupMembers = widget.confirmationGroup;
    _assignmentStream = _isGroup
        ? _watchGroup(appState)
        : appState.assignmentRepo.watchAssignment(widget.assignment.id);
    _recordsStream = appState.db.watchRecordsByAssignment(widget.assignment.id);
  }

  /// The group total, re-emitted whenever any allocation's balance changes.
  Stream<Assignment?> _watchGroup(AppState appState) {
    final ids = [for (final member in widget.confirmationGroup) member.id];
    final latest = <String, Assignment?>{};
    final subscriptions = <StreamSubscription<Assignment?>>[];
    // Single-subscription and owned by the StreamBuilder; cancelling ends it.
    // ignore: close_sinks
    late final StreamController<Assignment?> controller;
    controller = StreamController<Assignment?>(
      onListen: () {
        for (final id in ids) {
          subscriptions.add(
            appState.assignmentRepo.watchAssignment(id).listen((assignment) {
              latest[id] = assignment;
              if (latest.length < ids.length) return;
              final members = latest.values.whereType<Assignment>().toList();
              if (members.length != ids.length) {
                controller.add(null);
                return;
              }
              _latestGroupMembers = members;
              controller.add(aggregateConfirmationGroup(members));
            }, onError: controller.addError),
          );
        }
      },
      onCancel: () async {
        final active = List.of(subscriptions);
        subscriptions.clear();
        for (final subscription in active) {
          await subscription.cancel();
        }
      },
    );
    return controller.stream;
  }

  final completedController = TextEditingController();
  final remainingController = TextEditingController();
  final defectController = TextEditingController();
  final recallController = TextEditingController();
  var mode = _CompletionEntryMode.completed;
  var submitting = false;
  var processing = false;
  var defectEnabled = false;
  var recallEnabled = false;
  var recallAutomatic = true;
  bool _sheetOpen = false;

  @override
  void dispose() {
    completedController.dispose();
    remainingController.dispose();
    defectController.dispose();
    recallController.dispose();
    super.dispose();
  }

  void _closeConfirmation(BuildContext formContext) {
    if (submitting || !mounted) return;
    // Never pop another page that may have been opened in the meantime.
    if (ModalRoute.of(formContext)?.isCurrent != true) return;
    if (widget.openConfirmation) {
      context.pop();
    } else {
      Navigator.of(formContext).pop();
    }
  }

  Future<void> _openConfirmCompletionSheet(double remainingMax) async {
    if (_isSubmitting || _sheetOpen || remainingMax <= 0) return;
    _sheetOpen = true;
    completedController.clear();
    remainingController.clear();
    defectController.clear();
    recallController.clear();
    mode = _CompletionEntryMode.completed;
    defectEnabled = false;
    recallEnabled = false;
    recallAutomatic = true;
    final route = ModalBottomSheetRoute<void>(
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (formContext) =>
          _buildConfirmationForm(formContext, remainingMax),
    );
    try {
      await Navigator.of(context).push(route);
      await route.completed;
    } finally {
      _sheetOpen = false;
    }
  }

  Widget _buildConfirmationForm(
    BuildContext sheetContext,
    double remainingMax,
  ) {
    return StatefulBuilder(
      builder: (context, setModalState) {
        final completedText = completedController.text.trim();
        final remainingText = remainingController.text.trim();
        final defectText = defectEnabled ? defectController.text.trim() : '';
        final recallText = recallEnabled ? recallController.text.trim() : '';
        final hasCompletedInput =
            mode == _CompletionEntryMode.completed && completedText.isNotEmpty;
        final hasRemainingInput =
            mode == _CompletionEntryMode.remaining && remainingText.isNotEmpty;
        final hasAnyInput =
            hasCompletedInput ||
            hasRemainingInput ||
            defectEnabled ||
            recallText.isNotEmpty;
        final parsedCompleted = parseLocalizedQuantity(completedText);
        final parsedRemaining = parseLocalizedQuantity(remainingText);
        final parsedDefect = parseLocalizedQuantity(defectText);
        final parsedRecall = parseLocalizedQuantity(recallText);
        final enteredCompleted = parsedCompleted ?? 0;
        final enteredRemaining = parsedRemaining ?? remainingMax;
        final defect = parsedDefect ?? 0;
        final completion = mode == _CompletionEntryMode.completed
            ? enteredCompleted
            : (remainingMax - enteredRemaining - defect).clamp(
                0.0,
                double.infinity,
              );
        final balance = (remainingMax - completion - defect).clamp(
          0.0,
          double.infinity,
        );
        final recall = parsedRecall ?? 0;
        final hasPositiveQuantity = completion > 0 || defect > 0 || recall > 0;
        final completedValidation = completion != 0
            ? ProductionMath.validateProductionEntry(completion)
            : null;
        final uom = widget.assignment.uom;
        final completedWholeError = wholeQuantityInputError(completedText, uom);
        final remainingWholeError = wholeQuantityInputError(remainingText, uom);
        final defectWholeError = wholeQuantityInputError(defectText, uom);
        // Entering what is left fixes the total, so defects must fit inside
        // it. Entering what was finished does not: finished and defective
        // output may add up to more than was left, with a warning only.
        final defectError = !defectEnabled
            ? null
            : defectText.isEmpty || parsedDefect == null
            ? 'Nhập số lượng phế hợp lệ'
            : defectWholeError ??
                  (defect < 0
                      ? 'Nhập số lượng phế hợp lệ'
                      : mode == _CompletionEntryMode.remaining &&
                            ProductionMath.exceedsAtSapScale(
                              defect,
                              (remainingMax - enteredRemaining).clamp(
                                0.0,
                                double.infinity,
                              ),
                            )
                      ? 'Tổng số phế và số còn lại vượt quá ${_displayQuantity(remainingMax)}'
                      : null);
        final overLimit =
            mode == _CompletionEntryMode.completed &&
            ProductionMath.exceedsAtSapScale(completion + defect, remainingMax);
        String? pairError;
        if (!hasAnyInput) {
          pairError = 'Nhập ít nhất một số lượng';
        } else if (hasCompletedInput) {
          if (parsedCompleted == null) {
            pairError = 'Nhập số lượng hợp lệ';
          } else if (completedWholeError != null) {
            pairError = completedWholeError;
          } else if (completedValidation != null) {
            pairError = completedValidation;
          } else if (!hasPositiveQuantity) {
            pairError = 'Ít nhất một số lượng phải lớn hơn 0';
          }
        } else if (hasRemainingInput) {
          if (parsedRemaining == null) {
            pairError = 'Nhập số lượng hợp lệ';
          } else if (remainingWholeError != null) {
            pairError = remainingWholeError;
          } else if (enteredRemaining < 0 ||
              ProductionMath.exceedsAtSapScale(
                enteredRemaining,
                remainingMax,
              )) {
            pairError = 'Nhập từ 0 đến ${_displayQuantity(remainingMax)}';
          } else if (!hasPositiveQuantity) {
            pairError = 'Ít nhất một số lượng phải lớn hơn 0';
          }
        } else if (!hasPositiveQuantity) {
          pairError = 'Ít nhất một số lượng phải lớn hơn 0';
        }
        final recallError = recallText.isNotEmpty && parsedRecall == null
            ? 'Nhập số lượng hợp lệ'
            : wholeQuantityInputError(recallText, uom) ??
                  (recall < 0 ||
                          ProductionMath.exceedsAtSapScale(recall, balance)
                      ? 'Tối đa ${_displayQuantity(balance)}'
                      : null);
        final canSave =
            hasAnyInput &&
            pairError == null &&
            defectError == null &&
            recallError == null;
        final completionPercent = remainingMax <= 0
            ? 0.0
            : (completion / remainingMax).clamp(0.0, 1.0);

        void updateAutomaticRecall(double remaining) {
          if (recallEnabled && recallAutomatic) {
            recallController.text = ProductionMath.formatQuantity(
              remaining.clamp(0.0, double.infinity),
            );
          }
        }

        void setCompleted(String value) {
          final parsed = parseLocalizedQuantity(value);
          updateAutomaticRecall(
            remainingMax -
                (parsed ?? 0) -
                (parseLocalizedQuantity(defectController.text) ?? 0),
          );
          if (parsed != null && parsed >= 0) {
            remainingController.text = ProductionMath.formatQuantity(
              (remainingMax -
                      parsed -
                      (parseLocalizedQuantity(defectController.text) ?? 0))
                  .clamp(0.0, double.infinity),
            );
          }
          setModalState(() {});
        }

        void setRemaining(String value) {
          final parsed = parseLocalizedQuantity(value);
          updateAutomaticRecall(parsed ?? remainingMax);
          if (parsed != null && parsed >= 0) {
            completedController.text = ProductionMath.formatQuantity(
              (remainingMax -
                      parsed -
                      (parseLocalizedQuantity(defectController.text) ?? 0))
                  .clamp(0.0, double.infinity),
            );
          }
          setModalState(() {});
        }

        void setDefect(String value) {
          final parsedDefectValue = parseLocalizedQuantity(value) ?? 0;
          if (mode == _CompletionEntryMode.remaining) {
            final parsedBalance = parseLocalizedQuantity(
              remainingController.text,
            );
            if (parsedBalance != null && parsedBalance >= 0) {
              completedController.text = ProductionMath.formatQuantity(
                (remainingMax - parsedBalance - parsedDefectValue).clamp(
                  0.0,
                  double.infinity,
                ),
              );
            }
          } else {
            final parsedCompletion = parseLocalizedQuantity(
              completedController.text,
            );
            if (parsedCompletion != null && parsedCompletion >= 0) {
              remainingController.text = ProductionMath.formatQuantity(
                (remainingMax - parsedCompletion - parsedDefectValue).clamp(
                  0.0,
                  double.infinity,
                ),
              );
            }
          }
          updateAutomaticRecall(
            mode == _CompletionEntryMode.completed
                ? remainingMax -
                      (parseLocalizedQuantity(completedController.text) ?? 0) -
                      parsedDefectValue
                : (parseLocalizedQuantity(remainingController.text) ??
                      remainingMax),
          );
          setModalState(() {});
        }

        Widget modeButton(String label, _CompletionEntryMode value) {
          final selected = mode == value;
          return Expanded(
            child: TextButton(
              onPressed: () => setModalState(() => mode = value),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(38),
                backgroundColor: selected
                    ? CaslaColors.surface
                    : Colors.transparent,
                foregroundColor: CaslaColors.primaryNavy,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
          );
        }

        final activeController = mode == _CompletionEntryMode.completed
            ? completedController
            : remainingController;
        // An untouched form is incomplete, not an input error. Keep Save
        // disabled until valid input exists without greeting users in red.
        final activeError = hasAnyInput ? pairError : null;
        final activeLabel = mode == _CompletionEntryMode.completed
            ? 'Số vừa hoàn thành'
            : 'Số còn lại sau xác nhận';
        final activeValueChanged = mode == _CompletionEntryMode.completed
            ? setCompleted
            : setRemaining;

        return PopScope(
          canPop: !submitting,
          child: Stack(
            children: [
              AbsorbPointer(
                absorbing: submitting,
                child: SafeArea(
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.viewInsetsOf(context).bottom,
                    ),
                    child: Material(
                      color: CaslaColors.background,
                      child: SingleChildScrollView(
                        padding: EdgeInsets.zero,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.fromLTRB(
                                20,
                                14,
                                20,
                                16,
                              ),
                              color: CaslaColors.primaryNavy,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      SizedBox(
                                        width: 48,
                                        height: 48,
                                        child: IconButton(
                                          tooltip: 'Quay lại',
                                          alignment: Alignment.centerLeft,
                                          padding: EdgeInsets.zero,
                                          onPressed: () =>
                                              _closeConfirmation(sheetContext),
                                          icon: const Icon(
                                            Icons.arrow_back,
                                            color: Colors.white,
                                            size: 21,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      const Expanded(
                                        child: Text(
                                          'Xác nhận sản lượng',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'Manrope',
                                            fontSize: 20,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${widget.assignment.workerName} · ${widget.assignment.workerMaNv} · ${_assignmentDepartment()}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: CaslaColors.onDarkSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                18,
                                16,
                                18,
                                18,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: CaslaColors.surface,
                                      border: Border.all(
                                        color: CaslaColors.line,
                                      ),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    widget
                                                            .assignment
                                                            .operationName
                                                            .isEmpty
                                                        ? 'Chưa có tên công đoạn'
                                                        : widget
                                                              .assignment
                                                              .operationName,
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      fontSize: 15,
                                                      color: CaslaColors
                                                          .primaryNavy,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 5),
                                                  Text(
                                                    'LSX ${widget.assignment.productionOrder} · CĐ ${widget.assignment.operation}'
                                                    '${_isGroup ? ' · gộp ${widget.confirmationGroup.length} lần giao' : ''}',
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
                                                  '${_displayQuantity(remainingMax)} ${widget.assignment.uom}',
                                                  style: const TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w800,
                                                    color:
                                                        CaslaColors.primaryNavy,
                                                  ),
                                                ),
                                                const Text(
                                                  'còn lại hiện tại',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    color: CaslaColors.muted,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                        const Divider(height: 20),
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: _ContextValue(
                                                label: 'Tên hàng',
                                                value: widget
                                                    .assignment
                                                    .productName,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: _ContextValue(
                                                label: 'Mã hàng',
                                                value: widget
                                                    .assignment
                                                    .productCode,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: _ContextValue(
                                                label: 'Đã giao',
                                                value:
                                                    '${_displayQuantity(_currentAssignment.assignedQuantity)} ${widget.assignment.uom}',
                                                emphasized: true,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: _ContextValue(
                                                label: 'Đã thu hồi',
                                                value:
                                                    '${_displayQuantity(_currentAssignment.recalledQuantity)} ${widget.assignment.uom}',
                                                emphasized: true,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: _ContextValue(
                                                label: 'Đã xác nhận',
                                                value:
                                                    '${_displayQuantity(_currentAssignment.completedQuantity)} ${widget.assignment.uom}',
                                                emphasized: true,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  const Text(
                                    'Nhập số lượng xác nhận',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13,
                                      color: CaslaColors.primaryNavy,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: CaslaColors.surface,
                                      border: Border.all(
                                        color: CaslaColors.line,
                                      ),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: BoxDecoration(
                                            color: CaslaColors.background,
                                            borderRadius: BorderRadius.circular(
                                              11,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              modeButton(
                                                'Nhập số hoàn thành',
                                                _CompletionEntryMode.completed,
                                              ),
                                              modeButton(
                                                'Nhập số còn lại',
                                                _CompletionEntryMode.remaining,
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          activeLabel,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: CaslaColors.primaryNavy,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        TextField(
                                          controller: activeController,
                                          onChanged: activeValueChanged,
                                          textAlign: TextAlign.right,
                                          keyboardType:
                                              const TextInputType.numberWithOptions(
                                                decimal: true,
                                              ),
                                          decoration: InputDecoration(
                                            suffixText:
                                                ' ${widget.assignment.uom}',
                                            suffixStyle: const TextStyle(
                                              color: CaslaColors.primaryNavy,
                                              fontWeight: FontWeight.w700,
                                            ),
                                            hintText: '0',
                                            isDense: true,
                                            filled: true,
                                            fillColor: CaslaColors.surface,
                                            error: activeError == null
                                                ? null
                                                : Row(
                                                    children: [
                                                      const Icon(
                                                        Icons.error_outline,
                                                        size: 14,
                                                        color:
                                                            CaslaColors.danger,
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Text(
                                                        activeError,
                                                        style: const TextStyle(
                                                          color: CaslaColors
                                                              .danger,
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(11),
                                              borderSide: const BorderSide(
                                                color: CaslaColors.line,
                                              ),
                                            ),
                                            enabledBorder: overLimit
                                                ? OutlineInputBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          11,
                                                        ),
                                                    borderSide:
                                                        const BorderSide(
                                                          color: CaslaColors
                                                              .pending,
                                                          width: 1.4,
                                                        ),
                                                  )
                                                : null,
                                            focusedBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(11),
                                              borderSide: BorderSide(
                                                color: overLimit
                                                    ? CaslaColors.pending
                                                    : CaslaColors.primaryNavy,
                                                width: 1.4,
                                              ),
                                            ),
                                            errorBorder: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(11),
                                              borderSide: const BorderSide(
                                                color: CaslaColors.danger,
                                              ),
                                            ),
                                          ),
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 25,
                                            fontWeight: FontWeight.w800,
                                            color: CaslaColors.primaryNavy,
                                          ),
                                        ),
                                        if (overLimit && activeError == null)
                                          OverLimitLine(
                                            '${defect > 0 ? 'Tổng hoàn thành và phế vượt' : 'Vượt'} '
                                            'số còn lại ${_displayQuantity(remainingMax)} '
                                            '${widget.assignment.uom}.',
                                          ),
                                        const SizedBox(height: 12),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: LinearProgressIndicator(
                                            value: completionPercent,
                                            minHeight: 7,
                                            backgroundColor: CaslaColors.line,
                                            color: CaslaColors.success,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              '${formatCompletionPercent(completionPercent)} hoàn thành',
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: CaslaColors.muted,
                                              ),
                                            ),
                                            Text(
                                              'còn ${_displayQuantity(balance)} ${widget.assignment.uom}',
                                              style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                                color: CaslaColors.primaryNavy,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const Divider(height: 22),
                                        _DefectSection(
                                          enabled: defectEnabled,
                                          controller: defectController,
                                          unit: widget.assignment.uom,
                                          error: defectError,
                                          onToggle: (enabled) {
                                            setModalState(() {
                                              defectEnabled = enabled;
                                              if (!enabled) {
                                                defectController.clear();
                                              }
                                              final remainingAfterEntry =
                                                  mode ==
                                                      _CompletionEntryMode
                                                          .completed
                                                  ? remainingMax -
                                                        (parseLocalizedQuantity(
                                                              completedController
                                                                  .text,
                                                            ) ??
                                                            0)
                                                  : (parseLocalizedQuantity(
                                                          remainingController
                                                              .text,
                                                        ) ??
                                                        remainingMax);
                                              updateAutomaticRecall(
                                                remainingAfterEntry -
                                                    (enabled
                                                        ? (parseLocalizedQuantity(
                                                                defectController
                                                                    .text,
                                                              ) ??
                                                              0)
                                                        : 0),
                                              );
                                              if (mode ==
                                                  _CompletionEntryMode
                                                      .remaining) {
                                                completedController
                                                    .text = ProductionMath.formatQuantity(
                                                  (remainingAfterEntry -
                                                          (enabled
                                                              ? (parseLocalizedQuantity(
                                                                      defectController
                                                                          .text,
                                                                    ) ??
                                                                    0)
                                                              : 0))
                                                      .clamp(
                                                        0.0,
                                                        double.infinity,
                                                      ),
                                                );
                                              } else {
                                                remainingController
                                                    .text = ProductionMath.formatQuantity(
                                                  (remainingAfterEntry -
                                                          (enabled
                                                              ? (parseLocalizedQuantity(
                                                                      defectController
                                                                          .text,
                                                                    ) ??
                                                                    0)
                                                              : 0))
                                                      .clamp(
                                                        0.0,
                                                        double.infinity,
                                                      ),
                                                );
                                              }
                                            });
                                          },
                                          onChanged: setDefect,
                                        ),
                                        const SizedBox(height: 12),
                                        _RecallSection(
                                          enabled: recallEnabled,
                                          controller: recallController,
                                          unit: widget.assignment.uom,
                                          error: recallError,
                                          onToggle: (enabled) {
                                            setModalState(() {
                                              recallEnabled = enabled;
                                              recallAutomatic = true;
                                              recallController.text = enabled
                                                  ? ProductionMath.formatQuantity(
                                                      balance,
                                                    )
                                                  : '';
                                            });
                                          },
                                          onChanged: (_) => setModalState(() {
                                            recallAutomatic = false;
                                          }),
                                        ),
                                        const SizedBox(height: 14),
                                        Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.all(12),
                                          decoration: const BoxDecoration(
                                            color: CaslaColors.muted100,
                                            borderRadius: BorderRadius.all(
                                              Radius.circular(12),
                                            ),
                                          ),
                                          child: Column(
                                            children: [
                                              _SummaryLine(
                                                label: 'Ghi nhận hoàn thành',
                                                value:
                                                    '+${_displayQuantity(completion)} ${widget.assignment.uom}',
                                              ),
                                              if (defectEnabled)
                                                _SummaryLine(
                                                  label: 'Ghi nhận số phế',
                                                  value:
                                                      '+${_displayQuantity(defect)} ${widget.assignment.uom}',
                                                ),
                                              _SummaryLine(
                                                label: 'Còn lại sau xác nhận',
                                                value:
                                                    '${_displayQuantity(balance)} ${widget.assignment.uom}',
                                              ),
                                              if (recallEnabled)
                                                _SummaryLine(
                                                  label: 'Thu hồi lượt này',
                                                  value:
                                                      '${_displayQuantity(recall)} ${widget.assignment.uom}',
                                                ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 14),
                                        SizedBox(
                                          width: double.infinity,
                                          child: OutlinedButton(
                                            onPressed: canSave && !submitting
                                                ? () async {
                                                    FocusScope.of(
                                                      sheetContext,
                                                    ).unfocus();
                                                    setModalState(
                                                      () => submitting = true,
                                                    );
                                                    final saved = await _submitConfirmationDraft(
                                                      _ConfirmationDraft(
                                                        completed:
                                                            ProductionMath.toSapScale(
                                                              completion,
                                                            ),
                                                        defect:
                                                            ProductionMath.toSapScale(
                                                              defect,
                                                            ),
                                                        recalled:
                                                            ProductionMath.toSapScale(
                                                              recall,
                                                            ),
                                                        expectedRemaining:
                                                            mode ==
                                                                _CompletionEntryMode
                                                                    .remaining
                                                            ? ProductionMath.toSapScale(
                                                                remainingMax,
                                                              )
                                                            : null,
                                                      ),
                                                      onProcessing: (value) {
                                                        if (sheetContext
                                                            .mounted) {
                                                          setModalState(
                                                            () => processing =
                                                                value,
                                                          );
                                                        }
                                                      },
                                                    );
                                                    if (!sheetContext.mounted) {
                                                      return;
                                                    }
                                                    setModalState(
                                                      () => submitting = false,
                                                    );
                                                    if (saved) {
                                                      _closeConfirmation(
                                                        sheetContext,
                                                      );
                                                    }
                                                  }
                                                : null,
                                            child: const Text('Xác nhận'),
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
                    ),
                  ),
                ),
              ),
              if (processing) const _ConfirmationSubmittingOverlay(),
            ],
          ),
        );
      },
    );
  }

  Future<bool> _submitConfirmationDraft(
    _ConfirmationDraft draft, {
    required ValueChanged<bool> onProcessing,
  }) => ref
      .read(appStateProvider)
      .runCriticalOperation(
        () => _submitConfirmationDraftNow(draft, onProcessing: onProcessing),
      );

  Future<bool> _submitConfirmationDraftNow(
    _ConfirmationDraft draft, {
    required ValueChanged<bool> onProcessing,
  }) async {
    if (_isSubmitting) return false;
    final appState = ref.read(appStateProvider);
    final supervisorMaNv = appState.currentSession?.maNv ?? '';
    final activeShift = appState.activeShift;
    if (activeShift == null) {
      await _showConfirmationResultDialog(
        title: 'Chưa chọn ca làm việc',
        message: 'Hãy thiết lập ca làm việc trước khi xác nhận.',
        success: false,
      );
      return false;
    }
    // SAP resolves the shift by the operation's Work Center + ShiftID.
    final assignmentWorkCenter = widget.assignment.workCenter.trim();
    if (assignmentWorkCenter.isNotEmpty &&
        activeShift.workCenter.trim() != assignmentWorkCenter) {
      await _showConfirmationResultDialog(
        title: 'Ca làm việc chưa phù hợp',
        message:
            'Ca đang chọn thuộc Xưởng ${activeShift.workCenter}, nhưng '
            'công đoạn thuộc Xưởng $assignmentWorkCenter. Hãy đổi Xưởng '
            'và ca làm việc trước khi xác nhận.',
        success: false,
      );
      return false;
    }
    final businessDate = DateFormat(
      'yyyy-MM-dd',
    ).format(appState.activeBusinessDate);
    final generation = appState.sessionGeneration;
    setState(() => _isSubmitting = true);
    MutationReceipt? productionReceipt;
    MutationReceipt? recallReceipt;
    // A grouped confirmation writes one transaction per allocation. Once any
    // of them is saved the form must close: resubmitting the total would
    // post the saved part a second time.
    var savedAnyPart = false;
    try {
      final parts = _isGroup
          ? splitGroupedConfirmation(
              _groupMembers,
              completed: draft.completed,
              defect: draft.defect,
              recalled: draft.recalled,
            )
          : [
              ConfirmationPart(
                assignment: widget.assignment,
                completed: draft.completed,
                defect: draft.defect,
                recalled: draft.recalled,
              ),
            ];
      final shiftError = validateShiftExecution(
        shift: activeShift,
        businessDate: DateTime.parse(businessDate),
        executedAt: DateTime.now(),
      );
      if (shiftError != null) throw Exception(shiftError);
      // The first write is what proves the password; a refused password rolls
      // it back (nothing is queued) and the popup opens again, up to 3 times.
      final run = await runWithWorkerPassword<MutationReceipt?>(
        context,
        workerName: widget.assignment.workerName,
        actionLabel: 'xác nhận số đạt, số phế và thu hồi lên SAP',
        // Once any grouped part is saved, a retry would post it twice.
        isWrongPassword: (receipt) =>
            !savedAnyPart && receipt?.isWrongWorkerPassword == true,
        submit: (workerPassword) async {
          onProcessing(true);
          try {
            final latestShiftError = validateShiftExecution(
              shift: activeShift,
              businessDate: DateTime.parse(businessDate),
              executedAt: DateTime.now(),
            );
            if (latestShiftError != null) throw Exception(latestShiftError);
            if (!appState.isSessionGenerationCurrent(generation)) {
              throw Exception(
                'Phiên đăng nhập đã thay đổi. Vui lòng mở lại thao tác.',
              );
            }
            productionReceipt = null;
            recallReceipt = null;
            if (draft.completed > 0 || draft.defect > 0) {
              productionReceipt = await _submitParts(
                parts.where((part) => part.completed > 0 || part.defect > 0),
                onSaved: () => savedAnyPart = true,
                submit: (part) => appState.productionRepo.recordProduction(
                  assignmentId: part.assignment.id,
                  quantity: part.completed,
                  defectQuantity: part.defect,
                  businessDate: businessDate,
                  shiftId: activeShift.shiftId,
                  createdBy: supervisorMaNv,
                  workerPassword: workerPassword,
                  // Remaining-mode entry guards each allocation against a
                  // balance that moved since the form opened.
                  expectedRemaining: draft.expectedRemaining == null
                      ? null
                      : _isGroup
                      ? part.assignment.remaining
                      : draft.expectedRemaining,
                ),
              );
            }
            if (productionReceipt?.isRefused != true && draft.recalled > 0) {
              recallReceipt = await _submitParts(
                parts.where((part) => part.recalled > 0),
                onSaved: () => savedAnyPart = true,
                submit: (part) => appState.recallRepo.recallAssignment(
                  assignmentId: part.assignment.id,
                  quantity: part.recalled,
                  reasonCode: RecallReason.notFinished.code,
                  note: null,
                  businessDate: businessDate,
                  shiftId: activeShift.shiftId,
                  createdBy: supervisorMaNv,
                  workerPassword: workerPassword,
                ),
              );
            }
            return productionReceipt ?? recallReceipt;
          } finally {
            onProcessing(false);
          }
        },
      );
      // Three wrong passwords: the notice is up and the popup has closed.
      // The worker belongs to the assignment, so there is nothing to clear.
      if (!mounted || run.cancelled || run.exhausted) return savedAnyPart;
      // Captured by the submit closure above, so copy for type promotion.
      final production = productionReceipt;
      final recall = recallReceipt;
      if (production != null && production.isRefused) {
        await _showRefusalFeedback(
          production,
          title: 'Chưa hoàn tất xác nhận',
          fallback: 'SAP chưa chấp nhận sản lượng.',
          suffix: draft.recalled > 0 ? ' Chưa thực hiện thu hồi.' : '',
        );
        // Business rejections and refusals can be corrected in this form.
        return savedAnyPart;
      }
      if (recall != null && recall.isRefused) {
        await _showRefusalFeedback(
          recall,
          title: 'Chưa hoàn tất thu hồi',
          fallback: 'SAP chưa chấp nhận thu hồi.',
          prefix: production != null ? 'Phần xác nhận đã được lưu. ' : '',
        );
        return production != null || savedAnyPart;
      }
      if (production != null && recall != null) {
        final allSynced =
            production.state == MutationDeliveryState.synced &&
            recall.state == MutationDeliveryState.synced;
        await _showConfirmationResultDialog(
          title: allSynced ? 'Xác nhận thành công' : 'Đã lưu xác nhận',
          message: allSynced
              ? 'Đã ghi nhận +${_displayQuantity(draft.completed)} ${widget.assignment.uom} '
                    '${draft.defect > 0 ? '· phế ${_displayQuantity(draft.defect)} ${widget.assignment.uom} · ' : ''}'
                    'và thu hồi ${_displayQuantity(draft.recalled)} ${widget.assignment.uom}. SAP đã xác nhận giao dịch.'
              : 'Đã ghi nhận +${_displayQuantity(draft.completed)} ${widget.assignment.uom} '
                    '${draft.defect > 0 ? '· phế ${_displayQuantity(draft.defect)} ${widget.assignment.uom} · ' : ''}'
                    'và thu hồi ${_displayQuantity(draft.recalled)} ${widget.assignment.uom}. Giao dịch đã được lưu trên thiết bị; mở Đồng bộ để theo dõi.',
          success: true,
        );
      } else if (production != null) {
        await _showReceiptFeedback(
          production,
          'Đã ghi nhận +${_displayQuantity(draft.completed)} ${widget.assignment.uom}'
          '${draft.defect > 0 ? ' · phế ${_displayQuantity(draft.defect)} ${widget.assignment.uom}' : ''}.',
        );
      } else if (recall != null) {
        await _showReceiptFeedback(
          recall,
          'Đã thu hồi ${_displayQuantity(draft.recalled)} ${widget.assignment.uom}.',
        );
      }
      return true;
    } on Exception catch (e) {
      if (!mounted) return false;
      onProcessing(false);
      final message = productionReceipt != null && draft.recalled > 0
          ? 'Đã lưu phần xác nhận, nhưng chưa thu hồi được: ${friendlySapErrorMessage(e)}'
          : friendlySapErrorMessage(e);
      await _showConfirmationResultDialog(
        title: 'Chưa hoàn tất xác nhận',
        message: message,
        success: false,
      );
      // A saved first operation must not be submitted a second time.
      return productionReceipt != null || recallReceipt != null || savedAnyPart;
    } finally {
      onProcessing(false);
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// Submits one write per allocation, in order, and folds the receipts into
  /// one: the first rejection stops the rest (its message says how much was
  /// already saved); otherwise the least-settled delivery state is reported.
  Future<MutationReceipt?> _submitParts(
    Iterable<ConfirmationPart> parts, {
    required Future<MutationReceipt> Function(ConfirmationPart part) submit,
    required VoidCallback onSaved,
  }) async {
    MutationReceipt? combined;
    var saved = 0.0;
    for (final part in parts) {
      final receipt = await submit(part);
      if (receipt.isRefused) {
        if (saved <= 0) return receipt;
        return MutationReceipt(
          id: receipt.id,
          state: receipt.state,
          code: receipt.code,
          message:
              'Đã lưu ${_displayQuantity(saved)} ${widget.assignment.uom} ở các '
              'lần giao trước; phần còn lại chưa được ghi: '
              '${receipt.message ?? 'SAP chưa chấp nhận.'}',
        );
      }
      onSaved();
      saved += part.completed > 0 ? part.completed : part.recalled;
      combined = combined == null ? receipt : _lessSettled(combined, receipt);
    }
    return combined;
  }

  static MutationReceipt _lessSettled(MutationReceipt a, MutationReceipt b) {
    int rank(MutationDeliveryState state) => switch (state) {
      MutationDeliveryState.synced => 0,
      MutationDeliveryState.queued => 1,
      MutationDeliveryState.needsVerification => 2,
      MutationDeliveryState.rejected => 3,
      MutationDeliveryState.discarded => 4,
    };
    return rank(b.state) > rank(a.state) ? b : a;
  }

  /// A refusal the device rolled back gets the red SAP popup with its
  /// recovery guidance; a business rejection kept for review keeps the
  /// existing result dialog.
  Future<void> _showRefusalFeedback(
    MutationReceipt receipt, {
    required String title,
    required String fallback,
    String prefix = '',
    String suffix = '',
  }) async {
    if (!mounted) return;
    final message = '$prefix${receipt.message ?? fallback}$suffix';
    if (receipt.state == MutationDeliveryState.discarded) {
      await showMutationFeedback(
        context,
        receipt: MutationReceipt(
          id: receipt.id,
          state: receipt.state,
          code: receipt.code,
          message: message,
        ),
        successMessage: '',
      );
      return;
    }
    await _showConfirmationResultDialog(
      title: title,
      message: message,
      success: false,
    );
  }

  Future<void> _showReceiptFeedback(
    MutationReceipt receipt,
    String successMessage,
  ) async {
    if (!mounted) return;
    if (receipt.state != MutationDeliveryState.synced) {
      await showMutationFeedback(
        context,
        receipt: receipt,
        successMessage: successMessage,
        persistNonSuccess: true,
      );
      return;
    }
    await _showConfirmationResultDialog(
      title: 'Xác nhận thành công',
      message: '$successMessage SAP đã xác nhận giao dịch.',
      success: true,
    );
  }

  Future<void> _showConfirmationResultDialog({
    required String title,
    required String message,
    required bool success,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: CaslaColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        titlePadding: const EdgeInsets.fromLTRB(22, 22, 22, 0),
        contentPadding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
        actionsPadding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
        title: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: (success ? CaslaColors.success : CaslaColors.danger)
                    .withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                success ? Icons.check_rounded : Icons.error_outline_rounded,
                color: success ? CaslaColors.success : CaslaColors.danger,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: CaslaColors.primaryNavy,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(
            fontSize: 14,
            height: 1.45,
            color: CaslaColors.muted,
          ),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              style: FilledButton.styleFrom(
                backgroundColor: success
                    ? CaslaColors.primaryNavy
                    : CaslaColors.danger,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Đã hiểu'),
            ),
          ),
        ],
      ),
    );
  }

  String _assignmentDepartment() {
    final teamId = widget.assignment.teamId.trim();
    final normalizedTeamId = teamId.toUpperCase();
    final appState = ref.read(appStateProvider);
    final contexts =
        appState.currentSession?.workContexts ?? const <UserWorkContext>[];

    for (final context in contexts) {
      final contextIds = <String>{
        context.workId.trim().toUpperCase(),
        context.workName.trim().toUpperCase(),
        context.workCenter.trim().toUpperCase(),
      }..removeWhere((value) => value.isEmpty);
      if (!contextIds.contains(normalizedTeamId)) continue;

      final label = _workContextDisplayLabel(context);
      if (label.isNotEmpty) return label;
      final workId = context.workId.trim();
      if (workId.isNotEmpty) return workId;
    }

    final active = appState.activeWorkContext;
    if (active != null &&
        (teamId.isEmpty ||
            active.workId.trim().toUpperCase() == normalizedTeamId)) {
      final label = _workContextDisplayLabel(active);
      if (label.isNotEmpty) return label;
    }

    return teamId.isNotEmpty ? teamId : 'Chưa xác định bộ phận';
  }

  String _workContextDisplayLabel(UserWorkContext context) {
    final name = context.workName.trim().isNotEmpty
        ? context.workName.trim()
        : context.boPhan.trim();
    if (name.isEmpty) return '';
    final location = context.location.trim();
    return location.isEmpty ? name : '$name ($location)';
  }

  String _displayQuantity(double value) =>
      formatQuantity(value, uom: widget.assignment.uom);

  @override
  Widget build(BuildContext context) {
    if (widget.openConfirmation) {
      return Scaffold(
        backgroundColor: CaslaColors.background,
        resizeToAvoidBottomInset: false,
        body: StreamBuilder<Assignment?>(
          stream: _assignmentStream,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError || snapshot.data == null) {
              return const Center(
                child: Text(
                  'Chưa tải được số lượng phân công. Vui lòng mở lại.',
                ),
              );
            }
            // Keep the submitted draft stable while the atomic write emits
            // its updated balance. Otherwise the remaining-mode input changes
            // meaning underneath the in-flight confirmation.
            if (!submitting) {
              _currentAssignment = snapshot.data!;
              _groupMembers = _latestGroupMembers;
            }
            return _buildConfirmationForm(
              context,
              _currentAssignment.remaining,
            );
          },
        ),
      );
    }
    final appState = ref.watch(appStateProvider);
    final canRecall =
        appState.currentSession?.hasPermission(Permission.recallAssignment) ==
        true;

    return Stack(
      children: [
        Scaffold(
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
              if (!submitting) _currentAssignment = assignment;
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
                                      value: _displayQuantity(initialAssigned),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: KpiCard(
                                      label: 'Đã thu hồi',
                                      value: _displayQuantity(recalled),
                                      valueColor: CaslaColors.danger,
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 12),

                              // Ring progress card
                              RingProgressCard(
                                percentage: pct,
                                remainingValue: _displayQuantity(remaining),
                                detailText:
                                    'Giao hiệu lực ${_displayQuantity(effective)} · Hoàn thành ${_displayQuantity(completed)} · Phế ${_displayQuantity(assignment.defectQuantity)}',
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
                                        border: Border.all(
                                          color: CaslaColors.line,
                                        ),
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
                                                    color:
                                                        CaslaColors.primaryNavy,
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
                                                '+${_displayQuantity((r['quantity'] as num).toDouble())}',
                                                style: const TextStyle(
                                                  fontFamily: 'monospace',
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 14,
                                                  color: CaslaColors.success,
                                                ),
                                              ),
                                              if (((r['defect_quantity']
                                                              as num?)
                                                          ?.toDouble() ??
                                                      0) >
                                                  0)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 2,
                                                      ),
                                                  child: Text(
                                                    'Phế +${_displayQuantity((r['defect_quantity'] as num).toDouble())}',
                                                    style: const TextStyle(
                                                      fontFamily: 'monospace',
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      fontSize: 11,
                                                      color: CaslaColors.scrap,
                                                    ),
                                                  ),
                                                ),
                                              const SizedBox(height: 2),
                                              StatusChip(
                                                status:
                                                    r['sync_status'] ??
                                                    'SYNCED',
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
                          icon: const Icon(Icons.check_circle_outline),
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
        ),
      ],
    );
  }
}

class _DefectSection extends StatelessWidget {
  final bool enabled;
  final TextEditingController controller;
  final String unit;
  final String? error;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String> onChanged;

  const _DefectSection({
    required this.enabled,
    required this.controller,
    required this.unit,
    required this.error,
    required this.onToggle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(
          color: enabled ? CaslaColors.danger : CaslaColors.line,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: enabled ? CaslaColors.dangerBg : CaslaColors.surface,
            child: InkWell(
              onTap: () => onToggle(!enabled),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
                child: Row(
                  children: [
                    Checkbox(
                      value: enabled,
                      activeColor: CaslaColors.danger,
                      onChanged: (value) => onToggle(value ?? false),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Có số lượng phế',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Tích để nhập số lượng sản phẩm phế',
                            style: TextStyle(
                              fontSize: 11,
                              color: CaslaColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      enabled ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: CaslaColors.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (enabled)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    key: const ValueKey('defect-quantity'),
                    controller: controller,
                    onChanged: onChanged,
                    textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Số lượng phế',
                      suffixText: ' $unit',
                      errorText: error,
                      errorMaxLines: 2,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Số phế được gửi riêng và vẫn trừ vào số lượng còn lại.',
                    style: TextStyle(fontSize: 11, color: CaslaColors.muted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RecallSection extends StatelessWidget {
  final bool enabled;
  final TextEditingController controller;
  final String unit;
  final String? error;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String> onChanged;

  const _RecallSection({
    required this.enabled,
    required this.controller,
    required this.unit,
    required this.error,
    required this.onToggle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(
          color: enabled ? CaslaColors.accentGold : CaslaColors.line,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: enabled
                ? CaslaColors.accentGold.withValues(alpha: 0.25)
                : CaslaColors.surface,
            child: InkWell(
              onTap: () => onToggle(!enabled),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
                child: Row(
                  children: [
                    Checkbox(
                      value: enabled,
                      activeColor: CaslaColors.gold700,
                      onChanged: (value) => onToggle(value ?? false),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Có thu hồi',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Tích để nhập số lượng thu hồi',
                            style: TextStyle(
                              fontSize: 11,
                              color: CaslaColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      enabled ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: CaslaColors.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (enabled)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    key: const ValueKey('recall-quantity'),
                    controller: controller,
                    onChanged: onChanged,
                    textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Số thu hồi',
                      suffixText: ' $unit',
                      errorText: error,
                      errorMaxLines: 2,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Tự điền số còn lại. Có thể sửa số lượng cần thu hồi.',
                    style: TextStyle(fontSize: 11, color: CaslaColors.muted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ConfirmationSubmittingOverlay extends StatelessWidget {
  const _ConfirmationSubmittingOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        children: [
          const ModalBarrier(
            dismissible: false,
            color: Colors.black26,
            semanticsLabel: 'Đang xử lý xác nhận',
          ),
          Center(
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                constraints: const BoxConstraints(minWidth: 190, maxWidth: 260),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 20,
                ),
                decoration: BoxDecoration(
                  color: CaslaColors.surface,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                    SizedBox(height: 14),
                    Text(
                      'Đang xử lý xác nhận',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'Vui lòng chờ, không đóng màn hình.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: CaslaColors.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
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

class _ContextValue extends StatelessWidget {
  final String label;
  final String value;

  /// Larger type for the quantity figures the supervisor checks first.
  final bool emphasized;

  const _ContextValue({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: emphasized ? 12 : 10.5,
            color: CaslaColors.muted,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value.isEmpty ? '—' : value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: emphasized ? 15 : 12,
            fontWeight: emphasized ? FontWeight.w800 : FontWeight.w700,
            color: CaslaColors.primaryNavy,
          ),
        ),
      ],
    );
  }
}

class _SummaryLine extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
          Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: CaslaColors.primaryNavy,
            ),
          ),
        ],
      ),
    );
  }
}
