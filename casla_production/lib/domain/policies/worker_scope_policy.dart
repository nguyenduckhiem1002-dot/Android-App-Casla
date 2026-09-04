enum WorkerScopeMatch { inScope, outOfScope, unknown }

/// Evaluates only the local master-data hint used for navigation ergonomics.
///
/// An empty worker team list means the SAP-derived employee cache has not yet
/// learned the worker's team membership. That is `unknown`, not `outOfScope`.
/// Write operations remain protected by SAP, which re-checks the authenticated
/// supervisor work scope server-side.
class WorkerScopePolicy {
  WorkerScopePolicy._();

  static WorkerScopeMatch evaluate({
    required Iterable<String> workerTeamIds,
    required Iterable<String> supervisorTeamIds,
  }) {
    final supervisorScope = supervisorTeamIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (supervisorScope.isEmpty) return WorkerScopeMatch.outOfScope;

    final workerScope = workerTeamIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (workerScope.isEmpty) return WorkerScopeMatch.unknown;

    return workerScope.any(supervisorScope.contains)
        ? WorkerScopeMatch.inScope
        : WorkerScopeMatch.outOfScope;
  }
}
