// Screen S15 — confirm several operations of one worker at once.
//
// Reached from the Xác nhận tab when the worker has more than one operation
// open. The list shows operation names only, with a tick box each; the arrow
// opens the details. One quantity is confirmed on every ticked operation, so
// it cannot exceed the one with the least left. Defect and recall quantities
// stay on the single-operation form (S08), offered when exactly one is ticked.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../core/utils/operation_qr_parser.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../core/utils/shift_execution_validation.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/mutation_receipt.dart';
import '../../../domain/policies/grouped_confirmation.dart';
import '../../../domain/policies/multi_confirmation.dart';
import '../../../main.dart';
import '../../../presentation/widgets/over_limit_line.dart';
import '../../../presentation/widgets/scan_slot_field.dart';
import '../../../presentation/widgets/worker_verification_dialog.dart';

class S15MultiConfirmScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> worker;

  /// The worker's confirmation groups that still have something open.
  final List<List<Assignment>> groups;

  @visibleForTesting
  final DateTime Function()? now;

  const S15MultiConfirmScreen({
    super.key,
    required this.worker,
    required this.groups,
    this.now,
  });

  @override
  ConsumerState<S15MultiConfirmScreen> createState() =>
      _S15MultiConfirmScreenState();
}

class _S15MultiConfirmScreenState extends ConsumerState<S15MultiConfirmScreen> {
  final TextEditingController _qtyController = TextEditingController();
  final Set<int> _selected = {};
  final Set<int> _expanded = {};

  /// Bộ phận of each group's operation, read from its label once.
  final Map<int, String> _departments = {};
  late final List<Assignment> _totals = [
    for (final group in widget.groups) aggregateConfirmationGroup(group),
  ];
  bool _isSubmitting = false;
  String? _quantityError;

  String get _workerName {
    final name = widget.worker['ten']?.toString().trim() ?? '';
    return name.isEmpty ? 'Công nhân' : name;
  }

  String get _workerDepartment {
    final department = widget.worker['bo_phan']?.toString().trim() ?? '';
    // The placeholder given to a worker whose card carries no department.
    return department == 'Công nhân sản xuất' ? '' : department;
  }

  @override
  void initState() {
    super.initState();
    _loadDepartments();
  }

  @override
  void dispose() {
    _qtyController.dispose();
    super.dispose();
  }

  Future<void> _loadDepartments() async {
    final db = ref.read(appStateProvider).db;
    for (var index = 0; index < _totals.length; index++) {
      try {
        final order = await db.getOrderById(_totals[index].orderId);
        final department = OperationQrParser.parse(
          order?['operation_qr_payload']?.toString() ?? '',
        ).boPhan.trim();
        if (!mounted) return;
        if (department.isNotEmpty) {
          setState(() => _departments[index] = department);
        }
      } catch (_) {
        // The department is only shown among the operation's details.
      }
    }
  }

  String _name(int index) => confirmationGroupName(widget.groups[index]);

  bool _isOpen(int index) => _totals[index].remaining > 0;

  String get _uom {
    final index = _selected.isEmpty ? null : _selected.first;
    return index == null
        ? (_totals.isEmpty ? '' : _totals.first.uom)
        : _totals[index].uom;
  }

  ({double remaining, String name})? get _limit {
    final tightest = tightestConfirmationGroup([
      for (final index in _selected) widget.groups[index],
    ]);
    return tightest == null
        ? null
        : (
            remaining: tightest.remaining,
            name: confirmationGroupName(tightest.group),
          );
  }

  void _toggle(int index, bool selected) {
    if (!_isOpen(index)) return;
    if (selected && _selected.isNotEmpty) {
      final unit = _totals[_selected.first].uom.trim().toUpperCase();
      if (_totals[index].uom.trim().toUpperCase() != unit) {
        _showSnack(
          '${_name(index)} tính theo ${_totals[index].uom}, không xác nhận '
          'chung với ${_totals[_selected.first].uom}.',
        );
        return;
      }
    }
    setState(() {
      selected ? _selected.add(index) : _selected.remove(index);
      _quantityError = null;
    });
  }

