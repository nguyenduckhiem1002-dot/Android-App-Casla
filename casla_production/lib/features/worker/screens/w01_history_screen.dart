// W01 — Lịch sử sản lượng (công nhân)
// Spec: Section 5.1 ("Công nhân" role) — read-only view backed by
// ZUI_PP_OPALLOC.getWorkHistory. Scope (chỉ của mình / cả tổ) do SAP quyết
// định theo quyền tài khoản (PP_HIST_SELF / PP_HIST_TEAM), màn hình không
// tự chọn hay gửi WorkerID.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../data/sap/sap_shift_controller.dart';
import '../../../domain/entities/work_history.dart';
import '../../../main.dart';
import '../../../presentation/widgets/casla_skeleton.dart';

class W01HistoryScreen extends ConsumerStatefulWidget {
  const W01HistoryScreen({super.key});

  @override
  ConsumerState<W01HistoryScreen> createState() => _W01HistoryScreenState();
}

class _WorkerHistoryGroupData {
  final String key;
  DateTime date;
  String productionOrder;
  String operation;
  String operationName;
  String productName;
  String productCode;
  String salesOrder;
  String salesOrderItem;
  final List<WorkHistoryEntry> entries = [];

  _WorkerHistoryGroupData({
    required this.key,
    required this.date,
    required this.productionOrder,
    required this.operation,
    required this.operationName,
    required this.productName,
    required this.productCode,
    required this.salesOrder,
    required this.salesOrderItem,
  });
}

class _W01HistoryScreenState extends ConsumerState<W01HistoryScreen> {
  static const int _historyEntryPageSize = 50;

  HistoryRange _range = HistoryRange.month;
  DateTime? _customDateFrom;
  DateTime? _customDateTo;
  String? _historyShiftId;
  String _historyShiftLabel = 'Tất cả ca';
  Future<List<SapShift>>? _historyShiftsFuture;
  String _historyShiftsKey = '';
  late Stream<WorkHistoryResult> _historyStream;
  int _visibleEntryCount = _historyEntryPageSize;
  String _activeContextKey = '';
  bool _historyDataReady = false;
  WorkHistoryResult? _lastHistoryResult;

  @override
  void initState() {
    super.initState();
    _syncActiveContext();
    _replaceHistoryStream();
  }

  bool _syncActiveContext() {
    final state = ref.read(appStateProvider);
    final date = state.activeBusinessDate;
    final key =
        '${DateFormat('yyyy-MM-dd').format(date)}|'
        '${state.activeShift?.shiftId ?? ''}|${state.activeWorkContext?.workId ?? ''}';
    if (key == _activeContextKey) return false;
    _activeContextKey = key;
    if (state.activeShift != null) {
      _range = HistoryRange.custom;
      _customDateFrom = DateTime(date.year, date.month, date.day);
      _customDateTo = _customDateFrom;
      _historyShiftId = state.activeShift!.shiftId;
      _historyShiftLabel = state.activeShift!.shiftName;
    } else {
      _historyShiftId = null;
      _historyShiftLabel = 'Tất cả ca';
    }
    _historyShiftsFuture = null;
    _historyShiftsKey = '';
    return true;
  }

