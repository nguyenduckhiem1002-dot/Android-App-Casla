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
