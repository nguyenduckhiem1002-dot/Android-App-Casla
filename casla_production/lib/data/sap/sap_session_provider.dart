// SAP Integration — session credential seam
//
// Decouples SapPpOpAllocGateway (data layer) from AppState (app layer): the
// gateway needs to read the current access token and trigger a refresh, but
// must not depend on where session state actually lives.

import '../../core/auth/session_refresh.dart';

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
  /// [staleAccessToken] is the token the failed request carried. When the
  /// session already holds a different one, somebody else refreshed in the
  /// meantime and the caller only needs to retry: no second rotation is
  /// made, which matters because SAP's refresh token is single-use.
  ///
  /// The outcome says what the caller should do next — see
  /// [SessionRefreshOutcome]. Only [SessionRefreshOutcome.refreshed] is a
  /// license to retry; [SessionRefreshOutcome.unavailable] must be reported
  /// as a transient delivery problem, never as an expired session.
  Future<SessionRefreshOutcome> refreshSession({String? staleAccessToken});
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
