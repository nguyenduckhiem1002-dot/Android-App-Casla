import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../domain/entities/work_history.dart';
import '../../../domain/policies/production_math.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../main.dart';
import '../../../presentation/widgets/kpi_card.dart';
import '../../../presentation/widgets/status_chip.dart';
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

  @override
  void initState() {
    super.initState();
    final appState = ref.read(appStateProvider);
    _historyStream = _watchHistory();
    _assignmentStream = appState.assignmentRepo.watchAssignmentsByTeams(
      appState.currentSession?.toIds ?? const <String>[],
    );
  }

  Stream<WorkHistoryResult> _watchHistory() {
    return ref
        .read(appStateProvider)
        .workHistoryRepo
        .watchWorkHistory(
          range: _historyRange,
          dateFrom:
              _historyRange == HistoryRange.custom ||
                  _historyRange == HistoryRange.day
              ? _rangeFrom
              : null,
          dateTo:
              _historyRange == HistoryRange.custom ||
                  _historyRange == HistoryRange.day
              ? _rangeTo
              : null,
        )
        .asyncMap(_ensureHistoryEmployees);
  }

  Future<WorkHistoryResult> _fetchHistory({bool forceRefresh = false}) async {
    final result = await ref
        .read(appStateProvider)
        .workHistoryRepo
        .getWorkHistory(
          range: _historyRange,
          dateFrom:
              _historyRange == HistoryRange.custom ||
                  _historyRange == HistoryRange.day
              ? _rangeFrom
              : null,
          dateTo:
              _historyRange == HistoryRange.custom ||
                  _historyRange == HistoryRange.day
              ? _rangeTo
              : null,
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
    switch (_historyRange) {
      case HistoryRange.day:
        return _dateOnly(_selectedDate);
      case HistoryRange.week:
        final anchor = _dateOnly(DateTime.now());
        return anchor.subtract(Duration(days: anchor.weekday - 1));
      case HistoryRange.month:
        final now = DateTime.now();
        return DateTime(now.year, now.month, 1);
      case HistoryRange.custom:
        return _customDateFrom ?? _dateOnly(_selectedDate);
    }
  }

  DateTime get _rangeTo {
    switch (_historyRange) {
      case HistoryRange.day:
        return _rangeFrom;
      case HistoryRange.week:
        return _rangeFrom.add(const Duration(days: 6));
      case HistoryRange.month:
        return DateTime(_rangeFrom.year, _rangeFrom.month + 1, 0);
      case HistoryRange.custom:
        return _customDateTo ?? _rangeFrom;
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

  String get _dayChipLabel {
    if (_historyRange == HistoryRange.day) {
      final display = _formatDisplayDate(_selectedDate);
      return display == 'Hôm nay' ? 'Hôm nay ▾' : '$display ▾';
    }
    return 'Hôm nay ▾';
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

  bool _isInSelectedRange(String businessDate) {
    final parsed = DateTime.tryParse(businessDate);
    if (parsed == null) return false;
    final date = _dateOnly(parsed);
    return !date.isBefore(_rangeFrom) && !date.isAfter(_rangeTo);
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

  Future<void> _pickSingleDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: DateTime(now.year + 2, 12, 31),
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
      _historyStream = _watchHistory();
    });
  }

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
                    _historyStream = _watchHistory();
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
                    _historyStream = _watchHistory();
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
      lastDate: DateTime(now.year + 2, 12, 31),
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
      _historyStream = _watchHistory();
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
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
                                  supervisorName,
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
                                  'Supervisor · ${emp?.teamName.isNotEmpty == true ? emp!.teamName : 'Phạm vi được phân quyền'}',
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
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          // 1. Lọc theo tổ sản xuất
                          _buildFilterChip(
                            '$teamFilterLabel ▾',
                            icon: Icons.groups_outlined,
                            isSelected: true,
                            onTap: _showTeamFilterSheet,
                          ),

                          // 2. Chip Hôm nay (hoặc 1 ngày cụ thể)
                          _buildFilterChip(
                            _dayChipLabel,
                            icon: Icons.calendar_today_outlined,
                            isSelected: _historyRange == HistoryRange.day,
                            onTap: _showDaySelectionSheet,
                          ),

                          // 3. Chip Tuần này
                          _buildFilterChip(
                            'Tuần này',
                            isSelected: _historyRange == HistoryRange.week,
                            onTap: () {
                              setState(() {
                                _historyRange = HistoryRange.week;
                                _historyStream = _watchHistory();
                              });
                            },
                          ),

                          // 4. Chip Tháng này
                          _buildFilterChip(
                            'Tháng này',
                            isSelected: _historyRange == HistoryRange.month,
                            onTap: () {
                              setState(() {
                                _historyRange = HistoryRange.month;
                                _historyStream = _watchHistory();
                              });
                            },
                          ),

                          // 5. Chip Khoảng ngày (Custom Date Range)
                          _buildFilterChip(
                            _customRangeChipLabel,
                            icon: Icons.date_range_outlined,
                            isSelected: _historyRange == HistoryRange.custom,
                            onTap: _pickDateRange,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Phạm vi SAP: ${_scopeSummary(emp)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: CaslaColors.muted,
                          fontWeight: FontWeight.w600,
                        ),
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
              return StreamBuilder<List<Assignment>>(
                stream: _assignmentStream,
                builder: (context, assignmentSnapshot) {
                  return FutureBuilder<List<Map<String, dynamic>>>(
                    future: _employeesFor(effectiveTeamIds),
                    builder: (context, empSnapshot) {
                      final isHistoryLoading =
                          historySnapshot.connectionState ==
                              ConnectionState.waiting &&
                          !historySnapshot.hasData;
                      final isEmpLoading =
                          empSnapshot.connectionState ==
                              ConnectionState.waiting &&
                          !empSnapshot.hasData;

                      if (isHistoryLoading || isEmpLoading) {
                        return const _OverviewSkeleton();
                      }

                      // Process SAP data
                      final sapResult = historySnapshot.data;
                      final sapWorkers =
                          sapResult?.workers ?? const <WorkHistorySummary>[];
                      final sapEntries =
                          sapResult?.entries ?? const <WorkHistoryEntry>[];

                      // Process Local data
                      final rawAssignments =
                          assignmentSnapshot.data ?? const <Assignment>[];
                      final localAssignments = rawAssignments.where((a) {
                        if (_selectedTeamScopeIds != null &&
                            !_selectedTeamScopeIds!.contains(a.teamId)) {
                          return false;
                        }
                        if (!_isInSelectedRange(a.businessDate)) {
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

                        final effectiveQty =
                            ProductionMath.calculateEffectiveAssigned(
                              workerAssigned,
                              recalledQty,
                            );
                        final remainingQty = ProductionMath.calculateRemaining(
                          effectiveQty,
                          completedQty,
                        );

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
                                  // KPI Grid Cards
                                  LayoutBuilder(
                                    builder: (context, constraints) => Wrap(
                                      spacing: 10,
                                      runSpacing: 10,
                                      children:
                                          <Widget>[
                                                KpiCard(
                                                  label: 'Tổng giao hiệu lực',
                                                  value: formatQuantity(
                                                    totalEffective,
                                                  ),
                                                  isAccent: true,
                                                ),
                                                KpiCard(
                                                  label: 'Tổng hoàn thành',
                                                  value: formatQuantity(
                                                    totalCompleted,
                                                  ),
                                                ),
                                                KpiCard(
                                                  label: 'Đã được giao',
                                                  value: '$assignedWorkerCount',
                                                  uom: 'NV',
                                                ),
                                                KpiCard(
                                                  label: 'Phân công OPEN',
                                                  value: '$openCount',
                                                ),
                                              ]
                                              .map(
                                                (card) => SizedBox(
                                                  width:
                                                      constraints.maxWidth <
                                                              320 ||
                                                          MediaQuery.textScalerOf(
                                                                context,
                                                              ).scale(14) >
                                                              21
                                                      ? constraints.maxWidth
                                                      : (constraints.maxWidth -
                                                                10) /
                                                            2,
                                                  child: ConstrainedBox(
                                                    constraints:
                                                        const BoxConstraints(
                                                          minHeight: 110,
                                                        ),
                                                    child: card,
                                                  ),
                                                ),
                                              )
                                              .toList(),
                                    ),
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
