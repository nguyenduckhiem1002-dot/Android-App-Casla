// Data Layer — Repository Implementations
// Spec: Section 9.1 (Business contracts)
// Each transaction: Entity + SyncQueue + AuditLog atomic

import '../../core/config/app_config.dart';
import '../../core/database/casla_database.dart';
import '../../core/sync/sap_write_gateway.dart';
import '../../core/sync/sync_failure.dart';
import '../../core/sync/sync_push.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/device_info.dart';
import 'package:flutter/foundation.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/work_history.dart';
import '../../domain/policies/production_math.dart';
import '../../domain/repositories/repositories.dart';

import '../sap/sap_odata_client.dart';
import '../sap/sap_auth_controller.dart';
import '../sap/sap_pp_opalloc_gateway.dart';

// ─── Auth Repository ────────────────────────────────────────────────
class AuthRepositoryImpl implements AuthRepository {
  final CaslaDatabase db;
  late final SapODataClient _sapClient;
  late final SapAuthController _sapAuth;

  AuthRepositoryImpl(this.db) {
    _sapClient = SapODataClient(baseUrl: AppConfig.sapAuthServiceUrl);
    _sapAuth = SapAuthController(_sapClient);
  }

  /// Exposed so [AppState] can reuse the same authenticated client for token
  /// refresh, rather than standing up a second one.
  SapAuthController get authController => _sapAuth;

  @override
  Future<UserSession> loginByCredentials(
    String username,
    String password,
  ) async {
    final deviceId = await DeviceInfoHelper.getDeviceId();
    final result = await _sapAuth.login(
      username: username,
      password: password,
      deviceId: deviceId,
    );

    // `Status == 'F'` covers wrong password, inactive account AND a lockout —
    // deliberately the same public response for all three, so this must not
    // try to guess which one happened from anything else in the result.
    if (!result.isSuccess) {
      throw Exception(
        'Đăng nhập thất bại. Vui lòng kiểm tra lại tài khoản hoặc mật khẩu.',
      );
    }

    final authorization = parseAuthorization(
      permissions: result.permissions,
      workContexts: result.workContexts,
    );

    // Display-only; a failed lookup must not fail the login itself.
    final detail = await _sapAuth.getUserDetail(result.userUuid);

    final session = UserSession(
      id: result.userUuid,
      maNv: username,
      fullName: (detail?['FullName'] ?? username).toString(),
      email: (detail?['Email'] ?? '').toString(),
      teamName: authorization.workContexts.isNotEmpty
          ? authorization.workContexts.first.workName
          : '',
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
      passwordChangeRequired: result.passwordChangeRequired,
      role: authorization.role,
      permissions: authorization.permissions,
      toIds: authorization.workContexts.map((w) => w.workId).toList(),
    );

    await db.insertAuditLog({
      'id': IdGenerator.newId(),
      'event_type': 'LOGIN_SAP',
      'actor_id': username,
      'target_employee_id': username,
      'entity_type': 'SESSION',
      'entity_id': session.id,
      'device_id': deviceId,
      'occurred_at_utc': DateTime.now().millisecondsSinceEpoch,
    });

    return session;
  }

  @override
  Future<void> logout({String? accessToken}) async {
    if (accessToken != null && accessToken.isNotEmpty) {
      await _sapAuth.logout(
        accessToken: accessToken,
        deviceId: await DeviceInfoHelper.getDeviceId(),
      );
    }
  }

  /// Function IDs that mark an account as a supervisor for this app.
  ///
  /// SAP no longer sends an explicit Role claim (see `ZA_MOB_LoginResult` —
  /// there is no `Role` field): the app derives it from the permission set
  /// login/refresh return, the same vocabulary `ZA_MOB_Permission.FuncID`
  /// uses. Matching [Permission.assignQuantity] alone would let a
  /// worker-only account with one stray permission in, so this requires the
  /// full supervisor set.
  static const _supervisorFuncIds = {
    'ASSIGN_QUANTITY',
    'RECALL_ASSIGNMENT',
    'VIEW_TEAM_PRODUCTION',
  };

