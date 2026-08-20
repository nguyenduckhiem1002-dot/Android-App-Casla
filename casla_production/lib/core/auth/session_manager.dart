// Core — Session Manager (Riverpod providers)
// Manages current user session, permissions, and navigation state

import 'package:flutter/foundation.dart';
import '../../data/repositories/repositories_impl.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';
import '../../core/database/casla_database.dart';

/// App-level state holder (simple ChangeNotifier for MVP, upgrade to Riverpod later)
class AppState extends ChangeNotifier {
  final CaslaDatabase db;
  late final AuthRepositoryImpl authRepo;
  late final AssignmentRepositoryImpl assignmentRepo;
  late final ProductionRepositoryImpl productionRepo;
  late final RecallRepositoryImpl recallRepo;

  UserSession? _currentSession;

  AppState() : db = CaslaDatabase.instance {
    authRepo = AuthRepositoryImpl(db);
    assignmentRepo = AssignmentRepositoryImpl(db);
    productionRepo = ProductionRepositoryImpl(db);
    recallRepo = RecallRepositoryImpl(db);
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
}
