import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../domain/entities/mutation_receipt.dart';

void showMutationFeedback(
  BuildContext context, {
  required MutationReceipt receipt,
  required String successMessage,
}) {
  final (message, color) = switch (receipt.state) {
    MutationDeliveryState.synced => (
      '$successMessage SAP đã xác nhận giao dịch.',
      CaslaColors.success,
    ),
    MutationDeliveryState.queued => (
      'Đã lưu an toàn trên thiết bị. ${receipt.message ?? 'Chưa gửi được SAP; theo dõi tại mục Đồng bộ.'}',
      CaslaColors.pending,
    ),
    MutationDeliveryState.needsVerification => (
      'Đã lưu trên thiết bị. ${receipt.message ?? 'Cần xác minh công nhân tại mục Đồng bộ để gửi SAP.'}',
      CaslaColors.gold700,
    ),
    MutationDeliveryState.rejected => (
      receipt.code == 'WORKER_AUTH_FAILED'
          ? 'Mật khẩu công nhân chưa đúng. Giao dịch đã được giữ lại; mở Đồng bộ để xác minh lại.'
          : 'Đã lưu trên thiết bị nhưng SAP từ chối: ${receipt.message ?? 'Cần kiểm tra lại dữ liệu.'}',
      CaslaColors.danger,
    ),
  };

  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
}
