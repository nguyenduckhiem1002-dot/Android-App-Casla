// Repository Contracts — Domain Layer
// These interfaces define the business operations.
// UI depends on these, not on data layer implementations.
// Spec: Section 9.1

import '../entities/entities.dart';

/// Authentication & session management
abstract class AuthRepository {
  Future<UserSession> loginByCredentials(String username, String password);
  Future<void> logout({String? accessToken});
}

/// Assignment CRUD & queries
abstract class AssignmentRepository {
  Future<String> createAssignment({
    required String workerId,
    required String orderId,
    required String teamId,
    required double assignedQuantity,
    required String businessDate,
    required String shiftId,
    String? note,
    required String createdBy,
  });

  Stream<List<Assignment>> watchWorkerAssignments(String workerId);
  Stream<List<Assignment>> watchAllAssignments();
  Future<Assignment?> getAssignmentById(String id);
}

/// Production recording
abstract class ProductionRepository {
  Future<String> recordProduction({
    required String assignmentId,
    required double quantity,
    required String businessDate,
    required String shiftId,
    required String createdBy,
    String? note,
  });

  Stream<List<ProductionRecord>> watchRecordsByAssignment(String assignmentId);
  Future<double> getCompletedQuantity(String assignmentId);
  Future<double> getTodayCompleted(String workerId, String businessDate);
}

/// Recall operations
abstract class RecallRepository {
  Future<String> recallAssignment({
    required String assignmentId,
    required double quantity,
    required String reasonCode,
    String? note,
    required String businessDate,
    required String shiftId,
    required String createdBy,
  });

  Future<double> getRecalledQuantity(String assignmentId);
}
