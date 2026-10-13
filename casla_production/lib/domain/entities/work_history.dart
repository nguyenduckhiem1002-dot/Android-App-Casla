// Domain — Work history (ZUI_PP_OPALLOC.getWorkHistory)
//
// Read-only report backing the worker's "Lịch sử" screen. Scope is decided
// entirely server-side (zcl_pp_work_history): an account with only
// PP_HIST_SELF always gets its own rows back regardless of what WorkerID
// this app sends. WorkID is retained on each row to identify the posting
// location used for that transaction.

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

  /// When the transaction was posted (SAP `ExecutedAt`, local time). Use it
  /// for the time of day and ordering — never to decide which working day a
  /// row belongs to: see [workDate].
  final DateTime executionDate;

  /// SAP `WorkDate` as reported: the shift's business date. Null for rows
  /// that do not carry one (older services, older cache rows).
  final DateTime? reportedWorkDate;
  final String workerId;
  final String workerName;
  final String productionOrder;
  final String operation;
  final String operationName;
  final String productName;
  final String productCode;
  final String salesOrder;
  final String salesOrderItem;
  final String plant;
  final String workCenter;

  /// SAP WorkID captured on the transaction. This is the exact work context
  /// used when the assignment/confirmation was posted.
  final String workId;
  final String transactionType;
  final double quantity;
  final double defectQuantity;
  final String unitOfMeasure;
  final String transactionStatus;

  /// The allocation (INITIAL_ASSIGN/transfer) a confirmation or recall
  /// consumed. Empty when the SAP service does not publish it yet; then the
  /// app can only attribute rows it created itself.
  final String originalTransactionUuid;

  /// Position the transaction was made at (SAP `PositionID`), possibly a
  /// temporary seat. Empty on older rows and when none was sent.
  final String positionId;

  /// The worker's own seat when SAP posted the row (`OriginPositionID`).
  final String originPositionId;

  const WorkHistoryEntry({
    required this.transactionUuid,
    required this.executionDate,
    this.reportedWorkDate,
    required this.workerId,
    required this.workerName,
    required this.productionOrder,
    required this.operation,
    this.operationName = '',
    this.productName = '',
    this.productCode = '',
    this.salesOrder = '',
    this.salesOrderItem = '',
    required this.plant,
    required this.workCenter,
    this.workId = '',
    required this.transactionType,
    required this.quantity,
    this.defectQuantity = 0,
    required this.unitOfMeasure,
    required this.transactionStatus,
    this.originalTransactionUuid = '',
    this.positionId = '',
    this.originPositionId = '',
  });

  /// The working day this row belongs to. A night shift's work posted at
  /// 02:00 on the 25th belongs to the 24th: SAP filters and totals history by
  /// this date, so every per-day grouping and match must use it too.
  DateTime get workDate {
    final day = reportedWorkDate ?? executionDate;
    return DateTime(day.year, day.month, day.day);
  }
}

/// One `ZA_PP_HistWorker` row — running totals for one worker over the window.
class WorkHistorySummary {
  final String workerId;
  final String workerName;
  final double assignedQuantity;
  final double completedQuantity;
  final double defectQuantity;
  final double remainingQuantity;

  /// Recalled over the window. `AssignedQuantity` is gross of recalls, so
  /// remaining = assigned − recalled − completed − defective.
  final double recalledQuantity;
  final String unitOfMeasure;
  final int transactionCount;
  final String workId;
  final String workName;
  final String boPhan;
  final String location;

  const WorkHistorySummary({
    required this.workerId,
    required this.workerName,
    required this.assignedQuantity,
    required this.completedQuantity,
    this.defectQuantity = 0,
    required this.remainingQuantity,
    this.recalledQuantity = 0,
    required this.unitOfMeasure,
    required this.transactionCount,
    this.workId = '',
    this.workName = '',
    this.boPhan = '',
    this.location = '',
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
