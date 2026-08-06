import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';
import '../../../presentation/widgets/kpi_card.dart';
import '../../../presentation/widgets/status_chip.dart';

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

  // Filter States
  String _selectedTeamId = 'ALL'; // 'ALL', 'team-1', 'team-2', 'team-3'
  String _selectedTeamLabel = 'Tổ: Tất cả';

  String _selectedShift = 'ALL'; // 'ALL', 'SHIFT_1', 'SHIFT_2', 'SHIFT_3'
  String _selectedShiftLabel = 'Ca ngày';

  DateTime _selectedDate = DateTime.now();

  String _dateStr(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
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

  void _showTeamFilterSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Lọc theo Tổ sản xuất',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                title: const Text('Tất cả các tổ'),
                selected: _selectedTeamId == 'ALL',
                onTap: () {
                  setState(() {
                    _selectedTeamId = 'ALL';
                    _selectedTeamLabel = 'Tổ: Tất cả';
                  });
                  Navigator.pop(context);
                },
              ),
              ListTile(
                title: const Text('Tổ Cắt 1'),
                selected: _selectedTeamId == 'team-1',
                onTap: () {
                  setState(() {
                    _selectedTeamId = 'team-1';
                    _selectedTeamLabel = 'Tổ Cắt 1';
                  });
                  Navigator.pop(context);
                },
              ),
              ListTile(
                title: const Text('Tổ Cắt 2'),
                selected: _selectedTeamId == 'team-2',
                onTap: () {
                  setState(() {
                    _selectedTeamId = 'team-2';
                    _selectedTeamLabel = 'Tổ Cắt 2';
                  });
                  Navigator.pop(context);
                },
              ),
              ListTile(
                title: const Text('Tổ Cắt 3'),
                selected: _selectedTeamId == 'team-3',
                onTap: () {
                  setState(() {
                    _selectedTeamId = 'team-3';
                    _selectedTeamLabel = 'Tổ Cắt 3';
                  });
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showShiftFilterSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Lọc theo Ca làm việc',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                title: const Text('Tất cả các ca'),
                selected: _selectedShift == 'ALL',
                onTap: () {
                  setState(() {
                    _selectedShift = 'ALL';
                    _selectedShiftLabel = 'Tất cả ca';
                  });
                  Navigator.pop(context);
                },
              ),
              ListTile(
                title: const Text('Ca ngày (06:00 – 14:00)'),
                selected: _selectedShift == 'SHIFT_1',
                onTap: () {
                  setState(() {
                    _selectedShift = 'SHIFT_1';
                    _selectedShiftLabel = 'Ca ngày';
                  });
                  Navigator.pop(context);
                },
              ),
              ListTile(
                title: const Text('Ca chiều (14:00 – 22:00)'),
                selected: _selectedShift == 'SHIFT_2',
                onTap: () {
                  setState(() {
                    _selectedShift = 'SHIFT_2';
                    _selectedShiftLabel = 'Ca chiều';
                  });
                  Navigator.pop(context);
                },
              ),
              ListTile(
                title: const Text('Ca đêm (22:00 – 06:00)'),
                selected: _selectedShift == 'SHIFT_3',
                onTap: () {
                  setState(() {
                    _selectedShift = 'SHIFT_3';
                    _selectedShiftLabel = 'Ca đêm';
                  });
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showDatePickerDialog() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2026, 1, 1),
      lastDate: DateTime(2027, 12, 31),
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final emp = appState.currentSession;
    final supervisorName = emp?.userName ?? 'Trần Thị B';

    final effectiveTeamIds = _selectedTeamId == 'ALL'
        ? (emp?.toIds ?? ['team-1', 'team-2', 'team-3'])
        : [_selectedTeamId];

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(70),
        child: Container(
          color: CaslaColors.primaryNavy,
          padding: const EdgeInsets.fromLTRB(18, 36, 18, 12),
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
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: const Color(0xFF26305C),
                            borderRadius: BorderRadius.circular(10),
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
                              fontSize: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              supervisorName,
                              style: const TextStyle(
                                fontFamily: 'Manrope',
                                fontWeight: FontWeight.w700,
                                fontSize: 14.5,
                                color: Colors.white,
                              ),
                            ),
                            const Text(
                              'Supervisor · Tổ Cắt 1–3',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                color: CaslaColors.identityMeta,
                              ),
                            ),
                          ],
                        ),
                      ],
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
        ),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: appState.db.watchAssignmentsByTeams(effectiveTeamIds),
        builder: (context, snapshot) {
          final rawAssignments = snapshot.data ?? [];
          final selectedDateFormatted = _dateStr(_selectedDate);

          // Filter assignments by selected Date and Shift
          final assignments = rawAssignments.where((a) {
            if (a['business_date'] != selectedDateFormatted) return false;
            if (_selectedShift != 'ALL' && a['shift_id'] != _selectedShift) {
              return false;
            }
            return true;
          }).toList();

          final totalEffective = assignments.fold<double>(
            0.0,
            (sum, a) => sum + (a['assigned_quantity'] as double? ?? 0.0),
          );

          return FutureBuilder<List<Map<String, dynamic>>>(
            future: appState.db.getEmployeesByTeamIds(effectiveTeamIds),
            builder: (context, empSnapshot) {
              final rawEmployees = empSnapshot.data ?? [];

              // Filter employees by search query
              final employees = rawEmployees.where((e) {
                if (_searchQuery.isEmpty) return true;
                final name = (e['ten'] ?? '').toString().toLowerCase();
                final code = (e['ma_nv'] ?? '').toString().toLowerCase();
                return name.contains(_searchQuery) || code.contains(_searchQuery);
              }).toList();

              return SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Interactive Filter Row
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildFilterChip(
                            '$_selectedTeamLabel ▾',
                            isSelected: true,
                            onTap: _showTeamFilterSheet,
                          ),
                          const SizedBox(width: 8),
                          _buildFilterChip(
                            '$_selectedShiftLabel ▾',
                            onTap: _showShiftFilterSheet,
                          ),
                          const SizedBox(width: 8),
                          _buildFilterChip(
                            '${_formatDisplayDate(_selectedDate)} ▾',
                            onTap: _showDatePickerDialog,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // KPI Grid
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 1.6,
                      children: [
                        KpiCard(
                          label: 'Tổng giao hiệu lực',
                          value: totalEffective.toStringAsFixed(0),
                          isAccent: true,
                        ),
                        const KpiCard(
                          label: 'Tổng hoàn thành',
                          value: '851',
                        ),
                        KpiCard(
                          label: 'Đang làm việc',
                          value: '${employees.length}',
                          uom: 'NV',
                        ),
                        KpiCard(
                          label: 'Phân công OPEN',
                          value:
                              '${assignments.where((a) => a['status'] == 'OPEN').length}',
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Nhân viên trong tổ',
                          style: TextStyle(
                            fontFamily: 'Manrope',
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: CaslaColors.primaryNavy,
                          ),
                        ),
                        Text(
                          '(${employees.length} NV)',
                          style: const TextStyle(
                            fontSize: 12,
                            color: CaslaColors.muted,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    if (employees.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: CaslaColors.surface,
                          border: Border.all(color: CaslaColors.line),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Center(
                          child: Text(
                            'Không tìm thấy nhân viên nào phù hợp bộ lọc.',
                            style: TextStyle(
                              color: CaslaColors.muted,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    else
                      ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: employees.length,
                        itemBuilder: (context, index) {
                          final worker = employees[index];
                          final workerAssignments = assignments
                              .where((a) => a['nhan_vien_id'] == worker['id'])
                              .toList();

                          double workerAssigned = 0.0;
                          for (final a in workerAssignments) {
                            workerAssigned +=
                                (a['assigned_quantity'] as double? ?? 0.0);
                          }

                          // Match status according to worker
                          String status = 'SYNCED';
                          String statusLabel = 'SYNCED';

                          if (worker['ma_nv'] == 'MNV00147') {
                            status = 'PENDING';
                            statusLabel = '2 PENDING';
                          } else if (worker['ma_nv'] == 'MNV00158') {
                            status = 'FAILED';
                            statusLabel = '1 FAILED';
                          } else if (worker['ma_nv'] == 'MNV00199') {
                            status = 'OPEN';
                            statusLabel = 'CHƯA XÁC NHẬN';
                          }

                          final completionRate = workerAssigned > 0
                              ? (status == 'OPEN' ? 0.0 : 0.67)
                              : 0.0;
                          final completedQty = workerAssigned * completionRate;
                          final remainingQty = workerAssigned - completedQty;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: Material(
                              color: CaslaColors.surface,
                              borderRadius: BorderRadius.circular(14),
                              child: InkWell(
                                onTap: () {
                                  context.push('/supervisor/employee_detail',
                                      extra: worker);
                                },
                                borderRadius: BorderRadius.circular(14),
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    border: Border.all(color: CaslaColors.line),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                worker['ten'] ?? 'Nhân viên',
                                                style: const TextStyle(
                                                  fontFamily: 'Manrope',
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 14.5,
                                                  color:
                                                      CaslaColors.primaryNavy,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${worker['ma_nv']} · ${worker['bo_phan']}',
                                                style: const TextStyle(
                                                  fontFamily: 'monospace',
                                                  fontSize: 11.5,
                                                  color: CaslaColors.muted,
                                                ),
                                              ),
                                            ],
                                          ),
                                          StatusChip(
                                            status: status,
                                            label: statusLabel,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),

                                      // Progress bar
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: LinearProgressIndicator(
                                          value: completionRate,
                                          minHeight: 7,
                                          backgroundColor: CaslaColors.muted100,
                                          valueColor:
                                              const AlwaysStoppedAnimation<
                                                  Color>(
                                            CaslaColors.accentGold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 10),

                                      // Stats row
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          _buildStatItem('Giao',
                                              workerAssigned.toStringAsFixed(0)),
                                          _buildStatItem('H.thành',
                                              completedQty.toStringAsFixed(0)),
                                          _buildStatItem('Còn lại',
                                              remainingQty.toStringAsFixed(0)),
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
                  ],
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          context.push('/supervisor/create_assignment');
        },
        backgroundColor: CaslaColors.accentGold,
        foregroundColor: CaslaColors.navy900,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: const Icon(Icons.add, size: 28),
      ),
    );
  }

  Widget _buildFilterChip(String label,
      {bool isSelected = false, VoidCallback? onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: CaslaColors.surface,
            border: Border.all(
              color: isSelected ? CaslaColors.accentGold : CaslaColors.line,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: CaslaColors.primaryNavy,
            ),
          ),
        ),
      ),
    );
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
