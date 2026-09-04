// SAP Integration — session credential seam
//
// Decouples SapPpOpAllocGateway (data layer) from AppState (app layer): the
// gateway needs to read the current access token and trigger a refresh, but
// must not depend on where session state actually lives.

abstract class SapSessionProvider {
  /// The current session's access token, or null when nobody is logged in.
  String? get accessToken;

  /// Attempts to refresh the current session's tokens using its refresh
  /// token, updating whatever holds the session on success.
  ///
  /// Returns false when there is no session to refresh, or the refresh call
  /// itself was rejected (dead refresh token, revoked session) — the engine
  /// treats that as "give up on this pass", not as license to retry forever.
  Future<bool> refreshSession();
}
