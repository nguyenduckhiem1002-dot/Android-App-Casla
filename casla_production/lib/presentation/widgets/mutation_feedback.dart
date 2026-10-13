import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/casla_colors.dart';
import '../../domain/entities/mutation_receipt.dart';

bool _requiresDataCorrection(String? code) => switch (code) {
  'OPERATION_QUANTITY_EXCEEDED' ||
  'CONFIRM_QUANTITY_EXCEEDED' ||
  'SOURCE_BALANCE_INSUFFICIENT' ||
  'CONFIRM_ORIGINAL_QUANTITY_EXCEEDED' ||
  'WORKER_BALANCE_NOT_FOUND' ||
  'REVERSE_BALANCE_INCONSISTENT' => true,
  _ => false,
};

String _recoveryGuidance(MutationReceipt receipt) {
  if (receipt.state == MutationDeliveryState.discarded) {
    return '${_refusalGuidance(receipt.code)} '
        'Giao dịch không được lưu và không đưa vào mục Đồng bộ.';
  }
  switch (receipt.code) {
    case 'OPERATION_QUANTITY_EXCEEDED':
      return 'Làm mới sản lượng công đoạn rồi nhập lại số lượng giao.';
    case 'CONFIRM_QUANTITY_EXCEEDED':
      return 'Làm mới số dư công nhân rồi nhập lại số lượng xác nhận.';
    case 'SOURCE_BALANCE_INSUFFICIENT':
      return 'Làm mới số dư nguồn rồi nhập lại số lượng.';
    case 'CONFIRM_ORIGINAL_QUANTITY_EXCEEDED':
      return 'Làm mới số còn lại của giao dịch gốc rồi nhập lại.';
    case 'WORKER_BALANCE_NOT_FOUND':
      return 'Công nhân chưa có phân bổ cho công đoạn này. Hãy giao việc trước.';
    case 'REVERSE_BALANCE_INCONSISTENT':
      return 'Không gửi lại giao dịch. Cần kiểm tra lại số dư và ledger.';
    default:
      if (receipt.state == MutationDeliveryState.needsVerification) {
        return 'Mở Đồng bộ để xác minh lại công nhân.';
      }
      return 'Giao dịch đã được lưu trên thiết bị. Mở Đồng bộ để kiểm tra và xử lý.';
  }
}

String _refusalGuidance(String? code) => switch (code) {
  'USER_INACTIVE' =>
    'Tài khoản đã bị khóa/ngừng hoạt động. Không thử lại; báo quản trị.',
  'WORKER_AUTH_FAILED' =>
    'Mật khẩu công nhân sai hoặc tài khoản công nhân không hợp lệ.',
  'MANAGER_OPERATION_NOT_ALLOWED' =>
    'Hãy chọn vị trí làm việc có quyền với công đoạn này.',
  'WORKER_OPERATION_NOT_ALLOWED' =>
    'Hãy chọn công nhân khác hoặc yêu cầu cấp lại quyền cho công nhân.',
  'WORKER_ASSIGNMENT_EXPIRED' =>
    'Phân công của công nhân đã hết hiệu lực. Không thử lại; báo quản trị.',
  'MISSING_PERMISSION' =>
    'Tài khoản không có quyền với chức năng này. Liên hệ quản trị.',
  'WORK_NOT_FOUND' => 'Hãy chọn lại vị trí làm việc khác.',
  'POSITION_GROUP_MISMATCH' =>
    'Quét lại đúng vị trí đã giao cho công nhân ở lần trước trong ca rồi '
        'giao lại.',
  'POSITION_NOT_ACTIVE' =>
    'Mở tab Vị trí, quét nhãn của máy này để tạo vị trí, rồi quay lại giao '
        'việc. Hoặc xóa ô Vị trí / mã máy để giao mà không ghi vị trí.',
  'WORK_CONTEXT_MISMATCH' => 'Hãy quét lại QR hoặc chọn đúng vị trí làm việc.',
  'WORK_OPERATION_MISMATCH' =>
    'Vị trí làm việc không khớp công đoạn. Không thể tiếp tục.',
  'OPERATION_DEPARTMENT_MISMATCH' =>
    'Không thể tiếp tục; cần sửa cấu hình master công đoạn.',
  'OPERATION_QUANTITY_EXCEEDED' =>
    'Làm mới sản lượng công đoạn rồi nhập lại số lượng giao.',
  'CONFIRM_QUANTITY_EXCEEDED' =>
    'Làm mới số dư công nhân rồi nhập lại số lượng xác nhận.',
  'SOURCE_BALANCE_INSUFFICIENT' => 'Làm mới số dư nguồn rồi nhập lại số lượng.',
  'CONFIRM_ORIGINAL_QUANTITY_EXCEEDED' =>
    'Làm mới số còn lại của giao dịch gốc rồi nhập lại.',
  'WORKER_BALANCE_NOT_FOUND' =>
    'Công nhân chưa có phân bổ cho công đoạn này. Hãy giao việc trước.',
  _ => 'Kiểm tra lại thông tin theo phản hồi của SAP rồi thử lại.',
};

