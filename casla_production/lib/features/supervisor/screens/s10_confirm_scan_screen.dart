// Screen S10 — Scan Worker QR & Confirm Production Screen
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../data/sap/odata_error.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';
import '../../../presentation/widgets/casla_dialog_header.dart';
import '../../../core/auth/session_manager.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../core/utils/shift_execution_validation.dart';
import '../../../core/utils/vietnamese_text_normalizer.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../domain/entities/work_history.dart';
import '../../../domain/policies/grouped_confirmation.dart';
import '../../../domain/policies/local_history_overlay.dart';
import '../../../domain/policies/recall_all.dart';
import '../../../presentation/widgets/account_avatar_button.dart';
import '../../../presentation/widgets/confirmation_target_picker.dart';
import '../../../presentation/widgets/recall_all_confirm_dialog.dart';
import '../../../data/repositories/confirmation_targets.dart';
import '../../../main.dart';
import '../../../presentation/widgets/adaptive_barcode_scanner_view.dart';
import '../../../presentation/widgets/barcode_scan_listener.dart';
import '../../../presentation/widgets/searchable_picker_sheet.dart';
import '../../../presentation/widgets/worker_scan_acceptance.dart';
import 's15_multi_confirm_screen.dart';

class S10ConfirmScanScreen extends ConsumerStatefulWidget {
  const S10ConfirmScanScreen({super.key});

  @override
  ConsumerState<S10ConfirmScanScreen> createState() =>
      _S10ConfirmScanScreenState();
}

class _S10ConfirmScanScreenState extends ConsumerState<S10ConfirmScanScreen> {
  bool _isProcessing = false;
  bool _isOpeningWorker = false;
  bool _isRecallingAll = false;
  String? _errorMessage;
  bool _isLoadingWorkers = true;
  bool _showScanner = false;
  String _workerQuery = '';
  List<Map<String, dynamic>> _cachedWorkers = const [];
  Map<String, dynamic>? _selectedWorker;
  Map<String, String> _cachedWorkContextLabels = const {};
  late final TextEditingController _workerSearchController;

  /// The worker list's own scroll position. The supervisor shell keeps every
  /// tab alive in one route, so the route's PrimaryScrollController already
  /// holds another tab's list, and a scrollbar with a visible thumb needs
  /// exactly one position.
  final ScrollController _workerListScroll = ScrollController();
  late final AppState _observedState;
  String _loadedScope = '';
  int _workerLoadGeneration = 0;
  StreamSubscription<void>? _remotePostingSubscription;
  Timer? _remoteReloadTimer;

  String _scopeKey() =>
      '${_observedState.sessionGeneration}|${_dateKey(_observedState.activeBusinessDate)}|${_observedState.activeShift?.shiftId}|${_observedState.activeWorkContext?.workId}|${_observedState.activeWorkContext?.boPhan.trim().toUpperCase()}|${_observedState.activeWorkContext?.workCenter.trim().toUpperCase()}';

  void _onScopeChanged() {
    if (mounted && _scopeKey() != _loadedScope) unawaited(_loadCachedWorkers());
  }

