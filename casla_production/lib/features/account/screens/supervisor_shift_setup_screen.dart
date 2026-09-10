import 'package:flutter/material.dart';

import '../../../app/theme/casla_spacing.dart';
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

  const SupervisorShiftSetupScreen({super.key, this.returnToPrevious = false});

  @override
  ConsumerState<SupervisorShiftSetupScreen> createState() =>
      _SupervisorShiftSetupScreenState();
}

class _SupervisorShiftSetupScreenState
    extends ConsumerState<SupervisorShiftSetupScreen> {
  String? _selectedPlant;
  UserWorkContext? _work;
  SapShift? _shift;
  DateTime _date = DateTime.now();
  List<SapShift> _shifts = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    final appState = ref.read(appStateProvider);
    final session = appState.currentSession;
    final contexts = session?.workContexts ?? const <UserWorkContext>[];
    final savedWorkId = appState.activeWorkContext?.workId;
    _work =
        _findWorkContext(contexts, savedWorkId) ??
        (contexts.isEmpty ? null : contexts.first);
    _selectedPlant = _work?.plant;
    _date = appState.activeBusinessDate;
    _shift = appState.activeShift;
    _loadShifts();
  }

  Future<void> _loadShifts() async {
    final requestGeneration = ++_loadGeneration;
    final work = _work;
    if (work == null) {
      setState(() {
        _loading = false;
        _error = 'Tài khoản chưa được cấp vị trí làm việc trên SAP.';
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
          .getShifts(plant: work.plant, onDate: _date);
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

  List<String> _plants(List<UserWorkContext> contexts) {
    final plants = contexts
        .map((context) => context.plant.trim())
        .where((plant) => plant.isNotEmpty)
        .toSet()
        .toList();
    plants.sort();
    return plants;
  }

  List<UserWorkContext> _workCentersFor(
    List<UserWorkContext> contexts,
    String? plant,
  ) => plant == null
      ? const []
      : contexts
            .where((context) => context.plant == plant)
            .toList(growable: false);

  void _selectPlant(String? plant) {
    if (plant == null || plant == _selectedPlant) return;
    // Invalidates an in-flight request for the previous plant immediately.
    _loadGeneration++;
    setState(() {
      _selectedPlant = plant;
      _work = null;
      _shift = null;
      _shifts = const [];
      _loading = false;
      _error = null;
    });
  }

  void _selectWorkCenter(UserWorkContext? work) {
    if (work == null) return;
    setState(() {
      _work = work;
      _shift = null;
    });
    _loadShifts();
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
    context.go(
      '/supervisor',
      extra: allowIncompleteSetup ? _skipSupervisorSetupExtra : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final contexts =
        ref.read(appStateProvider).currentSession?.workContexts ??
        const <UserWorkContext>[];
    final currentWork = _findWorkContext(contexts, _work?.workId);
    if (_work != null && currentWork == null) {
      _work = null;
      _shift = null;
    } else if (currentWork != null && !identical(currentWork, _work)) {
      _work = currentWork;
      _selectedPlant = currentWork.plant;
    }
    final plants = _plants(contexts);
    final workCenters = _workCentersFor(contexts, _selectedPlant);
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
                  fontSize: CaslaType.title,
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
                subtitle: 'Work Center được lọc theo nhà máy đã chọn.',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _selectedPlant,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Nhà máy'),
                items: [
                  for (final plant in plants)
                    DropdownMenuItem(value: plant, child: Text(plant)),
                ],
                onChanged: _saving ? null : _selectPlant,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<UserWorkContext>(
                initialValue: _work,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Work Center',
                  helperText: _selectedPlant == null
                      ? 'Chọn Nhà máy trước.'
                      : 'Chỉ hiển thị Work Center thuộc Nhà máy đã chọn.',
                ),
                items: [
                  for (final item in workCenters)
                    DropdownMenuItem(
                      value: item,
                      child: Text(
                        item.workName.isEmpty
                            ? item.workCenter
                            : '${item.workCenter} · ${item.workName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _saving || _selectedPlant == null
                    ? null
                    : _selectWorkCenter,
              ),
              const SizedBox(height: 16),
              const _SetupSection(
                number: '02',
                title: 'Ngày và ca',
                subtitle: 'Với ca đêm, chọn ngày bắt đầu ca.',
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: _saving ? null : _pickDate,
                borderRadius: BorderRadius.circular(CaslaRadius.sm),
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
                  'Chưa có ca phù hợp. Hãy chọn Work Center và kiểm tra ngày làm việc.',
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
                      _shift == null || _loading || _saving || _error != null
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
          borderRadius: BorderRadius.circular(CaslaRadius.md),
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
                fontSize: CaslaType.subtitle,
                fontWeight: FontWeight.w700,
                color: CaslaColors.primaryNavy,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: CaslaType.body,
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
