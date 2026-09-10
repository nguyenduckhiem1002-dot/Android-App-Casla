import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../core/auth/session_manager.dart';
import '../../../data/sap/sap_shift_controller.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../domain/entities/work_history.dart';
import '../../../domain/policies/history_work_context.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../main.dart';
import '../../../presentation/widgets/status_chip.dart';
import '../../../presentation/widgets/active_shift_context_card.dart';
import '../../../presentation/widgets/casla_empty_state.dart';
import '../../../presentation/widgets/casla_skeleton.dart';

class _WorkerOverviewData {
  final String id;
  final String code;
  final String name;
  final String department;
  final double assignedQty;
  final double completedQty;
  final double remainingQty;
  final String uom;
  final List<WorkHistoryEntry> sapEntries;
  final List<Assignment> localAssignments;

  const _WorkerOverviewData({
    required this.id,
    required this.code,
    required this.name,
    required this.department,
    required this.assignedQty,
    required this.completedQty,
    required this.remainingQty,
    required this.uom,
    this.sapEntries = const [],
    this.localAssignments = const [],
  });

  double get completionRate =>
      assignedQty > 0 ? (completedQty / assignedQty).clamp(0.0, 1.0) : 0.0;
}

class _TeamFilterOption {
  final String id;
  final String name;
  final String detail;
  final Set<String> scopeIds;

  const _TeamFilterOption({
    required this.id,
    required this.name,
    required this.detail,
    required this.scopeIds,
  });
}

class S06SupervisorOverviewScreen extends ConsumerStatefulWidget {
  const S06SupervisorOverviewScreen({super.key});

  @override
  ConsumerState<S06SupervisorOverviewScreen> createState() =>
      _S06SupervisorOverviewScreenState();
}

