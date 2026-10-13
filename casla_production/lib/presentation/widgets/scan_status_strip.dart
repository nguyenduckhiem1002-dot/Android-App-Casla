import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import 'barcode_scan_listener.dart';

/// Tells the operator, at a glance, whether the trigger will do anything.
///
/// Without this the reader is invisible: pulling the trigger and getting no
/// response is indistinguishable from a bad label, a dead scanner and a screen
/// that simply is not listening. One line at the top of the form removes that
/// whole class of confusion.
class ScanStatusStrip extends StatelessWidget {
  const ScanStatusStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final status = BarcodeScanListener.statusOf(context);
    if (status == null) return const SizedBox.shrink();

    final (background, foreground, icon) = switch (status.state) {
      HardwareScanState.probing => (
        CaslaColors.muted100,
        CaslaColors.muted,
        Icons.hourglass_empty_rounded,
      ),
      HardwareScanState.ready => (
        CaslaColors.successBg,
        CaslaColors.success,
        Icons.sensors_rounded,
      ),
      HardwareScanState.busy => (
        CaslaColors.gold100,
        CaslaColors.gold700,
        Icons.downloading_rounded,
      ),
      HardwareScanState.unavailable => (
        CaslaColors.muted100,
        CaslaColors.muted,
        Icons.sensors_off_rounded,
      ),
    };

    return Semantics(
      liveRegion: true,
      label: status.message,
      child: Container(
        width: double.infinity,
        color: background,
        padding: const EdgeInsets.symmetric(
          horizontal: CaslaSpacing.md,
          vertical: CaslaSpacing.xs,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: CaslaSpacing.xs),
            Expanded(
              child: Text(
                status.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: CaslaType.caption,
                  fontWeight: FontWeight.w700,
                  color: foreground,
                ),
              ),
            ),
            if (status.acceptedCount > 0)
              Text(
                '${status.acceptedCount} mã',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: CaslaType.caption,
                  color: foreground,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Persistent, dismissible banner for a rejected scan.
///
/// A snackbar is the wrong container here: it covers the submit button, and it
/// vanishes before an operator who was looking at the pallet has looked back
/// at the screen.
class ScanErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const ScanErrorBanner({
    super.key,
    required this.message,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Lỗi quét mã. $message',
      child: Container(
        width: double.infinity,
        color: CaslaColors.dangerBg,
        padding: const EdgeInsets.fromLTRB(
          CaslaSpacing.md,
          CaslaSpacing.xs,
          CaslaSpacing.xs,
          CaslaSpacing.xs,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 20,
              color: CaslaColors.danger,
            ),
            const SizedBox(width: CaslaSpacing.xs),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  message,
                  style: const TextStyle(
                    fontSize: CaslaType.caption,
                    fontWeight: FontWeight.w600,
                    color: CaslaColors.danger,
                    height: 1.35,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Đóng thông báo',
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 18),
              color: CaslaColors.danger,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}
