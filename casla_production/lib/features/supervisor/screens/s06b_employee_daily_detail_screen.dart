import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/entities.dart';
import '../../../main.dart';
import '../../../presentation/widgets/casla_empty_state.dart';
import '../../../presentation/widgets/casla_skeleton.dart';
import '../../../presentation/widgets/status_chip.dart';

class S06bEmployeeDailyDetailScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> worker;

  const S06bEmployeeDailyDetailScreen({super.key, required this.worker});

  @override
  ConsumerState<S06bEmployeeDailyDetailScreen> createState() =>
      _S06bEmployeeDailyDetailScreenState();
}

class _EmployeeDetailSkeleton extends StatelessWidget {
  const _EmployeeDetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const CaslaSkeleton(width: 170, height: 18, radius: 6),
        const SizedBox(height: 12),
        const CaslaSkeleton(height: 94, radius: 14),
        const SizedBox(height: 20),
        const CaslaSkeleton(width: 210, height: 18, radius: 6),
        const SizedBox(height: 12),
        for (var index = 0; index < 3; index++) ...[
          const CaslaSkeleton(height: 68, radius: 12),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _S06bEmployeeDailyDetailScreenState
    extends ConsumerState<S06bEmployeeDailyDetailScreen> {
  DateTime _selectedDate = DateTime.now();

  String _dateStr(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final workerName = widget.worker['ten'] ?? 'Nhân viên';
    final workerCode = widget.worker['ma_nv'] ?? 'Chưa có mã';
    final workerTeam = widget.worker['bo_phan'] ?? 'Chưa xác định tổ';
    final workerId = widget.worker['id'] as String? ?? '';

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              workerName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$workerCode · $workerTeam',
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
      body: Column(
        children: [
          // Date Selector Header
          Container(
            color: CaslaColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Ngày: ${DateFormat('dd/MM/yyyy').format(_selectedDate)}',
                  style: const TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
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
                  },
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: const Text('Chọn ngày'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(110, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          Expanded(
            child: StreamBuilder<List<Assignment>>(
              stream: appState.assignmentRepo.watchWorkerAssignments(workerId),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const _EmployeeDetailSkeleton();
                }
                if (snapshot.hasError) {
                  return const CaslaEmptyState(
                    icon: Icons.cloud_off_outlined,
                    title: 'Không tải được chi tiết công nhân',
                    message:
                        'Không thể đọc dữ liệu phân công trên thiết bị lúc này.',
                  );
                }

                final allAssignments = snapshot.data ?? const <Assignment>[];
                final dateFormatted = _dateStr(_selectedDate);

                final filteredAssignments = allAssignments
                    .where((a) => a.businessDate == dateFormatted)
                    .toList();

                return StreamBuilder<List<Map<String, dynamic>>>(
                  stream: appState.db.watchProductionHistory(
                    workerId,
                    fromBusinessDate: dateFormatted,
                    toBusinessDate: dateFormatted,
                  ),
                  builder: (context, prodSnapshot) {
                    if (prodSnapshot.connectionState ==
                            ConnectionState.waiting &&
                        !prodSnapshot.hasData) {
                      return const _EmployeeDetailSkeleton();
                    }
                    final productionLoadFailed = prodSnapshot.hasError;
                    final records = prodSnapshot.data ?? [];

                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Phân công trong ngày',
                            style: TextStyle(
                              fontFamily: 'Manrope',
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          const SizedBox(height: 10),

                          if (filteredAssignments.isEmpty)
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: CaslaColors.surface,
                                border: Border.all(color: CaslaColors.line),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Center(
                                child: Text(
                                  'Không có phân công nào trong ngày này.',
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
                              itemCount: filteredAssignments.length,
                              itemBuilder: (context, index) {
                                final asg = filteredAssignments[index];
                                return Material(
                                  color: CaslaColors.surface,
                                  borderRadius: BorderRadius.circular(14),
                                  child: InkWell(
                                    onTap: () {
                                      context.push(
                                        '/supervisor/assignment_detail',
                                        extra: asg,
                                      );
                                    },
                                    borderRadius: BorderRadius.circular(14),
                                    child: Container(
                                      margin: const EdgeInsets.only(bottom: 10),
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: CaslaColors.line,
                                        ),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                asg.orderCode,
                                                style: const TextStyle(
                                                  fontFamily: 'monospace',
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w600,
                                                  color: CaslaColors.muted,
                                                ),
                                              ),
                                              StatusChip(
                                                status: asg.status.label,
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                'Giao: ${asg.effectiveAssigned.toStringAsFixed(0)} cái',
                                                style: const TextStyle(
                                                  fontFamily: 'Manrope',
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 14,
                                                  color:
                                                      CaslaColors.primaryNavy,
                                                ),
                                              ),
                                              const Icon(
                                                Icons.chevron_right,
                                                color: CaslaColors.muted,
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),

                          const SizedBox(height: 20),
                          const Text(
                            'Lịch sử xác nhận hoàn thành',
                            style: TextStyle(
                              fontFamily: 'Manrope',
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          const SizedBox(height: 10),

                          if (productionLoadFailed)
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: CaslaColors.dangerBg,
                                border: Border.all(
                                  color: CaslaColors.danger.withValues(
                                    alpha: 0.35,
                                  ),
                                ),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Row(
                                children: [
                                  Icon(
                                    Icons.history_toggle_off_outlined,
                                    color: CaslaColors.danger,
                                  ),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Chưa tải được lịch sử sản lượng. Danh sách phân công phía trên vẫn dùng được.',
                                      style: TextStyle(
                                        color: CaslaColors.danger,
                                        fontSize: 12.5,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else if (records.isEmpty)
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: CaslaColors.surface,
                                border: Border.all(color: CaslaColors.line),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Center(
                                child: Text(
                                  'Chưa có lượt xác nhận sản lượng nào.',
                                  style: TextStyle(
                                    color: CaslaColors.muted,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            )
                          else
                            ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: records.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final r = records[index];
                                final timeStr = DateFormat('HH:mm').format(
                                  DateTime.fromMillisecondsSinceEpoch(
                                    r['occurred_at_utc'] ?? 0,
                                  ),
                                );

                                return Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: CaslaColors.surface,
                                    border: Border.all(color: CaslaColors.line),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              r['ten_sp'] ?? '',
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13,
                                                color: CaslaColors.primaryNavy,
                                              ),
                                            ),
                                            Text(
                                              '$timeStr · Người xác nhận: ${r['nguoi_xac_nhan']}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 11,
                                                color: CaslaColors.muted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        '+${(r['quantity'] as double).toStringAsFixed(0)} cái',
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                          color: CaslaColors.success,
                                        ),
                                      ),
                                    ],
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
          ),
        ],
      ),
    );
  }
}
