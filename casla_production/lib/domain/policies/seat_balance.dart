// Domain — a worker's balance on one operation (a "seat").
//
// Decided 2026-10-24: SAP adds a worker's allocations on an operation up and
// subtracts what was confirmed and recalled, in no particular order and
// without clamping in between. The balance may go negative after an
// over-confirmation (give 1.000, confirm 1.500, give 700 more: 200 is left,
// not 700); only a balance above zero can be confirmed against, and only a
// balance above zero is carried to the next day by the overnight job
// (ZCL_PP_REASSIGN_JOB). The history report's RemainingQuantity is the same
// sum. The event-ordered, clamp-at-zero model tried on 2026-10-23 is gone;
// the event API stays so callers keep one place to compute the figure.

import '../entities/work_history.dart';

/// One ledger row's effect on a seat, in event order.
class SeatEvent {
  final DateTime at;

  /// Positive for an allocation, negative for what consumed it.
  final double delta;

  /// Breaks ties between rows posted at the same instant.
  final String order;

  const SeatEvent({required this.at, required this.delta, this.order = ''});
}

/// Signed effect of a ledger row on its seat, or null when the row type does
/// not move the balance (or its direction is unknown, like a transfer whose
/// side is not published).
double? seatEffect({
  required String transactionType,
  required double quantity,
  double defectQuantity = 0,
}) {
  switch (transactionType.trim().toUpperCase()) {
    case 'INITIAL_ASSIGN':
    case 'REASSIGN':
    case 'ALLOC_ADJUST':
      return quantity;
    case 'CONFIRM':
    case 'CORRECTION':
    case 'CONFIRM_ADJUST':
      return -(quantity + defectQuantity);
    case 'RECALL':
    case 'RECALL_ADJUST':
      return -quantity;
    case 'REVERSE':
      return quantity + defectQuantity;
    default:
      return null;
  }
}

/// The seat's balance: the plain sum of [events]. Order does not matter and
/// the result may be negative after an over-confirmation; callers treat only
/// a positive balance as confirmable.
double settleSeatBalance(Iterable<SeatEvent> events) =>
    events.fold<double>(0, (balance, event) => balance + event.delta);

/// Rows that never reached SAP hold nothing.
bool _holdsNothing(String status) {
  final upper = status.trim().toUpperCase();
  return upper == 'REJECTED' || upper == 'FAILED';
}

/// Seat events of SAP history rows (all of one worker, order, operation and
/// unit — the caller scopes them).
List<SeatEvent> seatEventsFromHistory(Iterable<WorkHistoryEntry> entries) {
  final events = <SeatEvent>[];
  for (final entry in entries) {
    if (_holdsNothing(entry.transactionStatus)) continue;
    final delta = seatEffect(
      transactionType: entry.transactionType,
      quantity: entry.quantity,
      defectQuantity: entry.defectQuantity,
    );
    if (delta == null) continue;
    events.add(
      SeatEvent(
        at: entry.executionDate,
        delta: delta,
        order: entry.transactionUuid,
      ),
    );
  }
  return events;
}

/// What SAP still holds for one worker, per unit: [entries] (all of one
/// worker and day, scoped as the screen is) added up seat by seat (order,
/// operation, unit) and the seats added up per unit — the same sum as the
/// report's RemainingQuantity, computed from the rows when the report has no
/// per-worker total.
Map<String, double> settledRemainingByUnit(Iterable<WorkHistoryEntry> entries) {
  final seats = <(String, String, String), List<SeatEvent>>{};
  for (final entry in entries) {
    final key = (
      entry.productionOrder.trim(),
      entry.operation.trim(),
      entry.unitOfMeasure.trim().toUpperCase(),
    );
    (seats[key] ??= []).addAll(seatEventsFromHistory([entry]));
  }
  final byUnit = <String, double>{};
  for (final MapEntry(key: seat, value: events) in seats.entries) {
    byUnit[seat.$3] = (byUnit[seat.$3] ?? 0) + settleSeatBalance(events);
  }
  return byUnit;
}
