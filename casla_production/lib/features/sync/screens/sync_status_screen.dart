// Screen S12 — Sync Status
// Spec: Section 5.2 S12 (List pending sync, manual retry button)

import 'package:flutter/material.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_typography.dart';
import '../../../shared/widgets/components.dart';
import '../../../domain/entities/enums.dart';

class SyncStatusScreen extends StatelessWidget {
  final List<Map<String, dynamic>> queueItems;
  final VoidCallback onBack;
  final VoidCallback onRetryAll;
  final bool isSyncing;

  const SyncStatusScreen({
    super.key,
    required this.queueItems,
    required this.onBack,
    required this.onRetryAll,
    this.isSyncing = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaslaColors.background,
      body: SafeArea(
        child: Column(
          children: [
            CaslaSubHeader(
              title: 'Trạng thái đồng bộ',
              subtitle: '${queueItems.length} bản ghi đang chờ',
              onBack: onBack,
            ),
            
            // Sync action row
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: CaslaColors.surface,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      isSyncing ? 'Đang đồng bộ dữ liệu lên SAP...' : 'Trạng thái kết nối: Tạm ổn',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isSyncing ? CaslaColors.pending : CaslaColors.success,
                      ),
                    ),
                  ),
                  if (!isSyncing && queueItems.isNotEmpty)
                    ElevatedButton.icon(
                      onPressed: onRetryAll,
                      icon: const Icon(Icons.sync, size: 16),
                      label: const Text('Đồng bộ ngay'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: CaslaColors.primaryNavy,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                    ),
                  if (isSyncing)
                    const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: CaslaColors.pending),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),

            Expanded(
              child: queueItems.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.cloud_done_outlined, size: 64, color: CaslaColors.success.withOpacity(0.5)),
                        const SizedBox(height: 16),
                        const Text('Tất cả dữ liệu đã được đồng bộ', style: TextStyle(
                          fontSize: 15, color: CaslaColors.muted, fontWeight: FontWeight.w600,
                        )),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: queueItems.length,
                    itemBuilder: (context, index) {
                      final item = queueItems[index];
                      final type = item['entity_type'] as String;
                      final errCode = item['last_error_code'] as String?;
                      final errMsg = item['last_error_message'] as String?;
                      
                      String typeLabel = type;
                      if (type == 'ASSIGNMENT') typeLabel = 'Giao việc';
                      if (type == 'PRODUCTION') typeLabel = 'Ghi nhận sản lượng';
                      if (type == 'RECALL') typeLabel = 'Thu hồi giao việc';

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: CaslaColors.surface,
                          border: Border.all(color: errCode != null ? CaslaColors.dangerBg : CaslaColors.line),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(typeLabel, style: CaslaTypography.label),
                                SyncStatusChip(status: errCode != null ? SyncStatus.failed : SyncStatus.pending),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text('ID: ${item['entity_id']}', style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 11, color: CaslaColors.muted,
                            )),
                            
                            if (errMsg != null) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: CaslaColors.dangerBg,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.error_outline, size: 14, color: CaslaColors.danger),
                                    const SizedBox(width: 6),
                                    Expanded(child: Text(errMsg, style: const TextStyle(
                                      fontSize: 12, color: CaslaColors.danger,
                                    ))),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
