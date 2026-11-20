// Core — session lifetime and refresh serialization.
//
// A SAP refresh is asynchronous and its token rotation is single-use.  Keeping
// the lifetime guard here means an old refresh can never overwrite a newer
// login (or resurrect a session after logout).

import 'package:flutter/foundation.dart';

import '../../domain/entities/entities.dart';
import 'session_refresh.dart';

typedef SessionRefresher = Future<UserSession?> Function(UserSession current);

class SessionCoordinator extends ChangeNotifier {
  final SessionRefresher _refreshSession;

  UserSession? _currentSession;
  int _generation = 0;
  Future<SessionRefreshOutcome>? _refreshInFlight;
  int? _refreshGeneration;

  SessionCoordinator(this._refreshSession);

  UserSession? get currentSession => _currentSession;
  int get generation => _generation;
  bool get isLoggedIn => _currentSession != null;

  /// Starts a new login lifetime. Any result belonging to a previous lifetime
  /// is ignored by [completeLogin].
  int beginLogin() {
    _generation++;
    _currentSession = null;
    _refreshInFlight = null;
    _refreshGeneration = null;
    notifyListeners();
    return _generation;
  }

  /// Accepts a login result only when it still belongs to the active attempt.
  bool completeLogin({required int generation, required UserSession session}) {
    if (_generation != generation) return false;
    _currentSession = session;
    notifyListeners();
    return true;
  }

  /// Ends local access immediately. The caller may revoke [UserSession]'s
  /// token remotely afterwards without holding the UI or restoring this state.
  UserSession? clear() {
    final previous = _currentSession;
    _generation++;
    _currentSession = null;
    _refreshInFlight = null;
    _refreshGeneration = null;
    notifyListeners();
    return previous;
  }

  bool isGenerationCurrent(int generation) =>
      _generation == generation && _currentSession != null;

  /// Refreshes at most once for a session generation. The result is committed
  /// only if the exact same account and refresh token are still active.
  Future<bool> refresh({String? staleAccessToken}) async =>
      await refreshDetailed(staleAccessToken: staleAccessToken) ==
      SessionRefreshOutcome.refreshed;

  /// Like [refresh], but says why it did not refresh. When [staleAccessToken]
  /// is given and the session already carries a newer access token, the
  /// answer is [SessionRefreshOutcome.refreshed] without a SAP call: the
  /// caller's request simply raced an earlier refresh and can be retried.
  Future<SessionRefreshOutcome> refreshDetailed({String? staleAccessToken}) {
    final current = _currentSession;
    if (current == null || current.refreshToken.isEmpty) {
      return Future<SessionRefreshOutcome>.value(SessionRefreshOutcome.skipped);
    }
    if (staleAccessToken != null &&
        staleAccessToken.isNotEmpty &&
        current.accessToken != staleAccessToken) {
      return Future<SessionRefreshOutcome>.value(
        SessionRefreshOutcome.refreshed,
      );
    }
    final generation = _generation;
    final inFlight = _refreshInFlight;
    if (inFlight != null && _refreshGeneration == generation) {
      return inFlight;
    }
    final future = _refreshFor(current, generation);
    _refreshInFlight = future;
    _refreshGeneration = generation;
    return future;
  }

  Future<SessionRefreshOutcome> _refreshFor(
    UserSession current,
    int generation,
  ) async {
    try {
      final refreshed = await _refreshSession(current);
      if (refreshed == null) return SessionRefreshOutcome.skipped;
      if (_generation != generation ||
          _currentSession?.id != current.id ||
          _currentSession?.refreshToken != current.refreshToken) {
        return SessionRefreshOutcome.skipped;
      }
      _currentSession = refreshed;
      notifyListeners();
      return SessionRefreshOutcome.refreshed;
    } on SessionRefreshRejectedException {
      return SessionRefreshOutcome.rejected;
    } catch (_) {
      // A transport failure, or an answer that could not be read. The session
      // is kept: nothing says it is over.
      return SessionRefreshOutcome.unavailable;
    } finally {
      if (_refreshGeneration == generation) {
        _refreshInFlight = null;
        _refreshGeneration = null;
      }
    }
  }
}
