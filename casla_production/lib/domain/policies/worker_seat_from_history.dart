/// Where a worker is working, read off the history window: the position the
/// newest row of theirs carries (`PositionID`, the seat the work was done
/// at, falling back to `OriginPositionID`, their own seat when SAP posted the
/// row). Empty when no row in the window names a position, as on rows posted
/// before positions were tracked.
///
/// The overview card shows it as text next to the worker's status; it is
/// not the live board (that is the Vị trí tab), only what the ledger says.
library;

import '../entities/work_history.dart';

String latestWorkerPosition(
  Iterable<WorkHistoryEntry> entries,
  String workerId,
) {
  final wanted = workerId.trim().toUpperCase();
  WorkHistoryEntry? newest;
  for (final entry in entries) {
    if (entry.workerId.trim().toUpperCase() != wanted) continue;
    if (_positionOf(entry).isEmpty) continue;
    // Ties keep the first seen: SAP lists the newest row first.
    if (newest == null || entry.executionDate.isAfter(newest.executionDate)) {
      newest = entry;
    }
  }
  return newest == null ? '' : _positionOf(newest);
}

String _positionOf(WorkHistoryEntry entry) {
  final current = entry.positionId.trim().toUpperCase();
  return current.isNotEmpty
      ? current
      : entry.originPositionId.trim().toUpperCase();
}
