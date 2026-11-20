// Domain — confirming several allocations of one operation as one.
//
// A worker can receive the same production order + operation more than once
// in a shift (100, then 333, then 1.000). SAP keeps each allocation separate,
// but since 2026-10-23 it settles the worker's balance per seat (operation,
// worker, position) in event order: a confirmation referencing any allocation
// of the seat consumes the whole seat, over-confirmation clears it to zero,
// and a later allocation opens a new run. The supervisor therefore counts the
// work as one pile and the form sends exactly what was entered as ONE
// transaction against the oldest allocation that is still open. No splitting:
// SAP must receive the quantity the user typed, not a reconstruction of it.
//
// What the pile still holds is the seat's settled balance (see
// `seat_balance.dart`), carried on the members as `seatRemaining`; adding up
// the members' own remainders would charge an earlier over-confirmation to
// allocations given afterwards.

import '../entities/entities.dart';
import '../entities/enums.dart';
import 'production_math.dart';

/// Allocations that can be confirmed together: same worker, work context,
/// shift and work date, production order, operation, work center, unit and
/// position — the same key SAP uses to book later allocations onto one root.
/// Without the position, allocations given before and after a move (100 + 100
/// unplaced and recalled, then 800 at TR1) became one group and the oldest
/// member took the confirmation, booking TR1's work on the spent blank seat
/// (2026-11-11).
String confirmationGroupKey(Assignment assignment) => [
  assignment.workerId.trim(),
  assignment.teamId.trim().toUpperCase(),
  assignment.shiftId.trim(),
  assignment.businessDate.trim(),
  assignment.productionOrder.trim(),
  assignment.operation.trim(),
  assignment.workCenter.trim().toUpperCase(),
  assignment.uom.trim().toUpperCase(),
  assignment.positionId.trim().toUpperCase(),
].join('\u0000');

/// Groups [targets] for the picker, keeping the order of first appearance.
/// Each group is sorted oldest first.
List<List<Assignment>> groupConfirmationTargets(Iterable<Assignment> targets) {
  final groups = <String, List<Assignment>>{};
  for (final target in targets) {
    (groups[confirmationGroupKey(target)] ??= []).add(target);
  }
  return [for (final group in groups.values) sortedOldestFirst(group)];
}

List<Assignment> sortedOldestFirst(Iterable<Assignment> assignments) {
  final sorted = assignments.toList();
  sorted.sort((a, b) {
    final byDate = a.businessDate.compareTo(b.businessDate);
    if (byDate != 0) return byDate;
    final byCreated = a.createdAtUtc.compareTo(b.createdAtUtc);
    if (byCreated != 0) return byCreated;
    return a.id.compareTo(b.id);
  });
  return sorted;
}

/// The seat balance the members carry (all members of one group share it),
/// or null when none was settled.
double? seatRemainingOf(Iterable<Assignment> members) {
  for (final member in members) {
    final value = member.seatRemaining;
    if (value != null) return value;
  }
  return null;
}

/// The seat balance of [opened] moved by what changed on this device since:
/// allocations added and quantities confirmed or recalled on [current]
/// compared with [opened]. Null when [opened] carried no settled balance.
double? carrySeatRemaining({
  required List<Assignment> opened,
  required List<Assignment> current,
}) {
  final settled = seatRemainingOf(opened);
  if (settled == null) return null;
  double given(List<Assignment> members) =>
      members.fold(0.0, (total, member) => total + member.assignedQuantity);
  double consumed(List<Assignment> members) => members.fold(
    0.0,
    (total, member) =>
        total +
        member.completedQuantity +
        member.defectQuantity +
        member.recalledQuantity,
  );
  final moved =
      settled +
      (given(current) - given(opened)) -
      (consumed(current) - consumed(opened));
  return ProductionMath.toSapScale(moved < 0 ? 0 : moved);
}

