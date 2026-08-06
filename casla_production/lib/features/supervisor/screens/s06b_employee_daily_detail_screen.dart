import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';
import '../../../presentation/widgets/status_chip.dart';

class S06bEmployeeDailyDetailScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> worker;

  const S06bEmployeeDailyDetailScreen({
    super.key,
    required this.worker,
  });

  @override
  ConsumerState<S06bEmployeeDailyDetailScreen> createState() =>
      _S06bEmployeeDailyDetailScreenState();
}

class _S06bEmployeeDailyDetailScreenState
    extends ConsumerState<S06bEmployeeDailyDetailScreen> {
  DateTime _selectedDate = DateTime.now();

  String _dateStr(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final workerName = widget.worker['ten'] ?? 'Nhân viên';
    final workerCode = widget.worker['ma_nv'] ?? 'MNV00000';
    final workerTeam = widget.worker['bo_phan'] ?? 'Tổ Cắt 2';
    final workerId = widget.worker['id'] ?? 'emp-1';

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
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            Text(
              '$workerCode · $workerTeam',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
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
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: appState.db.watchAssignmentsByWorker(workerId),
              builder: (context, snapshot) {
                final allAssignments = snapshot.data ?? [];
                final dateFormatted = _dateStr(_selectedDate);

                final filteredAssignments = allAssignments
                    .where((a) => a['business_date'] == dateFormatted)
                    .toList();

                return FutureBuilder<List<Map<String, dynamic>>>(
                  future: appState.db.getProductionHistory(
                    workerId,
                    fromBusinessDate: dateFormatted,
                    toBusinessDate: dateFormatted,
                  ),
                  builder: (context, prodSnapshot) {
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
                                      color: CaslaColors.muted, fontSize: 13),
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
                                        border: Border.all(color: CaslaColors.line),
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
                                                asg['don_hang_id'] ?? '',
                                                style: const TextStyle(
                                                  fontFamily: 'monospace',
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w600,
                                                  color: CaslaColors.muted,
                                                ),
                                              ),
                                              StatusChip(
                                                status: asg['status'] ?? 'OPEN',
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                'Giao: ${asg['assigned_quantity']?.toStringAsFixed(0)} cái',
                                                style: const TextStyle(
                                                  fontFamily: 'Manrope',
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 14,
                                                  color: CaslaColors.primaryNavy,
                                                ),
                                              ),
                                              const Icon(Icons.chevron_right,
                                                  color: CaslaColors.muted),
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

                          if (records.isEmpty)
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
                                      color: CaslaColors.muted, fontSize: 13),
                                ),
                              ),
                            )
                          else
                            ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: records.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final r = records[index];
                                final timeStr = DateFormat('HH:mm').format(
                                  DateTime.fromMillisecondsSinceEpoch(
                                      r['occurred_at_utc'] ?? 0),
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
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            r['ten_sp'] ?? '',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13,
                                              color: CaslaColors.primaryNavy,
                                            ),
                                          ),
                                          Text(
                                            '$timeStr · Người xác nhận: ${r['nguoi_xac_nhan']}',
                                            style: const TextStyle(
                                              fontFamily: 'monospace',
                                              fontSize: 11,
                                              color: CaslaColors.muted,
                                            ),
                                          ),
                                        ],
                                      ),
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