  /// Converts the permissions/work-contexts SAP returned into the app
  /// session's role/permission/scope claims.
  ///
  /// The app now serves two roles:
  /// - the full supervisor set above → [UserRole.supervisor], which also
  ///   needs at least one Work Context (Plant/WorkCenter) since the
  ///   supervisor screens scope by team;
  /// - `PP_HIST_SELF` (see `zcl_pp_work_history`) alone, with no supervisor
  ///   permissions and no Work Context required → [UserRole.worker], who can
  ///   only reach the read-only history screen. `getWorkHistory` derives the
  ///   worker's own id server-side from the authenticated account, so no
  ///   local Work Context is needed for this.
  ///
  /// Still fails closed: an account with neither is rejected rather than
  /// silently landing on a broken/empty UI.
  @visibleForTesting
  static ({
    UserRole role,
    Set<Permission> permissions,
    List<SapWorkContext> workContexts,
  })
  parseAuthorization({
    required List<SapPermission> permissions,
    required List<SapWorkContext> workContexts,
  }) {
    final funcIds = permissions.map((p) => p.funcId).toSet();
    final appPermissions = Permission.values
        .where((permission) => funcIds.contains(permission.code))
        .toSet();

    if (funcIds.containsAll(_supervisorFuncIds)) {
      if (workContexts.isEmpty) {
        throw Exception('Tài khoản chưa được phân phạm vi tổ sản xuất.');
      }
      return (
        role: UserRole.supervisor,
        permissions: appPermissions,
        workContexts: workContexts,
      );
    }

    if (funcIds.contains(Permission.viewOwnProductionHistory.code) ||
        funcIds.contains(Permission.viewTeamProductionHistory.code)) {
      return (
        role: UserRole.worker,
        permissions: appPermissions,
        workContexts: workContexts,
      );
    }

    throw Exception('Tài khoản chưa được cấp quyền sử dụng ứng dụng.');
  }
}

// ─── Assignment Repository ──────────────────────────────────────────
class AssignmentRepositoryImpl implements AssignmentRepository {
  final CaslaDatabase db;
  final SapWriteGateway gateway;

  AssignmentRepositoryImpl(this.db, {required this.gateway});

  @override
  Future<String> createAssignment({
    required String workerId,
    required String orderId,
    required String teamId,
    required double assignedQuantity,
    required String businessDate,
    required String shiftId,
    String? note,
    required String createdBy,
    String? workerPassword,
  }) async {
    if (assignedQuantity <= 0) throw Exception('Số lượng giao phải lớn hơn 0');

    final id = IdGenerator.newId();
    final idempotencyKey = IdGenerator.newIdempotencyKey();
    final now = DateTime.now().millisecondsSinceEpoch;

    // Atomic: Assignment + SyncQueue + AuditLog
    final assignmentRow = {
      'id': id,
      'nhan_vien_id': workerId,
      'don_hang_id': orderId,
      'to_id': teamId,
      'assigned_quantity': assignedQuantity,
      'business_date': businessDate,
      'shift_id': shiftId,
      'status': 'OPEN',
      'note': note,
      'created_by': createdBy,
      'occurred_at_utc': now,
      'device_id': DeviceInfoHelper.deviceId,
      'sync_status': 'PENDING',
      'idempotency_key': idempotencyKey,
      'created_at_utc': now,
    };
    await db.insertAssignment(assignmentRow);

    final queueItem = {
      'id': IdGenerator.newId(),
      'entity_type': 'ASSIGNMENT',
      'entity_id': id,
      'action': 'CREATE',
      'priority': 1,
      'retry_count': 0,
      'created_at_utc': now,
      'updated_at_utc': now,
    };
    await db.insertSyncQueueItem(queueItem);

    await db.insertAuditLog({
      'id': IdGenerator.newId(),
      'event_type': 'CREATE_ASSIGNMENT',
      'actor_id': createdBy,
      'target_employee_id': workerId,
      'entity_type': 'PhanCong',
      'entity_id': id,
      'business_date': businessDate,
      'shift_id': shiftId,
      'occurred_at_utc': now,
      'device_id': DeviceInfoHelper.deviceId,
    });

    // Spec 4.7: "Có mạng/API tốt → gửi ngay". Every mutation on this backend
    // needs the worker's own password; without one this call still isn't a
    // no-op — it immediately marks the item NEEDS_VERIFICATION rather than
    // leaving it looking like ordinary PENDING work the background engine
    // will get to on its own (it never can, for this backend — see
    // `SyncPushRequest.workerPassword`).
    await pushAndRecord(
      database: db,
      gateway: gateway,
      backoff: SyncBackoff(),
      queueItem: queueItem,
      source: assignmentRow,
      workerPassword: workerPassword,
    );

    return id;
  }

