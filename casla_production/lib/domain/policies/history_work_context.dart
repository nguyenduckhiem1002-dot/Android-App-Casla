import '../entities/entities.dart';
import '../entities/work_history.dart';

/// Marker for a local confirmation target materialized from SAP history.
/// It is durable so a later QR scan can reopen the same target, but list
/// screens should not count it a second time beside the SAP ledger row.
const historyImportedAssignmentNote = '__SAP_HISTORY_ASSIGNMENT__';

/// Rebuild a work-center report only from a complete ledger. HistWorker totals
/// span all authorized contexts and cannot be filtered by worker membership.
WorkHistoryResult historyForWorkContext(
  WorkHistoryResult result, {
  required String plant,
  required String workCenter,
  String? workId,
}) {
  final requestedWorkId = workId?.trim() ?? '';
  final hasWorkIds = result.entries.any((e) => e.workId.trim().isNotEmpty);
  final canFilterByWorkId = requestedWorkId.isNotEmpty && hasWorkIds;
  if (result.isTruncated ||
      (result.entries.isEmpty && result.workers.isNotEmpty) ||
      (!canFilterByWorkId &&
          (plant.trim().isEmpty ||
              workCenter.trim().isEmpty ||
              result.entries.any(
                (e) => e.plant.trim().isEmpty || e.workCenter.trim().isEmpty,
              )))) {
    throw const FormatException(
      'Chưa đủ dữ liệu để tính theo tổ. Hãy chọn khoảng ngày ngắn hơn hoặc Tất cả tổ.',
    );
  }
  final entries = requestedWorkId.isNotEmpty && hasWorkIds
      ? result.entries.where((e) => e.workId.trim() == requestedWorkId).toList()
      : result.entries
            .where(
              (e) =>
                  e.plant.trim() == plant.trim() &&
                  e.workCenter.trim() == workCenter.trim(),
            )
            .toList();
  final groups = <(String, String), List<WorkHistoryEntry>>{};
  for (final entry in entries) {
    if (entry.transactionType == 'TRANSFER') {
      // The published entry does not expose FromWorkerID / ToWorkerID.
      throw const FormatException(
        'Kỳ này có chuyển giao giữa công nhân. Hãy xem Tất cả tổ để có tổng chính xác.',
      );
    }
    (groups[(entry.workerId, entry.unitOfMeasure)] ??= []).add(entry);
  }
  if (groups.keys.map((key) => key.$2).toSet().length > 1) {
    throw const FormatException(
      'Kỳ này có nhiều đơn vị tính. Chưa thể gộp thành một KPI theo tổ.',
    );
  }
  // Entries do not carry the worker's own department; SAP's summary rows do,
  // and it is the same on every row of a worker.
  final workerDepartments = <String, String>{
    for (final worker in result.workers)
      if (worker.workerBoPhan.trim().isNotEmpty)
        worker.workerId.trim().toUpperCase(): worker.workerBoPhan,
  };
  return WorkHistoryResult(
    scopeCode: result.scopeCode,
    dateFrom: result.dateFrom,
    dateTo: result.dateTo,
    isTruncated: false,
    entries: entries,
    workers: groups.entries.map((group) {
      // Same rules as zcl_pp_work_history=>summarize: assigned is gross of
      // recalls, and a REASSIGN (the opening balance SAP's overnight job
      // carries over) counts only on the first day of the window — otherwise
      // a week would add the same unfinished work once per day.
      double assigned = 0, completed = 0, defect = 0, recalled = 0;
      for (final entry in group.value) {
        switch (entry.transactionType) {
          case 'INITIAL_ASSIGN':
            assigned += entry.quantity;
          case 'REASSIGN':
            if (isOpeningBalanceDay(entry.workDate, result.dateFrom)) {
              assigned += entry.quantity;
            }
          case 'RECALL':
            recalled += entry.quantity;
          case 'CONFIRM':
          case 'CORRECTION':
            completed += entry.quantity;
            defect += entry.defectQuantity;
          case 'REVERSE':
            completed -= entry.quantity;
            defect -= entry.defectQuantity;
        }
      }
      return WorkHistorySummary(
        workerId: group.key.$1,
        workerName: group.value.first.workerName,
        unitOfMeasure: group.key.$2,
        assignedQuantity: assigned,
        completedQuantity: completed,
        defectQuantity: defect,
        recalledQuantity: recalled,
        remainingQuantity: assigned - recalled - completed - defect,
        transactionCount: group.value.length,
        workId: group.value.first.workId,
        workerBoPhan:
            workerDepartments[group.key.$1.trim().toUpperCase()] ?? '',
      );
    }).toList(),
  );
}

/// Whether a REASSIGN dated [entryDate] is the opening balance of a report
/// window starting [windowFrom]. Compared by calendar day only.
bool isOpeningBalanceDay(DateTime entryDate, DateTime windowFrom) =>
    entryDate.year == windowFrom.year &&
    entryDate.month == windowFrom.month &&
    entryDate.day == windowFrom.day;

