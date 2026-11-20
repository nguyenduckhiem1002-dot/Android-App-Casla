// Domain — recalling everything a worker still holds, without a password.
//
// The Xác nhận sheet recalls one order/operation at a time. A worker who is
// away may hold several; an account with PP_RECALL_NOPASS takes them all back
// from the worker list in one go (decided 2026-11-19). Each order/operation
// seat is still its own SAP transaction: SAP recalls against one original
// allocation at a time, so "all" is one recall per group, sent in turn.

import '../entities/entities.dart';
import '../entities/mutation_receipt.dart';
import '../repositories/repositories.dart';
import 'grouped_confirmation.dart';
import 'production_math.dart';

/// One recall of a "recall everything": a group of allocations (see
/// [confirmationGroupKey]) and what is left on it.
class RecallAllLine {
  /// The group's allocations, oldest first.
  final List<Assignment> members;

  /// The allocation the recall is booked on, the same one the Xác nhận sheet
  /// would pick (see [confirmationTarget]).
  final Assignment target;

  /// Everything left on the group: its seat balance when SAP settled one,
  /// else the members' own remainders.
  final double quantity;

  const RecallAllLine({
    required this.members,
    required this.target,
    required this.quantity,
  });

  /// See `RecallRepository.recallAssignment.seatCeiling`: the recall was
  /// sized by the pile's balance, which the booked allocation's own figure
  /// may be below.
  double? get seatCeiling =>
      members.length > 1 || target.seatRemaining != null ? quantity : null;
}

/// The recalls that empty every group of [targets] still holding something.
/// Groups with nothing left, or already closed, are left out.
List<RecallAllLine> planRecallAll(Iterable<Assignment> targets) {
  final lines = <RecallAllLine>[];
  for (final group in groupConfirmationTargets(targets)) {
    if (!group.any((member) => member.canConfirm)) continue;
    final room =
        seatRemainingOf(group) ??
        group.fold<double>(
          0.0,
          (total, member) =>
              total + ProductionMath.toSapScale(member.remaining),
        );
    final quantity = ProductionMath.toSapScale(room);
    if (quantity <= 0) continue;
    // The same split the sheet uses, so both book on the same allocation.
    final parts = splitGroupedConfirmation(
      group,
      completed: 0,
      recalled: quantity,
    );
    if (parts.isEmpty) continue;
    lines.add(
      RecallAllLine(
        members: group,
        target: parts.single.assignment,
        quantity: parts.single.recalled,
      ),
    );
  }
  return lines;
}

/// What became of one [RecallAllLine].
class RecallAllOutcome {
  final RecallAllLine line;

  /// Null when the recall never reached the repository ([skipped]) or the
  /// device refused to store it ([error]).
  final MutationReceipt? receipt;

  /// A local refusal, e.g. the allocation was closed in the meantime.
  final Object? error;

  /// Not attempted: an earlier refusal applies to every order of the worker.
  final bool skipped;

  const RecallAllOutcome({
    required this.line,
    this.receipt,
    this.error,
    this.skipped = false,
  });

  /// Stored on the device, whether SAP already has it or it is still queued.
  bool get saved => receipt != null && !receipt!.isRefused;

  /// SAP confirmed the recall.
  bool get synced => receipt?.state == MutationDeliveryState.synced;
}

/// SAP refusals that are about the account or the worker, not about one
/// order: every remaining recall would be refused the same way, so the run
/// stops instead of collecting identical rejections.
const Set<String> recallAllStopCodes = {
  'RECALL_NOPASS_NOT_ALLOWED',
  'MISSING_PERMISSION',
  'MANAGER_WORKER_NOT_ALLOWED',
  'WORKER_NO_ACCOUNT',
  'WORKER_NOT_IN_WORK_CENTER',
  'USER_INACTIVE',
};

/// Sends [lines] one after another as password-less recalls.
///
/// A refusal that concerns a single order (its balance moved, its lineage is
/// off) does not stop the others; one from [recallAllStopCodes] does, and the
/// rest come back [RecallAllOutcome.skipped]. [canContinue] is asked before
/// each recall, e.g. to stop when the session changed underneath the run.
Future<List<RecallAllOutcome>> recallAllWithoutPassword({
  required RecallRepository recallRepo,
  required List<RecallAllLine> lines,
  required String reasonCode,
  required String businessDate,
  required String shiftId,
  required String createdBy,
  bool Function()? canContinue,
}) async {
  final outcomes = <RecallAllOutcome>[];
  var stopped = false;
  for (final line in lines) {
    if (stopped || canContinue?.call() == false) {
      stopped = true;
      outcomes.add(RecallAllOutcome(line: line, skipped: true));
      continue;
    }
    try {
      final receipt = await recallRepo.recallAssignment(
        assignmentId: line.target.id,
        quantity: line.quantity,
        reasonCode: reasonCode,
        businessDate: businessDate,
        shiftId: shiftId,
        createdBy: createdBy,
        withoutWorkerPassword: true,
        seatCeiling: line.seatCeiling,
      );
      outcomes.add(RecallAllOutcome(line: line, receipt: receipt));
      if (receipt.isRefused && recallAllStopCodes.contains(receipt.code)) {
        stopped = true;
      }
    } on Exception catch (error) {
      outcomes.add(RecallAllOutcome(line: line, error: error));
    }
  }
  return outcomes;
}

/// What the lines take back in total, per unit, in order of first appearance.
/// Quantities of different units are never added together.
Map<String, double> recallAllTotals(Iterable<RecallAllLine> lines) {
  final totals = <String, double>{};
  for (final line in lines) {
    final uom = line.target.uom.trim().toUpperCase();
    totals[uom] = ProductionMath.toSapScale((totals[uom] ?? 0) + line.quantity);
  }
  return totals;
}

/// How a line is named in the recall-all popups: `order.operation`, as on the
/// shop-floor paperwork. Two lines of one order/operation differ only by
/// position, so the position is appended for those ([all] is the whole plan).
String recallAllLineLabel(RecallAllLine line, Iterable<RecallAllLine> all) {
  String base(RecallAllLine other) {
    final target = other.target;
    final order = target.productionOrder.trim().isEmpty
        ? target.orderCode.trim()
        : target.productionOrder.trim();
    return '$order.${target.operation.trim()}';
  }

  final label = base(line);
  final shared = all.where((other) => base(other) == label).length > 1;
  if (!shared) return label;
  final position = line.target.positionId.trim();
  return '$label · ${position.isEmpty ? 'không vị trí' : position}';
}
