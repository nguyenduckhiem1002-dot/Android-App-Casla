import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/casla_colors.dart';

class SyncFailureDialogData {
  final String title;
  final String statusLabel;
  final String message;
  final String guidance;
  final String transactionSummary;
  final String orderOperation;
  final String businessDateShift;
  final String createdAt;
  final String technicalCode;
  final String technicalMessage;
  final bool stoppedWorkerChain;

  const SyncFailureDialogData({
    this.title = 'Không thể đồng bộ',
    this.statusLabel = 'Cần kiểm tra dữ liệu',
    required this.message,
    required this.guidance,
    this.transactionSummary = '',
    this.orderOperation = '',
    this.businessDateShift = '',
    this.createdAt = '',
    this.technicalCode = '',
    this.technicalMessage = '',
    this.stoppedWorkerChain = false,
  });
}

Future<void> showSyncFailureDialog(
  BuildContext context, {
  required SyncFailureDialogData data,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => SyncFailureDialog(data: data),
  );
}

class SyncFailureDialog extends StatelessWidget {
  final SyncFailureDialogData data;

  const SyncFailureDialog({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final technicalText = <String>[
      if (data.technicalCode.isNotEmpty) data.technicalCode,
      if (data.technicalMessage.isNotEmpty &&
          data.technicalMessage != data.technicalCode)
        data.technicalMessage,
    ].join('\n');

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: data.title,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: CaslaColors.dangerBg,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.sync_problem_rounded,
                        color: CaslaColors.danger,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data.title,
                              style: const TextStyle(
                                fontFamily: 'Manrope',
                                fontSize: 20,
                                height: 1.2,
                                fontWeight: FontWeight.w800,
                                color: CaslaColors.primaryNavy,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _StatusLabel(label: data.statusLabel),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Đóng',
                      visualDensity: VisualDensity.standard,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                      color: CaslaColors.muted,
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  data.message,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
                if (_hasTransactionDetails) ...[
                  const SizedBox(height: 16),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: CaslaColors.background,
                      border: Border.all(color: CaslaColors.line),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        children: [
                          if (data.transactionSummary.isNotEmpty)
                            _InfoRow(
                              label: 'Giao dịch',
                              value: data.transactionSummary,
                              emphasize: true,
                            ),
                          if (data.orderOperation.isNotEmpty)
                            _InfoRow(
                              label: 'LSX · CĐ',
                              value: data.orderOperation,
                            ),
                          if (data.businessDateShift.isNotEmpty)
                            _InfoRow(
                              label: 'Ngày · Ca',
                              value: data.businessDateShift,
                            ),
                          if (data.createdAt.isNotEmpty)
                            _InfoRow(
                              label: 'Tạo lúc',
                              value: data.createdAt,
                              isLast: true,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (data.stoppedWorkerChain) ...[
                  const SizedBox(height: 12),
                  const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: CaslaColors.muted,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Chuỗi đồng bộ của công nhân đã dừng tại giao dịch này.',
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: CaslaColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: CaslaColors.gold100,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.lightbulb_outline_rounded,
                        size: 20,
                        color: CaslaColors.gold700,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Cách xử lý',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: CaslaColors.gold700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              data.guidance,
                              style: const TextStyle(
                                fontSize: 12.5,
                                height: 1.45,
                                color: CaslaColors.bannerText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (technicalText.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      title: const Text(
                        'Chi tiết kỹ thuật',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: CaslaColors.muted,
                        ),
                      ),
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                          decoration: BoxDecoration(
                            color: CaslaColors.muted100,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: SelectableText(
                                  technicalText,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11.5,
                                    height: 1.45,
                                    color: CaslaColors.primaryNavy,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Sao chép mã lỗi',
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: technicalText),
                                  );
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Đã sao chép mã lỗi.'),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.copy_outlined, size: 20),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else
                  const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 52),
                      backgroundColor: CaslaColors.primaryNavy,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text(
                      'Quay lại danh sách',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _hasTransactionDetails =>
      data.transactionSummary.isNotEmpty ||
      data.orderOperation.isNotEmpty ||
      data.businessDateShift.isNotEmpty ||
      data.createdAt.isNotEmpty;
}

class _StatusLabel extends StatelessWidget {
  final String label;

  const _StatusLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: CaslaColors.dangerBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 15,
            color: CaslaColors.danger,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: CaslaColors.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasize;
  final bool isLast;

  const _InfoRow({
    required this.label,
    required this.value,
    this.emphasize = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: CaslaColors.muted),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
