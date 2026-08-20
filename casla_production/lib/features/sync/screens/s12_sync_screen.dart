import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';
import '../../../presentation/widgets/status_chip.dart';

class S12SyncScreen extends ConsumerStatefulWidget {
  const S12SyncScreen({super.key});

  @override
  ConsumerState<S12SyncScreen> createState() => _S12SyncScreenState();
}

class _S12SyncScreenState extends ConsumerState<S12SyncScreen> {
  int _selectedTabIndex = 0; // 0: Tất cả, 1: Đang chờ, 2: Lỗi, 3: Đã xong

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Đồng bộ',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Quản lý bản ghi pending / failed',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: CaslaColors.identityMeta,
              ),
            ),
          ],
        ),
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: appState.db.watchSyncFeed(),
        builder: (context, snapshot) {
          final feedItems = snapshot.data ?? [];

          final pendingCount = feedItems
              .where((i) => i['status'] == 'PENDING')
              .length;
          final failedCount = feedItems
              .where((i) => i['status'] == 'FAILED')
              .length;
          final syncedCount = 142; // Demo count

          final filteredItems = feedItems.where((i) {
            if (_selectedTabIndex == 1) return i['status'] == 'PENDING';
            if (_selectedTabIndex == 2) return i['status'] == 'FAILED';
            if (_selectedTabIndex == 3) return i['status'] == 'SYNCED';
            return true;
          }).toList();

          return SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Summary Boxes
                Row(
                  children: [
                    _buildSummaryBox('$pendingCount', 'PENDING'),
                    const SizedBox(width: 8),
                    _buildSummaryBox(
                      '$failedCount',
                      'FAILED',
                      color: CaslaColors.danger,
                    ),
                    const SizedBox(width: 8),
                    _buildSummaryBox(
                      '$syncedCount',
                      'SYNCED',
                      color: CaslaColors.success,
                    ),
                  ],
                ),

                const SizedBox(height: 14),

                // Tabs Row
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: CaslaColors.muted100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      _buildTab('Tất cả', 0),
                      _buildTab('Đang chờ', 1),
                      _buildTab('Lỗi', 2),
                      _buildTab('Đã xong', 3),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // List Items
                if (filteredItems.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: CaslaColors.surface,
                      border: Border.all(color: CaslaColors.line),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Center(
                      child: Text(
                        'Không có bản ghi nào trong mục này.',
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
                    itemCount: filteredItems.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = filteredItems[index];
                      final isFailed = item['status'] == 'FAILED';
                      final isPending = item['status'] == 'PENDING';

                      return Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: CaslaColors.muted100,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                isFailed
                                    ? Icons.error_outline
                                    : (isPending
                                          ? Icons.access_time
                                          : Icons.check_circle_outline),
                                size: 20,
                                color: isFailed
                                    ? CaslaColors.danger
                                    : (isPending
                                          ? CaslaColors.pending
                                          : CaslaColors.success),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item['payload_summary'] ?? 'Bản ghi',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                      color: CaslaColors.primaryNavy,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    isFailed
                                        ? (item['last_error_message'] ??
                                              'Lỗi xác thực')
                                        : 'PDA-CT02-A17 · Đã lưu offline',
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      color: isFailed
                                          ? CaslaColors.danger
                                          : CaslaColors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isFailed)
                              ElevatedButton(
                                onPressed: () async {
                                  final success = await appState.db
                                      .retrySyncItem(item['id']);
                                  if (context.mounted && success) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Đã đưa giao dịch vào hàng đợi đồng bộ.',
                                        ),
                                        backgroundColor: CaslaColors.success,
                                      ),
                                    );
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: CaslaColors.primaryNavy,
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(64, 32),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                ),
                                child: const Text(
                                  'Thử lại',
                                  style: TextStyle(fontSize: 11),
                                ),
                              )
                            else
                              StatusChip(status: item['status']),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSummaryBox(String count, String label, {Color? color}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: CaslaColors.surface,
          border: Border.all(color: CaslaColors.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(
              count,
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: color ?? CaslaColors.primaryNavy,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: CaslaColors.muted,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(String label, int index) {
    final isSelected = _selectedTabIndex == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _selectedTabIndex = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? CaslaColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 3,
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: isSelected ? CaslaColors.primaryNavy : CaslaColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}
