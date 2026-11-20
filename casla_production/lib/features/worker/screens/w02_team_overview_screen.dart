// W02 — Tổng quan (tài khoản xem lịch sử team, PP_HIST_TEAM)
//
// A read-only counterpart of the supervisor's overview for an account that
// may see its team's history but gives no work out: one card per worker with
// what was given, confirmed and is still open over the period, narrowed by
// department and found by code, name or a scan of the worker's card. A card
// opens that worker's history (W01 on one worker).
//
// Figures come from ZUI_PP_OPALLOC.getWorkHistory for the whole authorized
// scope; "Còn lại" is settled seat by seat (seat_balance.dart) so it reads
// the same as the cards of the history screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../domain/entities/work_history.dart';
import '../../../domain/policies/history_work_context.dart';
import '../../../domain/policies/history_worker_filter.dart';
import '../../../domain/policies/production_math.dart';
import '../../../domain/policies/seat_balance.dart';
import '../../../domain/policies/worker_position_policy.dart';
import '../../../domain/policies/worker_summary_merge.dart';
import '../../../main.dart';
import '../../../presentation/widgets/barcode_scan_listener.dart';
import '../../../presentation/widgets/casla_empty_state.dart';
import '../../../presentation/widgets/history_department_sheet.dart';
import '../../../presentation/widgets/stale_history_banner.dart';
import '../../../presentation/widgets/status_chip.dart';
import '../../../presentation/widgets/worker_search_field.dart';
import '../../shared/seat_scan_lookup.dart';

/// One worker's figures in one unit over the period.
class TeamOverviewWorker {
  final String code;
  final String name;
  final String department;
  final String unit;
  final double given;
  final double recalled;
  final double completed;
  final double defect;
  final double remaining;

  const TeamOverviewWorker({
    required this.code,
    required this.name,
    required this.department,
    required this.unit,
    required this.given,
    required this.recalled,
    required this.completed,
    required this.defect,
    required this.remaining,
  });

  /// Given minus recalled: what the worker is expected to finish.
  double get effective => given - recalled;

  double get completionRate {
    if (!hasRemainingQuantity(remaining, uom: unit) && completed > 0) {
      return 1;
    }
    return effective > 0 ? (completed / effective).clamp(0.0, 1.0) : 0.0;
  }
}

/// The cards of [result]: SAP's summary merged per worker and unit, its
/// remaining settled seat by seat unless the report was cut short. Workers
/// with work first, then by name.
List<TeamOverviewWorker> teamOverviewWorkers(
  WorkHistoryResult result, {
  Map<String, String> departmentNames = const {},
}) {
  final rows = <TeamOverviewWorker>[];
  for (final summary in mergeWorkerSummaries(result.workers)) {
    final code = summary.workerId.trim();
    final unit = summary.unitOfMeasure.trim();
    final own = result.entries
        .where((e) => e.workerId.trim().toUpperCase() == code.toUpperCase())
        .toList();
    final settled = result.isTruncated
        ? null
        : settledRemainingByUnit(own)[unit.toUpperCase()];
    final workIds = {
      for (final entry in own)
        if (entry.workId.trim().isNotEmpty) entry.workId.trim().toUpperCase(),
    };
    final department = summary.workName.trim().isNotEmpty
        ? summary.workName.trim()
        : summary.boPhan.trim().isNotEmpty
        ? summary.boPhan.trim()
        : workIds.length == 1
        ? departmentNames[workIds.single] ?? workIds.single
        : '';
    rows.add(
      TeamOverviewWorker(
        code: code,
        name: summary.workerName.trim().isEmpty
            ? code
            : summary.workerName.trim(),
        department: department,
        unit: unit,
        given: summary.assignedQuantity,
        recalled: summary.recalledQuantity,
        completed: summary.completedQuantity,
        defect: summary.defectQuantity,
        remaining: settled ?? summary.remainingQuantity,
      ),
    );
  }
  rows.sort((a, b) {
    if (a.given > 0 && b.given <= 0) return -1;
    if (a.given <= 0 && b.given > 0) return 1;
    final byName = a.name.compareTo(b.name);
    return byName != 0 ? byName : a.unit.compareTo(b.unit);
  });
  return rows;
}

