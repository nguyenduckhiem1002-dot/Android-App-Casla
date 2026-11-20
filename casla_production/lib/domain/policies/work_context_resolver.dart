import '../entities/entities.dart';

/// Resolves a local Work Context only when the operation QR carries an exact
/// Plant + Work Center pair. An empty result is intentional: SAP remains the
/// authority for the write and the app must not guess among multiple scopes.
UserWorkContext? resolveWorkContext({
  required UserSession session,
  required String plant,
  required String workCenter,
}) {
  final normalizedPlant = plant.trim().toLowerCase();
  final normalizedWorkCenter = workCenter.trim().toLowerCase();
  if (normalizedPlant.isEmpty || normalizedWorkCenter.isEmpty) return null;

  final matches = session.workContexts.where(
    (context) =>
        context.plant.trim().toLowerCase() == normalizedPlant &&
        context.workCenter.trim().toLowerCase() == normalizedWorkCenter,
  );
  return matches.length == 1 ? matches.first : null;
}

/// The Work Context an assignment goes out under, or [blocked] when it must
/// not be sent from the current selection.
typedef AssignmentWorkScope = ({UserWorkContext? context, bool blocked});

/// Decides the Work Context of an assignment from the manager's [selected]
/// setup and the context the operation label resolved to ([scanned], from
/// [resolveWorkContext]; null when the label names none or several).
///
/// SAP accepts any active WorkID that shares the operation's Work Center
/// (`WORK_OPERATION_MISMATCH` otherwise) and compares neither Plant nor
/// department. So within one Work Center the selected department is the one
/// sent, even when the label's Plant singles out a sibling department; that
/// difference is only a warning on the form. Another Work Center is refused.
AssignmentWorkScope assignmentWorkScope({
  required UserWorkContext? selected,
  required UserWorkContext? scanned,
}) {
  if (scanned == null) return (context: selected, blocked: false);
  if (selected == null) return (context: null, blocked: true);
  if (selected.workId == scanned.workId) {
    return (context: selected, blocked: false);
  }
  final selectedWorkCenter = selected.workCenter.trim().toLowerCase();
  final scannedWorkCenter = scanned.workCenter.trim().toLowerCase();
  if (selectedWorkCenter.isNotEmpty &&
      selectedWorkCenter == scannedWorkCenter) {
    return (context: selected, blocked: false);
  }
  return (context: null, blocked: true);
}
