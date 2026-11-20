// Danh mục máy: the third view of S14 (Vị trí & công nhân), read only.
//
// Every machine active in SAP's catalog (getMachines), with the position it
// is attached to and the worker seated there. The supervisor finds a machine
// by typing or by scanning its label; the parent screen owns the reader and
// the camera and hands every scan to [MachineCatalogViewState.handleScan].
// A scan of a known machine opens its detail; an unknown code is reported
// and nothing else happens. Nothing here writes to SAP.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';
import '../../../data/sap/sap_position_gateway.dart';
import '../../../domain/entities/worker_position.dart';
import '../../../domain/policies/machine_catalog_policy.dart';
import '../../../main.dart';
import '../../../presentation/widgets/scan_status_strip.dart';
import '../position_error_text.dart';
import 'compact_filter_chip.dart';

class MachineCatalogView extends ConsumerStatefulWidget {
  /// Overrides for tests; production reads these from AppState.
  final PositionApi? api;
  final String? workCenter;

  /// Opens the camera; the parent feeds what it reads to
  /// [MachineCatalogViewState.handleScan].
  final VoidCallback? onScan;

  const MachineCatalogView({super.key, this.api, this.workCenter, this.onScan});

  @override
  ConsumerState<MachineCatalogView> createState() => MachineCatalogViewState();
}

class MachineCatalogViewState extends ConsumerState<MachineCatalogView> {
  final _search = TextEditingController();

  MachineCatalog? _catalog;
  bool _loading = true;
  String? _loadError;
  int _request = 0;

  String _query = '';
  MachineFilter _filter = MachineFilter.all;
  bool _isDialogOpen = false;
  String? _scanError;

  /// Machine the last scan found, outlined in the list.
  String? _highlightId;

  PositionApi get _api =>
      widget.api ?? ref.read(appStateProvider).positionGateway;

