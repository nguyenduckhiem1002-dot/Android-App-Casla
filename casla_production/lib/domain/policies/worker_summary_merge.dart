import '../entities/work_history.dart';

/// Folds SAP's per-worker summary rows into one row per worker and unit.
///
/// `zcl_pp_work_history` keys `ZA_PP_HistWorker` by worker × WorkID × unit.
/// A worker who took work at two positions — typically yesterday's balance
/// carried over by REASSIGN (which keeps the original WorkID) next to a new
/// assignment today — therefore comes back as several rows. Screens show one
/// total per worker, so quantities of the same unit are added up; different
/// units are never added together.
List<WorkHistorySummary> mergeWorkerSummaries(
  Iterable<WorkHistorySummary> rows,
) {
  final merged = <(String, String), WorkHistorySummary>{};
  for (final row in rows) {
    final key = (
      row.workerId.trim().toUpperCase(),
      row.unitOfMeasure.trim().toUpperCase(),
    );
    final existing = merged[key];
    if (existing == null) {
      merged[key] = row;
      continue;
    }
    String pick(String a, String b) => a.trim().isNotEmpty ? a : b;
    merged[key] = WorkHistorySummary(
      workerId: existing.workerId,
      workerName: pick(existing.workerName, row.workerName),
      assignedQuantity: existing.assignedQuantity + row.assignedQuantity,
      completedQuantity: existing.completedQuantity + row.completedQuantity,
      defectQuantity: existing.defectQuantity + row.defectQuantity,
      remainingQuantity: existing.remainingQuantity + row.remainingQuantity,
      recalledQuantity: existing.recalledQuantity + row.recalledQuantity,
      unitOfMeasure: existing.unitOfMeasure,
      transactionCount: existing.transactionCount + row.transactionCount,
      // Several positions: no single WorkID describes the total.
      workId: existing.workId == row.workId ? existing.workId : '',
      workName: pick(existing.workName, row.workName),
      boPhan: pick(existing.boPhan, row.boPhan),
      location: pick(existing.location, row.location),
    );
  }
  return merged.values.toList();
}
