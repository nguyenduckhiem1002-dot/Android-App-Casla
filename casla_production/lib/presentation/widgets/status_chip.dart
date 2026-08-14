import 'package:flutter/material.dart';
import '../../app/theme/casla_colors.dart';

class StatusChip extends StatelessWidget {
  final String status;
  final String? label;

  const StatusChip({super.key, required this.status, this.label});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;

    switch (status.toUpperCase()) {
      case 'OPEN':
      case 'SYNCED':
        bg = CaslaColors.successBg;
        fg = CaslaColors.success;
        break;
      case 'PENDING':
        bg = CaslaColors.pendingBg;
        fg = CaslaColors.pending;
        break;
      case 'FAILED':
      case 'CLOSED':
      case 'RECALLED':
        bg = CaslaColors.dangerBg;
        fg = CaslaColors.danger;
        break;
      default:
        bg = CaslaColors.gold100;
        fg = CaslaColors.gold700;
    }

    final displayText = label ?? status.toUpperCase();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: fg.withValues(alpha: 0.22), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6.5,
            height: 6.5,
            decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            displayText,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: fg,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}
