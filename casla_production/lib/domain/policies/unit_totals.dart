import '../entities/work_history.dart';
import 'local_history_overlay.dart';
import 'worker_summary_merge.dart';

/// One worker's figures in one unit, for the header of the worker's screen.
///
/// [remaining] is carried as reported rather than derived: SAP's remaining
/// also reflects transfers and adjustments, so it is not always exactly
/// given − recalled − completed.
class UnitTotals {
  final String unit;
  final double given;
  final double completed;
  final double defect;
  final double recalled;
  final double remaining;

  const UnitTotals({
    required this.unit,
    required this.given,
    required this.completed,
    this.defect = 0,
    required this.recalled,
    required this.remaining,
  });

  static const zero = UnitTotals(
    unit: '',
    given: 0,
    completed: 0,
    defect: 0,
    recalled: 0,
    remaining: 0,
  );

  /// Given minus recalled: what is actually expected to be finished.
  double get effective => given - recalled;

  double get completionRate =>
      effective > 0 ? (completed / effective).clamp(0.0, 1.0) : 0.0;

  UnitTotals plus(UnitTotals other) => UnitTotals(
    unit: unit == other.unit ? unit : '',
    given: given + other.given,
    completed: completed + other.completed,
    defect: defect + other.defect,
    recalled: recalled + other.recalled,
    remaining: remaining + other.remaining,
  );

  /// Everything added together, whatever the unit. The unit is kept only
  /// when all [rows] share it.
  static UnitTotals sum(Iterable<UnitTotals> rows) {
    UnitTotals? total;
    for (final row in rows) {
      total = total == null ? row : total.plus(row);
    }
    return total ?? zero;
  }
}

/// The worker's figures per unit: SAP's report, merged per unit (it splits a
/// worker by WorkID too), with this device's not-yet-reported rows of the
/// same unit applied. A unit that so far exists only on this device gets its
/// own row. Sorted by given, largest first.
List<UnitTotals> workerUnitTotalsFromSap({
  required Iterable<WorkHistorySummary> sapRows,
  required Iterable<String> workerKeys,
  required LocalPendingLedger pending,
}) {
  final keys = {
    for (final key in workerKeys)
      if (key.trim().isNotEmpty) key.trim().toUpperCase(),
  };
  final merged = mergeWorkerSummaries(
    sapRows.where((row) => keys.contains(row.workerId.trim().toUpperCase())),
  );
  final result = <UnitTotals>[];
  final seen = <String>{};
  for (final row in merged) {
    final unit = row.unitOfMeasure.trim();
    seen.add(unit.toUpperCase());
    final local = pending.forWorker(keys, unit: unit);
    result.add(
      UnitTotals(
        unit: unit,
        given: row.assignedQuantity + local.assigned,
        completed: row.completedQuantity + local.completed,
        defect: row.defectQuantity + local.defect,
        recalled: row.recalledQuantity + local.recalled,
        remaining: row.remainingQuantity + local.remainingDelta,
      ),
    );
  }
  for (final unit in pending.unitsForWorker(keys)) {
    if (seen.contains(unit)) continue;
    final local = pending.forWorker(keys, unit: unit);
    if (local.isEmpty) continue;
    result.add(
      UnitTotals(
        unit: unit,
        given: local.assigned,
        completed: local.completed,
        defect: local.defect,
        recalled: local.recalled,
        remaining: local.remainingDelta,
      ),
    );
  }
  result.sort((a, b) => b.given.compareTo(a.given));
  return result;
}
