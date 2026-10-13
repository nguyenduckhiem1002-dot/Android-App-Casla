// Screen S10 — Scan Worker QR & Confirm Production Screen
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../data/sap/odata_error.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';
import '../../../core/auth/session_manager.dart';
import '../../../core/utils/vietnamese_text_normalizer.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/work_history.dart';
import '../../../domain/policies/grouped_confirmation.dart';
import '../../../domain/policies/local_history_overlay.dart';
import '../../../presentation/widgets/account_avatar_button.dart';
import '../../../presentation/widgets/confirmation_target_picker.dart';
import '../../../data/repositories/confirmation_targets.dart';
import '../../../main.dart';
import '../../../presentation/widgets/adaptive_barcode_scanner_view.dart';
import '../../../presentation/widgets/barcode_scan_listener.dart';
import '../../../presentation/widgets/searchable_picker_sheet.dart';
import '../../../presentation/widgets/worker_scan_acceptance.dart';

class S10ConfirmScanScreen extends ConsumerStatefulWidget {
  const S10ConfirmScanScreen({super.key});

  @override
  ConsumerState<S10ConfirmScanScreen> createState() =>
      _S10ConfirmScanScreenState();
}

class _S10ConfirmScanScreenState extends ConsumerState<S10ConfirmScanScreen> {
  bool _isProcessing = false;
  bool _isOpeningWorker = false;
  String? _errorMessage;
  bool _isLoadingWorkers = true;
  bool _showScanner = false;
  String _workerQuery = '';
  List<Map<String, dynamic>> _cachedWorkers = const [];
  Map<String, dynamic>? _selectedWorker;
  Map<String, String> _cachedWorkContextLabels = const {};
  late final TextEditingController _workerSearchController;
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
        _showError('Vui lòng chọn ca và bộ phận trước khi xác nhận.');
        return;
      }
      final history = await loadConfirmationHistory(
        appState.workHistoryRepo,
        range: HistoryRange.day,
        dateFrom: date,
        dateTo: date,
        shiftId: shiftId,
        workId: workContext.workId,
      );
      if (!mounted || openingScope != _scopeKey()) return;
      final assignments = await resolveConfirmationTargets(
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
      if (!mounted ||
          openingScope != _scopeKey() ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }

      if (!assignments.any((assignment) => assignment.canRecord)) {
        _showError(
          'Nhân viên không còn sản lượng cần xác nhận trong ca và bộ phận đang chọn.',
        );
        return;
      }

      // Several operations open: tick the ones to confirm together instead of
      // picking a single one.
      final openGroups = groupConfirmationTargets(
        assignments,
      ).where((group) => group.any((target) => target.canRecord)).toList();
      if (openGroups.length > 1) {
        await context.push(
          '/supervisor/confirm_multi',
          extra: <String, dynamic>{'worker': worker, 'groups': openGroups},
        );
        return;
      }

      final group = await pickConfirmationGroup(context, assignments);
      if (!mounted || openingScope != _scopeKey()) return;
      if (group != null) {
        await context.push(
          '/supervisor/assignment_detail',
          extra: <String, dynamic>{
            'assignment': group.first,
            'group': group,
            'openConfirmation': true,
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
    final selectedName = _selectedWorker == null
        ? ''
        : _workerName(_selectedWorker!);
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Chọn nhân viên từ thiết bị',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: CaslaColors.primaryNavy,
                          ),
                        ),
                        Text(
                          '${_cachedWorkers.length} nhân viên trong ca',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: CaslaColors.muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
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
                                const Text(
                                  'Nhân viên xác nhận',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                    color: CaslaColors.primaryNavy,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: CaslaColors.successBg,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: CaslaColors.success.withValues(
                                        alpha: 0.2,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text(
                                        '✓ Đã sẵn sàng trên thiết bị',
                                        style: TextStyle(
                                          color: CaslaColors.success,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      Text(
                                        '${_cachedWorkers.length} NV',
                                        style: const TextStyle(
                                          color: CaslaColors.success,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _workerSearchController,
                                  onChanged: (value) =>
                                      setState(() => _workerQuery = value),
                                  decoration: InputDecoration(
                                    prefixIcon: const Icon(Icons.search),
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
                                          thumbVisibility: workers.length > 4,
                                          child: ListView.separated(
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
                                                                      'Bộ phận: ${_workerDepartment(worker)}',
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
                                SizedBox(
                                  width: double.infinity,
                                  height: 48,
                                  child: OutlinedButton.icon(
                                    onPressed: _isProcessing
                                        ? null
                                        : () => setState(() {
                                            _showScanner = true;
                                            _errorMessage = null;
                                          }),
                                    icon: const Icon(Icons.qr_code_scanner),
                                    label: const Text('Quét QR nhân viên'),
                                  ),
                                ),
                                const SizedBox(height: 10),
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
                                        : Text(
                                            selectedName.isEmpty
                                                ? 'Tiếp tục xác nhận'
                                                : 'Tiếp tục xác nhận · $selectedName',
                                          ),
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
    return Stack(
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
