import 'package:flutter/material.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';

/// One row of filter chips that scrolls sideways instead of wrapping, so the
/// list below starts one line down whatever the counts are.
class CompactFilterRow extends StatelessWidget {
  final List<Widget> children;

  const CompactFilterRow({super.key, required this.children});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    clipBehavior: Clip.none,
    child: Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: CaslaSpacing.xs),
          children[i],
        ],
      ],
    ),
  );
}

/// A short pill: label with its count, navy when selected.
class CompactFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;

  const CompactFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    selected: selected,
    showCheckmark: false,
    selectedColor: CaslaColors.primaryNavy,
    backgroundColor: CaslaColors.surface,
    side: BorderSide(
      color: selected ? CaslaColors.primaryNavy : CaslaColors.line,
    ),
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
    labelPadding: EdgeInsets.zero,
    labelStyle: TextStyle(
      fontSize: CaslaType.caption,
      fontWeight: FontWeight.w700,
      color: selected ? Colors.white : CaslaColors.muted,
    ),
    onSelected: (_) => onSelected(),
  );
}

/// Search box and filter chips pinned above a list that scrolls on its own.
/// Goes into a `PinnedHeaderSliver`, which paints over the rows that slide
/// under it; the elevation draws that edge.
class FilterHeader extends StatelessWidget {
  final List<Widget> children;

  const FilterHeader({super.key, required this.children});

  @override
  Widget build(BuildContext context) => Material(
    color: CaslaColors.background,
    elevation: 3,
    shadowColor: Colors.black38,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        CaslaSpacing.md,
        CaslaSpacing.sm,
        CaslaSpacing.md,
        CaslaSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}
