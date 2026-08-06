// Screen S03 — Worker Dashboard
// Spec: Section 5.2 S03 (KPI grid, assignment list, sync banner)

import 'package:flutter/material.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_typography.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/policies/shift_resolver.dart';
import '../../../shared/widgets/components.dart';

class WorkerDashboardScreen extends StatelessWidget {
  final UserSession userSession;
  final List<Assignment> assignments;
  final int pendingSyncCount;
  final ValueChanged<Assignment> onSelectAssignment;
  final VoidCallback onOpenSyncManager;
  final VoidCallback onSwitchUser;

  const WorkerDashboardScreen({
    super.key,
    required this.userSession,
    required this.assignments,
    required this.pendingSyncCount,
    required this.onSelectAssignment,
    required this.onOpenSyncManager,
    required this.onSwitchUser,
  });

  @override
  Widget build(BuildContext context) {
    final shift = ShiftResolver.getCurrentShiftInfo();

    // Compute KPIs
    final totalEffectiveAssigned = assignments.fold(0.0, (s, a) => s + a.effectiveAssigned);
    final totalCompleted = assignments.fold(0.0, (s, a) => s + a.completedQuantity);
    final totalRemaining = assignments.fold(0.0, (s, a) => s + a.remaining);

    return Scaffold(
      backgroundColor: CaslaColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Identity Bar
            EmployeeIdentityBar(
              name: userSession.fullName,
              maNv: userSession.maNv,
              teamName: userSession.teamName,
              contextDate: '${shift.shiftName} · ${ShiftResolver.formatDateDisplay(shift.businessDate)}',
              onSwitchUser: onSwitchUser,
            ),

            // Scrollable content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // KPI Grid (2x2)
                    Row(
                      children: [
                        Expanded(child: KpiCard(
                          label: 'Giao hiệu lực',
                          value: totalEffectiveAssigned.toInt().toString(),
                          uom: 'cái',
                          isAccent: true,
                        )),
                        const SizedBox(width: 10),
                        Expanded(child: KpiCard(
                          label: 'Hoàn thành hôm nay',
                          value: totalCompleted.toInt().toString(),
                          uom: 'cái',
                        )),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: KpiCard(
                          label: 'Lũy kế hoàn thành',
                          value: totalCompleted.toInt().toString(),
                          uom: 'cái',
                        )),
                        const SizedBox(width: 10),
                        Expanded(child: KpiCard(
                          label: 'Còn lại',
                          value: totalRemaining.toInt().toString(),
                          uom: 'cái',
                        )),
                      ],
                    ),

                    // Sync Banner
                    SyncBanner(
                      pendingCount: pendingSyncCount,
                      onTap: onOpenSyncManager,
                    ),

                    // Assignment List
                    const SectionTitle('Phân công hôm nay'),

                    if (assignments.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(24),
                        alignment: Alignment.center,
                        child: Column(
                          children: [
                            Icon(Icons.assignment_outlined, size: 48, color: CaslaColors.muted.withOpacity(0.3)),
                            const SizedBox(height: 12),
                            const Text('Chưa có phân công nào', style: TextStyle(
                              fontSize: 14, color: CaslaColors.muted,
                            )),
                          ],
                        ),
                      )
                    else
                      ...assignments.map((a) => AssignmentCard(
                        assignment: a,
                        onTap: () => onSelectAssignment(a),
                      )),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
