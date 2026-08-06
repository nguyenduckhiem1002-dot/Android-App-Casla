// Screen S06 — Supervisor Overview
// Spec: Section 5.2 S06 (Filter row, KPI grid, assignment list, FAB)

import 'package:flutter/material.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_typography.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../domain/policies/shift_resolver.dart';
import '../../../shared/widgets/components.dart';

class SupervisorOverviewScreen extends StatelessWidget {
  final UserSession userSession;
  final List<Assignment> assignments;
  final SupervisorOverviewSummary summary;
  final VoidCallback onOpenCreateAssignment;
  final ValueChanged<Assignment> onSelectAssignment;
  final VoidCallback onOpenSyncManager;
  final VoidCallback onSwitchUser;

  const SupervisorOverviewScreen({
    super.key,
    required this.userSession,
    required this.assignments,
    required this.summary,
    required this.onOpenCreateAssignment,
    required this.onSelectAssignment,
    required this.onOpenSyncManager,
    required this.onSwitchUser,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaslaColors.navy900,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Dark Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(
                      color: CaslaColors.primaryNavy,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _getInitials(userSession.fullName),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        fontFamily: CaslaTypography.fontDisplay,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          userSession.fullName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Supervisor · ${userSession.teamName}',
                          style: const TextStyle(
                            color: CaslaColors.identityMeta,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: CaslaColors.primaryNavy,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.search, color: Colors.white, size: 20),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // White rounded sheet
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  color: CaslaColors.background,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(24),
                    topRight: Radius.circular(24),
                  ),
                ),
                child: Stack(
                  children: [
                    SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 100),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Filter row
                          Row(
                            children: const [
                              _FilterChip(label: 'Tổ: Tất cả'),
                              SizedBox(width: 8),
                              _FilterChip(label: 'Ca ngày'),
                              SizedBox(width: 8),
                              _FilterChip(label: 'Hôm nay'),
                            ],
                          ),
                          const SizedBox(height: 20),

                          // KPI Grid
                          Row(
                            children: [
                              Expanded(
                                child: _KpiCard(
                                  label: 'Tổng giao hiệu lực',
                                  value: summary.totalEffectiveAssigned.toInt().toString(),
                                  isDark: true,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _KpiCard(
                                  label: 'Tổng hoàn thành',
                                  value: summary.totalCompleted.toInt().toString(),
                                  isDark: false,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _KpiCard(
                                  label: 'Đang làm việc',
                                  value: summary.activeWorkersCount.toString(),
                                  unit: 'NV',
                                  isDark: false,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _KpiCard(
                                  label: 'Phân công OPEN',
                                  value: summary.openAssignmentsCount.toString(),
                                  isDark: false,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 24),
                          const Text(
                            'Nhân viên trong tổ',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          const SizedBox(height: 12),

                          if (assignments.isEmpty)
                            Container(
                              padding: const EdgeInsets.all(24),
                              alignment: Alignment.center,
                              child: Column(
                                children: [
                                  Icon(Icons.people_outline, size: 48, color: CaslaColors.muted.withOpacity(0.3)),
                                  const SizedBox(height: 12),
                                  const Text('Chưa có phân công nào', style: TextStyle(
                                    fontSize: 14, color: CaslaColors.muted,
                                  )),
                                ],
                              ),
                            )
                          else
                            ...assignments.map((a) => _WorkerCard(
                              assignment: a,
                              onTap: () => onSelectAssignment(a),
                            )),
                        ],
                      ),
                    ),
                    // Floating Action Button Overlay
                    Positioned(
                      bottom: 24,
                      right: 16,
                      child: GestureDetector(
                        onTap: onOpenCreateAssignment,
                        child: Container(
                          width: 56, height: 56,
                          decoration: BoxDecoration(
                            color: CaslaColors.accentGold,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: CaslaColors.accentGold.withOpacity(0.3),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const Icon(Icons.add, color: CaslaColors.navy900, size: 28),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getInitials(String name) {
    if (name.isEmpty) return 'CG';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[parts.length - 2][0]}${parts.last[0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }
}

class _FilterChip extends StatelessWidget {
  final String label;

  const _FilterChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: CaslaColors.line),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600,
            color: CaslaColors.primaryNavy,
          )),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_drop_down, size: 16, color: CaslaColors.primaryNavy),
        ],
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final bool isDark;

  const _KpiCard({
    required this.label,
    required this.value,
    this.unit,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: isDark ? CaslaColors.primaryNavy : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: isDark ? null : Border.all(color: CaslaColors.line, width: 0.5),
        boxShadow: isDark ? null : [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark ? CaslaColors.identityMeta : CaslaColors.muted,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  fontFamily: CaslaTypography.fontDisplay,
                  color: isDark ? Colors.white : CaslaColors.primaryNavy,
                  height: 1,
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(
                  unit!,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isDark ? CaslaColors.identityMeta : CaslaColors.muted,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _WorkerCard extends StatelessWidget {
  final Assignment assignment;
  final VoidCallback onTap;

  const _WorkerCard({required this.assignment, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final progress = assignment.effectiveAssigned > 0
        ? (assignment.completedQuantity / assignment.effectiveAssigned).clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: CaslaColors.line, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        // Mock uses worker name instead of order in this section
                        'Nguyễn Văn ${assignment.workerId.substring(assignment.workerId.length - 1)}',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: CaslaColors.primaryNavy,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${assignment.workerId} · ${assignment.teamId}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: CaslaColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                _SyncBadge(isSynced: assignment.syncStatus == SyncStatus.synced),
              ],
            ),
            const SizedBox(height: 16),
            // Progress Bar
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: CaslaColors.muted100,
                      valueColor: const AlwaysStoppedAnimation(CaslaColors.accentGold),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Stats row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StatItem(label: 'Giao', value: assignment.effectiveAssigned.toInt().toString()),
                _StatItem(label: 'H.thành', value: assignment.completedQuantity.toInt().toString()),
                _StatItem(label: 'Còn lại', value: assignment.remaining.toInt().toString()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncBadge extends StatelessWidget {
  final bool isSynced;

  const _SyncBadge({required this.isSynced});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isSynced ? CaslaColors.successBg : CaslaColors.pendingBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              color: isSynced ? CaslaColors.success : CaslaColors.pending,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            isSynced ? 'SYNCED' : 'PENDING',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: isSynced ? CaslaColors.success : CaslaColors.pending,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;

  const _StatItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(
          fontSize: 11, fontWeight: FontWeight.w600, color: CaslaColors.muted,
        )),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(
          fontSize: 15, fontWeight: FontWeight.w800, color: CaslaColors.primaryNavy,
          fontFamily: CaslaTypography.fontDisplay,
        )),
      ],
    );
  }
}
