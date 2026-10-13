import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../data/sap/sap_shift_controller.dart';
import '../../../domain/entities/entities.dart';
import '../../../main.dart';
import '../../../presentation/widgets/casla_skeleton.dart';

const _skipSupervisorSetupExtra = 'skip-supervisor-setup';

class SupervisorShiftSetupScreen extends ConsumerStatefulWidget {
  final bool returnToPrevious;

  /// Where the operator was headed when the router sent them here.
  final String? next;

  const SupervisorShiftSetupScreen({
    super.key,
    this.returnToPrevious = false,
    this.next,
  });

  @override
  ConsumerState<SupervisorShiftSetupScreen> createState() =>
      _SupervisorShiftSetupScreenState();
}

class _SupervisorShiftSetupScreenState
    extends ConsumerState<SupervisorShiftSetupScreen> {
  /// Selected Xưởng (SAP Work Center). Shifts are configured per Work Center.
  String? _selectedWorkCenter;
  UserWorkContext? _work;
  SapShift? _shift;
  DateTime _date = DateTime.now();
  List<SapShift> _shifts = const [];
  bool _loading = true;
  bool _initializing = true;
  bool _saving = false;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final appState = ref.read(appStateProvider);
    var session = appState.currentSession;
    var contexts = session?.workContexts ?? const <UserWorkContext>[];
    if (session != null &&
        session.refreshToken.trim().isNotEmpty &&
        (contexts.isEmpty ||
            contexts.any((context) => context.workCenter.trim().isEmpty))) {
      await appState.refreshWorkContexts();
      if (!mounted) return;
      session = appState.currentSession;
      contexts = session?.workContexts ?? const <UserWorkContext>[];
    }
    if (!mounted) return;
    final savedWorkId = appState.activeWorkContext?.workId;
    _work =
        _findWorkContext(contexts, savedWorkId) ??
        contexts
            .where((context) => context.workCenter.trim().isNotEmpty)
            .firstOrNull;
    _selectedWorkCenter = _work?.workCenter.trim();
    _date = appState.activeBusinessDate;
    _shift = appState.activeShift;
    setState(() => _initializing = false);
    await _loadShifts();
  }

  Future<void> _loadShifts() async {
    final requestGeneration = ++_loadGeneration;
    final workCenter = _selectedWorkCenter;
    if (workCenter == null || workCenter.isEmpty) {
      setState(() {
        _loading = false;
        _shifts = const [];
        _shift = null;
        _error = 'Tài khoản chưa được cấp Xưởng làm việc trên SAP.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final shifts = await ref
          .read(appStateProvider)
          .shiftController
          .getShifts(workCenter: workCenter, onDate: _date);
      if (!mounted || requestGeneration != _loadGeneration) return;
      setState(() {
        _shifts = shifts;
        final savedShiftId = _shift?.shiftId;
        _shift = shifts
            .where((item) => item.shiftId == savedShiftId)
            .firstOrNull;
        _shift ??= shifts.isEmpty ? null : shifts.first;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || requestGeneration != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  UserWorkContext? _findWorkContext(
    List<UserWorkContext> contexts,
    String? workId,
  ) {
    if (workId == null) return null;
    for (final context in contexts) {
      if (context.workId == workId) return context;
    }
    return null;
  }

  List<String> _workCenters(List<UserWorkContext> contexts) {
    final workCenters = contexts
        .map((context) => context.workCenter.trim())
        .where((workCenter) => workCenter.isNotEmpty)
        .toSet()
        .toList();
    workCenters.sort();
    return workCenters;
  }

  String _workCenterLabel(String workCenter, List<UserWorkContext> contexts) {
    final name = contexts
        .where((context) => context.workCenter.trim() == workCenter)
        .map((context) => context.workCenterDisplayName)
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    return name.isEmpty ? workCenter : '$workCenter ($name)';
  }

  List<UserWorkContext> _departmentsFor(
    List<UserWorkContext> contexts,
    String? workCenter,
  ) => workCenter == null
      ? const []
      : contexts
            .where((context) => context.workCenter.trim() == workCenter)
            .toList(growable: false);

  void _selectWorkCenter(String? workCenter) {
    if (workCenter == null || workCenter == _selectedWorkCenter) return;
    final departments = _departmentsFor(
      ref.read(appStateProvider).currentSession?.workContexts ?? const [],
      workCenter,
    );
    setState(() {
      _selectedWorkCenter = workCenter;
      // A Xưởng with a single Bộ phận needs no second pick.
      _work = departments.length == 1 ? departments.single : null;
      _shift = null;
      _shifts = const [];
    });
    _loadShifts();
  }

  // Bộ phận of the same Xưởng share its shifts: keep the list and the choice.
  void _selectDepartment(UserWorkContext? work) {
    if (work == null) return;
    setState(() => _work = work);
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(today.year, today.month, today.day),
      initialDate: _date.isAfter(today) ? today : _date,
    );
    if (picked == null) return;
    setState(() {
      _date = picked;
      _shift = null;
    });
    await _loadShifts();
  }

  Future<void> _continue() async {
    final work = _work;
    final shift = _shift;
    if (work == null || shift == null || _loading || _saving) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(appStateProvider)
          .completeSupervisorSetup(
            workContext: work,
            shift: shift,
            businessDate: _date,
          );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Không thể lưu lựa chọn ca trên thiết bị. Hãy thử lại.',
          ),
          backgroundColor: CaslaColors.danger,
        ),
      );
      return;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    _leaveSetup();
  }

  void _leaveSetup({bool allowIncompleteSetup = false}) {
    if (widget.returnToPrevious && context.canPop()) {
      context.pop();
      return;
    }
    if (allowIncompleteSetup) {
      context.go('/supervisor', extra: _skipSupervisorSetupExtra);
      return;
    }
    context.go(widget.next ?? '/supervisor');
  }

  @override
  Widget build(BuildContext context) {
    final contexts =
        ref.watch(appStateProvider).currentSession?.workContexts ??
        const <UserWorkContext>[];
    final currentWork = _findWorkContext(contexts, _work?.workId);
    if (_work != null && currentWork == null) {
      _work = null;
      _shift = null;
    } else if (currentWork != null && !identical(currentWork, _work)) {
      _work = currentWork;
      _selectedWorkCenter ??= currentWork.workCenter.trim();
    }
    final workCenters = _workCenters(contexts);
    final departments = _departmentsFor(contexts, _selectedWorkCenter);
    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        title: const Text('Thiết lập ca làm việc'),
        actions: [
          Semantics(
            button: true,
            label: 'Đóng thiết lập ca làm việc',
            child: IconButton(
              tooltip: 'Đóng',
              icon: const Icon(Icons.close),
              onPressed: () => _leaveSetup(allowIncompleteSetup: true),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Sẵn sàng cho ca làm',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Chọn nơi làm việc, ngày và ca. Lựa chọn được lưu trên thiết bị để dùng cho các thao tác tiếp theo.',
                style: TextStyle(color: CaslaColors.muted),
              ),
              const SizedBox(height: 24),
              const _SetupSection(
                number: '01',
                title: 'Nơi làm việc',
                subtitle: 'Bộ phận được lọc theo Xưởng đã chọn.',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _selectedWorkCenter,
                isExpanded: true,
                isDense: false,
                itemHeight: null,
                decoration: const InputDecoration(labelText: 'Xưởng'),
                items: [
                  for (final workCenter in workCenters)
                    DropdownMenuItem(
                      value: workCenter,
                      child: Text(_workCenterLabel(workCenter, contexts)),
                    ),
                ],
                onChanged: _initializing || _saving ? null : _selectWorkCenter,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<UserWorkContext>(
                initialValue: _work,
                isExpanded: true,
                isDense: false,
                itemHeight: null,
                decoration: InputDecoration(
                  labelText: 'Bộ phận',
                  helperText: _selectedWorkCenter == null
                      ? 'Chọn Xưởng trước.'
                      : 'Chỉ hiển thị Bộ phận thuộc Xưởng đã chọn.',
                ),
                items: [
                  for (final item in departments)
                    DropdownMenuItem(
                      value: item,
                      child: Text(item.departmentLabel),
                    ),
                ],
                onChanged:
                    _initializing || _saving || _selectedWorkCenter == null
                    ? null
                    : _selectDepartment,
              ),
              const SizedBox(height: 16),
              const _SetupSection(
                number: '02',
                title: 'Ngày và ca',
                subtitle: 'Với ca đêm, chọn ngày bắt đầu ca.',
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: _initializing || _saving ? null : _pickDate,
                borderRadius: BorderRadius.circular(8),
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Ngày làm việc'),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(DateFormat('dd/MM/yyyy').format(_date)),
                      const Icon(Icons.calendar_today_outlined),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_loading)
                Semantics(
                  label: 'Đang tải danh sách ca làm việc',
                  child: const CaslaSkeleton(height: 64, radius: 12),
                )
              else if (_error != null) ...[
                Text(
                  _error!,
                  style: const TextStyle(color: CaslaColors.danger),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _saving ? null : _loadShifts,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Tải lại danh mục ca'),
                ),
              ] else if (_shifts.isEmpty)
                const Text(
                  'Chưa có ca phù hợp. Hãy kiểm tra Xưởng và ngày làm việc.',
                  style: TextStyle(color: CaslaColors.muted),
                )
              else
                DropdownButtonFormField<SapShift>(
                  initialValue: _shift,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Ca làm việc'),
                  items: [
                    for (final shift in _shifts)
                      DropdownMenuItem(
                        value: shift,
                        child: Text(
                          '${shift.shiftName} · ${shift.timeLabel}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _shift = value),
                ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      _work == null ||
                          _shift == null ||
                          _loading ||
                          _saving ||
                          _error != null
                      ? null
                      : _continue,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Tiếp tục'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SetupSection extends StatelessWidget {
  final String number;
  final String title;
  final String subtitle;
  const _SetupSection({
    required this.number,
    required this.title,
    required this.subtitle,
  });
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: CaslaColors.navy100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          number,
          style: const TextStyle(
            color: CaslaColors.primaryNavy,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: CaslaColors.primaryNavy,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 13,
                height: 1.4,
                color: CaslaColors.muted,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