  DateTime get _filterTo {
    if (_range == HistoryRange.custom) return _customDateTo!;
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime get _filterFrom {
    final to = _filterTo;
    return switch (_range) {
      HistoryRange.day => to,
      HistoryRange.week => to.subtract(Duration(days: to.weekday - 1)),
      HistoryRange.month => DateTime(to.year, to.month, 1),
      HistoryRange.custom => _customDateFrom!,
    };
  }

  void _replaceHistoryStream() {
    _historyDataReady = false;
    _lastHistoryResult = null;
    _historyStream = _watchHistory();
  }

  Stream<WorkHistoryResult> _watchHistory() {
    final workId = ref.read(appStateProvider).activeWorkContext?.workId;
    return ref
        .read(appStateProvider)
        .workHistoryRepo
        .watchWorkHistory(
          range: _range,
          dateFrom: _filterFrom,
          dateTo: _filterTo,
          shiftId: _historyShiftId,
          workId: workId,
        );
  }

  Future<WorkHistoryResult> _load({bool forceRefresh = false}) {
    final workId = ref.read(appStateProvider).activeWorkContext?.workId;
    return ref
        .read(appStateProvider)
        .workHistoryRepo
        .getWorkHistory(
          range: _range,
          dateFrom: _filterFrom,
          dateTo: _filterTo,
          shiftId: _historyShiftId,
          workId: workId,
          forceRefresh: forceRefresh,
        );
  }

  void _selectRange(HistoryRange range) {
    if (range == HistoryRange.custom) {
      _showCustomDatePickerSheet();
      return;
    }
    if (range == _range) return;
    setState(() {
      _range = range;
      _visibleEntryCount = _historyEntryPageSize;
      _historyShiftId = null;
      _historyShiftLabel = 'Tất cả ca';
      _historyShiftsKey = '';
      _replaceHistoryStream();
    });
  }

  Future<void> _refresh() async {
    try {
      await _load(forceRefresh: true);
      if (!mounted) return;
      setState(() {
        _visibleEntryCount = _historyEntryPageSize;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Không thể làm mới từ SAP. Đang hiển thị dữ liệu gần nhất trên máy.',
          ),
        ),
      );
      // Keep the same stream alive: when it has a cached snapshot, it remains
      // on-screen instead of being replaced by an error-only FutureBuilder.
    }
  }