/// The allocation a grouped confirmation is booked on: the oldest one that is
/// still open and holds something, else the oldest open one, else the oldest.
/// An allocation closed by an over-confirmation must not be the target: the
/// device refuses to record on it, while SAP's seat balance still has room.
Assignment confirmationTarget(List<Assignment> members) {
  final ordered = sortedOldestFirst(members);
  for (final member in ordered) {
    if (member.canRecord && member.remaining > 0) return member;
  }
  for (final member in ordered) {
    if (member.canRecord) return member;
  }
  return ordered.first;
}

/// One transaction of a grouped confirmation.
class ConfirmationPart {
  final Assignment assignment;
  final double completed;
  final double defect;
  final double recalled;

  const ConfirmationPart({
    required this.assignment,
    required this.completed,
    this.defect = 0,
    required this.recalled,
  });
}

/// Books the entered [completed], [defect] and [recalled] as a single part on
/// the oldest open allocation of [members] (see [confirmationTarget]),
/// exactly as entered.
///
/// Completed and defective output may exceed the group's balance: SAP clears
/// the seat to zero and later allocations start a new run. A recall may not
/// exceed the group balance and throws [ArgumentError] when balances moved
/// underneath the open form. The name is kept for the existing callers; the
/// result now always has at most one part.
List<ConfirmationPart> splitGroupedConfirmation(
  List<Assignment> members, {
  required double completed,
  double defect = 0,
  required double recalled,
}) {
  final ordered = sortedOldestFirst(members);
  if (ordered.isEmpty) return const [];
  final room =
      seatRemainingOf(ordered) ??
      ordered.fold<double>(
        0.0,
        (total, member) => total + ProductionMath.toSapScale(member.remaining),
      );
  final recall = ProductionMath.toSapScale(recalled);
  if (recall > ProductionMath.toSapScale(room)) {
    throw ArgumentError('Recall exceeds the group balance');
  }
  final part = ConfirmationPart(
    assignment: confirmationTarget(ordered),
    completed: ProductionMath.toSapScale(completed),
    defect: ProductionMath.toSapScale(defect),
    recalled: recall,
  );
  if (part.completed <= 0 && part.defect <= 0 && part.recalled <= 0) {
    return const [];
  }
  return [part];
}

/// A read-only total of [members] for the confirmation form. Descriptive
/// fields come from the oldest allocation; quantities are summed. Its
/// `groupRemaining` is the seat balance ([seatRemaining], else the members')
/// — its own `remaining` would be the summed figure, which overstates or
/// understates the pile after an over-confirmation.
Assignment aggregateConfirmationGroup(
  List<Assignment> members, {
  double? seatRemaining,
}) {
  final ordered = sortedOldestFirst(members);
  final first = ordered.first;
  double sum(double Function(Assignment) value) =>
      ordered.fold(0.0, (total, item) => total + value(item));
  final anyOpen = ordered.any((item) => item.status == AssignmentStatus.open);
  return Assignment(
    id: first.id,
    workerId: first.workerId,
    workerMaNv: first.workerMaNv,
    workerName: first.workerName,
    teamId: first.teamId,
    orderId: first.orderId,
    orderCode: first.orderCode,
    productionOrder: first.productionOrder,
    operation: first.operation,
    operationName: first.operationName,
    productCode: first.productCode,
    productName: first.productName,
    plant: first.plant,
    workCenter: first.workCenter,
    uom: first.uom,
    assignedQuantity: sum((item) => item.assignedQuantity),
    completedQuantity: sum((item) => item.completedQuantity),
    defectQuantity: sum((item) => item.defectQuantity),
    recalledQuantity: sum((item) => item.recalledQuantity),
    businessDate: first.businessDate,
    shiftId: first.shiftId,
    status: anyOpen ? AssignmentStatus.open : first.status,
    note: first.note,
    createdBy: first.createdBy,
    idempotencyKey: first.idempotencyKey,
    sapId: first.sapId,
    syncStatus: first.syncStatus,
    createdAtUtc: first.createdAtUtc,
    positionId: first.positionId,
    seatRemaining: seatRemaining ?? seatRemainingOf(ordered),
  );
}
