// Core — one refresh-and-retry for a direct call that carries the access token.
//
// Queued writes and the gateways already renew an expired token on their own.
// A call made straight from a screen (changing the password) used to send
// whatever token the session held: after the token's lifetime the supervisor
// was told to log in again although the session was still renewable.

import 'session_refresh.dart';

/// Shown when the session could not be renewed because SAP was unreachable.
const String kSessionRenewUnavailableMessage =
    'Chưa làm mới được phiên đăng nhập. Hãy kiểm tra kết nối rồi thử lại.';

/// Shown when there is no session to send the call with.
const String kNoSessionMessage =
    'Không tìm thấy phiên đăng nhập hợp lệ. Vui lòng đăng nhập lại.';

/// Runs [call] with the current access token. If SAP answers that the token
/// has expired ([AccessTokenExpiredException]), the session is refreshed once
/// and [call] is sent again with the renewed token.
///
/// The refresh token is single-use, so this never refreshes twice: a second
/// expiry answer is passed on to the caller. When SAP refuses the refresh the
/// session is over (the caller of [refreshSession] ends it); the original
/// expiry is rethrown. When SAP cannot be reached, an [Exception] carrying
/// [kSessionRenewUnavailableMessage] is thrown and the session is kept.
Future<T> runWithAccessTokenRetry<T>({
  required String? Function() readAccessToken,
  required Future<SessionRefreshOutcome> Function({String? staleAccessToken})
  refreshSession,
  required Future<T> Function(String accessToken) call,
}) async {
  final usedToken = readAccessToken() ?? '';
  if (usedToken.isEmpty) {
    throw const AccessTokenExpiredException(kNoSessionMessage);
  }
  try {
    return await call(usedToken);
  } on AccessTokenExpiredException {
    final outcome = await refreshSession(staleAccessToken: usedToken);
    switch (outcome) {
      case SessionRefreshOutcome.refreshed:
        final renewed = readAccessToken() ?? '';
        if (renewed.isEmpty || renewed == usedToken) rethrow;
        return call(renewed);
      case SessionRefreshOutcome.unavailable:
        throw Exception(kSessionRenewUnavailableMessage);
      case SessionRefreshOutcome.rejected:
      case SessionRefreshOutcome.skipped:
        rethrow;
    }
  }
}
