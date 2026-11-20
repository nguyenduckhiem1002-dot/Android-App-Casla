// Core — what a SAP session refresh can come back with.
//
// SAP rotates the refresh token on every call and the old one is single-use,
// so a refresh is never retried blindly. Callers need to tell three things
// apart: the tokens were renewed (retry the request), SAP refused the refresh
// token (the session is over, log out and say so), or SAP could not be
// reached at all (keep the session, the work stays queued, try later).
// Collapsing the last two into "false" is what used to log a supervisor out
// over a flaky Wi-Fi moment.

enum SessionRefreshOutcome {
  /// Tokens renewed; the request that failed can be sent again.
  refreshed,

  /// SAP answered and refused: dead or rotated-away refresh token, revoked
  /// session, device mismatch. The session cannot recover.
  rejected,

  /// SAP did not answer (offline, timeout, 5xx). Nothing is known about the
  /// session; keep it and try again later.
  unavailable,

  /// Nothing to refresh: no session, no refresh token, or the session changed
  /// while the refresh was in flight.
  skipped,
}

/// SAP answered the refresh call with a business rejection.
class SessionRefreshRejectedException implements Exception {
  final String code;
  final String message;

  const SessionRefreshRejectedException({
    required this.code,
    required this.message,
  });

  @override
  String toString() => 'SessionRefreshRejectedException($code)';
}

/// SAP refused a call because its access token is no longer valid. Unlike a
/// refused refresh, the session may still be renewable: refresh, then send
/// the call again (see `runWithAccessTokenRetry`).
class AccessTokenExpiredException implements Exception {
  final String message;

  const AccessTokenExpiredException(this.message);

  @override
  String toString() => message;
}

/// The refresh call never got a usable answer from SAP.
class SessionRefreshUnavailableException implements Exception {
  final String message;

  const SessionRefreshUnavailableException(this.message);

  @override
  String toString() => 'SessionRefreshUnavailableException';
}