  @override
  Stream<List<Assignment>> watchWorkerAssignments(String workerId) {
    return db.watchAssignmentsByWorker(workerId).asyncMap((entities) async {
      return _mapToAssignmentsBatch(entities);
    });
  }

  @override
  Stream<List<Assignment>> watchAllAssignments() {
    return db.watchAllAssignments().asyncMap((entities) async {
      return _mapToAssignmentsBatch(entities);
    });
  }

  @override
  Future<Assignment?> getAssignmentById(String id) async {
    final entity = await db.getAssignmentById(id);
    if (entity == null) return null;
    final results = await _mapToAssignmentsBatch([entity]);
    return results.isNotEmpty ? results.first : null;
  }

  /// Batch-maps assignment entities to domain models.
  ///
  /// Every lookup table is fetched once up front, so the cost is
  /// O(E + O + P + R + N) rather than O(N × (P + R)). The per-assignment
  /// `getCompletedQuantity` / `getRecalledQuantity` calls that used to sit
  /// inside this loop each scanned the full records table.
  Future<List<Assignment>> _mapToAssignmentsBatch(
    List<Map<String, dynamic>> entities,
  ) async {
    if (entities.isEmpty) return [];

    final employees = await db.getAllEmployees();
    // All orders, not just OPEN ones: an assignment whose order has since closed
    // still has to render its real code and product name.
    final orders = await db.getAllOrders();
    final completedByAssignment = await db.getCompletedQuantitiesByAssignment();
    final recalledByAssignment = await db.getRecalledQuantitiesByAssignment();

    final empLookup = <String, Map<String, dynamic>>{};
    for (final e in employees) {
      empLookup[e['id'] as String] = e;
    }

    final orderLookup = <String, Map<String, dynamic>>{};
    for (final o in orders) {
      orderLookup[o['id'] as String] = o;
    }

    final result = <Assignment>[];
    for (final entity in entities) {
      final empId = entity['nhan_vien_id'] as String;
      final orderId = entity['don_hang_id'] as String;
      final assignmentId = entity['id'] as String;

      final emp = empLookup[empId];
      final ord = orderLookup[orderId];

      final completed = completedByAssignment[assignmentId] ?? 0.0;
      final recalled = recalledByAssignment[assignmentId] ?? 0.0;

      result.add(
        Assignment(
          id: assignmentId,
          workerId: empId,
          workerMaNv: emp?['ma_nv'] as String? ?? empId,
          workerName: emp?['ten'] as String? ?? 'Công nhân',
          teamId: entity['to_id'] as String,
          orderId: orderId,
          orderCode: ord?['ma_don_hang'] as String? ?? orderId,
          productCode: ord?['ma_sp'] as String? ?? 'SP',
          productName: ord?['ten_sp'] as String? ?? 'Sản phẩm',
          uom: ord?['uom'] as String? ?? 'cái',
          assignedQuantity: entity['assigned_quantity'] as double,
          completedQuantity: completed,
          recalledQuantity: recalled,
          businessDate: entity['business_date'] as String,
          shiftId: entity['shift_id'] as String,
          status: AssignmentStatus.values.firstWhere(
            (s) =>
                s.name.toUpperCase() ==
                (entity['status'] as String).toUpperCase(),
            orElse: () => AssignmentStatus.open,
          ),
          note: entity['note'] as String?,
          createdBy: entity['created_by'] as String,
          idempotencyKey: entity['idempotency_key'] as String,
          syncStatus: SyncStatus.values.firstWhere(
            (s) =>
                s.name.toUpperCase() ==
                (entity['sync_status'] as String).toUpperCase(),
            orElse: () => SyncStatus.pending,
          ),
        ),
      );
    }
    return result;
  }
}