  void _toggleAll() {
    final open = [
      for (var index = 0; index < _totals.length; index++)
        if (_isOpen(index)) index,
    ];
    setState(() {
      if (_selected.length == open.length) {
        _selected.clear();
      } else {
        // Only operations counted in the same unit can share one quantity.
        final unit = _totals[open.first].uom.trim().toUpperCase();
        _selected
          ..clear()
          ..addAll(
            open.where(
              (index) => _totals[index].uom.trim().toUpperCase() == unit,
            ),
          );
      }
      _quantityError = null;
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showMessage(String title, String message) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Đã hiểu'),
        ),
      ],
    ),
  );

  Future<void> _submit() =>
      ref.read(appStateProvider).runCriticalOperation(_submitNow);

  Future<void> _submitNow() async {
    if (_isSubmitting || _selected.isEmpty) return;
    FocusScope.of(context).unfocus();
    final indexes = _selected.toList()..sort();
    final uom = _uom;

    final quantity = parseLocalizedQuantity(_qtyController.text) ?? 0.0;
    if (!quantity.isFinite || quantity <= 0) {
      setState(
        () => _quantityError = 'Số lượng xác nhận phải là một số dương hợp lệ.',
      );
      return;
    }
    final wholeError = wholeQuantityInputError(_qtyController.text, uom);
    if (wholeError != null) {
      setState(() => _quantityError = wholeError);
      return;
    }
    // More than the tightest operation has left may be confirmed; the form
    // warns under the field.
    setState(() => _quantityError = null);

    final appState = ref.read(appStateProvider);
    final shift = appState.activeShift;
    if (shift == null) {
      await _showMessage(
        'Chưa chọn ca làm việc',
        'Hãy thiết lập ca làm việc trước khi xác nhận.',
      );
      return;
    }
    // SAP resolves the shift by the operation's Work Center + ShiftID.
    for (final index in indexes) {
      final workCenter = _totals[index].workCenter.trim();
      if (workCenter.isNotEmpty && shift.workCenter.trim() != workCenter) {
        await _showMessage(
          'Ca làm việc chưa phù hợp',
          'Ca đang chọn thuộc Xưởng ${shift.workCenter}, nhưng '
              '${_name(index)} thuộc Xưởng $workCenter. Hãy đổi Xưởng và ca '
              'làm việc trước khi xác nhận.',
        );
        return;
      }
    }
    final businessDate = DateFormat(
      'yyyy-MM-dd',
    ).format(appState.activeBusinessDate);
    String? shiftError() => validateShiftExecution(
      shift: shift,
      businessDate: DateTime.parse(businessDate),
      executedAt: widget.now?.call() ?? DateTime.now(),
    );
    final initialShiftError = shiftError();
    if (initialShiftError != null) {
      await _showMessage('Chưa hoàn tất xác nhận', initialShiftError);
      return;
    }

    // Each allocation of a group takes its share, oldest first.
    final partsByIndex = <int, List<ConfirmationPart>>{};
    try {
      for (final index in indexes) {
        partsByIndex[index] = splitGroupedConfirmation(
          widget.groups[index],
          completed: quantity,
          recalled: 0,
        );
      }
    } on ArgumentError {
      await _showMessage(
        'Số còn lại đã thay đổi',
        'Hãy quay lại danh sách công nhân rồi mở lại để lấy số mới nhất.',
      );
      return;
    }

    if (!mounted) return;
    final supervisor = appState.currentSession?.maNv ?? '';
    final generation = appState.sessionGeneration;
    setState(() => _isSubmitting = true);
    try {
      var savedAny = false;
      final run = await runWithWorkerPassword<List<_ConfirmOutcome>>(
        context,
        workerName: _workerName,
        actionLabel: 'gửi xác nhận ${indexes.length} công đoạn lên SAP',
        // Only the very first write can prove the password wrong. Once one
        // is saved, asking again would post it a second time.
        isWrongPassword: (outcomes) =>
            !savedAny &&
            outcomes.length == 1 &&
            outcomes.single.refusal?.isWrongWorkerPassword == true,
        submit: (workerPassword) async {
          final outcomes = <_ConfirmOutcome>[];
          for (final index in indexes) {
            final latestShiftError = shiftError();
            if (latestShiftError != null) throw Exception(latestShiftError);
            if (!appState.isSessionGenerationCurrent(generation)) {
              throw Exception(
                'Phiên đăng nhập đã thay đổi. Vui lòng mở lại thao tác.',
              );
            }
            var saved = 0.0;
            MutationReceipt? least;
            MutationReceipt? refusal;
            for (final part in partsByIndex[index]!) {
              final receipt = await appState.productionRepo.recordProduction(
                assignmentId: part.assignment.id,
                quantity: part.completed,
                businessDate: businessDate,
                shiftId: shift.shiftId,
                createdBy: supervisor,
                workerPassword: workerPassword,
              );
              if (receipt.isRefused) {
                refusal = receipt;
                break;
              }
              savedAny = true;
              saved += part.completed;
              least = least == null ? receipt : _lessSettled(least, receipt);
            }
            outcomes.add(
              _ConfirmOutcome(
                name: _name(index),
                saved: saved,
                receipt: least,
                refusal: refusal,
              ),
            );
            if (refusal?.isWrongWorkerPassword == true) break;
          }
          return outcomes;
        },
      );
      if (!mounted || run.cancelled || run.exhausted) return;
      final outcomes = run.result!;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _ConfirmResultDialog(
          outcomes: outcomes,
          quantity: quantity,
          uom: uom,
          workerName: _workerName,
        ),
      );
      // The list behind this screen holds the old balances: go back to it so
      // nothing here can be confirmed twice.
      if (mounted && savedAny) context.pop(true);
    } on Exception catch (error) {
      if (!mounted) return;
      await _showMessage(
        'Chưa hoàn tất xác nhận',
        friendlySapErrorMessage(error),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
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

  Future<void> _openSingle(int index) async {
    final group = widget.groups[index];
    await context.push(
      '/supervisor/assignment_detail',
      extra: <String, dynamic>{
        'assignment': group.first,
        'group': group,
        'openConfirmation': true,
      },
    );
    // That form changes the balance this list was opened with.
    if (mounted) context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final uom = _uom;
    final limit = _limit;
    final openCount = [
      for (var index = 0; index < _totals.length; index++)
        if (_isOpen(index)) index,
    ].length;
    final workerCode = widget.worker['ma_nv']?.toString().trim() ?? '';
    final workerDepartment = _workerDepartment;

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Xác nhận sản lượng',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: CaslaType.title,
              ),
            ),
            Text(
              appState.activeWorkContext?.departmentLabel ??
                  'Chọn công đoạn rồi nhập số lượng',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w500,
                color: CaslaColors.identityMeta,
              ),
            ),
          ],
        ),
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.opaque,
        child: ListView(
          padding: const EdgeInsets.all(CaslaSpacing.md),
          children: [
            _WorkerCard(
              name: _workerName,
              detail: [
                workerCode,
                workerDepartment,
              ].where((value) => value.isNotEmpty).join(' · '),
            ),
            const SizedBox(height: CaslaSpacing.md),
            Row(
              children: [
                const Expanded(
                  child: ScanFieldLabel(
                    text: 'Công đoạn cần xác nhận',
                    required: true,
                  ),
                ),
                if (openCount > 1)
                  TextButton(
                    onPressed: _isSubmitting ? null : _toggleAll,
                    child: Text(
                      _selected.length == openCount
                          ? 'Bỏ chọn hết'
                          : 'Chọn tất cả',
                    ),
                  ),
              ],
            ),
            for (var index = 0; index < _totals.length; index++)
              Padding(
                padding: const EdgeInsets.only(bottom: CaslaSpacing.xs),
                child: _OperationRow(
                  name: _name(index),
                  total: _totals[index],
                  lots: widget.groups[index].length,
                  selected: _selected.contains(index),
                  expanded: _expanded.contains(index),
                  enabled: _isOpen(index) && !_isSubmitting,
                  department: _departments[index],
                  onChanged: (value) => _toggle(index, value),
                  onToggleDetails: () => setState(
                    () => _expanded.contains(index)
                        ? _expanded.remove(index)
                        : _expanded.add(index),
                  ),
                ),
              ),
            const SizedBox(height: CaslaSpacing.sm),
            Row(
              children: [
                const Expanded(
                  child: ScanFieldLabel(
                    text: 'Số lượng xác nhận',
                    required: true,
                  ),
                ),
                if (_selected.isNotEmpty)
                  Text(
                    '${_selected.length} công đoạn',
                    style: const TextStyle(
                      fontSize: CaslaType.caption,
                      fontWeight: FontWeight.w700,
                      color: CaslaColors.muted,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: CaslaSpacing.xs),
            if (limit == null)
              const Text(
                'Tích ít nhất một công đoạn để nhập số lượng.',
                style: TextStyle(
                  fontSize: CaslaType.caption,
                  color: CaslaColors.muted,
                ),
              )
            else
              _LimitBanner(
                remaining: limit.remaining,
                uom: uom,
                limitedBy: _selected.length > 1 ? limit.name : null,
              ),
            const SizedBox(height: CaslaSpacing.xs),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _qtyController,
              builder: (context, value, _) {
                final entered = parseLocalizedQuantity(value.text);
                final over =
                    limit != null &&
                    entered != null &&
                    entered > limit.remaining;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _qtyController,
                      enabled: _selected.isNotEmpty && !_isSubmitting,
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
                        enabledBorder: over ? overLimitBorder() : null,
                        focusedBorder: over ? overLimitBorder(width: 2) : null,
                        errorText:
                            _quantityError ??
                            wholeQuantityInputError(value.text, uom),
                        suffixText: uom.isEmpty ? null : uom,
                      ),
                    ),
                    if (over)
                      OverLimitLine(
                        _selected.length > 1
                            ? 'Vượt số còn lại của ${limit.name} '
                                  '(${formatQuantity(limit.remaining, uom: uom)} $uom).'
                            : 'Vượt số còn lại '
                                  '${formatQuantity(limit.remaining, uom: uom)} $uom.',
                      ),
                    if (limit != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _isSubmitting
                              ? null
                              : () => _qtyController.text = formatQuantity(
                                  limit.remaining,
                                  uom: uom,
                                ),
                          child: const Text('Điền tối đa'),
                        ),
                      ),
                    if (_selected.length > 1 &&
                        entered != null &&
                        entered > 0 &&
                        !over)
                      Text(
                        'Mỗi công đoạn xác nhận '
                        '${formatQuantity(entered, uom: uom)} $uom.',
                        style: const TextStyle(
                          fontSize: CaslaType.caption,
                          color: CaslaColors.muted,
                        ),
                      ),
                  ],
                );
              },
            ),
            if (_selected.length == 1)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _isSubmitting
                      ? null
                      : () => _openSingle(_selected.first),
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text(
                    'Nhập số phế hoặc thu hồi cho công đoạn này',
                  ),
                ),
              )
            else if (_selected.length > 1)
              const Padding(
                padding: EdgeInsets.only(top: CaslaSpacing.xs),
                child: Text(
                  'Số phế và thu hồi chỉ nhập được khi tích một công đoạn.',
                  style: TextStyle(
                    fontSize: CaslaType.caption,
                    color: CaslaColors.muted,
                  ),
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(CaslaSpacing.md),
          child: ElevatedButton(
            onPressed: _isSubmitting || _selected.isEmpty ? null : _submit,
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
                    _selected.length > 1
                        ? 'Xác nhận ${_selected.length} công đoạn'
                        : 'Xác nhận sản lượng',
                  ),
          ),
        ),
      ),
    );
  }
}

