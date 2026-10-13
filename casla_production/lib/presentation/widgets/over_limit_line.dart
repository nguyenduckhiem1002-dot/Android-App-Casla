import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';

/// One amber line under a quantity field whose value is above what is left.
///
/// A warning, not an error: giving or confirming more than the remaining
/// quantity is allowed, the supervisor only has to see that it is the case.
class OverLimitLine extends StatelessWidget {
  final String text;

  const OverLimitLine(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: CaslaSpacing.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: CaslaColors.pending,
            ),
          ),
          const SizedBox(width: CaslaSpacing.xxs),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w600,
                color: CaslaColors.pending,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Amber outline for a quantity field while its value is above the limit, so
/// the field and [OverLimitLine] read as one warning.
InputBorder overLimitBorder({double width = 1.5}) => OutlineInputBorder(
  borderRadius: BorderRadius.circular(CaslaRadius.sm),
  borderSide: BorderSide(color: CaslaColors.pending, width: width),
);
