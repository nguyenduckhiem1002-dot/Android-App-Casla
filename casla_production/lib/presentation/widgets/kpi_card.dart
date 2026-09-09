import 'package:flutter/material.dart';
import '../../app/theme/casla_colors.dart';

class KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final String? uom;
  final bool isAccent;
  final Color? valueColor;

  const KpiCard({
    super.key,
    required this.label,
    required this.value,
    this.uom,
    this.isAccent = false,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    if (isAccent) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: CaslaColors.primaryNavy,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: CaslaColors.contextChipText,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w800,
                    fontSize: 26,
                    color: Colors.white,
                    height: 1.0,
                  ),
                ),
                if (uom != null) ...[
                  const SizedBox(width: 3),
                  Text(
                    uom!,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: CaslaColors.accentLabelDark,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        border: Border.all(color: CaslaColors.line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: CaslaColors.muted,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w800,
                  fontSize: 26,
                  color: valueColor ?? CaslaColors.primaryNavy,
                  height: 1.0,
                ),
              ),
              if (uom != null) ...[
                const SizedBox(width: 3),
                Text(
                  uom!,
                  style: const TextStyle(
                    fontSize: 11,
                    color: CaslaColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
