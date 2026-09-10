import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import '../../domain/entities/mutation_receipt.dart';

/// Reports what SAP did with a write.
///
/// The outcome decides the container, not the styling. A transient snackbar is
/// right for "SAP took it" and for "queued, the engine will retry" — nothing is
/// asked of the operator. It is wrong for the two states that need a human to
/// act, because a snackbar disappears after four seconds and takes the only
/// notice of a failed write with it. Those get a dialog with a way to reach the
/// sync queue.
Future<void> showMutationFeedback(
  BuildContext context, {
  required MutationReceipt receipt,
  required String successMessage,
}) async {
  switch (receipt.state) {
    case MutationDeliveryState.synced:
      _snack(
        context,
        '$successMessage SAP đã xác nhận giao dịch.',
        CaslaColors.success,
      );

    case MutationDeliveryState.queued:
      _snack(
        context,
        'Đã lưu an toàn trên thiết bị. '
        '${receipt.message ?? 'Chưa gửi được SAP; app sẽ tự gửi lại. Theo dõi tại mục Đồng bộ.'}',
        CaslaColors.pending,
      );

    case MutationDeliveryState.needsVerification:
      await _actionableDialog(
        context,
        icon: Icons.lock_outline_rounded,
        accent: CaslaColors.gold700,
        title: 'Cần xác minh công nhân',
        message:
            receipt.message ??
            'Giao dịch đã lưu trên thiết bị nhưng chưa gửi được SAP. '
                'Hãy mở mục Đồng bộ để công nhân nhập lại mật khẩu.',
      );

    case MutationDeliveryState.rejected:
      await _actionableDialog(
        context,
        icon: Icons.error_outline_rounded,
        accent: CaslaColors.danger,
        title: receipt.code == 'WORKER_AUTH_FAILED'
            ? 'Mật khẩu công nhân chưa đúng'
            : 'SAP chưa chấp nhận giao dịch',
        message: receipt.code == 'WORKER_AUTH_FAILED'
            ? 'Giao dịch đã được giữ lại trên thiết bị. Mở mục Đồng bộ để xác minh lại.'
            : 'Bản ghi vẫn được giữ trên thiết bị để kiểm tra. '
                  '${receipt.message ?? 'Cần kiểm tra lại dữ liệu.'}',
      );
  }
}

void _snack(BuildContext context, String message, Color color) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(seconds: 4),
      ),
    );
}

Future<void> _actionableDialog(
  BuildContext context, {
  required IconData icon,
  required Color accent,
  required String title,
  required String message,
}) async {
  if (!context.mounted) return;

  final openSync = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(icon, color: accent, size: 32),
      title: Text(title),
      content: Text(
        message,
        style: const TextStyle(fontSize: CaslaType.body, height: 1.45),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        CaslaSpacing.md,
        CaslaSpacing.xs,
        CaslaSpacing.md,
        CaslaSpacing.md,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Để sau'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(dialogContext, true),
          icon: const Icon(Icons.sync, size: 18),
          label: const Text('Mở Đồng bộ'),
        ),
      ],
    ),
  );

  if (openSync == true && context.mounted) unawaited(context.push('/sync'));
}
