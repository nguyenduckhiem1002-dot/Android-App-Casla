// Domain — confirming several operations of one worker in one go.
//
// The supervisor ticks the operations and either types one number, which is
// confirmed on each of them, or asks to finish what every ticked operation
// still has open, which confirms each operation's own balance.

import '../entities/entities.dart';
import 'grouped_confirmation.dart';
import 'production_math.dart';

/// What each of [groups] confirms, in the same order: [entered] on every one,
/// or with [confirmRemaining] whatever that operation still has open.
List<double> multiConfirmationQuantities(
  Iterable<List<Assignment>> groups, {
  required bool confirmRemaining,
  double entered = 0,
}) => [
  for (final group in groups)
    ProductionMath.toSapScale(
      confirmRemaining
          ? confirmationGroupRemaining(group).clamp(0.0, double.infinity)
          : entered,
    ),
];

/// The figure shown as "Tổng" beside the quantity: [quantities] added up.
double multiConfirmationTotal(Iterable<double> quantities) =>
    ProductionMath.toSapScale(
      quantities.fold(0.0, (total, quantity) => total + quantity),
    );

/// What is still open on a confirmation group: the seat's settled balance.
double confirmationGroupRemaining(List<Assignment> group) =>
    aggregateConfirmationGroup(group).groupRemaining;

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
