// Screen S15 — confirm several operations of one worker at once.
//
// Reached from the Xác nhận tab when the worker has more than one operation
// open. Each operation is a card with a tick box, its sales order and
// product, its name and order, and what was given, confirmed and is left.
// The supervisor types one quantity, confirmed on every ticked operation, or
// ticks "confirm what is left", which confirms each ticked operation's own
// balance. Defect and recall quantities stay on the single-operation form
// (S08), which "Chi tiết công đoạn" opens when exactly one is ticked.
//
// After a confirmation the balances are read again: the screen stays while
// the worker still has an operation open and returns to the worker list once
// nothing is left. The QR button returns there with the scanner open, to
// pick another worker.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';
import '../../../presentation/widgets/casla_dialog_header.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../core/utils/shift_execution_validation.dart';
import '../../../data/repositories/confirmation_targets.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/mutation_receipt.dart';
import '../../../domain/policies/grouped_confirmation.dart';
import '../../../domain/policies/multi_confirmation.dart';
import '../../../domain/policies/production_math.dart';
import '../../../main.dart';
import '../../../presentation/widgets/over_limit_line.dart';
import '../../../presentation/widgets/scan_slot_field.dart';
import '../../../presentation/widgets/worker_verification_dialog.dart';

class S15MultiConfirmScreen extends ConsumerStatefulWidget {
  /// What the route pops with when the supervisor asks to scan another
  /// worker: the worker list opens its scanner.
  static const scanAnotherWorker = 'scan-another-worker';

  final Map<String, dynamic> worker;

  /// The worker's confirmation groups that still have something open.
  final List<List<Assignment>> groups;

  @visibleForTesting
  final DateTime Function()? now;

  /// Reads the worker's open groups again after a confirmation. Tests
  /// replace the SAP-backed default.
  @visibleForTesting
  final Future<List<List<Assignment>>> Function()? reloadGroups;

  const S15MultiConfirmScreen({
    super.key,
    required this.worker,
    required this.groups,
    this.now,
    this.reloadGroups,
  });

  @override
  ConsumerState<S15MultiConfirmScreen> createState() =>
      _S15MultiConfirmScreenState();
}

class _S15MultiConfirmScreenState extends ConsumerState<S15MultiConfirmScreen> {
  final TextEditingController _qtyController = TextEditingController();
  final Set<int> _selected = {};

  /// The groups on screen: the ones the route was opened with, replaced by a
  /// fresh read after every confirmation.
  late List<List<Assignment>> _groups = widget.groups;
  late List<Assignment> _totals = [
    for (final group in _groups) aggregateConfirmationGroup(group),
  ];

  /// "SO/item" of each order, by local order id. Null until read; empty when
  /// the order carries none.
  final Map<String, String> _salesOrders = {};
  bool _isSubmitting = false;

