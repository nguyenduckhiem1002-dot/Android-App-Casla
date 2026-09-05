// Repository Contracts — Domain Layer
// These interfaces define the business operations.
// UI depends on these, not on data layer implementations.
// Spec: Section 9.1

import '../entities/entities.dart';
import '../entities/mutation_receipt.dart';
import '../entities/work_history.dart';

/// Authentication & session management
abstract class AuthRepository {
  Future<UserSession> loginByCredentials(String username, String password);
  Future<void> logout({String? accessToken});
}

/// Assignment CRUD & queries
abstract class AssignmentRepository {
  /// [workerPassword] is the worker's own SAP password — required by
  /// `submitInitialAssign` to push this immediately. Omit it (or pass an
  /// empty string) to write the assignment locally only; it is marked
  /// NEEDS_VERIFICATION until a supervisor supplies the password from the
  /// sync screen.
  Future<MutationReceipt> createAssignment({
    required String workerId,
    required String orderId,
    required String teamId,
    required double assignedQuantity,
    required String businessDate,
    required String shiftId,
    String? note,
    required String createdBy,
    String? workerPassword,
  });

  Stream<List<Assignment>> watchWorkerAssignments(String workerId);
  Stream<List<Assignment>> watchAssignmentsByTeams(List<String> teamIds);
  Stream<List<Assignment>> watchAllAssignments();
  Stream<Assignment?> watchAssignment(String id);
  Future<Assignment?> getAssignmentById(String id);
}

/// Production recording
abstract class ProductionRepository {
  /// See [AssignmentRepository.createAssignment] for what [workerPassword]
  /// does and why it's optional.
  Future<MutationReceipt> recordProduction({
    required String assignmentId,
    required double quantity,
    required String businessDate,
    required String shiftId,
    required String createdBy,
    String? note,
    String? workerPassword,
  });

  Stream<List<ProductionRecord>> watchRecordsByAssignment(String assignmentId);
  Future<double> getCompletedQuantity(String assignmentId);
  Future<double> getTodayCompleted(String workerId, String businessDate);
}

/// Recall operations
abstract class RecallRepository {
  /// See [AssignmentRepository.createAssignment] for what [workerPassword]
  /// does and why it's optional.
  Future<MutationReceipt> recallAssignment({
    required String assignmentId,
    required double quantity,
    required String reasonCode,
    String? note,
    required String businessDate,
    required String shiftId,
    required String createdBy,
    String? workerPassword,
  });

  Future<double> getRecalledQuantity(String assignmentId);
}

/// Read-only production history — `ZUI_PP_OPALLOC.getWorkHistory`.
///
/// Scope (self vs. team) is decided entirely server-side from the account's
/// RBAC functions; this repository never sends a worker id to filter by.
abstract class WorkHistoryRepository {
  Future<WorkHistoryResult> getWorkHistory({
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
    bool forceRefresh = false,
  });

  /// Emits the cached snapshot immediately, then emits a replacement whenever
  /// stale-while-revalidate obtains newer SAP data for this exact range.
  Stream<WorkHistoryResult> watchWorkHistory({
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
  });
}