// ─── Production Repository ──────────────────────────────────────────
class ProductionRepositoryImpl implements ProductionRepository {
  final CaslaDatabase db;
  final SapWriteGateway gateway;

  ProductionRepositoryImpl(this.db, {required this.gateway});

  @override
  Future<String> recordProduction({
    required String assignmentId,
    required double quantity,
    required String businessDate,
    required String shiftId,
    required String createdBy,
    String? note,
    String? workerPassword,
  }) async {
    final assignment = await db.getAssignmentById(assignmentId);
    if (assignment == null) throw Exception('Phân công không tồn tại');

    final statusStr = assignment['status'] as String;
    if (statusStr.toUpperCase() != 'OPEN') {
      throw Exception('Phân công đã đóng hoặc bị thu hồi');
    }

    final completed = await db.getCompletedQuantity(assignmentId);
    final recalled = await db.getRecalledQuantity(assignmentId);
    final assignedQty = assignment['assigned_quantity'] as double;
    final effective = ProductionMath.calculateEffectiveAssigned(
      assignedQty,
      recalled,
    );
    final remaining = ProductionMath.calculateRemaining(effective, completed);

    final validationErr = ProductionMath.validateProductionEntry(
      quantity,
      remaining,
    );
    if (validationErr != null) throw Exception(validationErr);

    final id = IdGenerator.newId();
    final idempotencyKey = IdGenerator.newIdempotencyKey();
    final now = DateTime.now().millisecondsSinceEpoch;

    // Atomic: ProductionRecord + SyncQueue + AuditLog
    final recordRow = {
      'id': id,
      'phan_cong_id': assignmentId,
      'quantity': quantity,
      'business_date': businessDate,
      'shift_id': shiftId,
      'note': note,
      'created_by': createdBy,
      'occurred_at_utc': now,
      'device_id': DeviceInfoHelper.deviceId,
      'sync_status': 'PENDING',
      'idempotency_key': idempotencyKey,
      'created_at_utc': now,
    };
    await db.insertProductionRecord(recordRow);

    // If remaining reaches 0, update assignment status
    if ((remaining - quantity) <= 0.0001) {
      await db.updateAssignmentStatus(assignmentId, 'COMPLETED', 'PENDING');
    }

    final queueItem = {
      'id': IdGenerator.newId(),
      'entity_type': 'PRODUCTION',
      'entity_id': id,
      'action': 'CREATE',
      'priority': 1,
      'retry_count': 0,
      'created_at_utc': now,
      'updated_at_utc': now,
    };
    await db.insertSyncQueueItem(queueItem);

    await db.insertAuditLog({
      'id': IdGenerator.newId(),
      'event_type': 'RECORD_PRODUCTION',
      'actor_id': createdBy,
      'target_employee_id': assignment['nhan_vien_id'],
      'entity_type': 'GhiNhanSanLuong',
      'entity_id': id,
      'business_date': businessDate,
      'shift_id': shiftId,
      'occurred_at_utc': now,
      'device_id': DeviceInfoHelper.deviceId,
    });

    // See AssignmentRepositoryImpl.createAssignment for what this does
    // without a password.
    await pushAndRecord(
      database: db,
      gateway: gateway,
      backoff: SyncBackoff(),
      queueItem: queueItem,
      source: recordRow,
      workerPassword: workerPassword,
    );

    return id;
  }

  @override
  Stream<List<ProductionRecord>> watchRecordsByAssignment(String assignmentId) {
    return db
        .watchRecordsByAssignment(assignmentId)
        .map(
          (list) => list
              .map(
                (r) => ProductionRecord(
                  id: r['id'] as String,
                  assignmentId: r['phan_cong_id'] as String,
                  quantity: r['quantity'] as double,
                  businessDate: r['business_date'] as String,
                  shiftId: r['shift_id'] as String,
                  note: r['note'] as String?,
                  createdBy: r['created_by'] as String,
                  occurredAtUtc: r['occurred_at_utc'] as int,
                  deviceId: r['device_id'] as String,
                  idempotencyKey: r['idempotency_key'] as String,
                  syncStatus: SyncStatus.values.firstWhere(
                    (s) =>
                        s.name.toUpperCase() ==
                        (r['sync_status'] as String).toUpperCase(),
                    orElse: () => SyncStatus.pending,
                  ),
                ),
              )
              .toList(),
        );
  }

