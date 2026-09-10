import 'package:flutter/material.dart';

import '../../app/theme/casla_spacing.dart';
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
          borderRadius: BorderRadius.circular(CaslaRadius.lg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: CaslaType.body,
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
                    fontWeight: FontWeight.w800,
                    fontSize: CaslaType.display,
                    color: Colors.white,
                    height: 1.0,
                  ),
                ),
                if (uom != null) ...[
                  const SizedBox(width: 3),
                  Text(
                    uom!,
                    style: const TextStyle(
                      fontSize: CaslaType.caption,
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
        borderRadius: BorderRadius.circular(CaslaRadius.lg),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: CaslaType.body,
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
                  fontWeight: FontWeight.w800,
                  fontSize: CaslaType.display,
                  color: valueColor ?? CaslaColors.primaryNavy,
                  height: 1.0,
                ),
              ),
              if (uom != null) ...[
                const SizedBox(width: 3),
                Text(
                  uom!,
                  style: const TextStyle(
                    fontSize: CaslaType.caption,
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
