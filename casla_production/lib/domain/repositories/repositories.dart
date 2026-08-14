// Repository Contracts — Domain Layer
// These interfaces define the business operations.
// UI depends on these, not on data layer implementations.
// Spec: Section 9.1

import '../entities/entities.dart';
import '../entities/enums.dart';

/// Authentication & session management
abstract class AuthRepository {
  Future<UserSession> loginByMaNv(String maNv);
  Future<UserSession> loginByCredentials(String username, String password);
  Future<List<Permission>> getSessionPermissions(String userId);
  Future<void> logout({String? accessToken});
}

/// Employee & master data
abstract class MasterDataRepository {
  Future<Employee?> findEmployeeByCode(String maNv);
  Future<List<Employee>> getAllEmployees();
  Future<List<ProductionOrder>> getOpenOrders();
  Future<List<Team>> getTeams();
  Future<List<Team>> getSupervisorScope(String supervisorId);
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

/// Sync queue management
abstract class SyncRepository {
  Stream<List<SyncQueueItem>> watchSyncQueue();
  Stream<int> watchPendingCount();
  Future<int> processSyncQueue();
  Future<void> retryItem(String itemId);
}
