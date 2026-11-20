import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import 'casla_dialog_header.dart';
import '../../domain/entities/mutation_receipt.dart';

bool _requiresDataCorrection(String? code) => switch (code) {
  'OPERATION_QUANTITY_EXCEEDED' ||
  'CONFIRM_QUANTITY_EXCEEDED' ||
  'RECALL_QUANTITY_EXCEEDED' ||
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
    case 'RECALL_QUANTITY_EXCEEDED':
      return 'Làm mới số dư công nhân rồi nhập lại số lượng thu hồi.';
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
  'WORKER_NO_ACCOUNT' =>
    'Công nhân chưa có tài khoản. Không nhập lại mật khẩu; báo quản trị '
        'tạo tài khoản cho công nhân.',
  'WORKER_IS_INACTIVE' =>
    'Tài khoản công nhân đã vô hiệu hóa. Không nhập lại mật khẩu; báo '
        'quản trị kích hoạt lại tài khoản.',
  'MANAGER_OPERATION_NOT_ALLOWED' =>
    'Hãy chọn vị trí làm việc có quyền với công đoạn này.',
  'WORKER_OPERATION_NOT_ALLOWED' =>
    'Hãy chọn công nhân khác hoặc yêu cầu cấp lại quyền cho công nhân.',
  'MANAGER_WORKER_NOT_ALLOWED' =>
    'Công nhân không thuộc tổ bạn được cấp quyền. Không thử lại; báo '
        'quản trị cấp tổ cho đúng role.',
  'WORKER_NOT_IN_WORK_CENTER' =>
    'Công nhân không thuộc Work Center của công đoạn. Chọn công nhân khác '
        'hoặc quét lại đúng công đoạn.',
  'WORKER_ASSIGNMENT_EXPIRED' =>
    'Phân công của công nhân đã hết hiệu lực. Không thử lại; báo quản trị.',
  'MISSING_PERMISSION' =>
    'Tài khoản không có quyền với chức năng này. Liên hệ quản trị.',
  'RECALL_NOPASS_NOT_ALLOWED' =>
    'Tài khoản chưa được cấp quyền thu hồi không cần mật khẩu. Thu hồi lại '
        'bằng mật khẩu công nhân hoặc báo quản trị cấp quyền.',
  'WORK_NOT_FOUND' => 'Hãy chọn lại vị trí làm việc khác.',
  'NO_REMAINING_QUANTITY' =>
    'Giao thêm việc cho công nhân trên công đoạn này rồi mới xác nhận tiếp.',
  'POSITION_GROUP_MISMATCH' =>
    'Công nhân còn việc chưa xác nhận hết ở vị trí khác của lệnh này. Xác '
        'nhận hoặc thu hồi hết ở vị trí cũ, hoặc giao lại đúng vị trí đó.',
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
        // The close button carries its own 8 px of tap area around it.
        titlePadding: const EdgeInsets.fromLTRB(
          CaslaDialog.padding,
          CaslaDialog.verticalPadding - 8,
          CaslaDialog.padding - 8,
          0,
        ),
        contentPadding: CaslaDialog.contentPadding,
        title: CaslaDialogHeader(
          dividerEndIndent: 8,
          child: Row(
            children: [
              if (refused) ...[
                const Icon(Icons.error, color: CaslaColors.danger, size: 22),
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
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.of(dialogContext).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'SAP phản hồi',
                style: TextStyle(
                  fontSize: 13,
                  color: CaslaColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                receipt.message ?? message,
                style: TextStyle(
                  fontSize: 16,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                  color: refused ? CaslaColors.danger : CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: CaslaColors.muted100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Mã lỗi',
                      style: TextStyle(fontSize: 13, color: CaslaColors.muted),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      receipt.code ?? 'ERR_UNKNOWN',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        height: 1.4,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Hướng xử lý',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _recoveryGuidance(receipt),
                style: const TextStyle(
                  fontSize: 14,
                  height: CaslaDialog.lineHeight,
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
                minimumSize: const Size.fromHeight(CaslaDialog.buttonHeight),
                backgroundColor: CaslaColors.primaryNavy,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(CaslaRadius.md),
                ),
              ).merge(CaslaDialog.actionStyle),
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
                minimumSize: const Size.fromHeight(CaslaDialog.buttonHeight),
              ).merge(CaslaDialog.actionStyle),
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