  @override
  void initState() {
    super.initState();
    _workerSearchController = TextEditingController();
    _observedState = ref.read(appStateProvider);
    _observedState.addListener(_onScopeChanged);
    // A queued confirmation posted in the background changes who still has
    // work left; refresh the list in place without flashing the loader.
    _remotePostingSubscription = _observedState.db.remotePostings.listen((_) {
      _remoteReloadTimer?.cancel();
      _remoteReloadTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted && !_isOpeningWorker && !_isProcessing) {
          unawaited(_loadCachedWorkers(quiet: true));
        }
      });
    });
    _loadCachedWorkers();
  }

  @override
  void dispose() {
    _observedState.removeListener(_onScopeChanged);
    _remoteReloadTimer?.cancel();
    unawaited(_remotePostingSubscription?.cancel());
    _workerSearchController.dispose();
    _workerListScroll.dispose();
    super.dispose();
  }

  Future<void> _loadCachedWorkers({bool quiet = false}) async {
    final generation = ++_workerLoadGeneration;
    final appState = _observedState;
    _loadedScope = _scopeKey();
    final previous = _selectedWorker;
    final date = appState.activeBusinessDate;
    final shift = appState.activeShift;
    final workId = appState.activeWorkContext?.workId;
    final session = appState.currentSession;
    final scopeIds = workId != null && workId.isNotEmpty
        ? [workId]
        : session?.toIds ?? const <String>[];
    if (!quiet) {
      setState(() {
        _isLoadingWorkers = true;
        _cachedWorkers = [];
        _selectedWorker = null;
      });
    }
    try {
      final workers = await appState.db.getWorkersForManualSelection(
        scopeIds,
        now: date,
      );
      final workContext = appState.activeWorkContext;
      final ids = shift == null
          ? <String>{}
          : await appState.db.getAssignedWorkerIdsForShift(
              teamIds: scopeIds,
              businessDate: _dateKey(date),
              shiftId: shift.shiftId,
            );
      // Workers SAP reports as fully settled once this device's unreported
      // writes are applied. SAP outranks the local balance for them: the
      // cached report may predate a confirmation made a moment ago.
      final settled = <String>{};
      if (shift != null) {
        try {
          final history = await appState.workHistoryRepo.getWorkHistory(
            range: HistoryRange.day,
            dateFrom: date,
            dateTo: date,
            shiftId: shift.shiftId,
            workId: workId,
          );
          final ledgerRows = await appState.db.getLocalLedgerRows(
            teamIds: scopeIds,
            fromBusinessDate: _dateKey(date),
            toBusinessDate: _dateKey(date),
            shiftId: shift.shiftId,
          );
          final ledger = buildLocalPendingLedger(
            sap: history,
            rows: ledgerRows.map(LocalLedgerRow.fromMap),
          );
          final sapRemaining = <String, double>{};
          for (final worker in history.workers) {
            if (!_historyWorkerMatchesScope(worker, workContext)) continue;
            sapRemaining[worker.workerId] =
                (sapRemaining[worker.workerId] ?? 0) + worker.remainingQuantity;
          }
          for (final entry in sapRemaining.entries) {
            final remaining =
                entry.value + ledger.forWorker([entry.key]).remainingDelta;
            if (remaining > 0.0001) {
              ids.add(entry.key);
            } else {
              settled.add(entry.key);
            }
          }
        } catch (_) {
          // Offline: retain only workers backed by matching local assignments.
        }
      }
      final filtered = workers.where((worker) {
        final id = worker['id']?.toString();
        final code = worker['ma_nv']?.toString();
        if (settled.contains(id) || settled.contains(code)) return false;
        return ids.contains(id) || ids.contains(code);
      }).toList();
      final teams = await appState.db.getTeamsForScope(scopeIds);
      if (!mounted || generation != _workerLoadGeneration) return;
      setState(() {
        _cachedWorkers = filtered;
        _selectedWorker = filtered
            .where((worker) => _sameWorker(previous, worker))
            .firstOrNull;
        _cachedWorkContextLabels = _buildWorkContextLabels(
          session?.workContexts ?? const <UserWorkContext>[],
          teams,
        );
        _isLoadingWorkers = false;
      });
    } catch (_) {
      // A background refresh keeps the list it already shows.
      if (!mounted || generation != _workerLoadGeneration || quiet) return;
      setState(() {
        _isLoadingWorkers = false;
        _errorMessage =
            'Không tải được nhân viên của ca đang chọn. Vui lòng thử lại.';
      });
    }
  }

  Future<bool> _handleWorkerCodeScanned(String rawCode) async {
    if (_isProcessing) return false;
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final outcome = await acceptScannedWorker(
        context,
        rawCode: rawCode,
        database: ref.read(appStateProvider).db,
      );
      if (!mounted) return false;

      switch (outcome) {
        case WorkerScanAccepted(:final worker):
          if (mounted) setState(() => _showScanner = false);
          await _openWorker(worker);
          return true;
        case WorkerScanRejected(:final message):
          _showError(message);
          return false;
        case WorkerScanCancelled():
          return false;
      }
    } catch (_) {
      _showError('Không thể kiểm tra mã công nhân lúc này. Vui lòng thử lại.');
      return false;
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  /// PP_CONFIRM may enter a confirmed quantity. An account with only
  /// PP_RECALL also uses this tab: its "Xác nhận" sheet then holds only the
  /// recall entry, and multi-confirm (all quantity entry) is skipped.
  bool get _canConfirm =>
      ref
          .read(appStateProvider)
          .currentSession
          ?.hasPermission(Permission.confirmProduction) ==
      true;

  /// Work done off the line is given and confirmed in one go: that needs
  /// both the assign and the confirm function.
  bool get _canConfirmDirectly {
    final session = ref.read(appStateProvider).currentSession;
    return session?.hasPermission(Permission.assignQuantity) == true &&
        session?.hasPermission(Permission.confirmProduction) == true;
  }

  Future<void> _openDirectConfirmation() async {
    await context.push('/supervisor/confirm_direct');
    // The wizard may have given and confirmed work for a worker of this
    // shift: the list behind it carries the old balances.
    if (mounted) unawaited(_loadCachedWorkers());
  }

  Future<void> _openWorker(Map<String, dynamic> worker) async {
    if (_isOpeningWorker) return;
    setState(() => _isOpeningWorker = true);
    try {
      final appState = ref.read(appStateProvider);
      final openingScope = _scopeKey();
      final date = appState.activeBusinessDate;
      final shiftId = appState.activeShift?.shiftId;
      final workContext = appState.activeWorkContext;
      if (shiftId == null || workContext == null) {
        _showError('Vui lòng chọn ca và tổ trước khi xác nhận.');
        return;
      }
      final assignments = await _loadWorkerTargets(
        appState,
        worker,
        date: date,
        shiftId: shiftId,
        workContext: workContext,
        openingScope: openingScope,
      );
      if (assignments == null ||
          !mounted ||
          openingScope != _scopeKey() ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }

      final canConfirm = _canConfirm;
      if (!assignments.any((assignment) => assignment.canConfirm)) {
        _showError(
          canConfirm
              ? 'Nhân viên không còn sản lượng cần xác nhận trong ca và tổ đang chọn.'
              : 'Nhân viên không còn sản lượng chưa làm để thu hồi trong ca và tổ đang chọn.',
        );
        return;
      }

      // Several operations open: tick the ones to confirm together instead of
      // picking a single one. That screen is all quantity entry, so a
      // recall-only account picks one operation below instead.
      final openGroups = groupConfirmationTargets(
        assignments,
      ).where((group) => group.any((target) => target.canConfirm)).toList();
      if (canConfirm && openGroups.length > 1) {
        final result = await context.push<Object?>(
          '/supervisor/confirm_multi',
          extra: <String, dynamic>{'worker': worker, 'groups': openGroups},
        );
        // Its QR button asks for another worker: scan the next card here.
        if (mounted && result == S15MultiConfirmScreen.scanAnotherWorker) {
          setState(() {
            _showScanner = true;
            _errorMessage = null;
          });
        }
        return;
      }

      final group = await pickConfirmationGroup(context, assignments);
      if (!mounted || openingScope != _scopeKey()) return;
      if (group != null) {
        await context.push(
          '/supervisor/assignment_detail',
          extra: <String, dynamic>{
            'assignment': group.first,
            // The "Xác nhận" form opens for PP_CONFIRM and PP_RECALL alike;
            // without PP_CONFIRM it holds only the recall entry.
            'group': group,
          },
        );
      }
    } on FormatException catch (error) {
      if (mounted) _showError(error.message);
    } catch (error, stackTrace) {
      debugPrint('Mở xác nhận từ tab Xác nhận thất bại: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showError(
          error is SapBusinessError
              ? 'Không tải được lịch sử từ SAP: ${friendlySapErrorMessage(error)}'
              : 'Chưa đối chiếu được số lượng với SAP. Kiểm tra kết nối rồi thử lại.',
        );
      }
    } finally {
      if (mounted) setState(() => _isOpeningWorker = false);
      if (mounted) unawaited(_loadCachedWorkers());
    }
  }

  /// The worker's allocations of the selected day, shift and department,
  /// reconciled with SAP. Null when the selection changed while loading.
  Future<List<Assignment>?> _loadWorkerTargets(
    AppState appState,
    Map<String, dynamic> worker, {
    required DateTime date,
    required String shiftId,
    required UserWorkContext workContext,
    required String openingScope,
  }) async {
    final history = await loadConfirmationHistory(
      appState.workHistoryRepo,
      range: HistoryRange.day,
      dateFrom: date,
      dateTo: date,
      shiftId: shiftId,
      workId: workContext.workId,
    );
    if (!mounted || openingScope != _scopeKey()) return null;
    return resolveConfirmationTargets(
      db: appState.db,
      assignments: appState.assignmentRepo,
      history: history,
      workerId: worker['id']?.toString() ?? '',
      workerCode: worker['ma_nv']?.toString() ?? '',
      businessDate: _dateKey(date),
      shiftId: shiftId,
      workId: workContext.workId,
      workCenter: workContext.workCenter,
      includeSettled: true,
    );
  }

  /// PP_RECALL_NOPASS on top of PP_RECALL: the worker list offers "Thu hồi
  /// không mật khẩu", which takes back everything the selected worker still
  /// holds here. The Xác nhận sheet does the same for one order at a time.
  bool get _canRecallWithoutPassword {
    final session = ref.read(appStateProvider).currentSession;
    return session?.hasPermission(Permission.recallAssignment) == true &&
        session?.hasPermission(Permission.recallWithoutPassword) == true;
  }

  /// Recalls every open order/operation of the selected worker, each as one
  /// password-less recall of what is left on it.
  Future<void> _recallAllWithoutPassword() async {
    final worker = _selectedWorker;
    if (worker == null || _isProcessing || _isOpeningWorker) return;
    setState(() {
      _isProcessing = true;
      _isRecallingAll = true;
      _errorMessage = null;
    });
    try {
      final appState = ref.read(appStateProvider);
      final openingScope = _scopeKey();
      final generation = appState.sessionGeneration;
      final date = appState.activeBusinessDate;
      final shift = appState.activeShift;
      final workContext = appState.activeWorkContext;
      if (shift == null || workContext == null) {
        _showError('Vui lòng chọn ca và tổ trước khi thu hồi.');
        return;
      }
      final assignments = await _loadWorkerTargets(
        appState,
        worker,
        date: date,
        shiftId: shift.shiftId,
        workContext: workContext,
        openingScope: openingScope,
      );
      if (assignments == null ||
          !mounted ||
          openingScope != _scopeKey() ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final lines = planRecallAll(assignments);
      if (lines.isEmpty) {
        _showError(
          'Nhân viên không còn sản lượng chưa làm để thu hồi trong ca và tổ đang chọn.',
        );
        return;
      }
      // SAP resolves the shift by the operation's Work Center + ShiftID.
      final shiftWorkCenter = shift.workCenter.trim();
      for (final line in lines) {
        final lineWorkCenter = line.target.workCenter.trim();
        if (lineWorkCenter.isNotEmpty && lineWorkCenter != shiftWorkCenter) {
          _showError(
            'Ca đang chọn thuộc Xưởng $shiftWorkCenter, nhưng công đoạn '
            '${line.target.operation} thuộc Xưởng $lineWorkCenter. Hãy đổi '
            'Xưởng và ca làm việc trước khi thu hồi.',
          );
          return;
        }
      }
      final shiftError = validateShiftExecution(
        shift: shift,
        businessDate: DateTime.parse(_dateKey(date)),
        executedAt: DateTime.now(),
      );
      if (shiftError != null) {
        _showError(shiftError);
        return;
      }

      final confirmed = await showRecallAllConfirmDialog(
        context,
        workerName: _workerName(worker),
        workerCode: _workerCode(worker),
        lines: lines,
      );
      if (!mounted || !confirmed) return;
      if (openingScope != _scopeKey()) {
        _showError('Ca hoặc tổ đã thay đổi. Hãy chọn lại công nhân.');
        return;
      }

      final outcomes = await appState.runCriticalOperation(
        () => recallAllWithoutPassword(
          recallRepo: appState.recallRepo,
          lines: lines,
          reasonCode: RecallReason.notFinished.code,
          businessDate: _dateKey(date),
          shiftId: shift.shiftId,
          createdBy: appState.currentSession?.maNv ?? '',
          canContinue: () => appState.isSessionGenerationCurrent(generation),
        ),
      );
      if (!mounted) return;
      await _showRecallAllResult(worker, outcomes);
    } on FormatException catch (error) {
      if (mounted) _showError(error.message);
    } catch (error, stackTrace) {
      debugPrint('Thu hồi không mật khẩu từ tab Xác nhận thất bại: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        _showError(
          error is SapBusinessError
              ? 'Không tải được lịch sử từ SAP: ${friendlySapErrorMessage(error)}'
              : 'Chưa đối chiếu được số lượng với SAP. Kiểm tra kết nối rồi thử lại.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _isRecallingAll = false;
        });
        unawaited(_loadCachedWorkers());
      }
    }
  }

  String _recallLineQuantity(RecallAllLine line) =>
      '${formatQuantity(line.quantity, uom: line.target.uom)} ${line.target.uom}';

  /// One line per order: SAP may take some and refuse others, and the
  /// supervisor has to see which.
  Future<void> _showRecallAllResult(
    Map<String, dynamic> worker,
    List<RecallAllOutcome> outcomes,
  ) async {
    final saved = outcomes.where((outcome) => outcome.saved).length;
    final allSynced = outcomes.every((outcome) => outcome.synced);
    String detail(RecallAllOutcome outcome) {
      if (outcome.skipped) return 'Chưa gửi vì lệnh trước bị từ chối.';
      final error = outcome.error;
      if (error != null) return friendlySapErrorMessage(error);
      final receipt = outcome.receipt!;
      if (receipt.isRefused) {
        return receipt.message ?? 'SAP chưa chấp nhận thu hồi.';
      }
      return outcome.synced
          ? 'Đã thu hồi, SAP đã xác nhận.'
          : 'Đã lưu trên thiết bị; mở Đồng bộ để theo dõi.';
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        titlePadding: CaslaDialog.titlePadding,
        contentPadding: CaslaDialog.contentPadding,
        backgroundColor: CaslaColors.surface,
        surfaceTintColor: Colors.transparent,
        title: CaslaDialogHeader(
          child: Text(
            allSynced
                ? 'Đã thu hồi ${outcomes.length} lệnh'
                : 'Thu hồi được $saved/${outcomes.length} lệnh',
            style: TextStyle(
              fontSize: CaslaDialog.titleSize,
              fontWeight: FontWeight.w800,
              color: saved == outcomes.length
                  ? CaslaColors.primaryNavy
                  : CaslaColors.danger,
            ),
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _workerName(worker),
                style: const TextStyle(fontSize: 13, color: CaslaColors.muted),
              ),
              const SizedBox(height: 8),
              for (final outcome in outcomes)
                _RecallAllRow(
                  label: recallAllLineLabel(outcome.line, [
                    for (final other in outcomes) other.line,
                  ]),
                  detail: detail(outcome),
                  trailing: _recallLineQuantity(outcome.line),
                  failed: !outcome.saved,
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: CaslaColors.primaryNavy,
              foregroundColor: Colors.white,
            ).merge(CaslaDialog.actionStyle),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Đã hiểu'),
          ),
        ],
      ),
    );
  }

  String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  bool _historyWorkerMatchesScope(
    WorkHistorySummary worker,
    UserWorkContext? context,
  ) {
    if (context == null) return true;
    final expectedWorkId = context.workId.trim();
    final workerWorkId = worker.workId.trim();
    // When SAP gives us a scoped WorkID, enforce it again on-device so a
    // stale or unexpectedly broad response cannot leak another department.
    if (expectedWorkId.isNotEmpty &&
        workerWorkId.toUpperCase() != expectedWorkId.toUpperCase()) {
      return false;
    }
    final expectedDepartment = context.boPhan.trim();
    final workerDepartment = worker.boPhan.trim();
    if (expectedDepartment.isNotEmpty &&
        workerDepartment.isNotEmpty &&
        !vietnameseLabelsEqual(expectedDepartment, workerDepartment)) {
      return false;
    }
    return true;
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _errorMessage = message);
  }

  void _dismissError() {
    if (!mounted || _errorMessage == null) return;
    setState(() => _errorMessage = null);
  }

  String _workerName(Map<String, dynamic> worker) =>
      worker['ten']?.toString().trim().isNotEmpty == true
      ? worker['ten'].toString().trim()
      : 'Công nhân';

  String _workerCode(Map<String, dynamic> worker) =>
      worker['ma_nv']?.toString().trim() ?? '';

  Map<String, String> _buildWorkContextLabels(
    List<UserWorkContext> contexts,
    List<Map<String, dynamic>> localTeams,
  ) {
    final labels = <String, String>{};

    void addLabel(Iterable<String> keys, String label) {
      final normalized = label.trim();
      if (normalized.isEmpty) return;
      for (final key in keys) {
        final value = key.trim().toUpperCase();
        if (value.isNotEmpty) labels[value] ??= normalized;
      }
    }

    // The session work contexts are the SAP-backed cache loaded during login.
    // Prefer the human-readable work name and location over the compact
    // department code stored on an employee.
    for (final context in contexts) {
      final workId = context.workId.trim();
      final name = context.workName.trim().isNotEmpty
          ? context.workName.trim()
          : context.boPhan.trim();
      final location = context.location.trim();
      final label = name.isEmpty
          ? workId
          : (location.isEmpty ? name : '$name ($location)');
      addLabel([workId, context.workName, context.workCenter], label);
    }

    // Keep locally cached team aliases working for older sessions whose
    // serialized workContexts do not contain display metadata yet.
    for (final team in localTeams) {
      final label = team['ten_to']?.toString().trim().isNotEmpty == true
          ? team['ten_to'].toString().trim()
          : team['bo_phan']?.toString().trim() ?? '';
      addLabel([
        team['id']?.toString() ?? '',
        team['ma_to']?.toString() ?? '',
      ], label);
    }
    return labels;
  }

  String _workerDepartment(Map<String, dynamic> worker) {
    final rawTeamIds = worker['to_ids'];
    final teamIds = rawTeamIds is List
        ? rawTeamIds.map((value) => value.toString())
        : <String>[];
    if (teamIds.isEmpty) return '';
    final workerContextIds = [
      ...teamIds,
      worker['to_id']?.toString() ?? '',
      worker['team_id']?.toString() ?? '',
      worker['work_id']?.toString() ?? '',
      worker['work_context_id']?.toString() ?? '',
    ].map((value) => value.trim()).where((value) => value.isNotEmpty).toList();
    for (final teamId in workerContextIds) {
      final mapped = _cachedWorkContextLabels[teamId.trim().toUpperCase()];
      if (mapped?.isNotEmpty == true) return mapped!;
    }

    // Keep the stable SAP scope id visible when cached work-context metadata
    // is missing. Do not replace it with the compact department code below.
    if (workerContextIds.isNotEmpty) return workerContextIds.first;
    return '';
  }

  String _workerInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) {
      final value = parts.first;
      return value
          .substring(0, value.length > 2 ? 2 : value.length)
          .toUpperCase();
    }
    return '${parts.first.substring(0, 1)}${parts.last.substring(0, 1)}'
        .toUpperCase();
  }

  bool _sameWorker(Map<String, dynamic>? left, Map<String, dynamic> right) {
    if (left == null) return false;
    final leftId = left['id']?.toString() ?? left['ma_nv']?.toString();
    final rightId = right['id']?.toString() ?? right['ma_nv']?.toString();
    return leftId == rightId;
  }

  List<Map<String, dynamic>> get _visibleWorkers {
    final query = _workerQuery.trim().toLowerCase();
    if (query.isEmpty) return _cachedWorkers;
    return _cachedWorkers.where((worker) {
      final haystack = [
        _workerName(worker),
        _workerCode(worker),
        _workerDepartment(worker),
      ].join(' ').toLowerCase();
      return haystack.contains(query);
    }).toList();
  }

  Future<void> _continueWithSelectedWorker() async {
    final worker = _selectedWorker;
    if (worker == null || _isProcessing) return;
    setState(() => _isProcessing = true);
    try {
      await _openWorker(worker);
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Widget _buildWorkerSelection(BuildContext context) {
    final workers = _visibleWorkers;
    return Material(
      color: CaslaColors.background,
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
              color: CaslaColors.primaryNavy,
              child: const Row(
                children: [
                  Expanded(
                    child: Text(
                      'Xác nhận sản lượng',
                      style: TextStyle(
                        color: Colors.white,
                        fontFamily: 'Manrope',
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  AccountAvatarButton(),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, _) {
                          // The list takes the remaining card height. The
                          // action buttons stay in the card footer and never
                          // get pushed below the viewport.
                          return Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: CaslaColors.surface,
                              border: Border.all(color: CaslaColors.line),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextField(
                                  controller: _workerSearchController,
                                  onChanged: (value) =>
                                      setState(() => _workerQuery = value),
                                  decoration: InputDecoration(
                                    prefixIcon: const Icon(Icons.search),
                                    suffixIcon: IconButton(
                                      key: const ValueKey('scan-worker-qr'),
                                      tooltip: 'Quét QR nhân viên',
                                      onPressed: _isProcessing
                                          ? null
                                          : () => setState(() {
                                              _showScanner = true;
                                              _errorMessage = null;
                                            }),
                                      icon: const Icon(Icons.qr_code_scanner),
                                      color: CaslaColors.primaryNavy,
                                    ),
                                    hintText: 'Tìm theo tên hoặc mã nhân viên',
                                    isDense: true,
                                    filled: true,
                                    fillColor: CaslaColors.background,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(11),
                                      borderSide: const BorderSide(
                                        color: CaslaColors.line,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Expanded(
                                  child: _isLoadingWorkers
                                      ? const Center(
                                          child: CircularProgressIndicator(),
                                        )
                                      : workers.isEmpty
                                      ? const Center(
                                          child: Text(
                                            'Chưa có nhân viên được phân công trong ngày/ca đang chọn.',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: CaslaColors.muted,
                                            ),
                                          ),
                                        )
                                      : Scrollbar(
                                          controller: _workerListScroll,
                                          thumbVisibility: workers.length > 4,
                                          child: ListView.separated(
                                            controller: _workerListScroll,
                                            padding: const EdgeInsets.only(
                                              top: 6,
                                              right: 8,
                                              bottom: 8,
                                            ),
                                            physics:
                                                const ClampingScrollPhysics(),
                                            itemCount: workers.length,
                                            separatorBuilder: (_, _) =>
                                                const Divider(height: 1),
                                            itemBuilder: (context, index) {
                                              final worker = workers[index];
                                              final selected = _sameWorker(
                                                _selectedWorker,
                                                worker,
                                              );
                                              return InkWell(
                                                onTap: () => setState(
                                                  () =>
                                                      _selectedWorker = worker,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                child: Container(
                                                  constraints:
                                                      const BoxConstraints(
                                                        minHeight: 56,
                                                      ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 8,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: selected
                                                        ? CaslaColors.navy100
                                                        : Colors.transparent,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      CircleAvatar(
                                                        radius: 19,
                                                        backgroundColor:
                                                            CaslaColors.navy100,
                                                        child: Text(
                                                          _workerInitials(
                                                            _workerName(worker),
                                                          ),
                                                          style: const TextStyle(
                                                            color: CaslaColors
                                                                .primaryNavy,
                                                            fontWeight:
                                                                FontWeight.w800,
                                                            fontSize: 12,
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 10),
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Text(
                                                              _workerName(
                                                                worker,
                                                              ),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: const TextStyle(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w800,
                                                                color: CaslaColors
                                                                    .primaryNavy,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              height: 2,
                                                            ),
                                                            Text(
                                                              [
                                                                    _workerCode(
                                                                      worker,
                                                                    ),
                                                                    if (_workerDepartment(
                                                                      worker,
                                                                    ).isNotEmpty)
                                                                      'Tổ: ${_workerDepartment(worker)}',
                                                                  ]
                                                                  .where(
                                                                    (
                                                                      value,
                                                                    ) => value
                                                                        .isNotEmpty,
                                                                  )
                                                                  .join(' · '),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: const TextStyle(
                                                                fontFamily:
                                                                    'monospace',
                                                                fontSize: 10,
                                                                color:
                                                                    CaslaColors
                                                                        .muted,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Semantics(
                                                        label: selected
                                                            ? 'Đã chọn ${_workerName(worker)}'
                                                            : 'Chọn ${_workerName(worker)}',
                                                        selected: selected,
                                                        child: Icon(
                                                          selected
                                                              ? Icons
                                                                    .check_circle
                                                              : Icons
                                                                    .radio_button_unchecked,
                                                          color: selected
                                                              ? CaslaColors
                                                                    .primaryNavy
                                                              : CaslaColors
                                                                    .line,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                ),
                                const SizedBox(height: 12),
                                if (_canConfirmDirectly) ...[
                                  SizedBox(
                                    width: double.infinity,
                                    height: 48,
                                    child: OutlinedButton.icon(
                                      key: const ValueKey(
                                        'confirm-direct-button',
                                      ),
                                      onPressed:
                                          _isProcessing || _isOpeningWorker
                                          ? null
                                          : _openDirectConfirmation,
                                      icon: const Icon(Icons.bolt_outlined),
                                      label: const Text(
                                        'Xác nhận sản lượng không dải chuyền',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                ],
                                if (_canRecallWithoutPassword) ...[
                                  SizedBox(
                                    width: double.infinity,
                                    height: 48,
                                    child: OutlinedButton.icon(
                                      key: const ValueKey(
                                        'recall-all-without-password',
                                      ),
                                      onPressed:
                                          _selectedWorker == null ||
                                              _isProcessing ||
                                              _isOpeningWorker
                                          ? null
                                          : _recallAllWithoutPassword,
                                      icon: _isRecallingAll
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                semanticsLabel: 'Đang thu hồi',
                                              ),
                                            )
                                          : const Icon(Icons.undo),
                                      label: const Text(
                                        'Thu hồi không mật khẩu',
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: CaslaColors.danger,
                                        side: BorderSide(
                                          color:
                                              _selectedWorker == null ||
                                                  _isProcessing ||
                                                  _isOpeningWorker
                                              ? CaslaColors.line
                                              : CaslaColors.danger,
                                          width: 1.5,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                ],
                                SizedBox(
                                  width: double.infinity,
                                  height: 50,
                                  child: ElevatedButton(
                                    onPressed:
                                        _selectedWorker == null ||
                                            _isProcessing ||
                                            _isOpeningWorker
                                        ? null
                                        : _continueWithSelectedWorker,
                                    child: _isOpeningWorker
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              semanticsLabel:
                                                  'Đang đối chiếu số lượng',
                                            ),
                                          )
                                        : const Text('Tiếp tục xác nhận'),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    if (_errorMessage case final message?) ...[
                      const SizedBox(height: 12),
                      _ScanErrorCard(
                        message: message,
                        onDismiss: _dismissError,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanner(BuildContext context) {
    // The scanner is a state of this tab, not a route: without this the
    // system Back button leaves the app instead of closing the scanner.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _isProcessing) return;
        setState(() => _showScanner = false);
      },
      child: Stack(
        children: [
          AdaptiveBarcodeScannerView(
            title: 'Quét QR nhân viên',
            subtitle: 'Quét mã để mở thẳng màn hình xác nhận sản lượng.',
            onScan: _handleWorkerCodeScanned,
            onManualInput: _showCachedWorkerPicker,
            manualInputLabel: 'Chọn nhân viên đã lưu',
            manualInputIcon: Icons.people_alt_outlined,
          ),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            left: 10,
            child: Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(24),
              child: IconButton(
                tooltip: 'Quay lại danh sách nhân viên',
                onPressed: () => setState(() => _showScanner = false),
                icon: const Icon(Icons.arrow_back, color: Colors.white),
              ),
            ),
          ),
          if (_isProcessing) const _ProcessingOverlay(),
        ],
      ),
    );
  }

  Future<void> _showCachedWorkerPicker() async {
    await _loadCachedWorkers();
    if (!mounted) return;
    final workers = _cachedWorkers;
    final worker = await showSearchablePicker(
      context,
      title: 'Chọn nhân viên xác nhận',
      searchHint: 'Tìm theo tên nhân viên',
      emptyMessage:
          'Chưa có nhân viên trong cache trên máy. Hãy đồng bộ danh sách hoặc quét thẻ nhân viên trước.',
      items: workers,
      itemTitle: (item) => item['ten']?.toString() ?? 'Công nhân',
      itemSubtitle: (item) => [
        item['ma_nv']?.toString() ?? '',
        _workerDepartment(item),
      ].where((value) => value.trim().isNotEmpty).join(' · '),
      searchableText: (item) => [
        item['ten']?.toString() ?? '',
        item['ma_nv']?.toString() ?? '',
        _workerDepartment(item),
      ].where((value) => value.trim().isNotEmpty).join(' '),
    );
    if (!mounted || worker == null) return;
    setState(() => _errorMessage = null);
    await _openWorker(worker);
  }

  @override
  Widget build(BuildContext context) {
    if (_showScanner) return _buildScanner(context);
    return BarcodeScanListener(
      onScan: _handleWorkerCodeScanned,
      child: _buildWorkerSelection(context),
    );
  }
}

class _ScanErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _ScanErrorCard({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Lỗi quét mã. $message',
      child: Material(
        color: CaslaColors.dangerBg,
        elevation: 6,
        borderRadius: BorderRadius.circular(CaslaRadius.md),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            CaslaSpacing.sm,
            CaslaSpacing.sm,
            CaslaSpacing.xxs,
            CaslaSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: CaslaColors.danger,
                size: 24,
              ),
              const SizedBox(width: CaslaSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Chưa thể mở công nhân',
                      style: TextStyle(
                        color: CaslaColors.danger,
                        fontWeight: FontWeight.w800,
                        fontSize: CaslaType.body,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      message,
                      style: const TextStyle(
                        color: CaslaColors.primaryNavy,
                        fontSize: CaslaType.caption,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Đóng thông báo',
                onPressed: onDismiss,
                icon: const Icon(
                  Icons.close,
                  size: 20,
                  color: CaslaColors.primaryNavy,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProcessingOverlay extends StatelessWidget {
  const _ProcessingOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: IgnorePointer(
          child: Center(
            child: Semantics(
              liveRegion: true,
              label: 'Đang kiểm tra mã công nhân',
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: CaslaSpacing.xl),
                padding: const EdgeInsets.symmetric(
                  horizontal: CaslaSpacing.lg,
                  vertical: CaslaSpacing.lg,
                ),
                decoration: BoxDecoration(
                  color: CaslaColors.navy900,
                  borderRadius: BorderRadius.circular(CaslaRadius.lg),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.6,
                        color: CaslaColors.accentGold,
                      ),
                    ),
                    SizedBox(width: CaslaSpacing.sm),
                    Flexible(
                      child: Text(
                        'Đang kiểm tra mã công nhân...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: CaslaType.body,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One order/operation in the recall-all question and in its result.
class _RecallAllRow extends StatelessWidget {
  final String label;
  final String detail;
  final String trailing;
  final bool failed;

  const _RecallAllRow({
    required this.label,
    required this.detail,
    required this.trailing,
    this.failed = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = failed ? CaslaColors.danger : CaslaColors.primaryNavy;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: failed ? CaslaColors.danger : CaslaColors.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            trailing,
            style: TextStyle(
              fontSize: CaslaDialog.figureSize,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
