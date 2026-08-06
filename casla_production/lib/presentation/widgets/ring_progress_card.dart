import 'package:flutter/material.dart';
import '../../app/theme/casla_colors.dart';

class RingProgressCard extends StatelessWidget {
  final double percentage;
  final String remainingValue;
  final String uom;
  final String detailText;

  const RingProgressCard({
    super.key,
    required this.percentage,
    required this.remainingValue,
    this.uom = 'cái',
    required this.detailText,
  });

  @override
  Widget build(BuildContext context) {
    final pctInt = (percentage * 100).clamp(0, 100).toInt();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        border: Border.all(color: CaslaColors.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          // Conic Ring representation using CircularProgressIndicator or CustomPainter
          SizedBox(
            width: 78,
            height: 78,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 78,
                  height: 78,
                  child: CircularProgressIndicator(
                    value: (percentage).clamp(0.0, 1.0),
                    strokeWidth: 8,
                    backgroundColor: CaslaColors.muted100,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        CaslaColors.accentGold),
                  ),
                ),
                Text(
                  '$pctInt%',
                  style: const TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),

          // Detail info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Còn lại',
                  style: TextStyle(
                    fontSize: 11,
                    color: CaslaColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      remainingValue,
                      style: const TextStyle(
                        fontFamily: 'Manrope',
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      uom,
                      style: const TextStyle(
                        fontSize: 11,
                        color: CaslaColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  detailText,
                  style: const TextStyle(
                    fontSize: 12,
                    color: CaslaColors.muted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
