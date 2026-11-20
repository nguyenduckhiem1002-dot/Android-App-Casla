import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';

/// The title block of every popup: the heading, an optional line under it
/// (who or what the popup is about), then a faint rule that sets it apart
/// from the content below.
///
/// Pass it as an [AlertDialog]'s `title`; the heading keeps the dialog
/// theme's title style.
class CaslaDialogHeader extends StatelessWidget {
  final Widget child;
  final Widget? subtitle;

  /// Pulls the line's right end in when the title padding was narrowed for
  /// a close button, so the line still ends where the content does.
  final double dividerEndIndent;

  const CaslaDialogHeader({
    super.key,
    required this.child,
    this.subtitle,
    this.dividerEndIndent = 0,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        child,
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          DefaultTextStyle.merge(
            style: const TextStyle(
              fontSize: CaslaDialog.bodySize,
              height: 1.35,
              fontWeight: FontWeight.w400,
              color: CaslaColors.muted,
            ),
            child: subtitle,
          ),
        ],
        const SizedBox(height: CaslaDialog.headerGap),
        Divider(
          height: 1,
          thickness: 1,
          endIndent: dividerEndIndent,
          color: CaslaColors.line,
        ),
      ],
    );
  }
}
