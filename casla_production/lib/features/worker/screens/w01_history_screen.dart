// W01 — Lịch sử sản lượng (công nhân)
// Spec: Section 5.1 ("Công nhân" role) — read-only view backed by
// ZUI_PP_OPALLOC.getWorkHistory. Scope (chỉ của mình / cả tổ) do SAP quyết
// định theo quyền tài khoản (PP_HIST_SELF / PP_HIST_TEAM), màn hình không
// tự chọn hay gửi WorkerID.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../domain/entities/work_history.dart';
import '../../../main.dart';
import '../../../presentation/widgets/casla_skeleton.dart';

class W01HistoryScreen extends ConsumerStatefulWidget {
  const W01HistoryScreen({super.key});

  @override
  ConsumerState<W01HistoryScreen> createState() => _W01HistoryScreenState();
}

class _W01HistoryScreenState extends ConsumerState<W01HistoryScreen> {
  HistoryRange _range = HistoryRange.month;
  DateTime? _customDateFrom;
  DateTime? _customDateTo;
  late Future<WorkHistoryResult> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<WorkHistoryResult> _load({bool forceRefresh = false}) {
    return ref
        .read(appStateProvider)
        .workHistoryRepo
        .getWorkHistory(
          range: _range,
          dateFrom: _range == HistoryRange.custom ? _customDateFrom : null,
          dateTo: _range == HistoryRange.custom ? _customDateTo : null,
          forceRefresh: forceRefresh,
        );
  }

  void _selectRange(HistoryRange range) {
    if (range == HistoryRange.custom) {
      _showCustomDatePickerSheet();
      return;
    }
    if (range == _range) return;
    setState(() {
      _range = range;
      _future = _load();
    });
  }

