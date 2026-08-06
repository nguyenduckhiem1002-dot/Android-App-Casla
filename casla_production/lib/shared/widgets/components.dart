// Shared Widgets — Component Library
// Spec: Section 6.3 (Component library)
// Matching index.html CSS pixel-perfect

import 'package:flutter/material.dart';
import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_typography.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';

// ─── Employee Identity Bar (Spec 6.3) ───────────────────────────────
class EmployeeIdentityBar extends StatelessWidget {
  final String name;
  final String maNv;
  final String teamName;
  final String contextDate;
  final VoidCallback? onSwitchUser;

  const EmployeeIdentityBar({
    super.key,
    required this.name,
    required this.maNv,
    required this.teamName,
    required this.contextDate,
    this.onSwitchUser,
  });

  @override
  Widget build(BuildContext context) {
    final initials = name.split(' ').length >= 2
        ? '${name.split(' ')[name.split(' ').length - 2][0]}${name.split(' ').last[0]}'
        : name.isNotEmpty ? name[0] : 'CG';

    return Container(
      color: CaslaColors.primaryNavy,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [CaslaColors.accentGold, CaslaColors.gold700],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Text(initials, style: const TextStyle(
                  fontFamily: CaslaTypography.fontDisplay,
                  fontWeight: FontWeight.w800, fontSize: 15,
                  color: CaslaColors.navy900,
                )),
              ),
              const SizedBox(width: 11),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: CaslaTypography.identityName),
                  const SizedBox(height: 2),
                  Text('$maNv · $teamName', style: CaslaTypography.identityMeta),
                ],
              )),
              if (onSwitchUser != null)
                GestureDetector(
                  onTap: onSwitchUser,
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.swap_horiz, color: Colors.white, size: 17),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.calendar_today, size: 12, color: CaslaColors.contextChipText),
                const SizedBox(width: 6),
                Text(contextDate, style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 11.5,
                  color: CaslaColors.contextChipText,
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── KPI Card (Spec 6.3) ────────────────────────────────────────────
class KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final String uom;
  final bool isAccent;

  const KpiCard({
    super.key,
    required this.label,
    required this.value,
    this.uom = '',
    this.isAccent = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isAccent ? null : CaslaColors.surface,
        gradient: isAccent ? const LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [CaslaColors.primaryNavy, CaslaColors.navy700],
        ) : null,
        border: isAccent ? null : Border.all(color: CaslaColors.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: CaslaTypography.kpiLabel.copyWith(
            color: isAccent ? CaslaColors.accentLabelDark : CaslaColors.muted,
          )),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(value, style: CaslaTypography.kpiValue.copyWith(
                color: isAccent ? Colors.white : CaslaColors.primaryNavy,
              )),
              if (uom.isNotEmpty) ...[
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(uom, style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600,
                    color: isAccent ? CaslaColors.accentLabelDark : CaslaColors.muted,
                  )),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Assignment Card (Spec 6.3) ─────────────────────────────────────
class AssignmentCard extends StatelessWidget {
  final Assignment assignment;
  final VoidCallback? onTap;

  const AssignmentCard({super.key, required this.assignment, this.onTap});

  @override
  Widget build(BuildContext context) {
    final progress = assignment.effectiveAssigned > 0
        ? (assignment.completedQuantity / assignment.effectiveAssigned).clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(top: 10),
        decoration: BoxDecoration(
          color: CaslaColors.surface,
          border: Border.all(color: CaslaColors.line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(assignment.orderCode, style: CaslaTypography.orderCode),
                    Text(assignment.productName, style: CaslaTypography.orderName),
                  ],
                )),
                StatusChip(status: assignment.status),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 7,
                backgroundColor: CaslaColors.muted100,
                valueColor: const AlwaysStoppedAnimation(CaslaColors.accentGold),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StatItem(label: 'Giao', value: assignment.effectiveAssigned.toInt().toString()),
                _StatItem(label: 'Hoàn thành', value: assignment.completedQuantity.toInt().toString()),
                _StatItem(label: 'Còn lại', value: assignment.remaining.toInt().toString(), isGold: true),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final bool isGold;

  const _StatItem({required this.label, required this.value, this.isGold = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: CaslaTypography.statLabel),
        Text(value, style: CaslaTypography.statValue.copyWith(
          color: isGold ? CaslaColors.gold700 : CaslaColors.primaryNavy,
        )),
      ],
    );
  }
}

