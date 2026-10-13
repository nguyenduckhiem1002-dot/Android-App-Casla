import '../entities/entities.dart';

/// Keeps confirmation targets inside the work context currently selected by
/// the supervisor. An empty context preserves the broader session scope.
List<Assignment> actionableAssignmentsForConfirmationScope(
  Iterable<Assignment> assignments, {
  String? workContextId,
}) {
  final expectedWorkContext = workContextId?.trim() ?? '';
  return assignments
      .where(
        (assignment) =>
            assignment.canRecord &&
            (expectedWorkContext.isEmpty ||
                assignment.teamId.trim() == expectedWorkContext),
      )
      .toList(growable: false);
}
