// W01 — Lịch sử sản lượng (công nhân)
// Spec: Section 5.1 ("Công nhân" role) — read-only view backed by
// ZUI_PP_OPALLOC.getWorkHistory. Scope (chỉ của mình / cả tổ) do SAP quyết
// định theo quyền tài khoản (PP_HIST_SELF / PP_HIST_TEAM), màn hình không
// tự chọn hay gửi WorkerID.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/work_history.dart';
import '../../../main.dart';

class W01HistoryScreen extends ConsumerStatefulWidget {
  const W01HistoryScreen({super.key});

  @override
  ConsumerState<W01HistoryScreen> createState() => _W01HistoryScreenState();
}

class _W01HistoryScreenState extends ConsumerState<W01HistoryScreen> {
  HistoryRange _range = HistoryRange.month;
  late Future<WorkHistoryResult> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<WorkHistoryResult> _load() {
    return ref
        .read(appStateProvider)
        .workHistoryRepo
        .getWorkHistory(range: _range);
  }

  void _selectRange(HistoryRange range) {
    if (range == _range) return;
    setState(() {
      _range = range;
      _future = _load();
    });
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _future = next);
    await next;
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(appStateProvider).currentSession;

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Lịch sử sản lượng',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              session?.fullName ?? '',
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
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<WorkHistoryResult>(
          future: _future,
          builder: (context, snapshot) {
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildRangeTabs(),
                  const SizedBox(height: 14),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (snapshot.hasError)
                    _buildError(snapshot.error!)
                  else if (snapshot.hasData)
                    _buildContent(snapshot.data!),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildRangeTabs() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: CaslaColors.muted100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _rangeTab('Hôm nay', HistoryRange.day),
          _rangeTab('Tuần này', HistoryRange.week),
          _rangeTab('Tháng này', HistoryRange.month),
        ],
      ),
    );
  }

  Widget _rangeTab(String label, HistoryRange range) {
    final selected = range == _range;
    return Expanded(
      child: GestureDetector(
        onTap: () => _selectRange(range),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? CaslaColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? CaslaColors.primaryNavy : CaslaColors.muted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError(Object error) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: CaslaColors.dangerBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CaslaColors.danger.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.error_outline, color: CaslaColors.danger, size: 18),
              SizedBox(width: 8),
              Text(
                'Không tải được lịch sử',
                style: TextStyle(
                  color: CaslaColors.danger,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            error.toString().replaceAll('Exception: ', ''),
            style: const TextStyle(color: CaslaColors.danger, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _refresh,
            style: ElevatedButton.styleFrom(
              backgroundColor: CaslaColors.primaryNavy,
              foregroundColor: Colors.white,
            ),
            child: const Text('Thử lại'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(WorkHistoryResult result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (result.workers.isNotEmpty) _buildSummary(result.workers.first),
        if (result.isTruncated) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CaslaColors.pendingBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'Danh sách đã bị giới hạn do quá nhiều dữ liệu trong khoảng thời gian này.',
              style: TextStyle(color: CaslaColors.bannerText, fontSize: 11.5),
            ),
          ),
        ],
        const SizedBox(height: 14),
        Text(
          'Chi tiết giao dịch',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
            color: CaslaColors.primaryNavy,
          ),
        ),
        const SizedBox(height: 8),
        if (result.entries.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: CaslaColors.surface,
              border: Border.all(color: CaslaColors.line),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Center(
              child: Text(
                'Không có giao dịch nào trong khoảng thời gian này.',
                style: TextStyle(color: CaslaColors.muted, fontSize: 13),
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: CaslaColors.surface,
              border: Border.all(color: CaslaColors.line),
              borderRadius: BorderRadius.circular(14),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: result.entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _buildEntryTile(result.entries[index]),
            ),
          ),
      ],
    );
  }

  Widget _buildSummary(WorkHistorySummary summary) {
    return Row(
      children: [
        _summaryTile(
          'Đã giao',
          summary.assignedQuantity,
          summary.unitOfMeasure,
          CaslaColors.primaryNavy,
        ),
        const SizedBox(width: 8),
        _summaryTile(
          'Đã hoàn thành',
          summary.completedQuantity,
          summary.unitOfMeasure,
          CaslaColors.success,
        ),
        const SizedBox(width: 8),
        _summaryTile(
          'Còn lại',
          summary.remainingQuantity,
          summary.unitOfMeasure,
          CaslaColors.pending,
        ),
      ],
    );
  }

  Widget _summaryTile(String label, double value, String uom, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: CaslaColors.surface,
          border: Border.all(color: CaslaColors.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              value.toStringAsFixed(0),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$label${uom.isNotEmpty ? ' ($uom)' : ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10.5, color: CaslaColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntryTile(WorkHistoryEntry entry) {
    final label = _transactionTypeLabel(entry.transactionType);
    final isNegative =
        entry.transactionType == 'RECALL' || entry.transactionType == 'REVERSE';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: CaslaColors.muted100,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _transactionTypeIcon(entry.transactionType),
              size: 18,
              color: CaslaColors.primaryNavy,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$label · ${entry.productionOrder}-${entry.operation}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  DateFormat('dd/MM/yyyy').format(entry.executionDate),
                  style: const TextStyle(
                    fontSize: 11,
                    color: CaslaColors.muted,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${isNegative ? '-' : '+'}${entry.quantity.toStringAsFixed(0)} ${entry.unitOfMeasure}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: isNegative ? CaslaColors.danger : CaslaColors.success,
            ),
          ),
        ],
      ),
    );
  }

  static String _transactionTypeLabel(String type) {
    switch (type) {
      case 'INITIAL_ASSIGN':
        return 'Giao việc';
      case 'TRANSFER':
        return 'Điều chuyển';
      case 'RECALL':
        return 'Thu hồi';
      case 'CONFIRM':
        return 'Xác nhận hoàn thành';
      case 'REVERSE':
        return 'Đảo giao dịch';
      case 'CORRECTION':
        return 'Điều chỉnh';
      default:
        return type;
    }
  }

  static IconData _transactionTypeIcon(String type) {
    switch (type) {
      case 'INITIAL_ASSIGN':
      case 'TRANSFER':
        return Icons.assignment_outlined;
      case 'RECALL':
        return Icons.undo;
      case 'CONFIRM':
        return Icons.check_circle_outline;
      case 'REVERSE':
        return Icons.replay;
      case 'CORRECTION':
        return Icons.edit_outlined;
      default:
        return Icons.receipt_long_outlined;
    }
  }
}
