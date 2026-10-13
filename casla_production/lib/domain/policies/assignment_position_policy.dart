/// One position per assignment group.
///
/// SAP groups a worker's assignments for an operation by Work ID, shift and
/// work date (`find_allocation_root` in `zbp_r_pp_opalloc`): a second
/// assignment in the same shift tops the first one up. Once that work was
/// given at a position, a top-up may not move it elsewhere or drop the
/// position, or the ledger would show one piece of work at two machines.
///
/// The backend does not enforce this yet, so the form checks it before
/// sending.
library;

import '../entities/work_history.dart';

const String _initialAssign = 'INITIAL_ASSIGN';

/// The position the worker's assignments in [entries] were made at, taken
/// from the newest assignment that recorded one. Null when none did.
///
/// [entries] must already be limited to one operation, shift and work date,
/// as the assignment form's history request is.
String? groupPositionFromHistory(
  Iterable<WorkHistoryEntry> entries, {
  required String workerId,
}) {
  final worker = workerId.trim().toUpperCase();
  WorkHistoryEntry? newest;
  for (final entry in entries) {
    if (entry.transactionType.trim().toUpperCase() != _initialAssign) continue;
    if (entry.workerId.trim().toUpperCase() != worker) continue;
    if (entry.positionId.trim().isEmpty) continue;
    if (newest == null || entry.executionDate.isAfter(newest.executionDate)) {
      newest = entry;
    }
  }
  return newest?.positionId.trim().toUpperCase();
}

/// Why [selectedPositionId] cannot be used when the group already sits at
/// [groupPositionId]; null when they agree or the group has no position.
String? groupPositionConflict({
  required String? groupPositionId,
  required String? selectedPositionId,
  String productionOrder = '',
  String operation = '',
}) {
  final group = groupPositionId?.trim().toUpperCase() ?? '';
  if (group.isEmpty) return null;
  final selected = selectedPositionId?.trim().toUpperCase() ?? '';
  if (selected == group) return null;
  final order = productionOrder.trim();
  final step = operation.trim();
  final existing =
      'Tồn tại phân công của lệnh${order.isEmpty ? '' : ' $order'}, công đoạn'
      '${step.isEmpty ? '' : ' $step'} tại vị trí $group.';
  return selected.isEmpty
      ? '$existing Hãy quét vị trí $group để giao tiếp.'
      : '$existing Không thể giao ở vị trí $selected.';
}