  String get _workCenter =>
      (widget.workCenter ??
              ref.read(appStateProvider).activeWorkContext?.workCenter ??
              '')
          .trim()
          .toUpperCase();

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      // The board is only a fallback for the worker columns (backend older
      // than 2026-11-05); the catalog alone is enough to show the list.
      final results = await Future.wait<Object?>([
        _api.getMachines(),
        _api.getBoard().then<Object?>((b) => b).catchError((_) => null),
      ]);
      if (!mounted || request != _request) return;
      final board = results[1];
      setState(() {
        _catalog = attachBoardWorkers(
          results[0]! as MachineCatalog,
          board is PositionBoard ? board : null,
        );
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _loadError = describePositionError(error);
      });
    }
  }

  // ─── Scanning ────────────────────────────────────────────────────

  /// A trigger pull, a camera read or a manual code. Returns false when the
  /// payload is not a machine of the catalog, so the operator hears the
  /// failure tone.
  Future<bool> handleScan(String raw) async {
    if (_isDialogOpen) return false;
    final code = parseMachineScan(raw);
    if (code == null) {
      _fail('Mã quét không phải nhãn máy. Quét nhãn dán trên máy.');
      return false;
    }
    final catalog = _catalog;
    if (catalog == null) {
      _fail('Chưa tải được danh mục máy. Tải lại rồi quét tiếp.');
      return false;
    }
    final machine = catalog.byId(code);
    if (machine == null) {
      _fail(
        'Máy $code không có trong danh mục đang dùng. Báo quản trị thêm máy '
        'trên Fiori nếu đây là máy mới.',
      );
      return false;
    }
    _search.text = machine.machineId;
    setState(() {
      _scanError = null;
      _query = machine.machineId;
      _filter = MachineFilter.all;
      _highlightId = machine.machineId;
    });
    unawaited(_showDetail(machine));
    return true;
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _scanError = message);
  }

  Future<void> _showDetail(MachineOption machine) async {
    if (_isDialogOpen) return;
    _isDialogOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: CaslaColors.surface,
        showDragHandle: true,
        builder: (context) =>
            _MachineDetailSheet(machine: machine, workCenter: _workCenter),
      );
    } finally {
      _isDialogOpen = false;
    }
  }

  // ─── UI ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final machines = _catalog?.machines ?? const <MachineOption>[];
    final summary = summarizeMachines(machines);
    final visible = filterMachines(machines, query: _query, filter: _filter);
    final severalWorkCenters =
        {
          for (final m in machines.where((m) => m.isInUse)) m.workCenter,
        }.length >
        1;

    return Column(
      children: [
        if (_scanError != null)
          ScanErrorBanner(
            message: _scanError!,
            onDismiss: () => setState(() => _scanError = null),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: reload,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                PinnedHeaderSliver(
                  child: FilterHeader(
                    children: [
                      TextField(
                        controller: _search,
                        textCapitalization: TextCapitalization.characters,
                        textInputAction: TextInputAction.search,
                        onChanged: (value) => setState(() {
                          _query = value;
                          _highlightId = null;
                        }),
                        decoration: InputDecoration(
                          hintText: 'Tìm mã máy, tên máy, vị trí',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _query.isEmpty
                              ? (widget.onScan == null
                                    ? null
                                    : IconButton(
                                        tooltip: 'Quét mã máy',
                                        onPressed: widget.onScan,
                                        icon: const Icon(Icons.qr_code_scanner),
                                      ))
                              : IconButton(
                                  tooltip: 'Xóa nội dung tìm kiếm',
                                  onPressed: () {
                                    _search.clear();
                                    setState(() {
                                      _query = '';
                                      _highlightId = null;
                                    });
                                  },
                                  icon: const Icon(Icons.close),
                                ),
                        ),
                      ),
                      const SizedBox(height: CaslaSpacing.xs),
                      CompactFilterRow(
                        children: [
                          _filterChip(
                            MachineFilter.all,
                            'Tất cả · ${summary.total}',
                          ),
                          for (final filter in MachineFilter.values)
                            if (filter.status case final status?)
                              _filterChip(
                                filter,
                                '${status.title} · ${summary.count(status)}',
                              ),
                        ],
                      ),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    CaslaSpacing.md,
                    CaslaSpacing.sm,
                    CaslaSpacing.md,
                    96,
                  ),
                  sliver: SliverList.list(
                    children: _listBody(machines, visible, severalWorkCenters),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _listBody(
    List<MachineOption> all,
    List<MachineOption> visible,
    bool severalWorkCenters,
  ) {
    if (_catalog == null && _loading) {
      return const [
        Padding(
          padding: EdgeInsets.all(CaslaSpacing.xl),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    final error = _loadError;
    if (_catalog == null && error != null) {
      return [
        _Notice(
          icon: Icons.cloud_off_rounded,
          text: 'Chưa tải được danh mục máy: $error',
          action: TextButton(onPressed: reload, child: const Text('Thử lại')),
        ),
      ];
    }
    if (visible.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(CaslaSpacing.xl),
          child: Text(
            all.isEmpty
                ? 'Danh mục chưa có máy nào đang dùng. Báo quản trị thêm máy '
                      'trên Fiori trước.'
                : _query.trim().isEmpty
                ? 'Không có máy nào khớp bộ lọc.'
                : 'Không có máy nào khớp "${_query.trim()}".',
            textAlign: TextAlign.center,
            style: const TextStyle(color: CaslaColors.muted, height: 1.4),
          ),
        ),
      ];
    }
    return [
      for (final machine in visible)
        _MachineCard(
          machine: machine,
          highlighted: machine.machineId == _highlightId,
          // Own Work Center reads as just the position, like the picker on
          // Quét gán; any other one is named. Without a Work Center in
          // context, name them only when the catalog spans several.
          showWorkCenter: _workCenter.isEmpty
              ? severalWorkCenters
              : !_same(machine.workCenter, _workCenter),
          onTap: () => _showDetail(machine),
        ),
    ];
  }

  Widget _filterChip(MachineFilter filter, String label) => CompactFilterChip(
    label: label,
    selected: _filter == filter,
    onSelected: () => setState(() => _filter = filter),
  );
}

bool _same(String a, String b) =>
    a.trim().toUpperCase() == b.trim().toUpperCase();

/// Where a machine is, for a row or the detail: `A-01` in the supervisor's
/// own Work Center, `A-01 · xưởng CL100078` elsewhere.
String _placeLabel(MachineOption machine, {required bool showWorkCenter}) =>
    showWorkCenter && machine.workCenter.isNotEmpty
    ? '${machine.positionId} · xưởng ${machine.workCenter}'
    : machine.positionId;

class _MachineCard extends StatelessWidget {
  final MachineOption machine;
  final bool highlighted;
  final bool showWorkCenter;
  final VoidCallback onTap;

  const _MachineCard({
    required this.machine,
    required this.highlighted,
    required this.showWorkCenter,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = machine.machineName.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: CaslaSpacing.xs),
      child: Material(
        color: highlighted ? CaslaColors.gold100 : CaslaColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CaslaRadius.md),
          side: BorderSide(
            color: highlighted ? CaslaColors.accentGold : CaslaColors.line,
            width: highlighted ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(CaslaRadius.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              CaslaSpacing.sm,
              CaslaSpacing.sm,
              CaslaSpacing.xs,
              CaslaSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty
                            ? machine.machineId
                            : '${machine.machineId} · $name',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Manrope',
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: CaslaColors.primaryNavy,
                        ),
                      ),
                      const SizedBox(height: 2),
                      _IconLine(
                        icon: Icons.place_outlined,
                        text: machine.isInUse
                            ? 'Vị trí ${_placeLabel(machine, showWorkCenter: showWorkCenter)}'
                            : 'Chưa gắn vị trí nào',
                        quiet: !machine.isInUse,
                      ),
                      _IconLine(
                        icon: Icons.badge_outlined,
                        text: machine.isOccupied
                            ? '${machine.workerLabel} · ${machine.workerId}'
                            : machine.isInUse
                            ? 'Vị trí chưa có công nhân'
                            : 'Không có công nhân',
                        quiet: !machine.isOccupied,
                      ),
                    ],
                  ),
                ),
                _StatusChip(status: machineStatusOf(machine)),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: CaslaColors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool quiet;

  const _IconLine({
    required this.icon,
    required this.text,
    required this.quiet,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 14, color: CaslaColors.muted),
      const SizedBox(width: 4),
      Expanded(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            color: CaslaColors.muted,
            fontStyle: quiet ? FontStyle.italic : FontStyle.normal,
          ),
        ),
      ),
    ],
  );
}

class _StatusChip extends StatelessWidget {
  final MachineStatus status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (status) {
      MachineStatus.active => (CaslaColors.successBg, CaslaColors.success),
      MachineStatus.missingWorker => (
        CaslaColors.pendingBg,
        CaslaColors.pending,
      ),
      MachineStatus.unassigned => (CaslaColors.muted100, CaslaColors.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(CaslaRadius.pill),
      ),
      child: Text(
        status.title,
        style: TextStyle(
          fontSize: CaslaType.caption,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}

class _MachineDetailSheet extends StatelessWidget {
  final MachineOption machine;
  final String workCenter;

  const _MachineDetailSheet({required this.machine, required this.workCenter});

  @override
  Widget build(BuildContext context) {
    final name = machine.machineName.trim();
    final elsewhere =
        machine.isInUse &&
        workCenter.isNotEmpty &&
        !_same(machine.workCenter, workCenter);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          CaslaSpacing.lg,
          0,
          CaslaSpacing.lg,
          CaslaSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Chi tiết máy',
              style: TextStyle(
                fontSize: CaslaType.caption,
                color: CaslaColors.muted,
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    machine.machineId,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: CaslaType.title,
                      fontWeight: FontWeight.w800,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                ),
                _StatusChip(status: machineStatusOf(machine)),
              ],
            ),
            if (name.isNotEmpty)
              Text(
                name,
                style: const TextStyle(
                  fontSize: CaslaType.body,
                  color: CaslaColors.muted,
                ),
              ),
            const SizedBox(height: CaslaSpacing.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(CaslaSpacing.sm),
              decoration: BoxDecoration(
                color: CaslaColors.background,
                borderRadius: BorderRadius.circular(CaslaRadius.md),
              ),
              child: Column(
                children: [
                  _InfoLine('Mã máy', machine.machineId),
                  name.isEmpty
                      ? const _InfoLine('Tên máy', 'Chưa đặt tên', quiet: true)
                      : _InfoLine('Tên máy', name),
                  machine.isInUse
                      ? _InfoLine('Xưởng', machine.workCenter)
                      : const _InfoLine('Xưởng', 'Chưa gắn', quiet: true),
                  machine.isInUse
                      ? _InfoLine('Vị trí', machine.positionId)
                      : const _InfoLine(
                          'Vị trí',
                          'Chưa gắn vị trí nào',
                          quiet: true,
                        ),
                  machine.isOccupied
                      ? _InfoLine(
                          'Công nhân',
                          '${machine.workerLabel} · ${machine.workerId}',
                        )
                      : _InfoLine(
                          'Công nhân',
                          machine.isInUse
                              ? 'Vị trí chưa có công nhân'
                              : 'Không có công nhân',
                          quiet: true,
                        ),
                  _InfoLine('Trạng thái', switch (machineStatusOf(machine)) {
                    MachineStatus.active =>
                      'Hoạt động: có vị trí, có công nhân',
                    MachineStatus.missingWorker =>
                      'Thiếu CN: vị trí ${machine.positionId} chưa có '
                          'công nhân',
                    MachineStatus.unassigned => 'Chưa bố trí: chưa gán vị trí',
                  }),
                ],
              ),
            ),
            if (elsewhere) ...[
              const SizedBox(height: CaslaSpacing.sm),
              _Notice(
                icon: Icons.swap_horiz_rounded,
                text:
                    'Máy đang gắn ở xưởng ${machine.workCenter}. Gắn máy này '
                    'ở xưởng khác thì máy được chuyển sang, vị trí cũ trống '
                    'mã máy. Nếu xưởng ${machine.workCenter} ngoài phạm vi '
                    'quyền của bạn thì SAP từ chối (MACHINE_IN_USE).',
              ),
            ],
            const SizedBox(height: CaslaSpacing.md),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Đóng'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final String label;
  final String value;
  final bool quiet;

  const _InfoLine(this.label, this.value, {this.quiet = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: CaslaColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: CaslaType.body,
              fontWeight: quiet ? FontWeight.w400 : FontWeight.w700,
              fontStyle: quiet ? FontStyle.italic : FontStyle.normal,
              color: quiet ? CaslaColors.muted : CaslaColors.primaryNavy,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const _Notice({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(CaslaSpacing.sm),
    decoration: BoxDecoration(
      color: CaslaColors.pendingBg,
      borderRadius: BorderRadius.circular(CaslaRadius.md),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: CaslaColors.pending),
            const SizedBox(width: CaslaSpacing.xs),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 13,
                  color: CaslaColors.pending,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
        if (action != null)
          Align(alignment: Alignment.centerRight, child: action),
      ],
    ),
  );
}
