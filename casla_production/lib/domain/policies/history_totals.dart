// Domain — the figures of the read-only history screen (W01).
//
// Computed the same way as the supervisor screens, so the numbers add up and
// match what the supervisor sees for the same worker:
//   given (+ carried over) = completed + defect + recalled + remaining.
// Defect (Phế) is counted apart from completed: SAP's CONFIRM carries the
// good quantity in `Quantity` and the scrap in `DefectQuantity`, and both
// consume the allocation.

import '../entities/work_history.dart';
import 'seat_balance.dart';
import 'unit_totals.dart';

/// The period's totals per unit, from SAP's per-worker summaries.
///
/// SAP splits a worker by WorkID, and a team history holds many workers, so
/// several rows can share a unit; they are added together. Sorted by given,
/// largest first.
List<UnitTotals> historyUnitTotals(Iterable<WorkHistorySummary> summaries) {
  final byUnit = <String, UnitTotals>{};
  for (final row in summaries) {
    final unit = row.unitOfMeasure.trim();
    final totals = UnitTotals(
      unit: unit,
      given: row.assignedQuantity,
      completed: row.completedQuantity,
      defect: row.defectQuantity,
      recalled: row.recalledQuantity,
      remaining: row.remainingQuantity,
    );
    final known = byUnit[unit.toUpperCase()];
    byUnit[unit.toUpperCase()] = known == null ? totals : known.plus(totals);
  }
  return byUnit.values.toList()..sort((a, b) => b.given.compareTo(a.given));
}

/// One operation card's figures: what was given that day, carried over from
/// the day before, completed, scrapped, recalled, and what is left.
class HistoryGroupTotals {
  final String unit;

  /// INITIAL_ASSIGN and allocation adjustments.
  final double given;

  /// REASSIGN: the previous day's remaining, carried by the overnight job.
  final double carriedOver;

  /// Good quantity confirmed, net of reversals.
  final double completed;

  /// Scrap confirmed, net of reversals.
  final double defect;
  final double recalled;

  /// The seat's balance (see [settleSeatBalance]); negative after an
  /// over-confirmation, like the supervisor screens show it.
  final double remaining;

  const HistoryGroupTotals({
    required this.unit,
    required this.given,
    required this.carriedOver,
    required this.completed,
    required this.defect,
    required this.recalled,
    required this.remaining,
  });
}

/// The figures of one operation card from its ledger rows. Rows SAP refused
/// (`FAILED`) moved nothing and are left out.
HistoryGroupTotals historyGroupTotals(Iterable<WorkHistoryEntry> entries) {
  var unit = '';
  var given = 0.0;
  var carriedOver = 0.0;
  var completed = 0.0;
  var defect = 0.0;
  var recalled = 0.0;
  final events = <SeatEvent>[];
  for (final entry in entries) {
    if (entry.transactionStatus.trim().toUpperCase() == 'FAILED') continue;
    if (unit.isEmpty) unit = entry.unitOfMeasure.trim();
    switch (entry.transactionType.trim().toUpperCase()) {
      case 'INITIAL_ASSIGN':
      case 'ALLOC_ADJUST':
        given += entry.quantity;
      case 'REASSIGN':
        carriedOver += entry.quantity;
      case 'CONFIRM':
      case 'CORRECTION':
      case 'CONFIRM_ADJUST':
        completed += entry.quantity;
        defect += entry.defectQuantity;
      case 'REVERSE':
        completed -= entry.quantity;
        defect -= entry.defectQuantity;
      case 'RECALL':
      case 'RECALL_ADJUST':
        recalled += entry.quantity;
    }
    final delta = seatEffect(
      transactionType: entry.transactionType,
      quantity: entry.quantity,
      defectQuantity: entry.defectQuantity,
    );
    if (delta != null) {
      events.add(SeatEvent(at: entry.executionDate, delta: delta));
    }
  }
  return HistoryGroupTotals(
    unit: unit,
    given: given,
    carriedOver: carriedOver,
    completed: completed,
    defect: defect,
    recalled: recalled,
    remaining: settleSeatBalance(events),
  );
}