  /// Confirm what each ticked operation has left instead of a typed figure.
  bool _confirmRemaining = false;
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
    unawaited(_loadSalesOrders());
  }

  @override
  void dispose() {
    _qtyController.dispose();
    super.dispose();
  }

  /// The sales order is kept on the order row, not on the allocation.
  Future<void> _loadSalesOrders() async {
    final db = ref.read(appStateProvider).db;
    for (final orderId in {for (final total in _totals) total.orderId}) {
      if (_salesOrders.containsKey(orderId)) continue;
      try {
        final order = await db.getOrderById(orderId);
        if (!mounted) return;
        final label = [
          order?['sales_order']?.toString().trim() ?? '',
          order?['sales_order_item']?.toString().trim() ?? '',
        ].where((value) => value.isNotEmpty).join('/');
        setState(() => _salesOrders[orderId] = label);
      } catch (_) {
        // The sales order is only shown among the operation's details.
      }
    }
  }

  /// The worker's open groups, read against SAP the way the worker list does
  /// before it opens this screen.
  Future<List<List<Assignment>>> _loadOpenGroups() async {
    final appState = ref.read(appStateProvider);
    final shift = appState.activeShift;
    final workContext = appState.activeWorkContext;
    if (shift == null || workContext == null) return const [];
    return loadOpenConfirmationGroups(
      db: appState.db,
      assignments: appState.assignmentRepo,
      workHistory: appState.workHistoryRepo,
      workerId: widget.worker['id']?.toString() ?? '',
      workerCode: widget.worker['ma_nv']?.toString() ?? '',
      businessDate: appState.activeBusinessDate,
      shiftId: shift.shiftId,
      workId: workContext.workId,
      workCenter: workContext.workCenter,
    );
  }

  /// Something was written, so the balances on screen are stale. Stays with
  /// fresh ones while the worker still has an operation open; otherwise goes
  /// back to the worker list to pick another worker. Balances that cannot be
  /// read again are not offered for a second confirmation either.
  Future<void> _reloadOrLeave() async {
    List<List<Assignment>> fresh;
    try {
      fresh = await (widget.reloadGroups ?? _loadOpenGroups)();
    } catch (_) {
      fresh = const [];
    }
    if (!mounted) return;
    if (fresh.isEmpty) {
      context.pop(true);
      return;
    }
    setState(() {
      _groups = fresh;
      _totals = [for (final group in fresh) aggregateConfirmationGroup(group)];
      _selected.clear();
      _qtyController.clear();
      _confirmRemaining = false;
      _quantityError = null;
    });
    unawaited(_loadSalesOrders());
  }

  String _name(int index) => confirmationGroupName(_groups[index]);

  bool _isOpen(int index) => _totals[index].groupRemaining > 0;

  /// Ticked operations, in list order.
  List<int> get _selectedIndexes => _selected.toList()..sort();

  /// What each ticked operation confirms for [entered], in list order.
  List<double> _quantitiesFor(double entered) => multiConfirmationQuantities(
    [for (final index in _selectedIndexes) _groups[index]],
    confirmRemaining: _confirmRemaining,
    entered: entered,
  );

  void _setConfirmRemaining(bool value) {
    setState(() {
      _confirmRemaining = value;
      if (value) _qtyController.clear();
      _quantityError = null;
    });
  }

  String get _uom {
    final index = _selected.isEmpty ? null : _selected.first;
    return index == null
        ? (_totals.isEmpty ? '' : _totals.first.uom)
        : _totals[index].uom;
  }

  ({double remaining, String name})? get _limit {
    final tightest = tightestConfirmationGroup([
      for (final index in _selected) _groups[index],
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
      titlePadding: CaslaDialog.titlePadding,
      contentPadding: CaslaDialog.contentPadding,
      title: CaslaDialogHeader(child: Text(title)),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        TextButton(
          style: CaslaDialog.actionStyle,
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
    final indexes = _selectedIndexes;
    final uom = _uom;
    final confirmRemaining = _confirmRemaining;

    var quantity = 0.0;
    if (!confirmRemaining) {
      quantity = parseLocalizedQuantity(_qtyController.text) ?? 0.0;
      if (!quantity.isFinite || quantity <= 0) {
        setState(
          () =>
              _quantityError = 'Số lượng xác nhận phải là một số dương hợp lệ.',
        );
        return;
      }
      final wholeError = wholeQuantityInputError(_qtyController.text, uom);
      if (wholeError != null) {
        setState(() => _quantityError = wholeError);
        return;
      }
    }
    // More than the tightest operation has left may be confirmed; the form
    // warns under the field.
    setState(() => _quantityError = null);
    // The typed figure on every ticked operation, or each one's own balance.
    final quantities = _quantitiesFor(quantity);
    final quantityOf = {
      for (var at = 0; at < indexes.length; at++) indexes[at]: quantities[at],
    };

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
          _groups[index],
          completed: quantityOf[index]!,
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
        // The worker signs what every ticked operation confirms in all, the
        // figure shown as "Tổng" under the quantity.
        summary: WorkerQuantitySummary(
          workerCode: widget.worker['ma_nv']?.toString().trim() ?? '',
          uom: uom,
          completedTotal: multiConfirmationTotal(quantities),
        ),
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
                quantity: quantityOf[index]!,
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
          confirmRemaining: confirmRemaining,
          uom: uom,
          workerName: _workerName,
        ),
      );
      // The balances on screen are the old ones: read them again before
      // anything here can be confirmed twice.
      if (mounted && savedAny) await _reloadOrLeave();
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
    final group = _groups[index];
    await context.push(
      '/supervisor/assignment_detail',
      extra: <String, dynamic>{'assignment': group.first, 'group': group},
    );
    // That form changes the balance this list was opened with.
    if (!mounted) return;
    setState(() => _isSubmitting = true);
    try {
      await _reloadOrLeave();
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
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
        actions: [
          IconButton(
            key: const Key('multi-confirm-scan-worker'),
            tooltip: 'Quét QR công nhân khác',
            onPressed: _isSubmitting
                ? null
                : () => context.pop(S15MultiConfirmScreen.scanAnotherWorker),
            icon: const Icon(Icons.qr_code_scanner),
          ),
        ],
      ),
      // The submit button lives in the body, not in a bottomNavigationBar:
      // the Scaffold keeps a bottom bar at the screen's edge, under the soft
      // keyboard, so a supervisor typing a quantity had to dismiss the
      // keyboard to reach it. The body shrinks above the keyboard instead.
      body: LayoutBuilder(
        builder: (context, box) => Column(
          children: [
            Expanded(
              child: GestureDetector(
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
                        child: _OperationCard(
                          name: _name(index),
                          total: _totals[index],
                          salesOrder:
                              _salesOrders[_totals[index].orderId] ?? '',
                          selected: _selected.contains(index),
                          enabled: _isOpen(index) && !_isSubmitting,
                          onChanged: (value) => _toggle(index, value),
                        ),
                      ),
                    // Scrolls with the operations it speaks of.
                    _RemainingToggle(
                      value: _confirmRemaining,
                      onChanged: _isSubmitting ? null : _setConfirmRemaining,
                    ),
                  ],
                ),
              ),
            ),
            // The quantity, its total and the two buttons stay put under
            // the list, whatever its length. Never taller than the body: on
            // a short screen with the keyboard up the list gives way and
            // the panel scrolls, the field last to go.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight),
              child: Container(
                key: const Key('multi-confirm-panel'),
                decoration: const BoxDecoration(
                  color: CaslaColors.surface,
                  border: Border(top: BorderSide(color: CaslaColors.line)),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      CaslaSpacing.md,
                      CaslaSpacing.xs,
                      CaslaSpacing.md,
                      CaslaSpacing.md,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: SingleChildScrollView(
                            reverse: true,
                            child: ValueListenableBuilder<TextEditingValue>(
                              valueListenable: _qtyController,
                              builder: (context, value, _) {
                                final entered = _confirmRemaining
                                    ? null
                                    : parseLocalizedQuantity(value.text);
                                final over =
                                    limit != null &&
                                    entered != null &&
                                    entered > limit.remaining;
                                final total = multiConfirmationTotal(
                                  _quantitiesFor(
                                    entered != null &&
                                            entered.isFinite &&
                                            entered > 0
                                        ? entered
                                        : 0,
                                  ),
                                );
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(
                                      children: [
                                        const Expanded(
                                          child: ScanFieldLabel(
                                            text: 'Số lượng xác nhận',
                                            required: true,
                                          ),
                                        ),
                                        // What this confirmation adds up to
                                        // across the ticked operations.
                                        Text(
                                          'Tổng: ${formatQuantity(total, uom: uom)}',
                                          key: const Key('multi-confirm-total'),
                                          style: const TextStyle(
                                            fontSize: CaslaType.body,
                                            fontWeight: FontWeight.w800,
                                            color: CaslaColors.primaryNavy,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: CaslaSpacing.xs),
                                    TextField(
                                      controller: _qtyController,
                                      enabled:
                                          _selected.isNotEmpty &&
                                          !_isSubmitting &&
                                          !_confirmRemaining,
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
                                        enabledBorder: over
                                            ? overLimitBorder()
                                            : null,
                                        focusedBorder: over
                                            ? overLimitBorder(width: 2)
                                            : null,
                                        errorText:
                                            _quantityError ??
                                            wholeQuantityInputError(
                                              value.text,
                                              uom,
                                            ),
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
                                    if (_selected.length > 1 &&
                                        entered != null &&
                                        entered > 0 &&
                                        !over)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          top: CaslaSpacing.xxs,
                                        ),
                                        child: Text(
                                          'Mỗi công đoạn xác nhận '
                                          '${formatQuantity(entered, uom: uom)} $uom.',
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
                          ),
                        ),
                        const SizedBox(height: CaslaSpacing.sm),
                        Row(
                          children: [
                            // The single-operation form (S08) holds the defect and
                            // recall entries, so it opens for exactly one operation.
                            Expanded(
                              flex: 5,
                              child: OutlinedButton(
                                key: const Key('multi-confirm-detail'),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 52),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: CaslaSpacing.xs,
                                  ),
                                ),
                                onPressed:
                                    _isSubmitting || _selected.length != 1
                                    ? null
                                    : () => _openSingle(_selected.first),
                                child: const FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('Chi tiết công đoạn'),
                                ),
                              ),
                            ),
                            const SizedBox(width: CaslaSpacing.xs),
                            Expanded(
                              flex: 6,
                              child: ElevatedButton(
                                key: const Key('multi-confirm-submit'),
                                onPressed: _isSubmitting || _selected.isEmpty
                                    ? null
                                    : _submit,
                                child: _isSubmitting
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: CaslaColors.navy900,
                                        ),
                                      )
                                    : const Text('Xác nhận'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What became of one operation of a several-operation confirmation.
class _ConfirmOutcome {
  final String name;

  /// What was asked for on this operation.
  final double quantity;

  /// Quantity written before a refusal, across the group's allocations.
  final double saved;

  /// The least settled receipt among the saved parts.
  final MutationReceipt? receipt;
  final MutationReceipt? refusal;

  const _ConfirmOutcome({
    required this.name,
    required this.quantity,
    required this.saved,
    this.receipt,
    this.refusal,
  });

  bool get ok => refusal == null && receipt != null;

  /// SAP accepted every part: the only outcome that may be called confirmed.
  bool get sent => ok && receipt!.state == MutationDeliveryState.synced;

  /// Saved on the device but not accepted by SAP yet (queued, or waiting for
  /// the worker's verification). The quantity shows as confirmed on the
  /// device's own balances while SAP still knows nothing about it, so the
  /// dialog must not present it as confirmed.
  bool get held => ok && !sent;
}

class _ConfirmResultDialog extends StatelessWidget {
  final List<_ConfirmOutcome> outcomes;

  /// The typed figure, confirmed on every operation.
  final double quantity;

  /// Each operation confirmed its own balance instead of [quantity].
  final bool confirmRemaining;
  final String uom;
  final String workerName;

  const _ConfirmResultDialog({
    required this.outcomes,
    required this.quantity,
    required this.confirmRemaining,
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
    final detail = outcome.receipt?.message;
    final why = detail == null || detail.trim().isEmpty ? '' : ' $detail';
    return switch (outcome.receipt?.state) {
      MutationDeliveryState.synced => 'Đã gửi SAP',
      MutationDeliveryState.queued =>
        'Chưa gửi SAP. Đã lưu trên máy, chờ đồng bộ.$why',
      MutationDeliveryState.needsVerification =>
        'Chưa gửi SAP. Đã lưu trên máy, cần xác minh ở mục Đồng bộ.$why',
      _ => 'Chưa gửi SAP. Đã lưu trên máy, xem mục Đồng bộ.$why',
    };
  }

  /// "Đã xác nhận" counts only what SAP accepted. Work that is merely saved
  /// on the device is named separately so a dropped post is never read as a
  /// confirmation.
  String _title() {
    final total = outcomes.length;
    final sent = outcomes.where((outcome) => outcome.sent).length;
    final held = outcomes.where((outcome) => outcome.held).length;
    if (sent == total) return 'Đã xác nhận $sent công đoạn';
    if (sent == 0 && held == 0) return 'Chưa xác nhận được công đoạn nào';
    if (sent == 0) {
      return 'Chưa gửi được SAP, $held công đoạn mới lưu trên máy';
    }
    final heldNote = held == 0 ? '' : ', $held chờ gửi SAP';
    return 'Đã xác nhận $sent/$total công đoạn$heldNote';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: CaslaDialog.titlePadding,
      contentPadding: CaslaDialog.contentPadding,
      title: CaslaDialogHeader(child: Text(_title())),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              confirmRemaining
                  ? 'Hết số còn lại của từng công đoạn cho $workerName.'
                  : 'Mỗi công đoạn ${formatQuantity(quantity, uom: uom)} $uom '
                        'cho $workerName.',
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
                      outcome.sent
                          ? Icons.check_circle_rounded
                          : outcome.held
                          ? Icons.schedule_rounded
                          : Icons.cancel_rounded,
                      size: 20,
                      color: outcome.sent
                          ? CaslaColors.success
                          : outcome.held
                          ? CaslaColors.pending
                          : CaslaColors.danger,
                    ),
                    const SizedBox(width: CaslaSpacing.xs),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            // The figures differ per operation only when
                            // each one confirmed its own balance.
                            confirmRemaining
                                ? '${outcome.name} · '
                                      '${formatQuantity(outcome.quantity, uom: uom)} $uom'
                                : outcome.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          Text(
                            _status(outcome),
                            style: TextStyle(
                              fontSize: CaslaType.caption,
                              color: outcome.sent
                                  ? CaslaColors.muted
                                  : outcome.held
                                  ? CaslaColors.pending
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
          style: CaslaDialog.actionStyle,
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

/// One operation: a tick box with its sales order and product, then its
/// name, where it comes from, and what was given, confirmed and is left.
/// Tapping anywhere ticks it.
class _OperationCard extends StatelessWidget {
  final String name;
  final Assignment total;

  /// "SO/item" of the order, empty when it carries none.
  final String salesOrder;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _OperationCard({
    required this.name,
    required this.total,
    required this.salesOrder,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    String quantity(double value) => formatQuantity(value, uom: total.uom);
    String orDash(String value) => value.trim().isEmpty ? '—' : value.trim();
    final done = total.groupRemaining <= 0;
    final product = total.productName.trim().isNotEmpty
        ? total.productName
        : total.productCode;
    final headStyle = TextStyle(
      fontSize: CaslaType.body,
      fontWeight: FontWeight.w800,
      color: done ? CaslaColors.muted : CaslaColors.primaryNavy,
    );
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
      child: InkWell(
        onTap: enabled ? () => onChanged(!selected) : null,
        child: Padding(
          padding: const EdgeInsets.all(CaslaSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: selected,
                      onChanged: enabled
                          ? (value) => onChanged(value ?? false)
                          : null,
                      activeColor: CaslaColors.primaryNavy,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: CaslaSpacing.xs),
                  // The sales order is short and never cut; the product
                  // takes what is left of the line.
                  Text(orDash(salesOrder), style: headStyle),
                  const SizedBox(width: CaslaSpacing.sm),
                  Expanded(
                    child: Text(
                      orDash(product),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: headStyle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: CaslaSpacing.xs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: done ? CaslaColors.muted : CaslaColors.navy900,
                      ),
                    ),
                  ),
                  if (done)
                    const Padding(
                      padding: EdgeInsets.only(left: CaslaSpacing.xs),
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
              const SizedBox(height: 2),
              _FactRow(
                left: 'LSX: ${orDash(total.productionOrder)}',
                right: 'Công đoạn: ${orDash(total.operation)}',
              ),
              const SizedBox(height: CaslaSpacing.xs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: CaslaSpacing.sm,
                  vertical: CaslaSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: selected ? CaslaColors.surface : CaslaColors.muted100,
                  borderRadius: BorderRadius.circular(CaslaRadius.sm),
                ),
                child: Row(
                  children: [
                    _Figure(
                      label: 'Giao hiệu lực',
                      value: quantity(total.effectiveAssigned),
                    ),
                    _Figure(
                      label: 'Đã xác nhận',
                      // Good output and scrap: both came off the balance.
                      value: quantity(
                        ProductionMath.confirmedQuantity(
                          total.completedQuantity,
                          total.defectQuantity,
                        ),
                      ),
                    ),
                    _Figure(
                      label: 'Còn lại',
                      value: quantity(total.groupRemaining),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two facts on one line: one at each end.
class _FactRow extends StatelessWidget {
  final String left;
  final String right;

  const _FactRow({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: CaslaType.caption,
      height: 1.3,
      color: CaslaColors.muted,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            left,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        const SizedBox(width: CaslaSpacing.xs),
        Text(right, maxLines: 1, style: style),
      ],
    );
  }
}

/// One of the three figures of an operation, without its unit: the unit is
/// on the quantity field and on the total below.
class _Figure extends StatelessWidget {
  final String label;
  final String value;

  const _Figure({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: CaslaType.caption,
              color: CaslaColors.muted,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
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

/// "Confirm what each ticked operation has left": the quantity field is
/// closed while it is ticked.
class _RemainingToggle extends StatelessWidget {
  final bool value;

  /// Null while a confirmation is being sent.
  final ValueChanged<bool>? onChanged;

  const _RemainingToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return InkWell(
      key: const Key('multi-confirm-remaining'),
      onTap: onChanged == null ? null : () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: CaslaSpacing.xs),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                onChanged: onChanged == null
                    ? null
                    : (checked) => onChanged(checked ?? false),
                activeColor: CaslaColors.primaryNavy,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: CaslaSpacing.xs),
            const Expanded(
              child: Text(
                'Xác nhận hoàn thành số lượng còn lại',
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
    );
  }
}
