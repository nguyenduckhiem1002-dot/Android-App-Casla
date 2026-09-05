// Sync — local visibility/ownership scope for durable queue items.
//
// The database intentionally keeps one device-wide outbox. This value is the
// app-side guard that prevents an authenticated supervisor from seeing or
// draining rows created by a different account/team on the same device.

class SyncAccessScope {
  final String actorId;
  final List<String> teamIds;
  final int sessionGeneration;

  SyncAccessScope({
    required String actorId,
    required Iterable<String> teamIds,
    this.sessionGeneration = 0,
  }) : actorId = actorId.trim(),
       teamIds = List.unmodifiable(
         teamIds
             .map((id) => id.trim())
             .where((id) => id.isNotEmpty)
             .toSet()
             .toList()
           ..sort(),
       );

  bool get isUsable => actorId.isNotEmpty && teamIds.isNotEmpty;

  bool matches(SyncAccessScope? other) =>
      other != null &&
      sessionGeneration == other.sessionGeneration &&
      actorId == other.actorId &&
      teamIds.length == other.teamIds.length &&
      _sameTeams(other.teamIds);

  bool _sameTeams(List<String> other) {
    for (var index = 0; index < teamIds.length; index++) {
      if (teamIds[index] != other[index]) return false;
    }
    return true;
  }
}

typedef SyncAccessScopeProvider = SyncAccessScope? Function();
