import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../core/utils/quantity_formatter.dart';
import '../../domain/policies/unit_totals.dart';

/// Header of a worker's detail screen: given · recalled · completed · scrap ·
/// remaining, a stacked bar that adds up to the given quantity, and the
/// completion rate against given minus recalled.
///
/// "Tất cả" adds every unit together; with more than one unit, chips narrow
/// the figures to one unit. The figures carry no unit on purpose; the unit
/// shows on the chips and the cards below.
class WorkerTotalsHeader extends StatefulWidget {
  final List<UnitTotals> units;

  const WorkerTotalsHeader({super.key, required this.units});

  @override
  State<WorkerTotalsHeader> createState() => _WorkerTotalsHeaderState();
}

class _WorkerTotalsHeaderState extends State<WorkerTotalsHeader> {
  /// Selected unit; null is "Tất cả".
  String? _unit;

  /// SAP's remaining is authoritative (it also nets transfers): once the
  /// remaining shown is 0, whatever was completed is the whole job. Without
  /// this, fractions hidden by whole-unit rounding (2.499,6 shown as 2.500)
  /// read 99% next to "Còn lại 0".
  static double _completionRate(UnitTotals totals, String unit) {
    final nothingLeft = !hasRemainingQuantity(totals.remaining, uom: unit);
    return nothingLeft && totals.completed > 0 ? 1.0 : totals.completionRate;
  }

  @override
  Widget build(BuildContext context) {
    final units = widget.units;
    // A unit that is no longer reported falls back to "Tất cả".
    final selected = units.where((u) => u.unit == _unit).firstOrNull;
    final shown = selected ?? UnitTotals.sum(units);
    final multi = units.length > 1;
    final scope = selected != null
        ? 'Đơn vị: ${selected.unit}'
        : multi
        ? 'Đang cộng ${units.length} đơn vị: '
              '${units.map((u) => u.unit).join(', ')}'
        : units.isEmpty
        ? 'Chưa có số liệu trong kỳ này'
        : 'Đơn vị: ${units.single.unit}';
    // Rounds like a count unit only when a single unit is shown.
    final formatUnit = shown.unit;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: CaslaColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (multi) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _UnitChip(
                  key: const ValueKey('unit-chip-all'),
                  label: 'Tất cả',
                  selected: selected == null,
                  onTap: () => setState(() => _unit = null),
                ),
                for (final u in units)
                  _UnitChip(
                    key: ValueKey('unit-chip-${u.unit}'),
                    label: u.unit,
                    detail: formatQuantity(u.given, uom: u.unit),
                    selected: selected?.unit == u.unit,
                    onTap: () => setState(() => _unit = u.unit),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              _Figure(
                label: 'Tổng giao',
                value: formatQuantity(shown.given, uom: formatUnit),
                color: CaslaColors.primaryNavy,
                first: true,
              ),
              _Figure(
                label: 'Thu hồi',
                value: formatQuantity(shown.recalled, uom: formatUnit),
                color: CaslaColors.danger,
              ),
              _Figure(
                label: 'Hoàn thành',
                value: formatQuantity(shown.completed, uom: formatUnit),
                color: CaslaColors.success,
              ),
              _Figure(
                label: 'Phế',
                value: formatQuantity(shown.defect, uom: formatUnit),
                color:
                    shown.defect > 0 &&
                        formatQuantity(shown.defect, uom: formatUnit) != '0'
                    ? CaslaColors.scrap
                    : CaslaColors.muted,
              ),
              _Figure(
                label: 'Còn lại',
                value: formatQuantity(shown.remaining, uom: formatUnit),
                color: CaslaColors.pending,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _StackedBar(totals: shown),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Tiến độ trên giao hiệu lực',
                  style: TextStyle(fontSize: 11.5, color: CaslaColors.muted),
                ),
              ),
              Text(
                formatCompletionPercent(_completionRate(shown, formatUnit)),
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: CaslaColors.primaryNavy,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            scope,
            key: const ValueKey('worker-totals-scope'),
            style: const TextStyle(
              fontSize: 11.5,
              color: CaslaColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _UnitChip extends StatelessWidget {
  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  const _UnitChip({
    super.key,
    required this.label,
    this.detail,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : CaslaColors.primaryNavy;
    return Semantics(
      button: true,
      selected: selected,
      label: detail == null ? label : '$label, giao $detail',
      excludeSemantics: true,
      child: Material(
        color: selected ? CaslaColors.primaryNavy : CaslaColors.surface,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? CaslaColors.primaryNavy : CaslaColors.line,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            // A comfortable glove-sized target on the PDA.
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: foreground,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      detail!,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? CaslaColors.onDarkSecondary
                            : CaslaColors.muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool first;

  const _Figure({
    required this.label,
    required this.value,
    required this.color,
    this.first = false,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.only(left: first ? 0 : 8, right: 4),
        decoration: first
            ? null
            : const BoxDecoration(
                border: Border(left: BorderSide(color: CaslaColors.line)),
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The value's colour matches its bar segment; no swatch needed.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: CaslaColors.muted,
                ),
              ),
            ),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Completed + scrap + recalled + remaining, side by side, over the given
/// quantity.
class _StackedBar extends StatelessWidget {
  final UnitTotals totals;

  const _StackedBar({required this.totals});

  @override
  Widget build(BuildContext context) {
    final segments = [
      (totals.completed, CaslaColors.success),
      (totals.defect, CaslaColors.scrap),
      (totals.recalled, CaslaColors.danger),
      (totals.remaining, CaslaColors.accentGold),
    ].where((s) => s.$1 > 0).toList();
    final whole = segments.fold(0.0, (sum, s) => sum + s.$1);
    return Semantics(
      label:
          'Hoàn thành ${formatQuantity(totals.completed)}, '
          'phế ${formatQuantity(totals.defect)}, '
          'thu hồi ${formatQuantity(totals.recalled)}, '
          'còn lại ${formatQuantity(totals.remaining)} '
          'trên tổng giao ${formatQuantity(totals.given)}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Container(
          height: 10,
          color: CaslaColors.muted100,
          child: whole <= 0
              ? null
              : Row(
                  // Childless ColoredBoxes take the smallest height they are
                  // allowed; stretch them to the bar's height or none shows.
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < segments.length; i++) ...[
                      if (i > 0) const SizedBox(width: 2),
                      Expanded(
                        // Integer flex; thousandths keep small parts visible.
                        flex: (segments[i].$1 / whole * 1000).ceil(),
                        child: ColoredBox(color: segments[i].$2),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}
