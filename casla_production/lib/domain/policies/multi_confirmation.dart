// Domain — confirming several operations of one worker with one quantity.
//
// The supervisor ticks the operations and types one number; that number is
// confirmed on each of them. It can therefore be no larger than what the
// operation with the least left can still take.

import '../entities/entities.dart';
import 'grouped_confirmation.dart';

/// What is still open on a confirmation group (all its allocations).
double confirmationGroupRemaining(List<Assignment> group) =>
    aggregateConfirmationGroup(group).remaining;

/// The group with the least left among [groups], which caps the quantity that
/// can be confirmed on all of them. Null when [groups] is empty.
({double remaining, List<Assignment> group})? tightestConfirmationGroup(
  Iterable<List<Assignment>> groups,
) {
  ({double remaining, List<Assignment> group})? tightest;
  for (final group in groups) {
    if (group.isEmpty) continue;
    final remaining = confirmationGroupRemaining(group);
    if (tightest == null || remaining < tightest.remaining) {
      tightest = (remaining: remaining, group: group);
    }
  }
  return tightest;
}

/// Display name of a group's operation: its SAP name, or `Công đoạn 0020`
/// when the label carried none.
String confirmationGroupName(List<Assignment> group) {
  final first = aggregateConfirmationGroup(group);
  final name = first.operationName.trim();
  return name.isEmpty ? 'Công đoạn ${first.operation}' : name;
}
