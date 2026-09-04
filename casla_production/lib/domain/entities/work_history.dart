// Domain — Work history (ZUI_PP_OPALLOC.getWorkHistory)
//
// Read-only report backing the worker's "Lịch sử" screen. Scope is decided
// entirely server-side (zcl_pp_work_history): an account with only
// PP_HIST_SELF always gets its own rows back regardless of what WorkerID
// this app sends, so nothing here carries a worker id to filter by.

/// Which window `getWorkHistory` should report over.
enum HistoryRange {
  day('D'),
  week('W'),
  month('M'),
  custom('C');

  const HistoryRange(this.code);
  final String code;
}

/// One `ZA_PP_HistEntry` row — a single posted transaction.
class WorkHistoryEntry {
  final String transactionUuid;
  final DateTime executionDate;
  final String workerId;
  final String workerName;
  final String productionOrder;
  final String operation;
  final String plant;
  final String workCenter;
  final String transactionType;
  final double quantity;
  final String unitOfMeasure;
  final String transactionStatus;

  const WorkHistoryEntry({
    required this.transactionUuid,
    required this.executionDate,
    required this.workerId,
    required this.workerName,
    required this.productionOrder,
    required this.operation,
    required this.plant,
    required this.workCenter,
    required this.transactionType,
    required this.quantity,
    required this.unitOfMeasure,
    required this.transactionStatus,
  });
}

/// One `ZA_PP_HistWorker` row — running totals for one worker over the window.
class WorkHistorySummary {
  final String workerId;
  final String workerName;
  final double assignedQuantity;
  final double completedQuantity;
  final double remainingQuantity;
  final String unitOfMeasure;
  final int transactionCount;

  const WorkHistorySummary({
    required this.workerId,
    required this.workerName,
    required this.assignedQuantity,
    required this.completedQuantity,
    required this.remainingQuantity,
    required this.unitOfMeasure,
    required this.transactionCount,
  });
}

/// `ZA_PP_HistResult` — the full response.
class WorkHistoryResult {
  /// `'S'` (self) or `'T'` (team) — whichever scope SAP actually applied,
  /// regardless of what this app asked for.
  final String scopeCode;
  final DateTime dateFrom;
  final DateTime dateTo;
  final bool isTruncated;
  final List<WorkHistoryEntry> entries;
  final List<WorkHistorySummary> workers;

  const WorkHistoryResult({
    required this.scopeCode,
    required this.dateFrom,
    required this.dateTo,
    required this.isTruncated,
    required this.entries,
    required this.workers,
  });
}
