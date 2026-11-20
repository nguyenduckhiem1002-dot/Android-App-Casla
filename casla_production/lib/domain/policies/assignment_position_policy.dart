/// One position per assignment group.
///
/// SAP groups a worker's assignments for an operation by Work ID, shift and
/// work date (`find_allocation_root` in `zbp_r_pp_opalloc`): a second
/// assignment in the same shift tops the first one up. Once that work was
/// given at a position, a top-up may not move it elsewhere or drop the
/// position, or the ledger would show one piece of work at two machines.
///
/// SAP enforces it too (`POSITION_GROUP_MISMATCH`, across shifts and days);
/// the form checks the shift's group before sending so the supervisor hears
/// it at once. An assignment made without a position holds its own place as
/// well (decided 2026-10-27): work given with no position must be confirmed
/// or recalled before the same operation is given at a position, and the
/// other way round. A group with nothing left on it (fully recalled, or
/// confirmed and recalled down to zero) is finished work: giving the worker
/// the same operation again may happen at another position.
library;

import '../entities/work_history.dart';

const String _initialAssign = 'INITIAL_ASSIGN';

/// Below this the group counts as settled: SAP stores quan(15,3).
const double _settledTolerance = 0.0001;

/// The position the worker's assignments in [entries] were made at, taken
/// from the newest assignment: its position, or '' when that assignment
/// recorded none (no position is a place of its own). Null when the worker
/// has no assignment among [entries].
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
    if (newest == null || entry.executionDate.isAfter(newest.executionDate)) {
      newest = entry;
    }
  }
  return newest?.positionId.trim().toUpperCase();
}

/// What the worker still holds of the group in [history]: assigned minus
/// recalled, confirmed and defective. SAP's per-worker totals are used when
/// present; otherwise the ledger rows are summed the way SAP does. Null when
/// the balance cannot be told: no rows, or a transfer whose direction the
/// published entry does not expose.
double? groupRemainingFromHistory(
  WorkHistoryResult history, {
  required String workerId,
}) {
  final worker = workerId.trim().toUpperCase();
  final summaries = history.workers.where(
    (summary) => summary.workerId.trim().toUpperCase() == worker,
  );
  if (summaries.isNotEmpty) {
    return summaries.fold<double>(
      0,
      (total, summary) => total + summary.remainingQuantity,
    );
  }
  double assigned = 0, settled = 0;
  var seen = false;
  for (final entry in history.entries) {
    if (entry.workerId.trim().toUpperCase() != worker) continue;
    seen = true;
    switch (entry.transactionType.trim().toUpperCase()) {
      case 'INITIAL_ASSIGN':
      case 'REASSIGN':
        assigned += entry.quantity;
      case 'RECALL':
        settled += entry.quantity;
      case 'CONFIRM':
      case 'CORRECTION':
        settled += entry.quantity + entry.defectQuantity;
      case 'REVERSE':
        settled -= entry.quantity + entry.defectQuantity;
      case 'TRANSFER':
        return null;
    }
  }
  return seen ? assigned - settled : null;
}

/// The position the worker's open group in [history] sits at. Null when no
/// assignment recorded one, or when the group is settled and so no longer
/// binds where the next assignment is made.
String? openGroupPositionFromHistory(
  WorkHistoryResult history, {
  required String workerId,
}) {
  final remaining = groupRemainingFromHistory(history, workerId: workerId);
  if (remaining != null && remaining <= _settledTolerance) return null;
  return groupPositionFromHistory(history.entries, workerId: workerId);
}

/// This device's side of one assignment group (one worker, operation,
/// department, shift and work date), as `CaslaDatabase.getGroupAssignmentLedger`
/// reads it.
class GroupAssignmentLedger {
  /// Whether any lot of the group is held on this device.
  final bool hasRows;

  /// The position of the newest lot that recorded one; null when none did.
  final String? position;

  /// Assigned minus confirmed, defective and recalled over this device's
  /// lots: not the seat balance when work was confirmed against lots this
  /// device never saw (carried-over work, another device).
  final double remaining;

  /// The part of [remaining] SAP has not seen yet: lots and consumption rows
  /// still queued, so SAP's own balance plus this is the seat's.
  final double unsentDelta;

  const GroupAssignmentLedger({
    required this.hasRows,
    required this.position,
    required this.remaining,
    required this.unsentDelta,
  });

  /// [position] while this device's rows alone say the group is open.
  String? get openPosition => remaining <= _settledTolerance ? null : position;
}

/// The position the worker's open group sits at, judged from both sides:
/// [history] (SAP's rows for the group, when it could be reached) and
/// [local] (this device's rows, when the database answered). Null when there
/// is no group or it is settled, so the next assignment may be made
/// elsewhere.
///
/// The balance is the seat's net total (`seat_balance.dart`): SAP's figure
/// plus what this device has not sent yet. This device's lots alone cannot
/// tell it, because a confirmation is booked against the oldest open lot,
/// which may be carried-over work or a lot another device gave: today's lot
/// then looks untouched while the seat is already at or below zero. Without
/// SAP, this device's rows are all that is known.
String? openGroupPosition({
  required GroupAssignmentLedger? local,
  required WorkHistoryResult? history,
  required String workerId,
}) {
  if (history == null) return local?.openPosition;
  final worker = workerId.trim().toUpperCase();
  final sapPosition = groupPositionFromHistory(
    history.entries,
    workerId: workerId,
  );
  final sapRemaining = groupRemainingFromHistory(history, workerId: workerId);
  if (sapRemaining == null) {
    final sapHasRows =
        history.entries.any(
          (entry) => entry.workerId.trim().toUpperCase() == worker,
        ) ||
        history.workers.any(
          (summary) => summary.workerId.trim().toUpperCase() == worker,
        );
    // A transfer whose direction is not published: keep the check
    // conservative and hold the group where it was given.
    if (sapHasRows) return sapPosition ?? local?.position;
    return local?.openPosition;
  }
  final seat = sapRemaining + (local?.unsentDelta ?? 0);
  if (seat <= _settledTolerance) return null;
  return sapPosition ?? local?.position;
}

/// Why [selectedPositionId] cannot be used when the group already sits at
/// [groupPositionId] ('' for a group given without a position); null when
/// they agree or there is no group (null).
String? groupPositionConflict({
  required String? groupPositionId,
  required String? selectedPositionId,
  String productionOrder = '',
  String operation = '',
}) {
  if (groupPositionId == null) return null;
  final group = groupPositionId.trim().toUpperCase();
  final selected = selectedPositionId?.trim().toUpperCase() ?? '';
  if (selected == group) return null;
  final order = productionOrder.trim();
  final step = operation.trim();
  final existing =
      'Tồn tại phân công của lệnh${order.isEmpty ? '' : ' $order'}, công đoạn'
      '${step.isEmpty ? '' : ' $step'}';
  if (group.isEmpty) {
    return '$existing chưa gắn vị trí. Xác nhận hoặc thu hồi hết phân công đó '
        'rồi mới giao ở vị trí $selected.';
  }
  return selected.isEmpty
      ? '$existing tại vị trí $group. Hãy quét vị trí $group để giao tiếp.'
      : '$existing tại vị trí $group. Không thể giao ở vị trí $selected.';
}
