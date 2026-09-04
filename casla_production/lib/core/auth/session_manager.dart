// Core — Session Manager (Riverpod providers)
// Manages current user session, permissions, and navigation state

import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../data/repositories/repositories_impl.dart';
import '../../data/sap/sap_auth_controller.dart';
import '../../data/sap/sap_odata_client.dart';
import '../../data/sap/sap_pp_opalloc_gateway.dart';
import '../../data/sap/sap_session_provider.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';
import '../config/app_config.dart';
import '../database/casla_database.dart';
import '../network/connectivity_monitor.dart';
import '../sync/sync_engine.dart';
import '../utils/device_info.dart';

/// App-level state holder (simple ChangeNotifier for MVP, upgrade to Riverpod later)
class AppState extends ChangeNotifier {
  final CaslaDatabase db;
  late final AuthRepositoryImpl authRepo;
  late final AssignmentRepositoryImpl assignmentRepo;
  late final ProductionRepositoryImpl productionRepo;
  late final RecallRepositoryImpl recallRepo;
  late final SapPpOpAllocGateway sapGateway;
  late final SyncEngine syncEngine;

  UserSession? _currentSession;

  AppState() : db = CaslaDatabase.instance {
    authRepo = AuthRepositoryImpl(db);

    sapGateway = SapPpOpAllocGateway(
      db: db,
      client: SapODataClient(baseUrl: AppConfig.sapPpOpAllocServiceUrl),
      session: _AppStateSapSession(this, authRepo.authController),
    );

    assignmentRepo = AssignmentRepositoryImpl(db, gateway: sapGateway);
    productionRepo = ProductionRepositoryImpl(db, gateway: sapGateway);
    recallRepo = RecallRepositoryImpl(db, gateway: sapGateway);

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
    )..start();
  }

  // ─── Session ──────────────────────────────────────────────────────
  UserSession? get currentSession => _currentSession;
  bool get isLoggedIn => _currentSession != null;
  UserRole? get currentRole => _currentSession?.role;

  Future<bool> loginByCredentials(String username, String password) async {
    try {
      _currentSession = await authRepo.loginByCredentials(username, password);
      notifyListeners();
      return true;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> logout() async {
    final token = _currentSession?.accessToken;
    try {
      if (token != null && token.isNotEmpty) {
        await authRepo.logout(accessToken: token);
      }
    } finally {
      // Local access must end even if SAP is offline or logout times out.
      _currentSession = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
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
  final SapAuthController _authController;

  _AppStateSapSession(this._app, this._authController);

  @override
  String? get accessToken => _app._currentSession?.accessToken;

  @override
  Future<bool> refreshSession() async {
    final current = _app._currentSession;
    if (current == null || current.refreshToken.isEmpty) return false;

    try {
      final result = await _authController.refresh(
        refreshToken: current.refreshToken,
        deviceId: await DeviceInfoHelper.getDeviceId(),
      );
      if (!result.isSuccess) return false;

      // Re-check: a concurrent logout must not resurrect a session.
      if (_app._currentSession == null) return false;

      _app._currentSession = current.copyWithTokens(
        accessToken: result.accessToken,
        refreshToken: result.refreshToken,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
