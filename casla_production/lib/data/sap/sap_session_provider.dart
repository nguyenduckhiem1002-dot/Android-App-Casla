// SAP Integration — session credential seam
//
// Decouples SapPpOpAllocGateway (data layer) from AppState (app layer): the
// gateway needs to read the current access token and trigger a refresh, but
// must not depend on where session state actually lives.

abstract class SapSessionProvider {
  /// The current session's access token, or null when nobody is logged in.
  String? get accessToken;

  /// Monotonically increases whenever the signed-in identity changes. A
  /// gateway captures it before I/O and verifies it again before mutating
  /// local sync state, preventing an old request from completing for a new
  /// account.
  int get generation;

  /// Whether [generation] still belongs to the active signed-in session.
  bool isGenerationCurrent(int generation);

  /// Attempts to refresh the current session's tokens using its refresh
  /// token, updating whatever holds the session on success.
  ///
  /// Returns false when there is no session to refresh, or the refresh call
  /// itself was rejected (dead refresh token, revoked session) — the engine
  /// treats that as "give up on this pass", not as license to retry forever.
  Future<bool> refreshSession();
}

/// The request belonged to a session that ended while it was in flight.
///
/// This is deliberately distinct from an expired SAP token: the caller must
/// leave the queue unchanged instead of recording a retry under another user.
class SapSessionInvalidatedException implements Exception {
  const SapSessionInvalidatedException();

  @override
  String toString() => 'SapSessionInvalidatedException';
}
