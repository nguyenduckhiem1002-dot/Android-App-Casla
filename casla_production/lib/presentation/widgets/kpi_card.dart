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
          gradient: const LinearGradient(
            colors: [CaslaColors.primaryNavy, CaslaColors.navy700],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: CaslaColors.accentLabelDark,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
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
                      fontSize: 11,
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
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: CaslaColors.muted,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
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
