import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';
import '../../../presentation/widgets/kpi_card.dart';
import '../../../presentation/widgets/status_chip.dart';

class S03WorkerHistoryScreen extends ConsumerStatefulWidget {
  const S03WorkerHistoryScreen({super.key});

  @override
  ConsumerState<S03WorkerHistoryScreen> createState() =>
      _S03WorkerHistoryScreenState();
}

class _S03WorkerHistoryScreenState
    extends ConsumerState<S03WorkerHistoryScreen> {
  int _selectedFilterIndex = 0; // 0: Hôm nay, 1: Hôm qua, 2: Tháng này
  bool _isLoading = false;
  List<Map<String, dynamic>> _historyRecords = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  String _todayStr() {
    final n = DateTime.now();
    return DateFormat('yyyy-MM-dd').format(n);
  }

  String _yesterdayStr() {
    final n = DateTime.now().subtract(const Duration(days: 1));
    return DateFormat('yyyy-MM-dd').format(n);
  }

  String _firstDayOfMonthStr() {
    final n = DateTime.now();
    return DateFormat('yyyy-MM-01').format(n);
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final appState = ref.read(appStateProvider);
    final emp = appState.currentSession;
    if (emp == null) return;

    String? from;
    String? to;

    if (_selectedFilterIndex == 0) {
      from = _todayStr();
      to = _todayStr();
    } else if (_selectedFilterIndex == 1) {
      from = _yesterdayStr();
      to = _yesterdayStr();
    } else {
      from = _firstDayOfMonthStr();
      to = _todayStr();
    }

    final records = await appState.db.getProductionHistory(
      emp.id,
      fromBusinessDate: from,
      toBusinessDate: to,
    );

    if (mounted) {
      setState(() {
        _historyRecords = records;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final emp = appState.currentSession;
    final workerName = emp?.userName ?? 'Nguyễn Văn A';
    final workerCode = emp?.maNv ?? 'MNV00123';
    final teamName = emp?.teamName ?? 'Tổ Cắt 2';

    final totalCompletedInPeriod = _historyRecords.fold<double>(
      0.0,
      (sum, r) => sum + (r['quantity'] as double? ?? 0.0),
    );

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(100),
        child: Container(
          color: CaslaColors.primaryNavy,
          padding: const EdgeInsets.fromLTRB(18, 44, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              CaslaColors.accentGold,
                              CaslaColors.gold700
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          workerName.isNotEmpty
                              ? workerName
                                  .split(' ')
                                  .last[0]
                                  .toUpperCase()
                              : 'A',
                          style: const TextStyle(
                            fontFamily: 'Manrope',
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: CaslaColors.navy900,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            workerName,
                            style: const TextStyle(
                              fontFamily: 'Manrope',
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$workerCode · $teamName',
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: CaslaColors.identityMeta,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.swap_horiz, color: Colors.white),
                    tooltip: 'Đổi người dùng',
                    onPressed: () async {
                      await appState.logout();
                      if (context.mounted) {
                        context.go('/login');
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Segmented filter
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: CaslaColors.muted100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    _buildSegmentButton('Hôm nay', 0),
                    _buildSegmentButton('Hôm qua', 1),
                    _buildSegmentButton('Tháng này', 2),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // KPI summary
              Row(
                children: [
                  Expanded(
                    child: KpiCard(
                      label: 'Tổng xác nhận',
                      value: totalCompletedInPeriod.toStringAsFixed(0),
                      uom: 'cái',
                      isAccent: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: KpiCard(
                      label: 'Số lần ghi nhận',
                      value: '${_historyRecords.length}',
                      uom: 'lần',
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),
              const Text(
                'Lịch sử được Supervisor xác nhận',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 10),

              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.all(30.0),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_historyRecords.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: CaslaColors.surface,
                    border: Border.all(color: CaslaColors.line),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Center(
                    child: Text(
                      'Chưa có bản ghi xác nhận nào trong kỳ này.',
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
                  itemCount: _historyRecords.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = _historyRecords[index];
                    final dateStr = item['business_date'] ?? '';
                    final timeStr = DateFormat('HH:mm').format(
                      DateTime.fromMillisecondsSinceEpoch(
                          item['occurred_at_utc'] ?? 0),
                    );

                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: CaslaColors.surface,
                        border: Border.all(color: CaslaColors.line),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: CaslaColors.success,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item['ten_sp'] ?? 'Sản phẩm',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13.5,
                                    color: CaslaColors.primaryNavy,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${item['nguoi_xac_nhan']} xác nhận · $dateStr $timeStr',
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: CaslaColors.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '+${(item['quantity'] as double).toStringAsFixed(0)} cái',
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: CaslaColors.success,
                                ),
                              ),
                              const SizedBox(height: 4),
                              StatusChip(status: item['sync_status'] ?? 'SYNCED'),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSegmentButton(String label, int index) {
    final isSelected = _selectedFilterIndex == index;
    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedFilterIndex = index;
          });
          _loadData();
        },
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? CaslaColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    )
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: isSelected ? CaslaColors.primaryNavy : CaslaColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}
