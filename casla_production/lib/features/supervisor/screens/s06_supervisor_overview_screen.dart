import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../domain/policies/production_math.dart';
import '../../../main.dart';
import '../../../presentation/widgets/kpi_card.dart';
import '../../../presentation/widgets/status_chip.dart';
import '../../../presentation/widgets/casla_empty_state.dart';
import '../../../presentation/widgets/casla_skeleton.dart';
import '../../account/widgets/change_password_dialog.dart';

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
  bool _hasCheckedMandatoryPassword = false;
  String _employeeScopeKey = '';
  Future<List<Map<String, dynamic>>>? _employeesFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hasCheckedMandatoryPassword && mounted) {
        _hasCheckedMandatoryPassword = true;
        final session = ref.read(appStateProvider).currentSession;
        if (session?.passwordChangeRequired == true) {
          showChangePasswordDialog(context, isMandatory: true, ref: ref);
        }
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // Filter States
  String _selectedTeamId = 'ALL';
  String _selectedTeamLabel = 'Tất cả tổ';

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

  Future<void> _showTeamFilterSheet() async {
    final appState = ref.read(appStateProvider);
    final scope = appState.currentSession?.toIds.toSet() ?? const <String>{};
    final allTeams = await appState.db.getAllTeams();
    if (!mounted) return;
    final teams = allTeams.where((team) => scope.contains(team['id'])).toList();

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
                        title: const Text('Tất cả các tổ'),
                        selected: _selectedTeamId == 'ALL',
                        trailing: _selectedTeamId == 'ALL'
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () {
                          setState(() {
                            _selectedTeamId = 'ALL';
                            _selectedTeamLabel = 'Tất cả tổ';
                          });
                          Navigator.pop(sheetContext);
                        },
                      ),
                      for (final team in teams)
                        ListTile(
                          title: Text(
                            team['ten_to'] as String? ?? 'Tổ sản xuất',
                          ),
                          subtitle: team['ma_to'] == null
                              ? null
                              : Text(team['ma_to'].toString()),
                          selected: _selectedTeamId == team['id'],
                          trailing: _selectedTeamId == team['id']
                              ? const Icon(Icons.check)
                              : null,
                          onTap: () {
                            setState(() {
                              _selectedTeamId = team['id'] as String;
                              _selectedTeamLabel =
                                  team['ten_to'] as String? ?? 'Tổ sản xuất';
                            });
                            Navigator.pop(sheetContext);
                          },
                        ),
                      if (teams.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Chưa có dữ liệu tên tổ tương ứng với phạm vi SAP.',
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

  void _showDatePickerDialog() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: DateTime(now.year + 2, 12, 31),
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
    final supervisorName = emp?.userName ?? 'Supervisor';

    final effectiveTeamIds = _selectedTeamId == 'ALL'
        ? (emp?.toIds ?? const <String>[])
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
      // Through the repository: Assignment already carries the completed and
      // recalled totals derived from real records, so nothing on this screen has
      // to guess them.
      body: StreamBuilder<List<Assignment>>(
        stream: appState.assignmentRepo.watchAllAssignments(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const _OverviewSkeleton();
          }
          if (snapshot.hasError) {
            return const CaslaEmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'Không tải được tổng quan',
              message:
                  'Dữ liệu vẫn an toàn trên thiết bị. Hãy mở lại màn hình để thử lại.',
            );
          }

          final rawAssignments = snapshot.data ?? const <Assignment>[];
          final selectedDateFormatted = _dateStr(_selectedDate);

          // Filter assignments by team and selected date.
          final assignments = rawAssignments.where((a) {
            if (!effectiveTeamIds.contains(a.teamId)) return false;
            if (a.businessDate != selectedDateFormatted) return false;
            return true;
          }).toList();

          // Group once, outside the list builder — filtering the full assignment
          // list per row made scrolling O(workers × assignments).
          final byWorker = <String, List<Assignment>>{};
          for (final a in assignments) {
            (byWorker[a.workerId] ??= []).add(a);
          }

          final totalEffective = assignments.fold<double>(
            0.0,
            (sum, a) => sum + a.effectiveAssigned,
          );

          final totalCompleted = assignments.fold<double>(
            0.0,
            (sum, a) => sum + a.completedQuantity,
          );

          final openCount = assignments
              .where((a) => a.status == AssignmentStatus.open)
              .length;
          final assignedWorkerCount = byWorker.length;

          return FutureBuilder<List<Map<String, dynamic>>>(
            future: _employeesFor(effectiveTeamIds),
            builder: (context, empSnapshot) {
              if (empSnapshot.connectionState == ConnectionState.waiting &&
                  !empSnapshot.hasData) {
                return const _OverviewSkeleton();
              }
              if (empSnapshot.hasError) {
                return const CaslaEmptyState(
                  icon: Icons.people_outline,
                  title: 'Không tải được danh sách công nhân',
                  message:
                      'Không thể đọc dữ liệu công nhân trong phạm vi hiện tại.',
                );
              }

              final rawEmployees = empSnapshot.data ?? [];

              // Filter employees by search query
              final employees = rawEmployees.where((e) {
                if (_searchQuery.isEmpty) return true;
                final name = (e['ten'] ?? '').toString().toLowerCase();
                final code = (e['ma_nv'] ?? '').toString().toLowerCase();
                return name.contains(_searchQuery) ||
                    code.contains(_searchQuery);
              }).toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // FIXED TOP SECTION: Filter Row + KPI Grid + Section Title
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
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
                                '${_formatDisplayDate(_selectedDate)} ▾',
                                onTap: _showDatePickerDialog,
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 14),

                        // KPI Grid Cards (FIXED)
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
                            KpiCard(
                              label: 'Tổng hoàn thành',
                              value: totalCompleted.toStringAsFixed(0),
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
                          ],
                        ),

                        const SizedBox(height: 16),

                        // Section Title Row (FIXED)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Công nhân trong phạm vi · ${_formatDisplayDate(_selectedDate)}',
                              style: const TextStyle(
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
                      ],
                    ),
                  ),

                  // INDEPENDENTLY SCROLLABLE SECTION: Worker Cards List
                  Expanded(
                    child: employees.isEmpty
                        ? CaslaEmptyState(
                            icon: Icons.people_outline_rounded,
                            title: 'Không có nhân viên phù hợp',
                            message:
                                'Không tìm thấy nhân viên nào phù hợp. Thử đổi ngày, tổ sản xuất hoặc từ khóa tìm kiếm.',
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(18, 0, 18, 80),
                            itemCount: employees.length,
                            itemBuilder: (context, index) {
                              final worker = employees[index];
                              final workerAssignments =
                                  byWorker[worker['id']] ??
                                  const <Assignment>[];

                              // Every figure below comes from production and
                              // recall records via the repository. This block
                              // used to derive status from hardcoded employee
                              // codes and apply a fixed 0.67 completion rate.
                              double workerAssigned = 0.0;
                              double completedQty = 0.0;
                              double recalledQty = 0.0;
                              for (final a in workerAssignments) {
                                workerAssigned += a.assignedQuantity;
                                completedQty += a.completedQuantity;
                                recalledQty += a.recalledQuantity;
                              }

                              final effectiveQty =
                                  ProductionMath.calculateEffectiveAssigned(
                                    workerAssigned,
                                    recalledQty,
                                  );
                              final completionRate =
                                  ProductionMath.calculateCompletionRate(
                                    completedQty,
                                    effectiveQty,
                                  );
                              final remainingQty =
                                  ProductionMath.calculateRemaining(
                                    effectiveQty,
                                    completedQty,
                                  );

                              final (status, statusLabel) = _workerSyncBadge(
                                workerAssignments,
                              );

                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                child: Material(
                                  color: CaslaColors.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  child: InkWell(
                                    onTap: () {
                                      context.push(
                                        '/supervisor/employee_detail',
                                        extra: worker,
                                      );
                                    },
                                    borderRadius: BorderRadius.circular(12),
                                    child: Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: CaslaColors.line,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Column(
                                        children: [
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      worker['ten'] ??
                                                          'Nhân viên',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontFamily: 'Manrope',
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 14.5,
                                                        color: CaslaColors
                                                            .primaryNavy,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '${worker['ma_nv']} · ${worker['bo_phan']}',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontFamily: 'monospace',
                                                        fontSize: 11.5,
                                                        color:
                                                            CaslaColors.muted,
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
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: LinearProgressIndicator(
                                              value: completionRate,
                                              minHeight: 7,
                                              backgroundColor:
                                                  CaslaColors.muted100,
                                              valueColor:
                                                  const AlwaysStoppedAnimation<
                                                    Color
                                                  >(CaslaColors.accentGold),
                                            ),
                                          ),
                                          const SizedBox(height: 10),

                                          // Stats row
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              _buildStatItem(
                                                'Giao',
                                                effectiveQty.toStringAsFixed(0),
                                              ),
                                              _buildStatItem(
                                                'H.thành',
                                                completedQty.toStringAsFixed(0),
                                              ),
                                              _buildStatItem(
                                                'Còn lại',
                                                remainingQty.toStringAsFixed(0),
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
  }) {
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

  /// Derives the worker's sync badge from their assignments' real sync state.
  ///
  /// Returns (chip status, chip label). The failed count leads, because that is
  /// what a supervisor has to act on.
  (String, String) _workerSyncBadge(List<Assignment> assignments) {
    if (assignments.isEmpty) return ('OPEN', 'CHƯA GIAO');

    final failed = assignments
        .where((a) => a.syncStatus == SyncStatus.failed)
        .length;
    if (failed > 0) return ('FAILED', '$failed LỖI');

    final needsVerification = assignments
        .where((a) => a.syncStatus == SyncStatus.needsVerification)
        .length;
    if (needsVerification > 0) {
      return ('NEEDS_VERIFICATION', '$needsVerification CẦN XÁC MINH');
    }

    final pending = assignments
        .where((a) => a.syncStatus == SyncStatus.pending)
        .length;
    if (pending > 0) return ('PENDING', '$pending ĐANG CHỜ');

    final anyCompleted = assignments.any((a) => a.completedQuantity > 0);
    if (!anyCompleted) return ('OPEN', 'CHƯA XÁC NHẬN');

    return ('SYNCED', 'ĐÃ ĐỒNG BỘ');
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
      padding: const EdgeInsets.all(18),
      children: [
        const Row(
          children: [
            CaslaSkeleton(width: 132, height: 34, radius: 18),
            SizedBox(width: 8),
            CaslaSkeleton(width: 104, height: 34, radius: 18),
          ],
        ),
        const SizedBox(height: 14),
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