Future<void> showMutationFeedback(
  BuildContext context, {
  required MutationReceipt receipt,
  required String successMessage,
  bool persistNonSuccess = false,
}) async {
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
          : 'SAP chưa chấp nhận giao dịch. Bản ghi cục bộ vẫn được giữ lại để kiểm tra: ${receipt.message ?? 'Cần kiểm tra lại dữ liệu.'}',
      CaslaColors.danger,
    ),
    MutationDeliveryState.discarded => (
      'SAP từ chối: ${receipt.message ?? 'SAP không chấp nhận giao dịch.'} '
          'Giao dịch không được lưu.',
      CaslaColors.danger,
    ),
  };
  final refused = receipt.isRefused;

  if ((persistNonSuccess || receipt.state == MutationDeliveryState.discarded) &&
      receipt.state != MutationDeliveryState.synced) {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: CaslaColors.surface,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        titleTextStyle: const TextStyle(
          fontSize: 18,
          height: 1.3,
          fontWeight: FontWeight.w800,
          color: CaslaColors.primaryNavy,
        ),
        title: Row(
          children: [
            if (refused) ...[
              const Icon(Icons.error, color: CaslaColors.danger),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                receipt.state == MutationDeliveryState.discarded
                    ? 'SAP từ chối thao tác'
                    : refused || _requiresDataCorrection(receipt.code)
                    ? 'Phân công chưa thành công'
                    : 'Phân công chờ xác nhận',
                style: refused
                    ? const TextStyle(color: CaslaColors.danger)
                    : null,
              ),
            ),
            IconButton(
              tooltip: 'Đóng',
              onPressed: () => Navigator.of(dialogContext).pop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Divider(height: 1, color: CaslaColors.line),
              const SizedBox(height: 20),
              const Text(
                'SAP phản hồi',
                style: TextStyle(
                  fontSize: 12,
                  color: CaslaColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                receipt.message ?? message,
                style: TextStyle(
                  fontSize: 16,
                  height: 1.5,
                  fontWeight: FontWeight.w600,
                  color: refused ? CaslaColors.danger : CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: CaslaColors.muted100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Mã lỗi',
                      style: TextStyle(fontSize: 12, color: CaslaColors.muted),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      receipt.code ?? 'ERR_UNKNOWN',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.5,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Hướng xử lý',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _recoveryGuidance(receipt),
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: CaslaColors.muted,
                ),
              ),
            ],
          ),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: CaslaColors.primaryNavy,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Đã hiểu'),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: () => Clipboard.setData(
                ClipboardData(
                  text:
                      'Phân công: ${receipt.id}\nMã lỗi: ${receipt.code ?? 'ERR_UNKNOWN'}\nSAP phản hồi: ${receipt.message ?? message}',
                ),
              ),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Sao chép thông tin hỗ trợ'),
              style: TextButton.styleFrom(
                foregroundColor: CaslaColors.muted,
                minimumSize: const Size.fromHeight(44),
              ),
            ),
          ),
        ],
      ),
    );
    return;
  }

  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
}
