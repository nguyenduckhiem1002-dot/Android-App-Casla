// Domain — confirming several allocations of one operation as one.
//
// A worker can receive the same production order + operation more than once
// in a shift (100, then 333, then 1.000). SAP keeps each allocation separate:
// every confirmation/recall must reference the INITIAL_ASSIGN it belongs to.
// The supervisor, however, counts the work as one pile. The form therefore
// shows the group total, and the entered quantity is split across the
// allocations here — oldest first, so earlier lots close before later ones.

import '../entities/entities.dart';
import '../entities/enums.dart';
import 'production_math.dart';

/// Allocations that can be confirmed together: same worker, work context,
/// shift and work date, production order, operation, work center and unit —
/// the same key SAP uses to book later allocations onto one root.
String confirmationGroupKey(Assignment assignment) => [
  assignment.workerId.trim(),
  assignment.teamId.trim().toUpperCase(),
  assignment.shiftId.trim(),
  assignment.businessDate.trim(),
  assignment.productionOrder.trim(),
  assignment.operation.trim(),
  assignment.workCenter.trim().toUpperCase(),
  assignment.uom.trim().toUpperCase(),
].join('\u0000');

/// Groups [targets] for the picker, keeping the order of first appearance.
/// Each group is sorted oldest first — the order quantities are applied in.
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

/// One allocation's share of a grouped confirmation.
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

/// Splits [completed], then [defect], then [recalled] across [members], oldest
/// first, filling each allocation's remaining balance.
///
/// Completed and defective output may exceed the group's balance: what does
/// not fit is booked on the newest allocation, the one the worker was last
/// given. A recall may not, and throws [ArgumentError] when balances moved
/// underneath the open form.
List<ConfirmationPart> splitGroupedConfirmation(
  List<Assignment> members, {
  required double completed,
  double defect = 0,
  required double recalled,
}) {
  final ordered = sortedOldestFirst(members);
  var completedLeft = ProductionMath.toSapScale(completed);
  var defectLeft = ProductionMath.toSapScale(defect);
  var recallLeft = ProductionMath.toSapScale(recalled);
  final parts = <ConfirmationPart>[];
  for (final member in ordered) {
    var room = ProductionMath.toSapScale(member.remaining);
    final completedPart = completedLeft < room ? completedLeft : room;
    room = ProductionMath.toSapScale(room - completedPart);
    completedLeft = ProductionMath.toSapScale(completedLeft - completedPart);
    final defectPart = defectLeft < room ? defectLeft : room;
    room = ProductionMath.toSapScale(room - defectPart);
    defectLeft = ProductionMath.toSapScale(defectLeft - defectPart);
    final recallPart = recallLeft < room ? recallLeft : room;
    recallLeft = ProductionMath.toSapScale(recallLeft - recallPart);
    if (completedPart > 0 || defectPart > 0 || recallPart > 0) {
      parts.add(
        ConfirmationPart(
          assignment: member,
          completed: completedPart,
          defect: defectPart,
          recalled: recallPart,
        ),
      );
    }
  }
  if (recallLeft > 0) {
    throw ArgumentError('Recall exceeds the group balance');
  }
  if ((completedLeft > 0 || defectLeft > 0) && ordered.isNotEmpty) {
    final newest = ordered.last;
    final index = parts.indexWhere((part) => part.assignment.id == newest.id);
    final booked = index < 0 ? null : parts[index];
    final surplus = ConfirmationPart(
      assignment: newest,
      completed: ProductionMath.toSapScale(
        (booked?.completed ?? 0) + completedLeft,
      ),
      defect: ProductionMath.toSapScale((booked?.defect ?? 0) + defectLeft),
      recalled: booked?.recalled ?? 0,
    );
    if (index < 0) {
      parts.add(surplus);
    } else {
      parts[index] = surplus;
    }
  }
  return parts;
}

/// A read-only total of [members] for the confirmation form. Descriptive
/// fields come from the oldest allocation; quantities are summed.
Assignment aggregateConfirmationGroup(List<Assignment> members) {
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
  );
}
