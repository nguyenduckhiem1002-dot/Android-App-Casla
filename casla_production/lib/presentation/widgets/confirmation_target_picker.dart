import 'package:flutter/material.dart';
import '../../core/utils/quantity_formatter.dart';
import '../../domain/entities/entities.dart';
import '../../domain/policies/grouped_confirmation.dart';

/// Picks what to confirm, as a group of allocations.
///
/// Allocations of the same production order, operation, unit and work
/// context are one line: the supervisor confirms the pile, and the quantity
/// is split across the allocations afterwards (see
/// [splitGroupedConfirmation]). With a single group there is nothing to
/// choose, so it is returned without showing the sheet.
Future<List<Assignment>?> pickConfirmationGroup(
  BuildContext context,
  List<Assignment> targets,
) async {
  // Settled allocations stay in their group so the form shows the
  // operation's full totals; a group needs at least one open allocation.
  final groups = groupConfirmationTargets(
    targets,
  ).where((group) => group.any((target) => target.canRecord)).toList();
  if (groups.isEmpty) return null;
  if (groups.length == 1) return groups.single;
  return showModalBottomSheet<List<Assignment>>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .7,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Text(
              'Chọn công đoạn cần xác nhận',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Các lần giao cùng lệnh và công đoạn đã được gộp thành một dòng.',
              ),
            ),
            for (final group in groups)
              _GroupTile(
                group: group,
                onTap: () => Navigator.of(context).pop(group),
              ),
          ],
        ),
      ),
    ),
  );
}

class _GroupTile extends StatelessWidget {
  final List<Assignment> group;
  final VoidCallback onTap;

  const _GroupTile({required this.group, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final total = aggregateConfirmationGroup(group);
    final uom = total.uom;
    final lots = group.length > 1 ? ' · ${group.length} lần giao' : '';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      title: Text(
        total.operationName.isEmpty
            ? 'Công đoạn ${total.operation}'
            : total.operationName,
      ),
      subtitle: Text(
        'LSX ${total.productionOrder} · CĐ ${total.operation}$lots\n'
        'Còn ${formatQuantity(total.remaining, uom: uom)} $uom · '
        'Đã giao ${formatQuantity(total.assignedQuantity, uom: uom)} $uom',
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