class W02TeamOverviewScreen extends ConsumerStatefulWidget {
  const W02TeamOverviewScreen({super.key});

  @override
  ConsumerState<W02TeamOverviewScreen> createState() =>
      _W02TeamOverviewScreenState();
}

class _W02TeamOverviewScreenState extends ConsumerState<W02TeamOverviewScreen> {
  HistoryRange _range = HistoryRange.day;
  late Stream<WorkHistoryResult> _stream;
  WorkHistoryResult? _last;

  /// Asked of SAP: null for the whole scope, a session WorkID only when the
  /// whole report came back cut short.
  String? _requestedWorkId;

  /// Narrowed on the device; null for every department.
  String? _localWorkId;
  String _departmentLabel = 'Tất cả tổ';

  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    final active = ref.read(appStateProvider).activeWorkContext;
    final activeId = active?.workId.trim() ?? '';
    if (active != null && activeId.isNotEmpty) {
      _localWorkId = activeId;
      _departmentLabel = workContextLabel(active);
    }
    _replaceStream();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  DateTime get _to {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime get _from {
    final to = _to;
    return switch (_range) {
      HistoryRange.week => to.subtract(Duration(days: to.weekday - 1)),
      HistoryRange.month => DateTime(to.year, to.month, 1),
      _ => to,
    };
  }

  String get _rangeLabel => switch (_range) {
    HistoryRange.week => 'Tuần này',
    HistoryRange.month => 'Tháng này',
    _ => 'Hôm nay',
  };

  void _replaceStream() {
    _last = null;
    _stream = ref
        .read(appStateProvider)
        .workHistoryRepo
        .watchWorkHistory(
          range: _range,
          dateFrom: _from,
          dateTo: _to,
          workId: _requestedWorkId,
        );
  }

  Future<void> _refresh() async {
    try {
      await ref
          .read(appStateProvider)
          .workHistoryRepo
          .getWorkHistory(
            range: _range,
            dateFrom: _from,
            dateTo: _to,
            workId: _requestedWorkId,
            forceRefresh: true,
          );
    } catch (_) {
      // The stream reports the failure; keep what is on screen.
    }
    if (mounted) setState(_replaceStream);
  }

  void _selectRange(HistoryRange range) {
    if (range == _range) return;
    setState(() {
      _range = range;
      _replaceStream();
    });
  }

  void _selectDepartment(HistoryDepartmentOption? option) {
    setState(() {
      _localWorkId = option?.workId;
      _departmentLabel = option?.label ?? 'Tất cả tổ';
      final requested =
          option != null && option.inSession && _last?.isTruncated == true
          ? option.workId
          : null;
      if (requested != _requestedWorkId) {
        _requestedWorkId = requested;
        _replaceStream();
      }
    });
  }

  /// Position board for scans of a position label, kept for a minute.
  late final _seats = SeatScanLookup(
    api: () => ref.read(appStateProvider).positionGateway,
  );

  /// A scanned card: show that worker, and open their history straight away
  /// when the period holds them. A position label (or a bare code the board
  /// knows as a position) does the same for whoever sits there; an
  /// operation label opens that operation's history.
  Future<bool> _onScanned(String raw) async {
    final scan = classifyHistoryScan(raw);
    if (scan is OperationHistoryScan) {
      unawaited(openOperationHistory(context, scan, range: _range));
      return true;
    }
    final explicitPosition = isPositionLabelScan(raw);
    if (explicitPosition || scan != null) {
      final workCenter =
          ref.read(appStateProvider).activeWorkContext?.workCenter.trim() ?? '';
      final lookup = await _seats.resolve(
        raw,
        workCenter: workCenter,
        explicit: explicitPosition,
        onError: _snack,
      );
      if (!mounted) return false;
      switch (lookup) {
        case SeatLookupWorker(:final seat):
          return _showWorker(seat.workerId, name: seat.workerName);
        case SeatLookupEmpty(:final positionId):
          _snack('Vị trí $positionId chưa có công nhân nào ngồi.');
          return false;
        case SeatLookupUnknown(:final positionId):
          _snack('Vị trí $positionId chưa có trong xưởng của bạn.');
          return false;
        case null:
          if (explicitPosition) return false;
      }
    }
    if (scan == null) {
      _snack('Mã QR không phải thẻ công nhân, QR vị trí hay QR công đoạn.');
      return false;
    }
    return _showWorker((scan as WorkerHistoryScan).code);
  }

  /// Puts [code] in the search box and opens the worker when the period
  /// holds them; [name] is what the board knows, for the snack otherwise.
  bool _showWorker(String code, {String name = ''}) {
    _searchController.text = code;
    setState(() => _query = code);
    final result = _last;
    if (result == null) return true;
    final found = teamOverviewWorkers(
      result,
    ).where((w) => w.code.toUpperCase() == code.toUpperCase()).firstOrNull;
    if (found != null) {
      _openWorker(found);
    } else {
      final who = name.trim().isEmpty ? 'Công nhân $code' : '$name ($code)';
      _snack('$who không có giao dịch trong ${_rangeLabel.toLowerCase()}.');
    }
    return true;
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _openWorker(TeamOverviewWorker worker) {
    openWorkerHistory(
      context,
      code: worker.code,
      name: worker.name,
      range: _range,
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(appStateProvider).currentSession;
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
              'Tổng quan',
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
      body: BarcodeScanListener(
        // The PDA trigger finds a worker by their card.
        onScan: _onScanned,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: StreamBuilder<WorkHistoryResult>(
            stream: _stream,
            builder: (context, snapshot) {
              if (snapshot.hasData) _last = snapshot.data;
              final result = snapshot.data ?? _last;
              return CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
                    sliver: SliverToBoxAdapter(child: _buildRangeTabs()),
                  ),
                  if (result == null && snapshot.hasError)
                    SliverPadding(
                      padding: const EdgeInsets.all(18),
                      sliver: SliverToBoxAdapter(
                        child: _buildError(snapshot.error!),
                      ),
                    )
                  else if (result == null)
                    const SliverPadding(
                      padding: EdgeInsets.all(40),
                      sliver: SliverToBoxAdapter(
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    )
                  else
                    ..._buildContent(result, stale: snapshot.hasError),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildRangeTabs() {
    Widget tab(String label, HistoryRange range) {
      final selected = range == _range;
      return Expanded(
        child: InkWell(
          onTap: () => _selectRange(range),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? CaslaColors.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? CaslaColors.primaryNavy : CaslaColors.muted,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: CaslaColors.muted100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          tab('Hôm nay', HistoryRange.day),
          tab('Tuần này', HistoryRange.week),
          tab('Tháng này', HistoryRange.month),
        ],
      ),
    );
  }

  Widget _buildError(Object error) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        border: Border.all(color: CaslaColors.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Text(
            'Không tải được dữ liệu từ SAP: ${friendlySapErrorMessage(error)}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: CaslaColors.danger),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => setState(_replaceStream),
            icon: const Icon(Icons.refresh),
            label: const Text('Thử lại'),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildContent(
    WorkHistoryResult reported, {
    required bool stale,
  }) {
    final appState = ref.read(appStateProvider);
    final contexts = uniqueWorkContexts(appState.currentSession);
    final departments = historyDepartmentOptions(
      contexts: contexts,
      result: reported,
      // With a shift set up, only the departments of its work center.
      within: historyFilterWorkIds(
        reported,
        contexts,
        active: appState.activeWorkContext,
      ),
    );
    final names = {
      for (final option in departments)
        option.workId.toUpperCase(): option.name.isEmpty
            ? option.workId
            : option.name,
    };
    final narrowed = filterHistoryByWorker(
      filterHistoryByWorkId(reported, _localWorkId),
      _query,
    );
    final workers = teamOverviewWorkers(narrowed, departmentNames: names);

    final people = <String>{};
    final open = <String>{};
    var effective = 0.0;
    var confirmed = 0.0;
    for (final worker in workers) {
      effective += worker.effective;
      // "Đã xác nhận": good output and scrap together.
      confirmed += ProductionMath.confirmedQuantity(
        worker.completed,
        worker.defect,
      );
      if (worker.given > 0) people.add(worker.code.toUpperCase());
      if (hasRemainingQuantity(worker.remaining, uom: worker.unit)) {
        open.add(worker.code.toUpperCase());
      }
    }

    Widget box(Widget child, {EdgeInsets? padding}) => SliverPadding(
      padding: padding ?? const EdgeInsets.fromLTRB(18, 12, 18, 0),
      sliver: SliverToBoxAdapter(child: child),
    );

    return [
      if (stale) box(const StaleHistoryBanner()),
      if (reported.isTruncated)
        box(
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CaslaColors.pendingBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'SAP đã giới hạn số giao dịch trả về. Chọn một tổ để xem đủ.',
              style: TextStyle(color: CaslaColors.bannerText, fontSize: 11.5),
            ),
          ),
        ),
      box(
        HistoryDepartmentButton(
          label: _departmentLabel,
          onPressed: () => showHistoryDepartmentSheet(
            context,
            options: departments,
            selectedWorkId: _localWorkId,
            onSelected: _selectDepartment,
          ),
        ),
      ),
      box(
        WorkerSearchField(
          controller: _searchController,
          onChanged: (value) => setState(() => _query = value),
          onScanned: _onScanned,
        ),
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      ),
      box(
        _buildKpiPanel(
          effective: effective,
          confirmed: confirmed,
          people: people.length,
          open: open.length,
        ),
      ),
      box(
        Row(
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
            Text(
              '(${people.isEmpty ? workers.length : people.length} NV)',
              style: const TextStyle(
                fontSize: 12,
                color: CaslaColors.muted,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
      ),
      if (workers.isEmpty)
        const SliverToBoxAdapter(
          child: CaslaEmptyState(
            icon: Icons.people_outline_rounded,
            title: 'Không có nhân viên phù hợp',
            message:
                'Không tìm thấy nhân viên nào phù hợp. Thử đổi ngày, tổ hoặc từ khóa tìm kiếm.',
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 40),
          sliver: SliverList.builder(
            itemCount: workers.length,
            itemBuilder: (context, index) => _buildWorkerCard(workers[index]),
          ),
        ),
    ];
  }

  Widget _buildKpiPanel({
    required double effective,
    required double confirmed,
    required int people,
    required int open,
  }) {
    Widget metric(String label, String value) => Expanded(
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
          Text(
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
        ],
      ),
    );

    return Container(
      key: const Key('team-overview-kpi'),
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
                metric('Giao hiệu lực', formatQuantity(effective)),
                const SizedBox(width: 14),
                Container(width: 1, height: 46, color: CaslaColors.line),
                const SizedBox(width: 14),
                metric('Đã xác nhận', formatQuantity(confirmed)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            color: CaslaColors.background,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$people NV được giao',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: CaslaColors.navy900,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '$open NV còn việc',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: CaslaColors.navy900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Same badge as the supervisor's overview.
  static (String, String) _progressBadge(TeamOverviewWorker worker) {
    if (worker.given == 0) return ('OPEN', 'CHƯA GIAO');
    if (!hasRemainingQuantity(worker.remaining, uom: worker.unit)) {
      // Nothing left, yet nothing was finished: all of it came back.
      if (worker.completed <= 0 && worker.recalled > 0) {
        return ('RECALLED', 'THU HỒI HOÀN TOÀN');
      }
      return ('COMPLETED', 'HOÀN THÀNH');
    }
    return ('PENDING', 'ĐANG THỰC HIỆN');
  }

  /// Bar value and colour matching the badge: a closed-out worker reads
  /// full — green when finished, red when everything was recalled.
  static (double, Color) _progressBar(
    String status,
    TeamOverviewWorker worker,
  ) => switch (status) {
    'COMPLETED' => (1.0, CaslaColors.success),
    'RECALLED' => (1.0, CaslaColors.danger),
    _ => (worker.completionRate, CaslaColors.accentGold),
  };

  /// Good output and scrap as shares of the track, as on the overview.
  static (double, double) _progressShares(
    String status,
    TeamOverviewWorker worker,
    double fallback,
  ) {
    final made = worker.completed + worker.defect;
    final whole = status == 'COMPLETED' || made > worker.effective
        ? made
        : worker.effective;
    if (status == 'RECALLED' || whole <= 0 || worker.defect <= 0) {
      return (fallback, 0);
    }
    return (
      (worker.completed / whole).clamp(0.0, 1.0),
      (worker.defect / whole).clamp(0.0, 1.0),
    );
  }

  /// One of five equal columns (Giao · Thu hồi · Hoàn thành · Phế · Còn
  /// lại), scaled down so a 5-digit quantity still fits a phone width.
  static Widget _statItem(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              maxLines: 1,
              style: const TextStyle(
                fontSize: 12,
                color: CaslaColors.muted,
                fontWeight: FontWeight.w600,
              ),
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
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 17,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkerCard(TeamOverviewWorker worker) {
    final (status, badge) = _progressBadge(worker);
    final bar = _progressBar(status, worker);
    final shares = _progressShares(status, worker, bar.$1);
    String qty(double value) => formatQuantity(value, uom: worker.unit);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: CaslaColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: Key('team-worker-${worker.code}-${worker.unit}'),
          onTap: () => _openWorker(worker),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border.all(color: CaslaColors.line),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            worker.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Manrope',
                              fontWeight: FontWeight.w700,
                              fontSize: 14.5,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              worker.code,
                              if (worker.department.isNotEmpty)
                                worker.department,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              color: CaslaColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    StatusChip(status: status, label: badge),
                  ],
                ),
                const SizedBox(height: 12),
                _WorkerProgressBar(
                  completed: shares.$1,
                  defect: shares.$2,
                  color: bar.$2,
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _statItem('Giao', qty(worker.given)),
                    _statItem('Thu hồi', qty(worker.recalled)),
                    _statItem('Hoàn thành', qty(worker.completed)),
                    _statItem('Phế', qty(worker.defect)),
                    _statItem('Còn lại', qty(worker.remaining)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A worker's progress: good output in [color], then scrap, on one track —
/// the bar of the supervisor's overview.
class _WorkerProgressBar extends StatelessWidget {
  /// Shares of the whole track, 0 to 1.
  final double completed;
  final double defect;
  final Color color;

  const _WorkerProgressBar({
    required this.completed,
    required this.defect,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    // Integer flex; thousandths keep a small share of scrap visible.
    final scrap = defect <= 0 ? 0 : (defect * 1000).ceil().clamp(1, 1000);
    final done = (completed * 1000).round().clamp(0, 1000 - scrap);
    final rest = 1000 - done - scrap;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 7,
        child: ColoredBox(
          color: CaslaColors.muted100,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (done > 0)
                Expanded(
                  flex: done,
                  child: ColoredBox(color: color),
                ),
              if (scrap > 0)
                Expanded(
                  flex: scrap,
                  child: const ColoredBox(color: CaslaColors.scrap),
                ),
              if (rest > 0) Spacer(flex: rest),
            ],
          ),
        ),
      ),
    );
  }
}
