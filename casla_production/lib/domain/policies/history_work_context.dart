import '../entities/work_history.dart';

/// Rebuild a work-center report only from a complete ledger. HistWorker totals
/// span all authorized contexts and cannot be filtered by worker membership.
WorkHistoryResult historyForWorkContext(
  WorkHistoryResult result, {
  required String plant,
  required String workCenter,
}) {
  if (plant.trim().isEmpty ||
      workCenter.trim().isEmpty ||
      result.isTruncated ||
      (result.entries.isEmpty && result.workers.isNotEmpty) ||
      result.entries.any(
        (e) => e.plant.trim().isEmpty || e.workCenter.trim().isEmpty,
      )) {
    throw const FormatException(
      'Chưa đủ dữ liệu để tính theo tổ. Hãy chọn khoảng ngày ngắn hơn hoặc Tất cả tổ.',
    );
  }
  final entries = result.entries
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
      double assigned = 0, completed = 0;
      for (final entry in group.value) {
        switch (entry.transactionType) {
          case 'INITIAL_ASSIGN':
            assigned += entry.quantity;
          case 'RECALL':
            assigned -= entry.quantity;
          case 'CONFIRM':
          case 'CORRECTION':
            completed += entry.quantity;
          case 'REVERSE':
            completed -= entry.quantity;
        }
      }
      return WorkHistorySummary(
        workerId: group.key.$1,
        workerName: group.value.first.workerName,
        unitOfMeasure: group.key.$2,
        assignedQuantity: assigned,
        completedQuantity: completed,
        remainingQuantity: assigned - completed,
        transactionCount: group.value.length,
      );
    }).toList(),
  );
}
