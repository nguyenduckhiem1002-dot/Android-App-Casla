// Core — Session Manager (Riverpod providers)
// Manages current user session, permissions, and navigation state

import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../data/repositories/repositories_impl.dart';
import '../../data/sap/sap_odata_client.dart';
import '../../data/sap/sap_pp_opalloc_gateway.dart';
import '../../data/sap/sap_session_provider.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';
import '../config/app_config.dart';
import '../database/casla_database.dart';
import '../network/connectivity_monitor.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_access_scope.dart';
import '../sync/verified_sync_coordinator.dart';
import 'session_coordinator.dart';

/// App-level state holder (simple ChangeNotifier for MVP, upgrade to Riverpod later)
class AppState extends ChangeNotifier {
  final CaslaDatabase db;
  late final AuthRepositoryImpl authRepo;
  late final AssignmentRepositoryImpl assignmentRepo;
  late final ProductionRepositoryImpl productionRepo;
  late final RecallRepositoryImpl recallRepo;
  late final WorkHistoryRepositoryImpl workHistoryRepo;
  late final SapPpOpAllocGateway sapGateway;
  late final SyncEngine syncEngine;
  late final VerifiedSyncCoordinator verifiedSync;
  late final SessionCoordinator _session;

  AppState() : db = CaslaDatabase.instance {
    authRepo = AuthRepositoryImpl(db);
    _session = SessionCoordinator(authRepo.refreshSession)
      ..addListener(_onSessionChanged);

    sapGateway = SapPpOpAllocGateway(
      db: db,
      client: SapODataClient(baseUrl: AppConfig.sapPpOpAllocServiceUrl),
      session: _AppStateSapSession(this),
    );
    verifiedSync = VerifiedSyncCoordinator(
      database: db,
      gateway: sapGateway,
      canExecute: _canRunBackgroundSync,
      scopeProvider: () => _syncAccessScope,
    );

    assignmentRepo = AssignmentRepositoryImpl(db, gateway: sapGateway);
    productionRepo = ProductionRepositoryImpl(
      db,
      gateway: sapGateway,
      verifiedSync: verifiedSync,
    );
    recallRepo = RecallRepositoryImpl(
      db,
      gateway: sapGateway,
      verifiedSync: verifiedSync,
    );
    workHistoryRepo = WorkHistoryRepositoryImpl(
      db,
      loadRemote: sapGateway.getWorkHistory,
      cacheSubject: () => _workHistoryCacheSubject,
      isCacheSubjectCurrent: _isCurrentWorkHistorySubject,
      onAuthorizationRejected: (subject) async {
        if (_isCurrentWorkHistorySubject(subject)) await logout();
      },
    );

    // Drains anything a write's immediate push left queued — offline at the
    // moment of write, a transient SAP error, or a token that needed a
    // refresh. It cannot do anything with an item stuck at
    // NEEDS_VERIFICATION: every mutation on this backend requires the
    // worker's own password, which this background loop has no way to ask
    // for — see `SyncPushRequest.workerPassword`.
    syncEngine = SyncEngine(
      database: db,
      gateway: sapGateway,
      connectivity: PlatformConnectivityMonitor(),
      canRun: _canRunBackgroundSync,
      scopeProvider: () => _syncAccessScope,
    );
  }

  String? get _workHistoryCacheSubject {
    final session = _session.currentSession;
    if (session == null) return null;

    // SAP can change history permissions between logins. Include the effective
    // history scope in the namespace so a reduced-permission login never sees
    // a team-level snapshot cached by an earlier session.
    final scopes =
        session.permissions
            .where(
              (permission) =>
                  permission == Permission.viewOwnProductionHistory ||
                  permission == Permission.viewTeamProductionHistory,
            )
            .map((permission) => permission.name)
            .toList()
          ..sort();
    final workScopes = session.toIds.toList()..sort();
    // A cache entry belongs to one exact local session lifetime, SAP endpoint
    // and authorization scope. This prevents a new user (or a user whose
    // scope was reduced) from seeing an earlier account's cached history.
    return 'v2:${_session.generation}:${AppConfig.sapPpOpAllocServiceUrl}:'
        '${session.id}:${session.maNv}:${scopes.join(',')}:'
        '${workScopes.join(',')}';
  }

  bool _isCurrentWorkHistorySubject(String subject) =>
      subject == _workHistoryCacheSubject;

  bool _canRunBackgroundSync() {
    final session = _session.currentSession;
    return session != null && !session.passwordChangeRequired;
  }

  SyncAccessScope? get _syncAccessScope {
    final session = _session.currentSession;
    if (session == null || session.passwordChangeRequired) return null;
    final scope = SyncAccessScope(
      actorId: session.maNv,
      teamIds: session.toIds,
    );
    return scope.isUsable ? scope : null;
  }

  void _onSessionChanged() {
    // Do not start a background write loop before login (or while the account
    // is restricted to a mandatory password change). It otherwise consumes
    // global queue items with no authenticated owner.
    if (_canRunBackgroundSync()) {
      syncEngine.start();
    } else {
      unawaited(syncEngine.stop());
    }
    notifyListeners();
  }

  // ─── Session ──────────────────────────────────────────────────────
  UserSession? get currentSession => _session.currentSession;
  bool get isLoggedIn => _session.isLoggedIn;
  UserRole? get currentRole => _session.currentSession?.role;

  Future<bool> loginByCredentials(String username, String password) async {
    final generation = _session.beginLogin();
    // Login, logout and refresh must not share a stale CSRF/cookie jar.
    authRepo.resetTransportSession();
    sapGateway.resetTransportSession();
    try {
      final session = await authRepo.loginByCredentials(username, password);
      if (_session.completeLogin(generation: generation, session: session)) {
        return true;
      }

      // A newer login/logout won the race. Revoke this abandoned token on a
      // dedicated client without ever restoring it locally.
      unawaited(_revokeDiscardedSession(session));
      return false;
    } catch (_) {
      rethrow;
    }
  }

  Future<void> logout() async {
    // End local access first. Remote revocation is best effort and must never
    // stall the UI, nor share the next login's CSRF/cookie state.
    final previous = _session.clear();
    authRepo.resetTransportSession();
    sapGateway.resetTransportSession();
    if (previous != null) unawaited(_revokeDiscardedSession(previous));
  }

  Future<void> _revokeDiscardedSession(UserSession session) async {
    try {
      await authRepo.logout(accessToken: session.accessToken);
    } catch (_) {
      // Local logout is already complete. SapAuthController.logout is also
      // best effort; this catch keeps a device/platform failure unobservable.
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    workHistoryRepo.dispose();
    unawaited(syncEngine.dispose());
    super.dispose();
  }
}

/// Adapts [AppState]'s session into the seam [SapPpOpAllocGateway] needs.
///
/// Lives in this file (not a separate one) because it reads `_currentSession`
/// directly — Dart privacy is per-library, so this only works alongside
/// [AppState] in the same file.
class _AppStateSapSession implements SapSessionProvider {
  final AppState _app;

  _AppStateSapSession(this._app);

  @override
  String? get accessToken => _app._session.currentSession?.accessToken;

  @override
  int get generation => _app._session.generation;

  @override
  bool isGenerationCurrent(int generation) =>
      _app._session.isGenerationCurrent(generation);

  @override
  Future<bool> refreshSession() => _app._session.refresh();
}