/// Narrow a SAP history to the selected work contexts (WorkIDs).
///
/// `_Workers` is summarized on SAP from the full scan and already carries the
/// WorkID of each row, so filtering it is exact even when `_Entries` was cut
/// at the service's row cap. An empty [workIds] means "all contexts" and
/// returns [result] untouched.
WorkHistoryResult historyForWorkIds(
  WorkHistoryResult result,
  Set<String> workIds,
) {
  final wanted = workIds
      .map((id) => id.trim())
      .where((id) => id.isNotEmpty)
      .toSet();
  if (wanted.isEmpty) return result;
  final untagged = result.workers.where((w) => w.workId.trim().isEmpty);
  if (untagged.isNotEmpty) {
    // An older service binding without HistWorker.WorkID cannot be split by
    // context; the caller may still rebuild a single context from entries.
    throw const FormatException(
      'SAP chưa trả vị trí làm việc cho tổng theo tổ. Hãy chọn Tất cả tổ.',
    );
  }
  return WorkHistoryResult(
    scopeCode: result.scopeCode,
    dateFrom: result.dateFrom,
    dateTo: result.dateTo,
    isTruncated: result.isTruncated,
    entries: result.entries
        .where((e) => wanted.contains(e.workId.trim()))
        .toList(growable: false),
    workers: result.workers
        .where((w) => wanted.contains(w.workId.trim()))
        .toList(growable: false),
  );
}

/// The departments (WorkIDs) of [contexts] in the work center [active] was
/// set up in: what "Tất cả tổ" on the overview covers (decided
/// 2026-10-29). A supervisor authorized across several work centers sees the
/// shift's own work center, not every department the account may read.
///
/// Null when nothing can be narrowed: no active context, no work center on
/// it, or no context of that work center among [contexts]; the caller then
/// keeps every authorized department.
Set<String>? workIdsOfWorkCenter(
  Iterable<UserWorkContext> contexts, {
  required UserWorkContext? active,
}) {
  final workCenter = active?.workCenter.trim().toUpperCase() ?? '';
  if (workCenter.isEmpty) return null;
  final plant = active!.plant.trim().toUpperCase();
  final ids = <String>{};
  for (final context in contexts) {
    final id = context.workId.trim();
    if (id.isEmpty) continue;
    if (context.workCenter.trim().toUpperCase() != workCenter) continue;
    final contextPlant = context.plant.trim().toUpperCase();
    if (plant.isNotEmpty && contextPlant.isNotEmpty && contextPlant != plant) {
      continue;
    }
    ids.add(id);
  }
  return ids.isEmpty ? null : ids;
}

/// The contexts the overview's "Tổ" filter offers one by one: those of
/// the work center [active] was set up in, in SAP's order. The list must not
/// be wider than "Tất cả tổ" above it, or a supervisor authorized across
/// work centers could pick a department of another one.
///
/// Every context of [contexts] when nothing can be narrowed (see
/// [workIdsOfWorkCenter]).
List<UserWorkContext> workContextsOfWorkCenter(
  Iterable<UserWorkContext> contexts, {
  required UserWorkContext? active,
}) {
  final ids = workIdsOfWorkCenter(contexts, active: active);
  if (ids == null) return contexts.toList(growable: false);
  return [
    for (final context in contexts)
      if (ids.contains(context.workId.trim())) context,
  ];
}

/// The departments (WorkIDs, upper-cased) the "Tổ" filter of a history
/// may offer while a shift is set up: the session's departments of the
/// shift's work center, plus any department [result] books a row for in that
/// work center (a history can hold departments the session does not name).
///
/// Only the list is narrowed; "Tất cả tổ" still shows every row SAP
/// reported. Null when nothing can be narrowed (see [workIdsOfWorkCenter]),
/// which is every account without a shift: the worker role.
Set<String>? historyFilterWorkIds(
  WorkHistoryResult result,
  Iterable<UserWorkContext> contexts, {
  required UserWorkContext? active,
}) {
  final sessionIds = workIdsOfWorkCenter(contexts, active: active);
  if (sessionIds == null) return null;
  final workCenter = active!.workCenter.trim().toUpperCase();
  final plant = active.plant.trim().toUpperCase();
  final ids = {for (final id in sessionIds) id.toUpperCase()};
  for (final entry in result.entries) {
    final id = entry.workId.trim().toUpperCase();
    if (id.isEmpty) continue;
    if (entry.workCenter.trim().toUpperCase() != workCenter) continue;
    final entryPlant = entry.plant.trim().toUpperCase();
    if (plant.isNotEmpty && entryPlant.isNotEmpty && entryPlant != plant) {
      continue;
    }
    ids.add(id);
  }
  return ids;
}