class _S06SupervisorOverviewScreenState
    extends ConsumerState<S06SupervisorOverviewScreen> {
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _employeeScopeKey = '';
  Future<List<Map<String, dynamic>>>? _employeesFuture;
  late Stream<WorkHistoryResult> _historyStream;
  late Stream<List<Assignment>> _assignmentStream;
  String _historyContextKey = '';
  String? _historyShiftId;
  String _historyShiftLabel = 'Tất cả ca';
  Future<List<SapShift>>? _historyShiftsFuture;
  String _historyShiftsKey = '';
  bool _historyDataReady = false;
  WorkHistoryResult? _lastHistoryResult;

  @override
  void initState() {
    super.initState();
    final appState = ref.read(appStateProvider);
    _historyContextKey = _currentHistoryContextKey(appState);
    _replaceHistoryStream();
  }

  String _currentHistoryContextKey(AppState appState) =>
      appState.activeWorkContext?.workId ?? '';

  Stream<WorkHistoryResult> _watchHistory() {
    return ref
        .read(appStateProvider)
        .workHistoryRepo
        .watchWorkHistory(
          range: _historyRange,
          // Supervisor filters are calendar windows. Sending both dates makes
          // the gateway use RAP RangeCode C, so "Tuần này" and "Tháng này"
          // match what the chips display instead of SAP's rolling windows.
          dateFrom: _rangeFrom,
          dateTo: _rangeTo,
          shiftId: _historyShiftId,
        )
        .asyncMap(_ensureHistoryEmployees);
  }

  Future<WorkHistoryResult> _fetchHistory({bool forceRefresh = false}) async {
    final result = await ref
        .read(appStateProvider)
        .workHistoryRepo
        .getWorkHistory(
          range: _historyRange,
          dateFrom: _rangeFrom,
          dateTo: _rangeTo,
          shiftId: _historyShiftId,
          forceRefresh: forceRefresh,
        );
    return _ensureHistoryEmployees(result);
  }

  Future<WorkHistoryResult> _ensureHistoryEmployees(
    WorkHistoryResult result,
  ) async {
    for (final worker in result.workers) {
      await ref
          .read(appStateProvider)
          .db
          .ensureEmployeeExists(
            id: worker.workerId,
            maNv: worker.workerId,
            name: worker.workerName.isNotEmpty
                ? worker.workerName
                : worker.workerId,
          );
    }
    return result;
  }

  void _replaceHistoryStream() {
    _historyDataReady = false;
    _lastHistoryResult = null;
    _historyStream = _watchHistory();
    final appState = ref.read(appStateProvider);
    _assignmentStream = appState.assignmentRepo.watchAssignmentsByTeams(
      appState.currentSession?.toIds ?? const <String>[],
      fromBusinessDate: DateFormat('yyyy-MM-dd').format(_rangeFrom),
      toBusinessDate: DateFormat('yyyy-MM-dd').format(_rangeTo),
      shiftId: _historyShiftId,
    );
  }

  Future<void> _refresh() async {
    try {
      await _fetchHistory(forceRefresh: true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // Filter States
  String _selectedTeamId = 'ALL';
  String _selectedTeamLabel = 'Tất cả tổ';
  Set<String>? _selectedTeamScopeIds;

  DateTime _selectedDate = DateTime.now();
  HistoryRange _historyRange = HistoryRange.day;
  DateTime? _customDateFrom;
  DateTime? _customDateTo;

  String _formatDisplayDate(DateTime d) {
    final today = DateTime.now();
    if (d.year == today.year && d.month == today.month && d.day == today.day) {
      return 'Hôm nay';
    }
    final yesterday = today.subtract(const Duration(days: 1));
    if (d.year == yesterday.year &&
        d.month == yesterday.month &&
        d.day == yesterday.day) {
      return 'Hôm qua';
    }
    return DateFormat('dd/MM/yyyy').format(d);
  }

  DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  DateTime get _rangeFrom {
    final today = _dateOnly(DateTime.now());
    DateTime notAfterToday(DateTime value) =>
        value.isAfter(today) ? today : value;
    switch (_historyRange) {
      case HistoryRange.day:
        return notAfterToday(_dateOnly(_selectedDate));
      case HistoryRange.week:
        final anchor = _dateOnly(DateTime.now());
        return anchor.subtract(Duration(days: anchor.weekday - 1));
      case HistoryRange.month:
        final now = DateTime.now();
        return DateTime(now.year, now.month, 1);
      case HistoryRange.custom:
        return notAfterToday(_customDateFrom ?? _dateOnly(_selectedDate));
    }
  }

  DateTime get _rangeTo {
    final today = _dateOnly(DateTime.now());
    DateTime notAfterToday(DateTime value) =>
        value.isAfter(today) ? today : value;
    switch (_historyRange) {
      case HistoryRange.day:
        return notAfterToday(_rangeFrom);
      case HistoryRange.week:
        return notAfterToday(_rangeFrom.add(const Duration(days: 6)));
      case HistoryRange.month:
        return notAfterToday(
          DateTime(_rangeFrom.year, _rangeFrom.month + 1, 0),
        );
      case HistoryRange.custom:
        return notAfterToday(_customDateTo ?? _rangeFrom);
    }
  }

  String get _rangeLabel {
    final format = DateFormat('dd/MM/yyyy');
    final shortFormat = DateFormat('dd/MM');
    switch (_historyRange) {
      case HistoryRange.day:
        final formatted = format.format(_selectedDate);
        final display = _formatDisplayDate(_selectedDate);
        return display == formatted ? formatted : '$display ($formatted)';
      case HistoryRange.week:
        return 'Tuần này (${shortFormat.format(_rangeFrom)} - ${shortFormat.format(_rangeTo)})';
      case HistoryRange.month:
        return 'Tháng này (${shortFormat.format(_rangeFrom)} - ${shortFormat.format(_rangeTo)})';
      case HistoryRange.custom:
        final from = _customDateFrom ?? _selectedDate;
        final to = _customDateTo ?? from;
        return from.year == to.year &&
                from.month == to.month &&
                from.day == to.day
            ? format.format(from)
            : '${format.format(from)} - ${format.format(to)}';
    }
  }

  String get _customRangeChipLabel {
    if (_historyRange == HistoryRange.custom &&
        _customDateFrom != null &&
        _customDateTo != null) {
      final format = DateFormat('dd/MM');
      if (_customDateFrom!.isAtSameMomentAs(_customDateTo!)) {
        return '${format.format(_customDateFrom!)} ▾';
      }
      return '${format.format(_customDateFrom!)} - ${format.format(_customDateTo!)} ▾';
    }
    return 'Khoảng ngày ▾';
  }

  Future<List<Map<String, dynamic>>> _employeesFor(List<String> teamIds) {
    final sortedIds = [...teamIds]..sort();
    final scopeKey = sortedIds.join('|');
    if (_employeesFuture == null || _employeeScopeKey != scopeKey) {
      _employeeScopeKey = scopeKey;
      _employeesFuture = ref
          .read(appStateProvider)
          .db
          .getEmployeesByTeamIds(teamIds);
    }
    return _employeesFuture!;
  }

  List<_TeamFilterOption> _sessionTeamOptions(UserSession? session) {
    if (session == null) return const [];

    final byId = <String, _TeamFilterOption>{};
    for (final workContext in session.workContexts) {
      final id = workContext.workId.trim();
      if (id.isEmpty) continue;
      byId.putIfAbsent(
        id,
        () => _TeamFilterOption(
          id: id,
          name: workContext.workName.trim().isNotEmpty
              ? workContext.workName.trim()
              : id,
          detail: [
            id,
            if (workContext.plant.trim().isNotEmpty) workContext.plant.trim(),
            if (workContext.workCenter.trim().isNotEmpty)
              workContext.workCenter.trim(),
          ].join(' · '),
          scopeIds: {id},
        ),
      );
    }
    if (byId.isNotEmpty) return byId.values.toList(growable: false);

    // Sessions created before `workContexts` was added still retain `toIds`.
    // Keep them usable, but never invent a name when SAP did not send one.
    for (final id in session.toIds) {
      final normalizedId = id.trim();
      if (normalizedId.isEmpty) continue;
      byId.putIfAbsent(
        normalizedId,
        () => _TeamFilterOption(
          id: normalizedId,
          name: session.toIds.length == 1 && session.teamName.trim().isNotEmpty
              ? session.teamName.trim()
              : normalizedId,
          detail: normalizedId,
          scopeIds: {normalizedId},
        ),
      );
    }
    return byId.values.toList(growable: false);
  }

  String _allTeamsLabel(UserSession? session) {
    final count = _sessionTeamOptions(session).length;
    return count > 1 ? 'Tất cả tổ ($count)' : 'Tất cả tổ';
  }

  String _scopeSummary(UserSession? session) {
    final names = _sessionTeamOptions(
      session,
    ).map((option) => option.name).toList(growable: false);
    if (names.isEmpty) return 'Chưa có phạm vi tổ từ SAP';
    return names.join(' · ');
  }

  Future<List<_TeamFilterOption>> _loadTeamFilterOptions() async {
    final appState = ref.read(appStateProvider);
    final session = appState.currentSession;
    final contextOptions = _sessionTeamOptions(session);
    final localTeams = await appState.db.getTeamsForScope(
      session?.toIds ?? const <String>[],
    );

    final options = <_TeamFilterOption>[];
    for (final contextOption in contextOptions) {
      final scopeIds = <String>{...contextOption.scopeIds};
      for (final team in localTeams) {
        final localId = team['id']?.toString().trim() ?? '';
        final sapCode = team['ma_to']?.toString().trim() ?? '';
        if (contextOption.scopeIds.contains(localId) ||
            contextOption.scopeIds.contains(sapCode)) {
          if (localId.isNotEmpty) scopeIds.add(localId);
          if (sapCode.isNotEmpty) scopeIds.add(sapCode);
        }
      }
      options.add(
        _TeamFilterOption(
          id: contextOption.id,
          name: contextOption.name,
          detail: contextOption.detail,
          scopeIds: scopeIds,
        ),
      );
    }

    // A legacy session may have no WorkContext display data but can still have
    // a local team master row. That row is safe to show only when it is inside
    // the already-authorized `toIds` scope returned by SAP.
    if (options.isEmpty) {
      for (final team in localTeams) {
        final localId = team['id']?.toString().trim() ?? '';
        final sapCode = team['ma_to']?.toString().trim() ?? '';
        if (localId.isEmpty && sapCode.isEmpty) continue;
        options.add(
          _TeamFilterOption(
            id: localId.isNotEmpty ? localId : sapCode,
            name: team['ten_to']?.toString().trim().isNotEmpty == true
                ? team['ten_to'].toString().trim()
                : (sapCode.isNotEmpty ? sapCode : localId),
            detail: sapCode.isNotEmpty ? sapCode : localId,
            scopeIds: {
              if (localId.isNotEmpty) localId,
              if (sapCode.isNotEmpty) sapCode,
            },
          ),
        );
      }
    }
    return options;
  }

  Future<List<SapShift>> _loadHistoryShifts() {
    final appState = ref.read(appStateProvider);
    final plant = appState.activeWorkContext?.plant.trim() ?? '';
    final date = _rangeFrom;
    final key = '$plant|${DateFormat('yyyy-MM-dd').format(date)}';
    if (_historyShiftsFuture == null || _historyShiftsKey != key) {
      _historyShiftsKey = key;
      _historyShiftsFuture = plant.isEmpty
          ? Future<List<SapShift>>.value(const [])
          : appState.shiftController.getShifts(plant: plant, onDate: date);
    }
    return _historyShiftsFuture!;
  }

  // Kept as a compatibility path for callers from older routes.
  // ignore: unused_element
  Future<void> _showHistoryShiftSheet() async {
    List<SapShift> shifts;
    try {
      shifts = await _loadHistoryShifts();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Không tải được danh sách ca để tra cứu.'),
          backgroundColor: CaslaColors.danger,
        ),
      );
      return;
    }
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(10, 16, 10, 18),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: Text(
                'Lọc lịch sử theo ca',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: CaslaColors.primaryNavy,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.all_inclusive),
              title: const Text('Tất cả ca'),
              selected: _historyShiftId == null,
              trailing: _historyShiftId == null
                  ? const Icon(Icons.check)
                  : null,
              onTap: () {
                setState(() {
                  _historyShiftId = null;
                  _historyShiftLabel = 'Tất cả ca';
                  _replaceHistoryStream();
                });
                Navigator.pop(sheetContext);
              },
            ),
            for (final shift in shifts)
              ListTile(
                leading: const Icon(Icons.schedule_outlined),
                title: Text(
                  shift.shiftName.isEmpty ? shift.shiftId : shift.shiftName,
                ),
                subtitle: Text('${shift.shiftId} · ${shift.timeLabel}'),
                selected: _historyShiftId == shift.shiftId,
                trailing: _historyShiftId == shift.shiftId
                    ? const Icon(Icons.check)
                    : null,
                onTap: () {
                  setState(() {
                    _historyShiftId = shift.shiftId;
                    _historyShiftLabel = shift.shiftName.isEmpty
                        ? shift.shiftId
                        : shift.shiftName;
                    _replaceHistoryStream();
                  });
                  Navigator.pop(sheetContext);
                },
              ),
            if (shifts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Chưa có ca phù hợp với ngày làm việc đang chọn.',
                  style: TextStyle(color: CaslaColors.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Kept as a compatibility path for callers from older routes.
  // ignore: unused_element
  Future<void> _showTeamFilterSheet() async {
    final appState = ref.read(appStateProvider);
    final session = appState.currentSession;
    final teams = await _loadTeamFilterOptions();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.68,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 18, 18, 10),
                  child: Text(
                    'Lọc theo tổ sản xuất',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 18),
                    children: [
                      ListTile(
                        title: Text(_allTeamsLabel(session)),
                        subtitle: Text(
                          'Phạm vi SAP: ${_scopeSummary(session)}',
                        ),
                        selected: _selectedTeamId == 'ALL',
                        trailing: _selectedTeamId == 'ALL'
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () {
                          setState(() {
                            _selectedTeamId = 'ALL';
                            _selectedTeamLabel = _allTeamsLabel(session);
                            _selectedTeamScopeIds = null;
                          });
                          Navigator.pop(sheetContext);
                        },
                      ),
                      for (final team in teams)
                        ListTile(
                          title: Text(team.name),
                          subtitle: Text(team.detail),
                          selected: _selectedTeamId == team.id,
                          trailing: _selectedTeamId == team.id
                              ? const Icon(Icons.check)
                              : null,
                          onTap: () {
                            setState(() {
                              _selectedTeamId = team.id;
                              _selectedTeamLabel = team.name;
                              _selectedTeamScopeIds = team.scopeIds;
                            });
                            Navigator.pop(sheetContext);
                          },
                        ),
                      if (teams.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'SAP chưa trả về phạm vi tổ cho phiên này.',
                            style: TextStyle(
                              color: CaslaColors.muted,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Kept as a compatibility path for callers from older routes.
  // ignore: unused_element
  Future<void> _pickSingleDate() async {
    final now = DateTime.now();
    final today = _dateOnly(now);
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: today,
      helpText: 'CHỌN NGÀY',
      cancelText: 'HỦY',
      confirmText: 'CHỌN',
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

    setState(() {
      _historyRange = HistoryRange.day;
      _selectedDate = _dateOnly(picked);
      _replaceHistoryStream();
    });
  }

  // Kept as a compatibility path for callers from older routes.
  // ignore: unused_element
  Future<void> _showDaySelectionSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
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
              const SizedBox(height: 14),
              const Text(
                'Chọn ngày xem dữ liệu',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: CaslaColors.primaryNavy.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.today,
                    color: CaslaColors.primaryNavy,
                    size: 20,
                  ),
                ),
                title: const Text(
                  'Hôm nay',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                subtitle: Text(
                  DateFormat('dd/MM/yyyy').format(DateTime.now()),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing:
                    _historyRange == HistoryRange.day &&
                        _formatDisplayDate(_selectedDate) == 'Hôm nay'
                    ? const Icon(Icons.check, color: CaslaColors.primaryNavy)
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  setState(() {
                    _historyRange = HistoryRange.day;
                    _selectedDate = _dateOnly(DateTime.now());
                    _replaceHistoryStream();
                  });
                },
              ),
              ListTile(
                leading: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: CaslaColors.primaryNavy.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.history,
                    color: CaslaColors.primaryNavy,
                    size: 20,
                  ),
                ),
                title: const Text(
                  'Hôm qua',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                subtitle: Text(
                  DateFormat(
                    'dd/MM/yyyy',
                  ).format(DateTime.now().subtract(const Duration(days: 1))),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing:
                    _historyRange == HistoryRange.day &&
                        _formatDisplayDate(_selectedDate) == 'Hôm qua'
                    ? const Icon(Icons.check, color: CaslaColors.primaryNavy)
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  setState(() {
                    _historyRange = HistoryRange.day;
                    _selectedDate = _dateOnly(
                      DateTime.now().subtract(const Duration(days: 1)),
                    );
                    _replaceHistoryStream();
                  });
                },
              ),
              ListTile(
                leading: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: CaslaColors.accentGold.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.calendar_month,
                    color: CaslaColors.navy900,
                    size: 20,
                  ),
                ),
                title: const Text(
                  'Chọn ngày khác trên lịch...',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                subtitle: const Text(
                  'Mở lịch để chọn 1 ngày bất kỳ',
                  style: TextStyle(fontSize: 12),
                ),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: CaslaColors.muted,
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickSingleDate();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Kept as a compatibility path for callers from older routes.
  // ignore: unused_element
  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final today = _dateOnly(now);
    DateTime start = today.subtract(const Duration(days: 6));
    DateTime end = today;

    if (_customDateFrom != null && _customDateTo != null) {
      if (!_customDateFrom!.isAfter(_customDateTo!)) {
        start = _dateOnly(_customDateFrom!);
        end = _dateOnly(_customDateTo!);
      }
    }

    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: start, end: end),
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: today,
      helpText: 'CHỌN KHOẢNG NGÀY (NHIỀU NGÀY)',
      fieldStartLabelText: 'Từ ngày',
      fieldEndLabelText: 'Đến ngày',
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
      _historyRange = HistoryRange.custom;
      _customDateFrom = from;
      _customDateTo = to;
      _selectedDate = from;
      _replaceHistoryStream();
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final historyContextKey = _currentHistoryContextKey(appState);
    if (historyContextKey != _historyContextKey) {
      _historyContextKey = historyContextKey;
      _historyShiftId = null;
      _historyShiftLabel = 'Tất cả ca';
      _historyShiftsFuture = null;
      _historyShiftsKey = '';
      _replaceHistoryStream();
    }
    final emp = appState.currentSession;
    final supervisorName = emp?.userName ?? 'Supervisor';

    final effectiveTeamIds =
        _selectedTeamScopeIds?.toList(growable: false) ??
        (emp?.toIds ?? const <String>[]);
    final teamFilterLabel = _selectedTeamId == 'ALL'
        ? _allTeamsLabel(emp)
        : _selectedTeamLabel;

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(
          26 + MediaQuery.textScalerOf(context).scale(44),
        ),
        child: Container(
          color: CaslaColors.primaryNavy,
          padding: EdgeInsets.fromLTRB(
            18,
            MediaQuery.paddingOf(context).top + 12,
            18,
            12,
          ),
          child: _isSearching
              ? Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        autofocus: true,
                        style: const TextStyle(color: Colors.white),
                        onChanged: (val) {
                          setState(() {
                            _searchQuery = val.trim().toLowerCase();
                          });
                        },
                        decoration: const InputDecoration(
                          hintText: 'Tìm theo tên hoặc mã NV...',
                          hintStyle: TextStyle(color: Colors.white70),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          fillColor: Colors.transparent,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () {
                        setState(() {
                          _isSearching = false;
                          _searchQuery = '';
                          _searchController.clear();
                        });
                      },
                    ),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: const Color(0xFF26305C),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              supervisorName.isNotEmpty
                                  ? supervisorName
                                        .split(' ')
                                        .last[0]
                                        .toUpperCase()
                                  : 'B',
                              style: const TextStyle(
                                fontFamily: 'Manrope',
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  'Tổng quan',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'Manrope',
                                    fontWeight: FontWeight.w800,
                                    fontSize: 17,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$supervisorName · ${emp?.teamName.isNotEmpty == true ? emp!.teamName : 'Phạm vi được phân quyền'}',
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
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.qr_code_scanner,
                            color: Colors.white,
                          ),
                          tooltip: 'Quét thẻ/QR công nhân',
                          onPressed: () =>
                              context.push('/supervisor/confirm_scan'),
                        ),
                        IconButton(
                          icon: const Icon(Icons.search, color: Colors.white),
                          tooltip: 'Tìm kiếm nhân viên',
                          onPressed: () {
                            setState(() {
                              _isSearching = true;
                            });
                          },
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverToBoxAdapter(
            child:
                // FIXED TOP FILTER SECTION (always visible, never replaced by skeleton)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ActiveShiftContextCard(
                        workContext: appState.activeWorkContext,
                        shift: appState.activeShift,
                        businessDate: appState.activeBusinessDate,
                        compact: true,
                        onEdit: () =>
                            context.push('/supervisor-setup', extra: true),
                      ),
                      const SizedBox(height: 12),
                      _buildOverviewFilterBar(
                        teamLabel: teamFilterLabel,
                        onTap: _showOverviewFiltersSheet,
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
          ),
        ],
        body: RefreshIndicator(
          onRefresh: _refresh,
          child: StreamBuilder<WorkHistoryResult>(
            stream: _historyStream,
            builder: (context, historySnapshot) {
              // A refresh error is emitted after cached data by the
              // repository. StreamBuilder does not retain that data on the
              // error snapshot, so keep the last successful result locally.
              if (historySnapshot.hasData &&
                  historySnapshot.connectionState != ConnectionState.waiting) {
                _lastHistoryResult = historySnapshot.data;
                _historyDataReady = true;
              }
              final sapResult = _historyDataReady
                  ? historySnapshot.data ?? _lastHistoryResult
                  : null;

              return StreamBuilder<List<Assignment>>(
                stream: _assignmentStream,
                builder: (context, assignmentSnapshot) {
                  return FutureBuilder<List<Map<String, dynamic>>>(
                    future: _employeesFor(effectiveTeamIds),
                    builder: (context, empSnapshot) {
                      final isHistoryLoading =
                          historySnapshot.connectionState ==
                              ConnectionState.waiting &&
                          sapResult == null;
                      final isEmpLoading =
                          empSnapshot.connectionState ==
                              ConnectionState.waiting &&
                          !empSnapshot.hasData;

                      if (isHistoryLoading ||
                          isEmpLoading ||
                          assignmentSnapshot.connectionState ==
                              ConnectionState.waiting) {
                        return const _OverviewSkeleton();
                      }

                      if (historySnapshot.hasError && sapResult == null) {
                        return _OverviewHistoryError(onRetry: _refresh);
                      }

                      // Process SAP data
                      WorkHistoryResult? scopedResult = sapResult;
                      if (sapResult != null && _selectedTeamScopeIds != null) {
                        final selected = appState.currentSession?.workContexts
                            .where((c) => c.workId == _selectedTeamId)
                            .firstOrNull;
                        try {
                          scopedResult = historyForWorkContext(
                            sapResult,
                            plant: selected?.plant ?? '',
                            workCenter: selected?.workCenter ?? '',
                          );
                        } on FormatException catch (error) {
                          return ListView(
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  children: [
                                    Text(error.message),
                                    TextButton(
                                      onPressed: () => setState(() {
                                        _selectedTeamId = 'ALL';
                                        _selectedTeamScopeIds = null;
                                      }),
                                      child: const Text('Xem tất cả tổ'),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        }
                      }
                      final sapWorkers =
                          scopedResult?.workers ?? const <WorkHistorySummary>[];
                      final sapEntries =
                          scopedResult?.entries ?? const <WorkHistoryEntry>[];
                      final uoms = sapWorkers
                          .map((worker) => worker.unitOfMeasure.trim())
                          .where((unit) => unit.isNotEmpty)
                          .toSet();
                      final overviewUom = uoms.length == 1
                          ? uoms.single
                          : uoms.length > 1
                          ? 'nhiều ĐVT'
                          : null;

                      // Process Local data
                      final rawAssignments =
                          assignmentSnapshot.data ?? const <Assignment>[];
                      final localAssignments = rawAssignments.where((a) {
                        if (_selectedTeamScopeIds != null &&
                            !_selectedTeamScopeIds!.contains(a.teamId)) {
                          return false;
                        }
                        return true;
                      }).toList();

                      final byWorkerLocal = <String, List<Assignment>>{};
                      for (final a in localAssignments) {
                        (byWorkerLocal[a.workerId] ??= []).add(a);
                      }

                      final rawEmployees = empSnapshot.data ?? [];

                      // BUILD UNIFIED WORKER MAP
                      final workerMap = <String, _WorkerOverviewData>{};

                      // 1. Add from SAP workers
                      for (final sw in sapWorkers) {
                        final localEmp = rawEmployees
                            .cast<Map<String, dynamic>?>()
                            .firstWhere(
                              (e) =>
                                  e != null &&
                                  (e['ma_nv'] == sw.workerId ||
                                      e['id'] == sw.workerId),
                              orElse: () => null,
                            );

                        final matchingLocal =
                            byWorkerLocal[sw.workerId] ??
                            (localEmp != null
                                ? byWorkerLocal[localEmp['id']]
                                : null) ??
                            const <Assignment>[];

                        final matchingSapEntries = sapEntries
                            .where((e) => e.workerId == sw.workerId)
                            .toList();

                        workerMap[sw.workerId] = _WorkerOverviewData(
                          id: localEmp?['id'] as String? ?? sw.workerId,
                          code: sw.workerId,
                          name: sw.workerName.isNotEmpty
                              ? sw.workerName
                              : (localEmp?['ten'] ?? sw.workerId),
                          department:
                              localEmp?['bo_phan'] ?? 'Công nhân sản xuất',
                          assignedQty: sw.assignedQuantity,
                          completedQty: sw.completedQuantity,
                          remainingQty: sw.remainingQuantity,
                          uom: sw.unitOfMeasure.isNotEmpty
                              ? sw.unitOfMeasure
                              : 'ST',
                          sapEntries: matchingSapEntries,
                          localAssignments: matchingLocal,
                        );
                      }

                      // 2. Add local employees who may not be in SAP workers
                      for (final emp in rawEmployees) {
                        final empId = emp['id'] as String? ?? '';
                        final empCode = emp['ma_nv'] as String? ?? '';

                        if (workerMap.containsKey(empCode) ||
                            workerMap.containsKey(empId)) {
                          continue;
                        }

                        final matchingLocal =
                            byWorkerLocal[empId] ??
                            byWorkerLocal[empCode] ??
                            const <Assignment>[];

                        double workerAssigned = 0.0;
                        double completedQty = 0.0;
                        double recalledQty = 0.0;
                        for (final a in matchingLocal) {
                          workerAssigned += a.assignedQuantity;
                          completedQty += a.completedQuantity;
                          recalledQty += a.recalledQuantity;
                        }

                        final effectiveQty = workerAssigned - recalledQty;
                        final remainingQty = effectiveQty - completedQty;

                        workerMap[empCode.isNotEmpty
                            ? empCode
                            : empId] = _WorkerOverviewData(
                          id: empId,
                          code: empCode,
                          name: emp['ten'] ?? 'Nhân viên',
                          department: emp['bo_phan'] ?? 'Công nhân sản xuất',
                          assignedQty: effectiveQty,
                          completedQty: completedQty,
                          remainingQty: remainingQty,
                          uom: matchingLocal.isNotEmpty
                              ? matchingLocal.first.uom
                              : 'cái',
                          sapEntries: const [],
                          localAssignments: matchingLocal,
                        );
                      }

                      // Calculate KPIs
                      double totalEffective = 0.0;
                      double totalCompleted = 0.0;
                      int assignedWorkerCount = 0;
                      int openCount = 0;

                      for (final w in workerMap.values) {
                        totalEffective += w.assignedQty;
                        totalCompleted += w.completedQty;
                        if (w.assignedQty > 0) assignedWorkerCount++;
                        if (w.remainingQty > 0) openCount++;
                      }

                      // Filter workers by search query
                      final allWorkers = workerMap.values.toList();
                      final filteredWorkers = allWorkers.where((w) {
                        if (_searchQuery.isEmpty) return true;
                        return w.name.toLowerCase().contains(_searchQuery) ||
                            w.code.toLowerCase().contains(_searchQuery);
                      }).toList();

                      // Sort: workers with assignments first, then by name
                      filteredWorkers.sort((a, b) {
                        if (a.assignedQty > 0 && b.assignedQty == 0) {
                          return -1;
                        }
                        if (a.assignedQty == 0 && b.assignedQty > 0) {
                          return 1;
                        }
                        return a.name.compareTo(b.name);
                      });

                      return CustomScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildOverviewKpiPanel(
                                    totalEffective: totalEffective,
                                    totalCompleted: totalCompleted,
                                    assignedWorkerCount: assignedWorkerCount,
                                    openCount: openCount,
                                    uom: overviewUom,
                                  ),

                                  const SizedBox(height: 16),

                                  // Section Title Row (FIXED)
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          'Công nhân trong phạm vi · $_rangeLabel',
                                          style: const TextStyle(
                                            fontFamily: 'Manrope',
                                            fontWeight: FontWeight.w800,
                                            fontSize: 14,
                                            color: CaslaColors.primaryNavy,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '(${filteredWorkers.length} NV)',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: CaslaColors.muted,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                ],
                              ),
                            ),
                          ),

                          // INDEPENDENTLY SCROLLABLE SECTION: Worker Cards List
                          filteredWorkers.isEmpty
                              ? const SliverToBoxAdapter(
                                  child: CaslaEmptyState(
                                    icon: Icons.people_outline_rounded,
                                    title: 'Không có nhân viên phù hợp',
                                    message:
                                        'Không tìm thấy nhân viên nào phù hợp. Thử đổi ngày, tổ sản xuất hoặc từ khóa tìm kiếm.',
                                  ),
                                )
                              : SliverPadding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    0,
                                    18,
                                    80,
                                  ),
                                  sliver: SliverList.builder(
                                    itemCount: filteredWorkers.length,
                                    itemBuilder: (context, index) {
                                      final worker = filteredWorkers[index];
                                      final (status, statusLabel) =
                                          _workerStatusBadge(worker);

                                      return Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 10,
                                        ),
                                        child: Material(
                                          color: CaslaColors.surface,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          child: InkWell(
                                            onTap: () {
                                              context.push(
                                                '/supervisor/employee_detail',
                                                extra: {
                                                  'id': worker.id,
                                                  'ma_nv': worker.code,
                                                  'ten': worker.name,
                                                  'bo_phan': worker.department,
                                                  'sap_entries':
                                                      worker.sapEntries,
                                                  'assigned_qty':
                                                      worker.assignedQty,
                                                  'completed_qty':
                                                      worker.completedQty,
                                                  'remaining_qty':
                                                      worker.remainingQty,
                                                  'uom': worker.uom,
                                                  'date': _rangeFrom,
                                                  'date_from': _rangeFrom,
                                                  'date_to': _rangeTo,
                                                  'shift_id': _historyShiftId,
                                                  'work_context_id':
                                                      _selectedTeamId == 'ALL'
                                                      ? null
                                                      : _selectedTeamId,
                                                },
                                              );
                                            },
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            child: Container(
                                              padding: const EdgeInsets.all(14),
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                  color: CaslaColors.line,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Column(
                                                children: [
                                                  Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .spaceBetween,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Text(
                                                              worker.name,
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: const TextStyle(
                                                                fontFamily:
                                                                    'Manrope',
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700,
                                                                fontSize: 14.5,
                                                                color: CaslaColors
                                                                    .primaryNavy,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              height: 2,
                                                            ),
                                                            Text(
                                                              '${worker.code} · ${worker.department}',
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: const TextStyle(
                                                                fontFamily:
                                                                    'monospace',
                                                                fontSize: 11.5,
                                                                color:
                                                                    CaslaColors
                                                                        .muted,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      StatusChip(
                                                        status: status,
                                                        label: statusLabel,
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 12),

                                                  // Progress bar
                                                  ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                    child: LinearProgressIndicator(
                                                      value:
                                                          worker.completionRate,
                                                      minHeight: 7,
                                                      backgroundColor:
                                                          CaslaColors.muted100,
                                                      valueColor:
                                                          const AlwaysStoppedAnimation<
                                                            Color
                                                          >(
                                                            CaslaColors
                                                                .accentGold,
                                                          ),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 10),

                                                  // Stats row
                                                  Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .spaceBetween,
                                                    children: [
                                                      _buildStatItem(
                                                        'Giao',
                                                        '${formatQuantity(worker.assignedQty)} ${worker.uom}',
                                                      ),
                                                      _buildStatItem(
                                                        'H.thành',
                                                        '${formatQuantity(worker.completedQty)} ${worker.uom}',
                                                      ),
                                                      _buildStatItem(
                                                        'Còn lại',
                                                        '${formatQuantity(worker.remainingQty)} ${worker.uom}',
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
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
      floatingActionButton:
          emp?.hasPermission(Permission.assignQuantity) == true
          ? FloatingActionButton(
              tooltip: 'Tạo phân công',
              onPressed: () {
                context.push('/supervisor/create_assignment');
              },
              backgroundColor: CaslaColors.accentGold,
              foregroundColor: CaslaColors.navy900,
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.add, size: 28),
            )
          : null,
    );
  }

  Widget _buildOverviewFilterBar({
    required String teamLabel,
    required VoidCallback onTap,
  }) {
    final range = switch (_historyRange) {
      HistoryRange.day =>
        '${_formatDisplayDate(_selectedDate)} · ${DateFormat('dd/MM/yyyy').format(_selectedDate)}',
      HistoryRange.week =>
        'Tuần này · ${DateFormat('dd/MM').format(_rangeFrom)}–${DateFormat('dd/MM').format(_rangeTo)}',
      HistoryRange.month =>
        'Tháng này · ${DateFormat('MM/yyyy').format(_rangeFrom)}',
      HistoryRange.custom => _customRangeChipLabel.replaceAll(' ▾', ''),
    };
    final rangeDetail = [teamLabel, _historyShiftLabel].join(' · ');

    return Semantics(
      button: true,
      label: 'Lọc dữ liệu tra cứu. $range. $rangeDetail',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                const Icon(
                  Icons.tune_rounded,
                  color: CaslaColors.muted,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        range,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: CaslaColors.primaryNavy,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        rangeDetail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: CaslaColors.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Text(
                  'Lọc',
                  style: TextStyle(
                    color: CaslaColors.primaryNavy,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 2),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: CaslaColors.muted,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showOverviewFiltersSheet() async {
    final session = ref.read(appStateProvider).currentSession;
    final teams = await _loadTeamFilterOptions();
    List<SapShift> shifts;
    try {
      shifts = await _loadHistoryShifts();
    } catch (_) {
      shifts = const [];
    }
    if (!mounted) return;

    var draftTeamId = _selectedTeamId;
    var draftTeamLabel = _selectedTeamLabel;
    Set<String>? draftTeamScopeIds = _selectedTeamScopeIds;
    var draftShiftId = _historyShiftId;
    var draftShiftLabel = _historyShiftLabel;
    var draftRange = _historyRange;
    var draftSelectedDate = _selectedDate;
    var draftDateFrom = _customDateFrom;
    var draftDateTo = _customDateTo;

    Future<void> pickDraftRange(StateSetter setModalState) async {
      final today = _dateOnly(DateTime.now());
      final currentFrom =
          draftDateFrom ?? today.subtract(const Duration(days: 6));
      final currentTo = draftDateTo ?? today;
      final picked = await showDateRangePicker(
        context: context,
        initialDateRange: DateTimeRange(
          start: currentFrom.isAfter(currentTo) ? currentTo : currentFrom,
          end: currentTo,
        ),
        firstDate: DateTime(today.year - 2, 1, 1),
        lastDate: today,
        helpText: 'CHỌN KHOẢNG NGÀY',
        fieldStartLabelText: 'Từ ngày',
        fieldEndLabelText: 'Đến ngày',
        cancelText: 'HỦY',
        confirmText: 'ÁP DỤNG',
        builder: (context, child) => Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: CaslaColors.primaryNavy,
              onPrimary: Colors.white,
              surface: CaslaColors.surface,
              onSurface: CaslaColors.navy900,
            ),
          ),
          child: child!,
        ),
      );
      if (picked == null) return;
      final from = _dateOnly(picked.start);
      final to = _dateOnly(picked.end);
      if (to.difference(from).inDays > 31) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Khoảng thời gian tối đa là 31 ngày'),
              backgroundColor: CaslaColors.danger,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      setModalState(() {
        draftRange = HistoryRange.custom;
        draftDateFrom = from;
        draftDateTo = to;
        draftSelectedDate = from;
      });
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setModalState) {
          final customLabel =
              draftRange == HistoryRange.custom &&
                  draftDateFrom != null &&
                  draftDateTo != null
              ? '${DateFormat('dd/MM').format(draftDateFrom!)} – ${DateFormat('dd/MM').format(draftDateTo!)}'
              : 'Ngày khác / Từ ngày – Đến ngày';
          final selectedTeamValue = draftTeamId == 'ALL'
              ? 'ALL'
              : teams.any((team) => team.id == draftTeamId)
              ? draftTeamId
              : 'ALL';

          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.86,
                ),
                decoration: const BoxDecoration(
                  color: CaslaColors.surface,
                  borderRadius: BorderRadius.all(Radius.circular(22)),
                ),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 34,
                        height: 4,
                        decoration: BoxDecoration(
                          color: CaslaColors.line,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Lọc dữ liệu',
                            style: TextStyle(
                              color: CaslaColors.primaryNavy,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Đóng bộ lọc',
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const Text(
                      'Chỉ thay đổi dữ liệu tra cứu. Không đổi ca đang làm của bạn.',
                      style: TextStyle(
                        color: CaslaColors.muted,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Thời gian',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _buildDraftPeriodButton(
                          label: 'Hôm nay',
                          selected:
                              draftRange == HistoryRange.day &&
                              _dateOnly(draftSelectedDate) ==
                                  _dateOnly(DateTime.now()),
                          onTap: () => setModalState(() {
                            draftRange = HistoryRange.day;
                            draftSelectedDate = _dateOnly(DateTime.now());
                          }),
                        ),
                        const SizedBox(width: 6),
                        _buildDraftPeriodButton(
                          label: 'Tuần này',
                          selected: draftRange == HistoryRange.week,
                          onTap: () => setModalState(
                            () => draftRange = HistoryRange.week,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _buildDraftPeriodButton(
                          label: 'Tháng này',
                          selected: draftRange == HistoryRange.month,
                          onTap: () => setModalState(
                            () => draftRange = HistoryRange.month,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        alignment: Alignment.centerLeft,
                        side: const BorderSide(color: CaslaColors.line),
                        foregroundColor: CaslaColors.primaryNavy,
                      ),
                      onPressed: () => pickDraftRange(setModalState),
                      icon: const Icon(Icons.date_range_outlined, size: 18),
                      label: Text(
                        customLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () async {
                          final today = _dateOnly(DateTime.now());
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: draftSelectedDate,
                            firstDate: DateTime(today.year - 2, 1, 1),
                            lastDate: today,
                            helpText: 'CHỌN NGÀY',
                            cancelText: 'HỦY',
                            confirmText: 'CHỌN',
                          );
                          if (picked == null) return;
                          setModalState(() {
                            draftRange = HistoryRange.day;
                            draftSelectedDate = _dateOnly(picked);
                          });
                        },
                        icon: const Icon(Icons.event_outlined, size: 17),
                        label: const Text('Chọn một ngày khác, ví dụ Hôm qua'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: selectedTeamValue,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Tổ sản xuất',
                        prefixIcon: Icon(Icons.groups_outlined),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'ALL',
                          child: Text(_allTeamsLabel(session)),
                        ),
                        for (final team in teams)
                          DropdownMenuItem(
                            value: team.id,
                            child: Text(
                              team.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setModalState(() {
                          draftTeamId = value;
                          if (value == 'ALL') {
                            draftTeamLabel = _allTeamsLabel(session);
                            draftTeamScopeIds = null;
                          } else {
                            final team = teams.firstWhere(
                              (item) => item.id == value,
                            );
                            draftTeamLabel = team.name;
                            draftTeamScopeIds = team.scopeIds;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: draftShiftId ?? 'ALL',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Ca tra cứu',
                        prefixIcon: Icon(Icons.schedule_outlined),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 'ALL',
                          child: Text('Tất cả ca'),
                        ),
                        for (final shift in shifts)
                          DropdownMenuItem(
                            value: shift.shiftId,
                            child: Text(
                              '${shift.shiftName.isEmpty ? shift.shiftId : shift.shiftName} · ${shift.timeLabel}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setModalState(() {
                          draftShiftId = value == 'ALL' ? null : value;
                          final shift = shifts
                              .where((item) => item.shiftId == value)
                              .firstOrNull;
                          draftShiftLabel = shift == null
                              ? 'Tất cả ca'
                              : (shift.shiftName.isEmpty
                                    ? shift.shiftId
                                    : shift.shiftName);
                        });
                      },
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => setModalState(() {
                              draftTeamId = 'ALL';
                              draftTeamLabel = _allTeamsLabel(session);
                              draftTeamScopeIds = null;
                              draftShiftId = null;
                              draftShiftLabel = 'Tất cả ca';
                              draftRange = HistoryRange.day;
                              draftSelectedDate = _dateOnly(DateTime.now());
                              draftDateFrom = null;
                              draftDateTo = null;
                            }),
                            child: const Text('Đặt lại'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: CaslaColors.primaryNavy,
                              minimumSize: const Size.fromHeight(48),
                            ),
                            onPressed: () {
                              setState(() {
                                _selectedTeamId = draftTeamId;
                                _selectedTeamLabel = draftTeamLabel;
                                _selectedTeamScopeIds = draftTeamScopeIds;
                                _historyShiftId = draftShiftId;
                                _historyShiftLabel = draftShiftLabel;
                                _historyRange = draftRange;
                                _selectedDate = draftSelectedDate;
                                _customDateFrom = draftDateFrom;
                                _customDateTo = draftDateTo;
                                _replaceHistoryStream();
                              });
                              Navigator.pop(sheetContext);
                            },
                            child: const Text('Áp dụng bộ lọc'),
                          ),
                        ),
                      ],
                    ),
                  ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDraftPeriodButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Material(
        color: selected ? CaslaColors.surface : CaslaColors.muted100,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? CaslaColors.line : Colors.transparent,
              ),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: CaslaColors.primaryNavy,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverviewKpiPanel({
    required double totalEffective,
    required double totalCompleted,
    required int assignedWorkerCount,
    required int openCount,
    required String? uom,
  }) {
    Widget metric(String label, String value) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: CaslaColors.muted,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: CaslaColors.primaryNavy,
                      fontFamily: 'Manrope',
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                ),
                if (uom != null) ...[
                  const SizedBox(width: 3),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      uom,
                      style: const TextStyle(
                        color: CaslaColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        border: Border.all(color: CaslaColors.line),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 11),
            child: Row(
              children: [
                metric('Giao hiệu lực', formatQuantity(totalEffective)),
                const SizedBox(width: 14),
                Container(width: 1, height: 46, color: CaslaColors.line),
                const SizedBox(width: 14),
                metric('Đã hoàn thành', formatQuantity(totalCompleted)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            color: CaslaColors.background,
            child: Row(
              children: [
                Expanded(
                  child: _buildKpiFooterItem(
                    '$assignedWorkerCount',
                    'công nhân được giao',
                  ),
                ),
                Expanded(
                  child: _buildKpiFooterItem('$openCount', 'phân công mở'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKpiFooterItem(String value, String label) {
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: const TextStyle(
          color: CaslaColors.muted,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
        children: [
          TextSpan(
            text: value,
            style: const TextStyle(
              color: CaslaColors.primaryNavy,
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: '  $label'),
        ],
      ),
    );
  }

  // Kept as a compatibility path for callers from older routes.
  // ignore: unused_element
  Widget _buildFilterChip(
    String label, {
    bool isSelected = false,
    VoidCallback? onTap,
    IconData? icon,
  }) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: 48,
              maxWidth: MediaQuery.sizeOf(context).width - 36,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? CaslaColors.primaryNavy.withValues(alpha: 0.08)
                    : CaslaColors.surface,
                border: Border.all(
                  color: isSelected ? CaslaColors.accentGold : CaslaColors.line,
                  width: isSelected ? 1.8 : 1.2,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: 15,
                      color: isSelected
                          ? CaslaColors.navy900
                          : CaslaColors.muted,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: isSelected
                            ? FontWeight.w800
                            : FontWeight.w600,
                        color: isSelected
                            ? CaslaColors.primaryNavy
                            : CaslaColors.navy900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Derives the worker's sync badge from their assignments' real sync state.
  ///
  /// Returns (chip status, chip label). The failed count leads, because that is
  /// what a supervisor has to act on.
  (String, String) _workerStatusBadge(_WorkerOverviewData worker) {
    if (worker.localAssignments.isNotEmpty) {
      final failed = worker.localAssignments
          .where((a) => a.syncStatus == SyncStatus.failed)
          .length;
      if (failed > 0) return ('FAILED', '$failed LỖI');

      final needsVerification = worker.localAssignments
          .where((a) => a.syncStatus == SyncStatus.needsVerification)
          .length;
      if (needsVerification > 0) {
        return ('NEEDS_VERIFICATION', '$needsVerification CẦN XÁC MINH');
      }

      final pending = worker.localAssignments
          .where((a) => a.syncStatus == SyncStatus.pending)
          .length;
      if (pending > 0) return ('PENDING', '$pending ĐANG CHỜ');
    }

    if (worker.assignedQty == 0) return ('OPEN', 'CHƯA GIAO');
    if (worker.remainingQty <= 0) return ('COMPLETED', 'HOÀN THÀNH');
    if (worker.completedQty > 0) return ('PENDING', 'ĐANG LÀM');
    return ('OPEN', 'CHƯA LÀM');
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: CaslaColors.muted,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'Manrope',
            fontWeight: FontWeight.w800,
            fontSize: 15,
            color: CaslaColors.primaryNavy,
          ),
        ),
      ],
    );
  }
}

class _OverviewSkeleton extends StatelessWidget {
  const _OverviewSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.6,
          children: const [
            CaslaSkeleton(height: 84, radius: 12),
            CaslaSkeleton(height: 84, radius: 12),
            CaslaSkeleton(height: 84, radius: 12),
            CaslaSkeleton(height: 84, radius: 12),
          ],
        ),
        const SizedBox(height: 20),
        const CaslaSkeleton(width: 210, height: 18, radius: 6),
        const SizedBox(height: 12),
        for (var index = 0; index < 3; index++) ...[
          const CaslaSkeleton(height: 126, radius: 12),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _OverviewHistoryError extends StatelessWidget {
  final Future<void> Function() onRetry;

  const _OverviewHistoryError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
      children: [
        Icon(
          Icons.cloud_off_outlined,
          size: 42,
          color: CaslaColors.muted.withValues(alpha: 0.75),
        ),
        const SizedBox(height: 14),
        const Text(
          'Chưa tải được dữ liệu SAP',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: CaslaColors.navy900,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Kéo xuống để thử lại hoặc kiểm tra kết nối mạng. Dữ liệu giao việc trên thiết bị vẫn được giữ nguyên.',
          textAlign: TextAlign.center,
          style: TextStyle(color: CaslaColors.muted, height: 1.4),
        ),
        const SizedBox(height: 18),
        Center(
          child: OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Thử tải lại'),
          ),
        ),
      ],
    );
  }
}
