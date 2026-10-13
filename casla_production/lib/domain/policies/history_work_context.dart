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