/// What became of one operation of a several-operation confirmation.
class _ConfirmOutcome {
  final String name;

  /// Quantity written before a refusal, across the group's allocations.
  final double saved;

  /// The least settled receipt among the saved parts.
  final MutationReceipt? receipt;
  final MutationReceipt? refusal;

  const _ConfirmOutcome({
    required this.name,
    required this.saved,
    this.receipt,
    this.refusal,
  });

  bool get ok => refusal == null && receipt != null;
}

class _ConfirmResultDialog extends StatelessWidget {
  final List<_ConfirmOutcome> outcomes;
  final double quantity;
  final String uom;
  final String workerName;

  const _ConfirmResultDialog({
    required this.outcomes,
    required this.quantity,
    required this.uom,
    required this.workerName,
  });

  String _status(_ConfirmOutcome outcome) {
    final refusal = outcome.refusal;
    if (refusal != null) {
      final reason = refusal.message ?? 'SAP chưa chấp nhận.';
      return outcome.saved > 0
          ? 'Mới ghi ${formatQuantity(outcome.saved, uom: uom)} $uom, phần còn '
                'lại chưa ghi: $reason'
          : 'Chưa xác nhận: $reason';
    }
    return switch (outcome.receipt?.state) {
      MutationDeliveryState.synced => 'Đã gửi SAP',
      MutationDeliveryState.queued => 'Đã lưu, chờ đồng bộ',
      MutationDeliveryState.needsVerification =>
        'Đã lưu, cần xác minh ở mục Đồng bộ',
      _ => 'Đã lưu, xem mục Đồng bộ',
    };
  }