// ─── Status Chip ────────────────────────────────────────────────────
class StatusChip extends StatelessWidget {
  final AssignmentStatus status;

  const StatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, textColor) = switch (status) {
      AssignmentStatus.open => (CaslaColors.successBg, CaslaColors.success),
      AssignmentStatus.completed => (CaslaColors.muted100, CaslaColors.muted),
      AssignmentStatus.recalled => (CaslaColors.dangerBg, CaslaColors.danger),
      AssignmentStatus.closed => (CaslaColors.muted100, CaslaColors.muted),
      AssignmentStatus.suspended => (CaslaColors.pendingBg, CaslaColors.pending),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(color: textColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(status.label, style: CaslaTypography.chipText.copyWith(color: textColor)),
        ],
      ),
    );
  }
}

// ─── Sync Status Chip ───────────────────────────────────────────────
class SyncStatusChip extends StatelessWidget {
  final SyncStatus status;

  const SyncStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, textColor, icon) = switch (status) {
      SyncStatus.pending => (CaslaColors.pendingBg, CaslaColors.pending, Icons.schedule),
      SyncStatus.syncing => (CaslaColors.gold100, CaslaColors.gold700, Icons.sync),
      SyncStatus.synced => (CaslaColors.successBg, CaslaColors.success, Icons.check_circle_outline),
      SyncStatus.failed => (CaslaColors.dangerBg, CaslaColors.danger, Icons.error_outline),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(color: textColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(status.label, style: CaslaTypography.chipText.copyWith(color: textColor)),
        ],
      ),
    );
  }
}

// ─── Sync Banner (Spec 6.3) ─────────────────────────────────────────
class SyncBanner extends StatelessWidget {
  final int pendingCount;
  final VoidCallback? onTap;

  const SyncBanner({super.key, required this.pendingCount, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (pendingCount <= 0) return const SizedBox.shrink();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: CaslaColors.gold100,
          border: Border.all(color: const Color(0xFFECD9AB)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(Icons.schedule, size: 15, color: CaslaColors.gold700),
            const SizedBox(width: 10),
            Expanded(child: Text(
              '$pendingCount bản ghi đang chờ đồng bộ',
              style: const TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w600,
                color: CaslaColors.bannerText,
              ),
            )),
            const Text('›', style: TextStyle(color: CaslaColors.gold700, fontSize: 18)),
          ],
        ),
      ),
    );
  }
}

// ─── Custom Keypad (Spec 6.3 QuantityKeypad) ────────────────────────
class QuantityKeypad extends StatelessWidget {
  final String valueText;
  final String uom;
  final ValueChanged<String> onValueChange;
  final ValueChanged<int> onQuickAdd;

  const QuantityKeypad({
    super.key,
    required this.valueText,
    required this.uom,
    required this.onValueChange,
    required this.onQuickAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Quantity display
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                valueText.isEmpty ? '0' : valueText,
                style: CaslaTypography.quantityDisplay,
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 4),
                child: Text(' $uom', style: const TextStyle(
                  fontSize: 16, color: CaslaColors.muted, fontWeight: FontWeight.w600,
                )),
              ),
            ],
          ),
        ),
        // Quick add buttons
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [10, 50, 100].map((amount) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () => onQuickAdd(amount),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: CaslaColors.gold100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('+$amount', style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700, color: CaslaColors.gold700,
                )),
              ),
            ),
          )).toList(),
        ),
        const SizedBox(height: 16),
        // Keypad grid
        ...['123', '456', '789'].map((row) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: row.split('').map((key) => _KeypadButton(
              label: key,
              onTap: () => onValueChange(valueText + key),
            )).toList(),
          ),
        )),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _KeypadButton(label: 'Xoá', isDanger: true, onTap: () => onValueChange('')),
              _KeypadButton(label: '0', onTap: () => onValueChange(valueText + '0')),
              _KeypadButton(label: '⌫', isDanger: true, onTap: () {
                if (valueText.isNotEmpty) onValueChange(valueText.substring(0, valueText.length - 1));
              }),
            ],
          ),
        ),
      ],
    );
  }
}