  Future<void> _pickSingleDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: (_customDateFrom != null && !_customDateFrom!.isAfter(today))
          ? _customDateFrom!
          : today,
      firstDate: DateTime(2020),
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
      _range = HistoryRange.custom;
      _customDateFrom = DateTime(picked.year, picked.month, picked.day);
      _customDateTo = DateTime(picked.year, picked.month, picked.day);
      _visibleEntryCount = _historyEntryPageSize;
      _historyShiftId = null;
      _historyShiftLabel = 'Tất cả ca';
      _historyShiftsKey = '';
      _replaceHistoryStream();
    });
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final savedFrom = _customDateFrom == null
        ? null
        : (_customDateFrom!.isAfter(today) ? today : _customDateFrom!);
    final savedTo = _customDateTo == null
        ? null
        : (_customDateTo!.isAfter(today) ? today : _customDateTo!);
    final initialRange =
        (savedFrom != null && savedTo != null && !savedFrom.isAfter(savedTo))
        ? DateTimeRange(start: savedFrom, end: savedTo)
        : DateTimeRange(
            start: today.subtract(const Duration(days: 7)),
            end: today,
          );

    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: initialRange,
      firstDate: DateTime(2020),
      lastDate: today,
      helpText: 'CHỌN KHOẢNG NGÀY (TỐI ĐA 1 THÁNG)',
      cancelText: 'HỦY',
      confirmText: 'CHỌN',
      saveText: 'CHỌN',
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

    final diffDays = picked.end.difference(picked.start).inDays;
    if (diffDays > 31) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Khoảng thời gian không được vượt quá 1 tháng (tối đa 31 ngày)',
          ),
          backgroundColor: CaslaColors.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      _range = HistoryRange.custom;
      _customDateFrom = DateTime(
        picked.start.year,
        picked.start.month,
        picked.start.day,
      );
      _customDateTo = DateTime(
        picked.end.year,
        picked.end.month,
        picked.end.day,
      );
      _visibleEntryCount = _historyEntryPageSize;
      _historyShiftId = null;
      _historyShiftLabel = 'Tất cả ca';
      _historyShiftsKey = '';
      _replaceHistoryStream();
    });
  }

  DateTime get _shiftReferenceDate {
    if (_range == HistoryRange.custom && _customDateFrom != null) {
      return _customDateFrom!;
    }
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  Future<List<SapShift>> _loadHistoryShifts() {
    final appState = ref.read(appStateProvider);
    final workCenter = appState.activeWorkContext?.workCenter.trim() ?? '';
    final date = _shiftReferenceDate;
    final key = '$workCenter|${DateFormat('yyyy-MM-dd').format(date)}';
    if (_historyShiftsFuture == null || _historyShiftsKey != key) {
      _historyShiftsKey = key;
      _historyShiftsFuture = workCenter.isEmpty
          ? Future<List<SapShift>>.value(const [])
          : appState.shiftController.getShifts(
              workCenter: workCenter,
              onDate: date,
            );
    }
    return _historyShiftsFuture!;
  }

  Future<void> _showHistoryShiftSheet() async {
    List<SapShift> shifts;
    try {
      shifts = await _loadHistoryShifts();
    } catch (_) {
      _historyShiftsFuture = null;
      _historyShiftsKey = '';
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 20),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                'Danh sách ca theo ngày ${DateFormat('dd/MM/yyyy').format(_shiftReferenceDate)}',
                style: const TextStyle(fontSize: 12, color: CaslaColors.muted),
              ),
            ),
            Material(
              color: Colors.transparent,
              child: ListTile(
                minTileHeight: 52,
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
            ),
            for (final shift in shifts)
              Material(
                color: Colors.transparent,
                child: ListTile(
                  minTileHeight: 58,
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
              ),
            if (shifts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Chưa có ca phù hợp với ngày đang chọn.',
                  style: TextStyle(color: CaslaColors.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showCustomDatePickerSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          decoration: const BoxDecoration(
            color: CaslaColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
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
              const SizedBox(height: 16),
              const Text(
                'Tùy chọn thời gian',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Chọn ngày cụ thể hoặc khoảng ngày (tối đa 1 tháng)',
                style: TextStyle(fontSize: 13, color: CaslaColors.muted),
              ),
              const SizedBox(height: 18),
              _buildOptionTile(
                icon: Icons.today_rounded,
                title: 'Chọn 1 ngày cụ thể',
                subtitle: 'Xem lịch sử sản xuất trong một ngày',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickSingleDate();
                },
              ),
              const SizedBox(height: 10),
              _buildOptionTile(
                icon: Icons.date_range_rounded,
                title: 'Chọn khoảng ngày',
                subtitle: 'Tối đa 31 ngày (1 tháng)',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickDateRange();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOptionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: CaslaColors.muted100.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CaslaColors.line),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: CaslaColors.primaryNavy.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: CaslaColors.primaryNavy, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: CaslaColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: CaslaColors.muted, size: 20),
          ],
        ),
      ),
    );
  }

  String get _customDateLabel {
    if (_customDateFrom == null || _customDateTo == null) {
      return 'Chọn ngày';
    }
    final df = DateFormat('dd/MM/yyyy');
    if (_customDateFrom!.year == _customDateTo!.year &&
        _customDateFrom!.month == _customDateTo!.month &&
        _customDateFrom!.day == _customDateTo!.day) {
      return 'Ngày: ${df.format(_customDateFrom!)}';
    }
    return '${df.format(_customDateFrom!)} - ${df.format(_customDateTo!)}';
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(appStateProvider).currentSession;
    if (_syncActiveContext()) _replaceHistoryStream();

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Lịch sử sản lượng',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              session?.fullName ?? '',
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
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: StreamBuilder<WorkHistoryResult>(
          stream: _historyStream,
          builder: (context, snapshot) {
            // StreamBuilder drops the previous `data` when a later refresh
            // emits an error. Keep the last successful result so a temporary
            // SAP/network failure does not replace usable cached content with
            // a full-screen error.
            if (snapshot.hasData &&
                snapshot.connectionState != ConnectionState.waiting) {
              _lastHistoryResult = snapshot.data;
              _historyDataReady = true;
            }
            final result = _historyDataReady
                ? snapshot.data ?? _lastHistoryResult
                : null;

            return CustomScrollView(
              key: PageStorageKey<String>('worker-history-${_range.code}'),
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                _boxSliver(
                  _buildRangeTabs(),
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 14)),
                if (snapshot.connectionState == ConnectionState.waiting &&
                    result == null)
                  _boxSliver(
                    const _HistorySkeleton(),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  )
                else if (result != null) ...[
                  if (snapshot.hasError)
                    _boxSliver(
                      _buildCachedRefreshWarning(),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                  ..._buildContentSlivers(result),
                ] else if (snapshot.hasError)
                  _boxSliver(
                    _buildError(snapshot.error!),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 18)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildRangeTabs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: CaslaColors.muted100,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              _rangeTab('Hôm nay', HistoryRange.day),
              _rangeTab('Tuần này', HistoryRange.week),
              _rangeTab('Tháng này', HistoryRange.month),
              _rangeTab('Tùy chọn', HistoryRange.custom),
            ],
          ),
        ),
        if (_range == HistoryRange.custom && _customDateFrom != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: CaslaColors.primaryNavy.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: CaslaColors.primaryNavy.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.event_available_outlined,
                  size: 16,
                  color: CaslaColors.primaryNavy,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _customDateLabel,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                ),
                InkWell(
                  onTap: _showCustomDatePickerSheet,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: CaslaColors.primaryNavy,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.edit_calendar_outlined,
                          size: 13,
                          color: Colors.white,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Đổi',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        SizedBox(
          height: 44,
          child: OutlinedButton.icon(
            onPressed: _showHistoryShiftSheet,
            icon: const Icon(Icons.schedule_outlined, size: 17),
            label: Expanded(
              child: Text(
                'Ca tra cứu: $_historyShiftLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            style: OutlinedButton.styleFrom(
              alignment: Alignment.centerLeft,
              foregroundColor: CaslaColors.primaryNavy,
              side: const BorderSide(color: CaslaColors.line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _rangeTab(String label, HistoryRange range) {
    final selected = range == _range;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: SizedBox(
          height: 48,
          child: InkWell(
            onTap: () => _selectRange(range),
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? CaslaColors.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? CaslaColors.primaryNavy : CaslaColors.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError(Object error) {
    // getWorkHistory already tried a silent token refresh before this reached
    // here (see SapPpOpAllocGateway.getWorkHistory) — a session that still
    // classifies as `auth` at this point didn't just expire, it's dead
    // (e.g. revoked by a password change). "Thử lại" would only repeat the
    // same failure; the only way forward is a fresh login.
    final needsReLogin = classifySyncError(error).kind == SyncFailureKind.auth;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: CaslaColors.dangerBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CaslaColors.danger.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.error_outline,
                color: CaslaColors.danger,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                needsReLogin
                    ? 'Phiên đăng nhập đã hết hạn'
                    : 'Không tải được lịch sử',
                style: const TextStyle(
                  color: CaslaColors.danger,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            needsReLogin
                ? 'Vui lòng đăng nhập lại để tiếp tục.'
                : error.toString().replaceAll('Exception: ', ''),
            style: const TextStyle(color: CaslaColors.danger, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: needsReLogin ? _reLogin : _refresh,
            style: ElevatedButton.styleFrom(
              backgroundColor: CaslaColors.primaryNavy,
              foregroundColor: Colors.white,
            ),
            child: Text(needsReLogin ? 'Đăng nhập lại' : 'Thử lại'),
          ),
        ],
      ),
    );
  }

  Widget _buildCachedRefreshWarning() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: CaslaColors.pendingBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            color: CaslaColors.bannerText,
            size: 17,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Không thể làm mới từ SAP. Đang hiển thị dữ liệu gần nhất trên máy.',
              style: TextStyle(color: CaslaColors.bannerText, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reLogin() async {
    await ref.read(appStateProvider).logout();
    if (!mounted) return;
    context.go('/login');
  }

  Widget _boxSliver(Widget child, {required EdgeInsets padding}) {
    return SliverPadding(
      padding: padding,
      sliver: SliverToBoxAdapter(child: child),
    );
  }

  List<Widget> _buildContentSlivers(WorkHistoryResult result) {
    final visibleCount = _visibleEntryCount < result.entries.length
        ? _visibleEntryCount
        : result.entries.length;
    final visibleEntryCount = visibleCount;
    final slivers = <Widget>[];

    if (result.workers.isNotEmpty) {
      slivers.add(
        _boxSliver(
          _buildSummary(result.workers),
          padding: const EdgeInsets.symmetric(horizontal: 18),
        ),
      );
    }

    if (result.isTruncated) {
      slivers.add(
        _boxSliver(
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CaslaColors.pendingBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'Danh sách đã bị giới hạn do quá nhiều dữ liệu trong khoảng thời gian này.',
              style: TextStyle(color: CaslaColors.bannerText, fontSize: 11.5),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
        ),
      );
    }

    slivers.add(
      _boxSliver(
        const Text(
          'Chi tiết giao dịch',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
            color: CaslaColors.primaryNavy,
          ),
        ),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      ),
    );

    if (result.entries.isEmpty) {
      slivers.add(
        _boxSliver(
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: CaslaColors.surface,
              border: Border.all(color: CaslaColors.line),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Center(
              child: Text(
                'Không có giao dịch nào trong khoảng thời gian này.',
                style: TextStyle(color: CaslaColors.muted, fontSize: 13),
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18),
        ),
      );
    } else {
      final visibleEntries = result.entries
          .take(visibleEntryCount)
          .toList(growable: false);
      final groups = _groupHistoryEntries(visibleEntries);
      slivers.add(
        _boxSliver(
          _buildHistoryGroups(groups),
          padding: const EdgeInsets.symmetric(horizontal: 18),
        ),
      );
    }

    if (visibleEntryCount < result.entries.length) {
      slivers.add(
        _boxSliver(
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              key: const Key('history-load-more'),
              onPressed: () {
                setState(() {
                  final next = _visibleEntryCount + _historyEntryPageSize;
                  _visibleEntryCount = next < result.entries.length
                      ? next
                      : result.entries.length;
                });
              },
              icon: const Icon(Icons.expand_more_rounded),
              label: Text(
                'Xem thêm • $visibleEntryCount/${result.entries.length} giao dịch',
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
        ),
      );
    }

    return slivers;
  }

  List<_WorkerHistoryGroupData> _groupHistoryEntries(
    List<WorkHistoryEntry> entries,
  ) {
    final grouped = <String, _WorkerHistoryGroupData>{};
    for (final entry in entries) {
      // The shift's business day: night-shift work posted after midnight
      // belongs to the day the shift started.
      final date = entry.workDate;
      final productionOrder = entry.productionOrder.trim().isEmpty
          ? 'Chưa có LSX'
          : entry.productionOrder.trim();
      final operation = entry.operation.trim().isEmpty
          ? 'Chưa có mã CĐ'
          : entry.operation.trim();
      final key =
          '${DateFormat('yyyy-MM-dd').format(date)}|$productionOrder|$operation';
      final group = grouped.putIfAbsent(
        key,
        () => _WorkerHistoryGroupData(
          key: key,
          date: date,
          productionOrder: productionOrder,
          operation: operation,
          operationName: entry.operationName.trim(),
          productName: entry.productName.trim(),
          productCode: entry.productCode.trim(),
          salesOrder: entry.salesOrder.trim(),
          salesOrderItem: entry.salesOrderItem.trim(),
        ),
      );
      if (group.operationName.isEmpty &&
          entry.operationName.trim().isNotEmpty) {
        group.operationName = entry.operationName.trim();
      }
      if (group.productName.isEmpty && entry.productName.trim().isNotEmpty) {
        group.productName = entry.productName.trim();
      }
      if (group.productCode.isEmpty && entry.productCode.trim().isNotEmpty) {
        group.productCode = entry.productCode.trim();
      }
      if (group.salesOrder.isEmpty && entry.salesOrder.trim().isNotEmpty) {
        group.salesOrder = entry.salesOrder.trim();
      }
      if (group.salesOrderItem.isEmpty &&
          entry.salesOrderItem.trim().isNotEmpty) {
        group.salesOrderItem = entry.salesOrderItem.trim();
      }
      group.entries.add(entry);
    }

    final result = grouped.values.toList();
    for (final group in result) {
      group.entries.sort((a, b) => b.executionDate.compareTo(a.executionDate));
    }
    result.sort((a, b) {
      final dateOrder = b.date.compareTo(a.date);
      if (dateOrder != 0) return dateOrder;
      return a.key.compareTo(b.key);
    });
    return result;
  }

  Widget _buildHistoryGroups(List<_WorkerHistoryGroupData> groups) {
    final children = <Widget>[];
    DateTime? lastDate;
    for (final group in groups) {
      if (lastDate == null || !group.date.isAtSameMomentAs(lastDate)) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 8),
            child: Text(
              DateFormat('dd/MM/yyyy').format(group.date),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
        );
        lastDate = group.date;
      }
      children.add(
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: CaslaColors.surface,
            border: Border.all(color: CaslaColors.line),
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: CaslaColors.surface,
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
                splashColor: CaslaColors.navy100,
              ),
              child: ExpansionTile(
                initiallyExpanded: true,
                tilePadding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
                childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                leading: const Icon(
                  Icons.account_tree_outlined,
                  color: CaslaColors.primaryNavy,
                  size: 20,
                ),
                title: _buildHistoryGroupSummary(group),
                children: [
                  for (final entry in group.entries) _buildHistoryChild(entry),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Column(children: children);
  }

  Widget _buildHistoryGroupSummary(_WorkerHistoryGroupData group) {
    return Padding(
      padding: const EdgeInsets.only(top: 5, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group.operationName.isEmpty
                ? 'Chưa có tên công đoạn'
                : group.operationName,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: CaslaColors.primaryNavy,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'LSX ${group.productionOrder}  ·  CĐ ${group.operation}',
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: CaslaColors.muted,
            ),
          ),
          if (group.productName.isNotEmpty ||
              group.productCode.isNotEmpty ||
              group.salesOrder.isNotEmpty ||
              group.salesOrderItem.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: CaslaColors.navy100,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: CaslaColors.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHistoryInfoLine(
                    'Tên hàng',
                    group.productName.isEmpty ? '—' : group.productName,
                  ),
                  const SizedBox(height: 5),
                  _buildHistoryInfoLine(
                    'Mã hàng',
                    group.productCode.isEmpty ? '—' : group.productCode,
                    monospace: true,
                  ),
                  if (group.salesOrder.isNotEmpty ||
                      group.salesOrderItem.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      'SO ${group.salesOrder.isEmpty ? '—' : group.salesOrder}'
                      '  ·  Item ${group.salesOrderItem.isEmpty ? '—' : group.salesOrderItem}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: CaslaColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHistoryInfoLine(
    String label,
    String value, {
    bool monospace = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 58,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 10.5,
              color: CaslaColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontFamily: monospace ? 'monospace' : 'Manrope',
              fontSize: 11,
              color: CaslaColors.navy900,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHistoryChild(WorkHistoryEntry entry) {
    final isNegative =
        entry.transactionType == 'RECALL' || entry.transactionType == 'REVERSE';
    final status = _historyStatusLabel(
      entry.transactionStatus.toUpperCase(),
      isNegative: isNegative,
    );
    // Carried-over balance reads in gold, apart from work given today.
    final isCarryOver = entry.transactionType == 'REASSIGN';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          if (isCarryOver) ...[
            const Icon(Icons.push_pin, size: 13, color: CaslaColors.carryOver),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              '${_transactionTypeLabel(entry.transactionType)}: '
              '${isNegative ? '-' : ''}${formatQuantity(entry.quantity, uom: entry.unitOfMeasure)} ${entry.unitOfMeasure}',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: isCarryOver
                    ? CaslaColors.carryOver
                    : isNegative
                    ? CaslaColors.danger
                    : CaslaColors.primaryNavy,
              ),
            ),
          ),
          _buildHistoryStatusBadge(
            label: status,
            isNegative: isNegative,
            isCarryOver: isCarryOver,
          ),
          const SizedBox(width: 8),
          Text(
            DateFormat('HH:mm').format(entry.executionDate),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: CaslaColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryStatusBadge({
    required String label,
    required bool isNegative,
    bool isCarryOver = false,
  }) {
    final foreground = isCarryOver
        ? CaslaColors.carryOver
        : isNegative
        ? CaslaColors.danger
        : CaslaColors.success;
    final background = isCarryOver
        ? CaslaColors.carryOverBg
        : isNegative
        ? CaslaColors.dangerBg
        : CaslaColors.successBg;
    return Container(
      constraints: const BoxConstraints(minHeight: 28),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: foreground.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 6, color: foreground),
          const SizedBox(width: 5),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: foreground,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  String _historyStatusLabel(String status, {bool isNegative = false}) {
    return switch (status) {
      'POSTED' || 'SYNCED' => isNegative ? 'ĐÃ THU HỒI' : 'ĐÃ GHI SỔ',
      'PENDING' => 'CHỜ ĐỒNG BỘ',
      'NEEDS_VERIFICATION' => 'CẦN XÁC MINH',
      'FAILED' => 'SAP TỪ CHỐI',
      _ => status.isEmpty ? (isNegative ? 'THU HỒI' : 'HOÀN THÀNH') : status,
    };
  }

  Widget _buildSummary(List<WorkHistorySummary> summaries) {
    final first = summaries.first;
    final assigned = summaries.fold<double>(
      0,
      (total, summary) => total + summary.assignedQuantity,
    );
    final completed = summaries.fold<double>(
      0,
      (total, summary) => total + summary.completedQuantity,
    );
    final remaining = summaries.fold<double>(
      0,
      (total, summary) => total + summary.remainingQuantity,
    );
    final uom = first.unitOfMeasure;
    return Row(
      children: [
        _summaryTile(
          summaries.length == 1 ? 'Đã giao' : 'Tổng đã giao',
          assigned,
          uom,
          CaslaColors.primaryNavy,
        ),
        const SizedBox(width: 8),
        _summaryTile('Đã hoàn thành', completed, uom, CaslaColors.success),
        const SizedBox(width: 8),
        _summaryTile('Còn lại', remaining, uom, CaslaColors.pending),
      ],
    );
  }

  Widget _summaryTile(String label, double value, String uom, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: CaslaColors.surface,
          border: Border.all(color: CaslaColors.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              formatQuantity(value, uom: uom),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$label${uom.isNotEmpty ? ' ($uom)' : ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10.5, color: CaslaColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  static String _transactionTypeLabel(String type) {
    switch (type) {
      case 'INITIAL_ASSIGN':
        return 'Giao';
      case 'REASSIGN':
        return 'Tồn chuyển từ ngày trước';
      case 'TRANSFER':
        return 'Điều chuyển';
      case 'RECALL':
        return 'Thu hồi';
      case 'CONFIRM':
        return 'Hoàn thành';
      case 'REVERSE':
        return 'Đảo giao dịch';
      case 'CORRECTION':
        return 'Điều chỉnh';
      default:
        return type;
    }
  }
}

class _HistorySkeleton extends StatelessWidget {
  const _HistorySkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Row(
          children: [
            Expanded(child: CaslaSkeleton(height: 76, radius: 12)),
            SizedBox(width: 8),
            Expanded(child: CaslaSkeleton(height: 76, radius: 12)),
            SizedBox(width: 8),
            Expanded(child: CaslaSkeleton(height: 76, radius: 12)),
          ],
        ),
        const SizedBox(height: 18),
        for (var index = 0; index < 4; index++) ...[
          const CaslaSkeleton(height: 64, radius: 10),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
