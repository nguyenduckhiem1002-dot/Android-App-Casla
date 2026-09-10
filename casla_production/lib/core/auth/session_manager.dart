// Core — Session Manager (Riverpod providers)
// Manages current user session, permissions, and navigation state

import 'dart:async';
import 'dart:convert';

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
import '../../data/sap/sap_shift_controller.dart';

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
  late final SapShiftController shiftController;
  late final SessionCoordinator _session;
  UserWorkContext? _activeWorkContext;
  SapShift? _activeShift;
  DateTime _activeBusinessDate = DateTime.now();
  DateTime? _setupExpiresAt;
  Timer? _setupExpiryTimer;

  AppState() : db = CaslaDatabase.instance {
    authRepo = AuthRepositoryImpl(db);
    _session = SessionCoordinator(authRepo.refreshSession)
      ..addListener(_onSessionChanged);

    sapGateway = SapPpOpAllocGateway(
      db: db,
      client: SapODataClient(baseUrl: AppConfig.sapPpOpAllocServiceUrl),
      session: _AppStateSapSession(this),
    );
    shiftController = SapShiftController(
      SapODataClient(baseUrl: AppConfig.sapShiftApiServiceUrl),
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
      loadRemote: ({required range, dateFrom, dateTo, shiftId}) =>
          sapGateway.getWorkHistory(
            range: range,
            dateFrom: dateFrom,
            dateTo: dateTo,
            shiftId: shiftId,
          ),
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
    return 'v3:${_session.generation}:${AppConfig.sapPpOpAllocServiceUrl}:'
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
      sessionGeneration: _session.generation,
    );
    return scope.isUsable ? scope : null;
  }

  void _onSessionChanged() {
    _reconcileSupervisorSetupWithSession();
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

  void _reconcileSupervisorSetupWithSession() {
    final session = _session.currentSession;
    if (session == null || session.role != UserRole.supervisor) return;

    final current = _activeWorkContext;
    if (current == null) return;

    final refreshedWork = _findCurrentWorkContext(session, current.workId);
    if (refreshedWork == null) {
      _setupExpiryTimer?.cancel();
      _setupExpiresAt = null;
      _activeWorkContext = null;
      _activeShift = null;
      return;
    }

    _activeWorkContext = refreshedWork;
    final shift = _activeShift;
    if (shift == null ||
        shift.plant != refreshedWork.plant ||
        !shift.isValidOn(_activeBusinessDate)) {
      _setupExpiryTimer?.cancel();
      _setupExpiresAt = null;
      _activeShift = null;
    }
  }

  DateTime _nextSupervisorSetupBoundary([DateTime? value]) {
    final now = value ?? DateTime.now();
    final todayAtEight = DateTime(now.year, now.month, now.day, 8);
    return now.isBefore(todayAtEight)
        ? todayAtEight
        : todayAtEight.add(const Duration(days: 1));
  }

  // ─── Session ──────────────────────────────────────────────────────
  UserSession? get currentSession => _session.currentSession;
  int get sessionGeneration => _session.generation;
  bool isSessionGenerationCurrent(int generation) =>
      _session.isGenerationCurrent(generation);
  bool get isLoggedIn => _session.isLoggedIn;
  UserRole? get currentRole => _session.currentSession?.role;
  bool get _setupExpired =>
      _setupExpiresAt != null && !DateTime.now().isBefore(_setupExpiresAt!);
  UserWorkContext? get activeWorkContext =>
      _setupExpired ? null : _activeWorkContext;
  SapShift? get activeShift => _setupExpired ? null : _activeShift;
  DateTime get activeBusinessDate => _activeBusinessDate;
  bool get needsSupervisorSetup =>
      currentRole == UserRole.supervisor &&
      currentSession != null &&
      !currentSession!.passwordChangeRequired &&
      (activeWorkContext == null || activeShift == null);

  Future<void> completeSupervisorSetup({
    required UserWorkContext workContext,
    required SapShift shift,
    required DateTime businessDate,
  }) async {
    final session = currentSession;
    if (session == null || session.role != UserRole.supervisor) {
      throw StateError('Phiên quản lý không còn hiệu lực.');
    }
    _activeWorkContext = workContext;
    _activeShift = shift;
    _activeBusinessDate = DateTime(
      businessDate.year,
      businessDate.month,
      businessDate.day,
    );
    final now = DateTime.now();
    // A selection remains valid for the working day. "Ngày mới" starts at
    // 08:00 the following calendar day, even when the setup is completed
    // before 08:00 today.
    final expiresAt = _nextSupervisorSetupBoundary(now);
    _setupExpiresAt = expiresAt;
    _scheduleSetupExpiry();
    try {
      await _persistSupervisorSetup(session);
    } catch (_) {
      _setupExpiryTimer?.cancel();
      _setupExpiresAt = null;
      _activeWorkContext = null;
      _activeShift = null;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> _restoreSupervisorSetup(
    UserSession session, {
    required int generation,
  }) async {
    _setupExpiryTimer?.cancel();
    _setupExpiresAt = null;
    _activeWorkContext = null;
    _activeShift = null;
    final today = DateTime.now();
    _activeBusinessDate = DateTime(today.year, today.month, today.day);
    if (session.role != UserRole.supervisor || session.passwordChangeRequired) {
      return;
    }
    final raw = await db.getLocalSetting('supervisor_setup:${session.id}');
    if (!isSessionGenerationCurrent(generation) ||
        currentSession?.id != session.id) {
      return;
    }
    if (raw == null || raw.isEmpty) return;
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return;
      final expiresAtMs = data['expires_at_local_ms'];
      final shiftData = data['shift'];
      if (expiresAtMs is! num || shiftData is! Map) return;
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        expiresAtMs.toInt(),
      );
      final setupBoundary = _nextSupervisorSetupBoundary();
      final effectiveExpiresAt = expiresAt.isAfter(setupBoundary)
          ? setupBoundary
          : expiresAt;
      if (!DateTime.now().isBefore(effectiveExpiresAt)) return;
      final businessDate = DateTime.tryParse('${data['business_date'] ?? ''}');
      if (businessDate == null) return;
      final savedWorkId = '${data['work_id'] ?? ''}';
      final workContext = _findCurrentWorkContext(session, savedWorkId);
      if (workContext == null) return;
      final shift = SapShift.fromJson(Map<String, dynamic>.from(shiftData));
      if (shift.plant != workContext.plant || !shift.isValidOn(businessDate)) {
        return;
      }
      _activeWorkContext = workContext;
      _activeShift = shift;
      _activeBusinessDate = DateTime(
        businessDate.year,
        businessDate.month,
        businessDate.day,
      );
      _setupExpiresAt = effectiveExpiresAt;
      _scheduleSetupExpiry();
      notifyListeners();
    } catch (_) {
      // A corrupt/stale preference must never block login. The setup screen
      // will ask for a fresh selection instead.
      _activeWorkContext = null;
      _activeShift = null;
      _setupExpiresAt = null;
    }
  }

  UserWorkContext? _findCurrentWorkContext(UserSession session, String workId) {
    for (final context in session.workContexts) {
      if (context.workId == workId) return context;
    }
    return null;
  }

  Future<void> _persistSupervisorSetup(UserSession session) async {
    final work = _activeWorkContext;
    final shift = _activeShift;
    final expiresAt = _setupExpiresAt;
    if (work == null || shift == null || expiresAt == null) return;
    await db.setLocalSetting(
      'supervisor_setup:${session.id}',
      jsonEncode({
        'work_id': work.workId,
        'work_name': work.workName,
        'plant': work.plant,
        'work_center': work.workCenter,
        'bo_phan': work.boPhan,
        'location': work.location,
        'business_date': _activeBusinessDate.toIso8601String(),
        'expires_at_local_ms': expiresAt.millisecondsSinceEpoch,
        'shift': {
          'Plant': shift.plant,
          'ShiftID': shift.shiftId,
          'ValidFrom': shift.validFrom.toIso8601String(),
          'ShiftName': shift.shiftName,
          'StartTime': shift.startTime,
          'EndTime': shift.endTime,
          'EndDayOffset': shift.endDayOffset,
          'SAPTimeZone': shift.timeZone,
          'ValidTo': shift.validTo?.toIso8601String(),
          'IsActive': shift.isActive,
        },
      }),
    );
  }

  void _scheduleSetupExpiry() {
    _setupExpiryTimer?.cancel();
    final expiresAt = _setupExpiresAt;
    if (expiresAt == null) return;
    final delay = expiresAt.difference(DateTime.now());
    if (delay.isNegative) return;
    _setupExpiryTimer = Timer(
      delay + const Duration(seconds: 1),
      _expireSupervisorSetup,
    );
  }

  void _expireSupervisorSetup() {
    if (!_setupExpired) return;
    _setupExpiresAt = null;
    _activeWorkContext = null;
    _activeShift = null;
    final now = DateTime.now();
    _activeBusinessDate = DateTime(now.year, now.month, now.day);
    notifyListeners();
  }

  Future<bool> loginByCredentials(String username, String password) async {
    final generation = _session.beginLogin();
    // Login, logout and refresh must not share a stale CSRF/cookie jar.
    authRepo.resetTransportSession();
    sapGateway.resetTransportSession();
    _setupExpiryTimer?.cancel();
    _setupExpiresAt = null;
    _activeWorkContext = null;
    _activeShift = null;
    try {
      final session = await authRepo.loginByCredentials(username, password);
      if (_session.completeLogin(generation: generation, session: session)) {
        await _restoreSupervisorSetup(session, generation: _session.generation);
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
    _setupExpiryTimer?.cancel();
    _setupExpiresAt = null;
    _activeWorkContext = null;
    _activeShift = null;
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
    _setupExpiryTimer?.cancel();
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
