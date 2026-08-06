// Core — Session Manager (Riverpod providers)
// Manages current user session, permissions, and navigation state

import 'package:flutter/foundation.dart';
import '../../data/repositories/repositories_impl.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';
import '../../core/database/casla_database.dart';
import '../../domain/policies/shift_resolver.dart';

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

  ShiftInfo get currentShift => ShiftResolver.getCurrentShiftInfo();

  Future<bool> loginByMaNv(String maNv) async {
    try {
      _currentSession = await authRepo.loginByMaNv(maNv);
      notifyListeners();
      return true;
    } catch (e) {
      return false;
    }
  }

  void logout() {
    _currentSession = null;
    notifyListeners();
  }
}
