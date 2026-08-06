// Screen S08 — Assignment Detail
// Spec: Section 5.2 S08 (Detail KPI, transaction list, Recall action)

import 'package:flutter/material.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_typography.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../shared/widgets/components.dart';

class AssignmentDetailScreen extends StatelessWidget {
  final Assignment assignment;
  final List<ProductionRecord> records;
  final VoidCallback onBack;
  final VoidCallback onOpenRecall;

  const AssignmentDetailScreen({
    super.key,
    required this.assignment,
    required this.records,
    required this.onBack,
    required this.onOpenRecall,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaslaColors.background,
      body: SafeArea(
        child: Column(
          children: [
            CaslaSubHeader(
              title: 'Chi tiết phân công',
              subtitle: '${assignment.workerMaNv} · ${assignment.workerName}',
              onBack: onBack,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Product context
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(assignment.orderCode, style: CaslaTypography.orderCode),
                            Text(assignment.productName, style: CaslaTypography.orderName),
                          ],
                        )),
                        StatusChip(status: assignment.status),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // KPI Grid
                    Row(
                      children: [
                        Expanded(child: KpiCard(
                          label: 'Giao hiệu lực',
                          value: assignment.effectiveAssigned.toInt().toString(),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: KpiCard(
                          label: 'Hoàn thành',
                          value: assignment.completedQuantity.toInt().toString(),
                        )),
                        const SizedBox(width: 8),
                        Expanded(child: KpiCard(
                          label: 'Còn lại',
                          value: assignment.remaining.toInt().toString(),
                          isAccent: true,
                        )),
                      ],
                    ),
                    
                    if (assignment.recalledQuantity > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          'Đã thu hồi: ${assignment.recalledQuantity.toInt()} ${assignment.uom}',
                          style: const TextStyle(fontSize: 12, color: CaslaColors.danger, fontWeight: FontWeight.w600),
                        ),
                      ),

                    const SectionTitle('Lịch sử ghi nhận'),
                    if (records.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Center(child: Text('Chưa có dữ liệu ghi nhận', style: TextStyle(color: CaslaColors.muted))),
                      )
                    else
                      ...records.map((r) => _RecordItem(record: r, uom: assignment.uom)),
                  ],
                ),
              ),
            ),
            if (assignment.maxRecall > 0 && assignment.status != AssignmentStatus.recalled)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                decoration: const BoxDecoration(
                  color: CaslaColors.surface,
                  border: Border(top: BorderSide(color: CaslaColors.line)),
                ),
                child: OutlinedButton(
                  onPressed: onOpenRecall,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: CaslaColors.danger,
                    side: const BorderSide(color: CaslaColors.danger, width: 1.5),
                  ),
                  child: const Text('Thu hồi phân công'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecordItem extends StatelessWidget {
  final ProductionRecord record;
  final String uom;

  const _RecordItem({required this.record, required this.uom});

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(record.occurredAtUtc);
    final timeStr = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        border: Border.all(color: CaslaColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Text(timeStr, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600, color: CaslaColors.muted)),
              const SizedBox(width: 12),
              SyncStatusChip(status: record.syncStatus),
            ],
          ),
          Text('+${record.quantity.toInt()} $uom', style: const TextStyle(
            fontWeight: FontWeight.w800, fontSize: 16, color: CaslaColors.success,
          )),
        ],
      ),
    );
  }
}
