import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../data/sap/sap_shift_controller.dart';
import '../../domain/entities/entities.dart';

/// Keeps the SAP operation context visible wherever a supervisor writes data.
/// The value is intentionally rendered from the selected [UserWorkContext]
/// and [SapShift] objects, so the label can never imply a Xưởng (Work Center)
/// / Bộ phận pair that was not returned by SAP.
class ActiveShiftContextCard extends StatelessWidget {
  final UserWorkContext? workContext;
  final SapShift? shift;
  final DateTime businessDate;
  final VoidCallback? onEdit;
  final bool compact;

  /// Uses one compact metadata line for forms where the card should leave
  /// room for the scanned operation details below it.
  final bool dense;

  const ActiveShiftContextCard({
    super.key,
    required this.workContext,
    required this.shift,
    required this.businessDate,
    this.onEdit,
    this.compact = false,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final work = workContext;
    final selectedShift = shift;
    final dateLabel =
        '${businessDate.day.toString().padLeft(2, '0')}/'
        '${businessDate.month.toString().padLeft(2, '0')}/'
        '${businessDate.year}';
    final hasSelection = work != null && selectedShift != null;
    final workshop = work?.workCenterLabel ?? '';
    final workshopLabel = workshop.isEmpty ? '' : 'Xưởng: $workshop';
    final department = work?.departmentLabel ?? '';
    final departmentLabel = department.isEmpty ? '' : 'Bộ phận: $department';
    final details = [
      if (workshopLabel.isNotEmpty) workshopLabel,
      if (departmentLabel.isNotEmpty) departmentLabel,
    ];

    return Semantics(
      container: true,
      label: hasSelection
          ? 'Ca đang làm ${selectedShift.shiftName}, ngày $dateLabel, '
                '${details.join(', ')}'
          : 'Chưa thiết lập ca làm việc',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 12 : (compact ? 12 : 16),
          vertical: dense ? 9 : (compact ? 12 : 16),
        ),
        decoration: BoxDecoration(
          color: hasSelection ? CaslaColors.surface : CaslaColors.pendingBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: hasSelection ? CaslaColors.line : CaslaColors.gold100,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: dense ? 32 : 36,
              height: dense ? 32 : 36,
              decoration: BoxDecoration(
                color: hasSelection
                    ? CaslaColors.primaryNavy
                    : CaslaColors.accentGold,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                hasSelection
                    ? Icons.schedule_outlined
                    : Icons.warning_amber_rounded,
                color: Colors.white,
                size: dense ? 18 : 20,
              ),
            ),
            SizedBox(width: dense ? 8 : 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasSelection
                        ? 'Ca đang làm · $dateLabel'
                        : 'Chưa chọn ca làm việc',
                    style: TextStyle(
                      color: CaslaColors.primaryNavy,
                      fontSize: dense ? 11 : 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: dense ? 2 : 4),
                  if (hasSelection) ...[
                    Text(
                      '${selectedShift.shiftName} · ${selectedShift.timeLabel}',
                      style: const TextStyle(
                        color: CaslaColors.primaryNavy,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: dense ? 2 : 3),
                    if (dense)
                      Text(
                        details.join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.clip,
                        style: const TextStyle(
                          color: CaslaColors.muted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else
                      Text(
                        details.join('\n'),
                        style: const TextStyle(
                          color: CaslaColors.muted,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ] else
                    const Text(
                      'Thiết lập Xưởng, Bộ phận và ca để tiếp tục.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: CaslaColors.gold700,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                ],
              ),
            ),
            if (onEdit != null)
              SizedBox(
                width: dense ? 56 : (compact ? 64 : 78),
                height: dense ? 40 : 48,
                child: TextButton(
                  onPressed: onEdit,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    foregroundColor: CaslaColors.primaryNavy,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(hasSelection ? 'Đổi' : 'Thiết lập'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