  @override
  Future<double> getCompletedQuantity(String assignmentId) =>
      db.getCompletedQuantity(assignmentId);

  @override
  Future<double> getTodayCompleted(String workerId, String businessDate) =>
      db.getTodayCompleted(workerId, businessDate);
}

// ─── Recall Repository ──────────────────────────────────────────────
class RecallRepositoryImpl implements RecallRepository {
  final CaslaDatabase db;
  final SapWriteGateway gateway;

  RecallRepositoryImpl(this.db, {required this.gateway});

  @override
  Future<String> recallAssignment({
    required String assignmentId,
    required double quantity,
    required String reasonCode,
    String? note,
    required String businessDate,
    required String shiftId,
    required String createdBy,
    String? workerPassword,
  }) async {
    final assignment = await db.getAssignmentById(assignmentId);
    if (assignment == null) throw Exception('Phân công không tồn tại');

    final completed = await db.getCompletedQuantity(assignmentId);
    final recalled = await db.getRecalledQuantity(assignmentId);
    final assignedQty = assignment['assigned_quantity'] as double;
    final maxRecall = ProductionMath.calculateMaxRecall(
      assignedQty,
      completed,
      recalled,
    );

    final validationErr = ProductionMath.validateRecallEntry(
      quantity,
      maxRecall,
      reasonCode,
      note,
    );
    if (validationErr != null) throw Exception(validationErr);

    final id = IdGenerator.newId();
    final idempotencyKey = IdGenerator.newIdempotencyKey();
    final now = DateTime.now().millisecondsSinceEpoch;

    final recallRow = {
      'id': id,
      'phan_cong_id': assignmentId,
      'quantity': quantity,
      'reason_code': reasonCode,
      'note': note,
      'business_date': businessDate,
      'shift_id': shiftId,
      'created_by': createdBy,
      'occurred_at_utc': now,
      'device_id': DeviceInfoHelper.deviceId,
      'sync_status': 'PENDING',
      'idempotency_key': idempotencyKey,
      'created_at_utc': now,
    };
    await db.insertRecallRecord(recallRow);

    // If total recall + completed == assigned, update status
    if ((maxRecall - quantity) <= 0.0001) {
      await db.updateAssignmentStatus(assignmentId, 'RECALLED', 'PENDING');
    }

    final queueItem = {
      'id': IdGenerator.newId(),
      'entity_type': 'RECALL',
      'entity_id': id,
      'action': 'CREATE',
      'priority': 1,
      'retry_count': 0,
      'created_at_utc': now,
      'updated_at_utc': now,
    };
    await db.insertSyncQueueItem(queueItem);

    await db.insertAuditLog({
      'id': IdGenerator.newId(),
      'event_type': 'RECALL_ASSIGNMENT',
      'actor_id': createdBy,
      'target_employee_id': assignment['nhan_vien_id'],
      'entity_type': 'ThuHoiPhanCong',
      'entity_id': id,
      'business_date': businessDate,
      'shift_id': shiftId,
      'occurred_at_utc': now,
      'device_id': DeviceInfoHelper.deviceId,
    });

    // See AssignmentRepositoryImpl.createAssignment for what this does
    // without a password.
    await pushAndRecord(
      database: db,
      gateway: gateway,
      backoff: SyncBackoff(),
      queueItem: queueItem,
      source: recallRow,
      workerPassword: workerPassword,
    );

    return id;
  }

  @override
  Future<double> getRecalledQuantity(String assignmentId) =>
      db.getRecalledQuantity(assignmentId);
}

// ─── Work History Repository ─────────────────────────────────────────
class WorkHistoryRepositoryImpl implements WorkHistoryRepository {
  final SapPpOpAllocGateway gateway;

  WorkHistoryRepositoryImpl(this.gateway);

  @override
  Future<WorkHistoryResult> getWorkHistory({required HistoryRange range}) =>
      gateway.getWorkHistory(range: range);
}