class _KeypadButton extends StatelessWidget {
  final String label;
  final bool isDanger;
  final VoidCallback onTap;

  const _KeypadButton({required this.label, this.isDanger = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 90, height: 52,
          decoration: BoxDecoration(
            color: CaslaColors.surface,
            border: Border.all(color: CaslaColors.line),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(
            fontFamily: label.length == 1 ? CaslaTypography.fontDisplay : null,
            fontWeight: FontWeight.w700,
            fontSize: label.length > 1 ? 14 : 18,
            color: isDanger ? CaslaColors.danger : CaslaColors.primaryNavy,
          )),
        ),
      ),
    );
  }
}

// ─── Sub Header ─────────────────────────────────────────────────────
class CaslaSubHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;

  const CaslaSubHeader({super.key, required this.title, this.subtitle, this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: CaslaColors.primaryNavy,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          if (onBack != null) ...[
            GestureDetector(
              onTap: onBack,
              child: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.chevron_left, color: Colors.white, size: 20),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: CaslaTypography.subheaderTitle),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!, style: CaslaTypography.subheaderSub),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Primary CTA Button ─────────────────────────────────────────────
class CaslaPrimaryButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final bool isDanger;

  const CaslaPrimaryButton({
    super.key,
    required this.text,
    this.onPressed,
    this.isDanger = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: isDanger ? CaslaColors.danger : CaslaColors.accentGold,
          foregroundColor: isDanger ? Colors.white : CaslaColors.navy900,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(text, style: CaslaTypography.button),
      ),
    );
  }
}

// ─── Locked Info Card ───────────────────────────────────────────────
class LockedInfoCard extends StatelessWidget {
  final Map<String, String> rows;

  const LockedInfoCard({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CaslaColors.muted100,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: rows.entries.map((e) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(e.key, style: const TextStyle(
                fontSize: 12.5, color: CaslaColors.muted, fontWeight: FontWeight.w600,
              )),
              Flexible(
                child: Text(e.value, style: const TextStyle(
                  fontFamily: 'monospace', fontWeight: FontWeight.w600,
                  fontSize: 12.5, color: CaslaColors.primaryNavy,
                ), textAlign: TextAlign.end),
              ),
            ],
          ),
        )).toList(),
      ),
    );
  }
}

// ─── Section Title ──────────────────────────────────────────────────
class SectionTitle extends StatelessWidget {
  final String text;

  const SectionTitle(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 10),
      child: Text(text, style: CaslaTypography.sectionTitle),
    );
  }
}

// ─── Reason Picker (Spec 6.3 ReasonPicker) ──────────────────────────
class ReasonPicker extends StatelessWidget {
  final List<RecallReason> reasons;
  final RecallReason? selected;
  final ValueChanged<RecallReason> onSelected;

  const ReasonPicker({
    super.key,
    required this.reasons,
    this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: reasons.map((reason) {
        final isActive = selected == reason;
        return GestureDetector(
          onTap: () => onSelected(reason),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
              border: Border.all(
                color: isActive ? CaslaColors.gold700 : CaslaColors.line,
                width: 1.5,
              ),
              color: isActive ? CaslaColors.gold100 : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Container(
                  width: 17, height: 17,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isActive ? CaslaColors.gold700 : CaslaColors.muted,
                      width: 2,
                    ),
                  ),
                  child: isActive ? Center(
                    child: Container(
                      width: 7, height: 7,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: CaslaColors.gold700,
                      ),
                    ),
                  ) : null,
                ),
                const SizedBox(width: 10),
                Text(reason.title, style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  color: CaslaColors.primaryNavy,
                )),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