  @override
  Widget build(BuildContext context) {
    final done = outcomes.where((outcome) => outcome.ok).length;
    final title = done == outcomes.length
        ? 'Đã xác nhận $done công đoạn'
        : done == 0
        ? 'Chưa xác nhận được công đoạn nào'
        : 'Đã xác nhận $done/${outcomes.length} công đoạn';
    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mỗi công đoạn ${formatQuantity(quantity, uom: uom)} $uom cho '
              '$workerName.',
              style: const TextStyle(color: CaslaColors.muted),
            ),
            const SizedBox(height: CaslaSpacing.sm),
            for (final outcome in outcomes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: CaslaSpacing.xxs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      outcome.ok
                          ? Icons.check_circle_rounded
                          : Icons.cancel_rounded,
                      size: 20,
                      color: outcome.ok
                          ? CaslaColors.success
                          : CaslaColors.danger,
                    ),
                    const SizedBox(width: CaslaSpacing.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            outcome.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          Text(
                            _status(outcome),
                            style: TextStyle(
                              fontSize: CaslaType.caption,
                              color: outcome.ok
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

class _WorkerCard extends StatelessWidget {
  final String name;
  final String detail;

  const _WorkerCard({required this.name, required this.detail});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(CaslaSpacing.sm),
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        borderRadius: BorderRadius.circular(CaslaRadius.md),
        border: Border.all(color: CaslaColors.line),
      ),
      child: Row(
        children: [
          const Icon(Icons.badge_outlined, color: CaslaColors.primaryNavy),
          const SizedBox(width: CaslaSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: CaslaType.subtitle,
                    fontWeight: FontWeight.w800,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    style: const TextStyle(
                      fontSize: CaslaType.caption,
                      color: CaslaColors.muted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One operation: a tick box and its name. The arrow opens the figures.
class _OperationRow extends StatelessWidget {
  final String name;
  final Assignment total;
  final int lots;
  final bool selected;
  final bool expanded;
  final bool enabled;
  final String? department;
  final ValueChanged<bool> onChanged;
  final VoidCallback onToggleDetails;

  const _OperationRow({
    required this.name,
    required this.total,
    required this.lots,
    required this.selected,
    required this.expanded,
    required this.enabled,
    required this.department,
    required this.onChanged,
    required this.onToggleDetails,
  });

  @override
  Widget build(BuildContext context) {
    final uom = total.uom;
    String quantity(double value) => '${formatQuantity(value, uom: uom)} $uom';
    final done = total.remaining <= 0;
    return Material(
      color: selected ? CaslaColors.navy100 : CaslaColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CaslaRadius.md),
        side: BorderSide(
          color: selected ? CaslaColors.primaryNavy : CaslaColors.line,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: enabled ? () => onChanged(!selected) : null,
                  child: Row(
                    children: [
                      Checkbox(
                        value: selected,
                        onChanged: enabled
                            ? (value) => onChanged(value ?? false)
                            : null,
                        activeColor: CaslaColors.primaryNavy,
                      ),
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontSize: CaslaType.body,
                            fontWeight: FontWeight.w700,
                            color: done
                                ? CaslaColors.muted
                                : CaslaColors.primaryNavy,
                          ),
                        ),
                      ),
                      if (done)
                        const Padding(
                          padding: EdgeInsets.only(right: CaslaSpacing.xs),
                          child: Text(
                            'Đã xong',
                            style: TextStyle(
                              fontSize: CaslaType.caption,
                              fontWeight: FontWeight.w700,
                              color: CaslaColors.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: expanded ? 'Thu gọn $name' : 'Chi tiết $name',
                onPressed: onToggleDetails,
                icon: Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                color: CaslaColors.muted,
              ),
            ],
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                48,
                0,
                CaslaSpacing.sm,
                CaslaSpacing.sm,
              ),
              child: Column(
                children: [
                  _DetailLine('Lệnh SX', total.productionOrder),
                  _DetailLine('Công đoạn', total.operation),
                  if ((department ?? '').isNotEmpty)
                    _DetailLine('Bộ phận', department!),
                  _DetailLine(
                    'Đã giao',
                    '${quantity(total.assignedQuantity)}'
                        '${lots > 1 ? ' · $lots lần giao' : ''}',
                  ),
                  _DetailLine('Đã xác nhận', quantity(total.completedQuantity)),
                  if (total.defectQuantity > 0)
                    _DetailLine('Số lượng phế', quantity(total.defectQuantity)),
                  _DetailLine('Còn lại', quantity(total.remaining)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  final String label;
  final String value;

  const _DetailLine(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w600,
                color: CaslaColors.muted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: CaslaType.body,
                fontWeight: FontWeight.w700,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LimitBanner extends StatelessWidget {
  final double remaining;
  final String uom;

  /// The operation that sets the ceiling, when several are ticked.
  final String? limitedBy;

  const _LimitBanner({
    required this.remaining,
    required this.uom,
    required this.limitedBy,
  });

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Xác nhận tối đa',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: CaslaColors.pending,
                  ),
                ),
              ),
              Text(
                '${formatQuantity(remaining, uom: uom)} $uom',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: CaslaColors.pending,
                ),
              ),
            ],
          ),
          if (limitedBy != null)
            Text(
              'Theo công đoạn còn ít nhất: $limitedBy',
              style: const TextStyle(
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w600,
                color: CaslaColors.pending,
              ),
            ),
        ],
      ),
    );
  }
}