  Future<void> _refresh() async {
    try {
      final result = await _load(forceRefresh: true);
      if (!mounted) return;
      setState(() => _future = Future.value(result));
    } catch (_) {
      if (!mounted) return;
      final cached = _load();
      setState(() => _future = cached);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Không thể làm mới từ SAP. Đang hiển thị dữ liệu gần nhất trên máy.',
          ),
        ),
      );
      try {
        await cached;
      } catch (_) {
        // No cached snapshot exists; FutureBuilder will render its normal error.
      }
    }
  }

  Future<void> _pickSingleDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _customDateFrom ?? now,
      firstDate: DateTime(2020),
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'CHỌN NGÀY',
      cancelText: 'HỦY',
      confirmText: 'CHỌN',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: CaslaColors.primaryNavy,
              onPrimary: Colors.white,
              surface: CaslaColors.surface,
              onSurface: CaslaColors.navy900,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked == null || !mounted) return;

    setState(() {
      _range = HistoryRange.custom;
      _customDateFrom = DateTime(picked.year, picked.month, picked.day);
      _customDateTo = DateTime(picked.year, picked.month, picked.day);
      _future = _load();
    });
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final initialRange =
        (_customDateFrom != null &&
            _customDateTo != null &&
            !_customDateFrom!.isAtSameMomentAs(_customDateTo!))
        ? DateTimeRange(start: _customDateFrom!, end: _customDateTo!)
        : DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now);

    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: initialRange,
      firstDate: DateTime(2020),
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'CHỌN KHOẢNG NGÀY (TỐI ĐA 1 THÁNG)',
      cancelText: 'HỦY',
      confirmText: 'CHỌN',
      saveText: 'CHỌN',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: CaslaColors.primaryNavy,
              onPrimary: Colors.white,
              surface: CaslaColors.surface,
              onSurface: CaslaColors.navy900,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked == null || !mounted) return;

    final diffDays = picked.end.difference(picked.start).inDays;
    if (diffDays > 31) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Khoảng thời gian không được vượt quá 1 tháng (tối đa 31 ngày)',
          ),
          backgroundColor: CaslaColors.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      _range = HistoryRange.custom;
      _customDateFrom = DateTime(
        picked.start.year,
        picked.start.month,
        picked.start.day,
      );
      _customDateTo = DateTime(
        picked.end.year,
        picked.end.month,
        picked.end.day,
      );
      _future = _load();
    });
  }

  void _showCustomDatePickerSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          decoration: const BoxDecoration(
            color: CaslaColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: CaslaColors.line,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Tùy chọn thời gian',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Chọn ngày cụ thể hoặc khoảng ngày (tối đa 1 tháng)',
                style: TextStyle(fontSize: 13, color: CaslaColors.muted),
              ),
              const SizedBox(height: 18),
              _buildOptionTile(
                icon: Icons.today_rounded,
                title: 'Chọn 1 ngày cụ thể',
                subtitle: 'Xem lịch sử sản xuất trong một ngày',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickSingleDate();
                },
              ),
              const SizedBox(height: 10),
              _buildOptionTile(
                icon: Icons.date_range_rounded,
                title: 'Chọn khoảng ngày',
                subtitle: 'Tối đa 31 ngày (1 tháng)',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickDateRange();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOptionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: CaslaColors.muted100.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CaslaColors.line),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: CaslaColors.primaryNavy.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: CaslaColors.primaryNavy, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: CaslaColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: CaslaColors.muted, size: 20),
          ],
        ),
      ),
    );
  }

  String get _customDateLabel {
    if (_customDateFrom == null || _customDateTo == null) {
      return 'Chọn ngày';
    }
    final df = DateFormat('dd/MM/yyyy');
    if (_customDateFrom!.year == _customDateTo!.year &&
        _customDateFrom!.month == _customDateTo!.month &&
        _customDateFrom!.day == _customDateTo!.day) {
      return 'Ngày: ${df.format(_customDateFrom!)}';
    }
    return '${df.format(_customDateFrom!)} - ${df.format(_customDateTo!)}';
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
                    const _HistorySkeleton()
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
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
              _rangeTab('Tùy chọn', HistoryRange.custom),
            ],
          ),
        ),
        if (_range == HistoryRange.custom && _customDateFrom != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: CaslaColors.primaryNavy.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: CaslaColors.primaryNavy.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.event_available_outlined,
                  size: 16,
                  color: CaslaColors.primaryNavy,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _customDateLabel,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                ),
                InkWell(
                  onTap: _showCustomDatePickerSheet,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: CaslaColors.primaryNavy,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.edit_calendar_outlined,
                          size: 13,
                          color: Colors.white,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Đổi',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
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
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? CaslaColors.primaryNavy : CaslaColors.muted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError(Object error) {
    // getWorkHistory already tried a silent token refresh before this reached
    // here (see SapPpOpAllocGateway.getWorkHistory) — a session that still
    // classifies as `auth` at this point didn't just expire, it's dead
    // (e.g. revoked by a password change). "Thử lại" would only repeat the
    // same failure; the only way forward is a fresh login.
    final needsReLogin = classifySyncError(error).kind == SyncFailureKind.auth;

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
          Row(
            children: [
              const Icon(
                Icons.error_outline,
                color: CaslaColors.danger,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                needsReLogin
                    ? 'Phiên đăng nhập đã hết hạn'
                    : 'Không tải được lịch sử',
                style: const TextStyle(
                  color: CaslaColors.danger,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            needsReLogin
                ? 'Vui lòng đăng nhập lại để tiếp tục.'
                : error.toString().replaceAll('Exception: ', ''),
            style: const TextStyle(color: CaslaColors.danger, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: needsReLogin ? _reLogin : _refresh,
            style: ElevatedButton.styleFrom(
              backgroundColor: CaslaColors.primaryNavy,
              foregroundColor: Colors.white,
            ),
            child: Text(needsReLogin ? 'Đăng nhập lại' : 'Thử lại'),
          ),
        ],
      ),
    );
  }

  Future<void> _reLogin() async {
    await ref.read(appStateProvider).logout();
    if (!mounted) return;
    context.go('/login');
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

class _HistorySkeleton extends StatelessWidget {
  const _HistorySkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Row(
          children: [
            Expanded(child: CaslaSkeleton(height: 76, radius: 12)),
            SizedBox(width: 8),
            Expanded(child: CaslaSkeleton(height: 76, radius: 12)),
            SizedBox(width: 8),
            Expanded(child: CaslaSkeleton(height: 76, radius: 12)),
          ],
        ),
        const SizedBox(height: 18),
        for (var index = 0; index < 4; index++) ...[
          const CaslaSkeleton(height: 64, radius: 10),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
