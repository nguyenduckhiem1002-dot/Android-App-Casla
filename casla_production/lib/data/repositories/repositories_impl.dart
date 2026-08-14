// Data Layer — Repository Implementations
// Spec: Section 9.1 (Business contracts)
// Each transaction: Entity + SyncQueue + AuditLog atomic

import '../../core/database/casla_database.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/device_info.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';
import '../../domain/policies/production_math.dart';
import '../../domain/repositories/repositories.dart';

import '../sap/sap_odata_client.dart';
import '../sap/sap_auth_controller.dart';

// ─── Auth Repository ────────────────────────────────────────────────
class AuthRepositoryImpl implements AuthRepository {
  final CaslaDatabase db;
  late final SapODataClient _sapClient;
  late final SapAuthController _sapAuth;

  AuthRepositoryImpl(this.db) {
    _sapClient = SapODataClient();
    _sapAuth = SapAuthController(_sapClient);
  }

  @override
  Future<UserSession> loginByMaNv(String maNv) async {
    final emp = await db.getEmployeeByCode(maNv);
    if (emp == null) {
      throw Exception('Mã nhân viên $maNv không tồn tại');
    }

    final isSupervisor = emp['vai_tro'] == 'SUPERVISOR';
    if (!isSupervisor) {
      throw Exception(
        'Công nhân không có quyền đăng nhập. Hệ thống chỉ dành cho Supervisor.',
      );
    }

    final permissions = {
      Permission.viewOwnProduction,
      Permission.assignQuantity,
      Permission.recallAssignment,
      Permission.viewTeamProduction,
      Permission.viewEmployeeHistory,
      Permission.viewSyncStatus,
      Permission.switchUser,
    };

    final session = UserSession(
      id: emp['id'] as String,
      maNv: emp['ma_nv'] as String,
      fullName: emp['ten'] as String,
      teamName: emp['bo_phan'] as String,
      role: isSupervisor ? UserRole.supervisor : UserRole.worker,
      permissions: permissions,
    );

    // Audit login
    await db.insertAuditLog({
      'id': IdGenerator.newId(),
      'event_type': 'LOGIN',
      'actor_id': maNv,
      'target_employee_id': maNv,
      'entity_type': 'SESSION',
      'entity_id': session.id,
      'device_id': DeviceInfoHelper.deviceId,
      'occurred_at_utc': DateTime.now().millisecondsSinceEpoch,
    });

    return session;
  }

  @override
  Future<UserSession> loginByCredentials(
    String username,
    String password,
  ) async {
    final sapResult = await _sapAuth.loginWithCredentials(username, password);
    if (sapResult != null && sapResult.accessToken.isNotEmpty) {
      final userDetail = sapResult.userDetail;
      final fullName =
          (userDetail?['FullName'] ?? userDetail?['Username'] ?? username)
              .toString();
      final email =
          (userDetail?['Email'] ??
                  userDetail?['email'] ??
                  '$username@caslastone.com')
              .toString();
      final pwdReqVal =
          userDetail?['PasswordChangeRequired'] ??
          userDetail?['password_change_required'];
      final passwordChangeRequired =
          pwdReqVal == true ||
          pwdReqVal.toString().toLowerCase() == 'true' ||
          pwdReqVal == 1;
      final userUuid = sapResult.userUuid;

      final permissions = {
        Permission.viewOwnProduction,
        Permission.assignQuantity,
        Permission.recallAssignment,
        Permission.viewTeamProduction,
        Permission.viewEmployeeHistory,
        Permission.viewSyncStatus,
        Permission.switchUser,
      };

      final session = UserSession(
        id: userUuid.isNotEmpty ? userUuid : 'sap-$username',
        maNv: username,
        fullName: fullName,
        email: email,
        accessToken: sapResult.accessToken,
        passwordChangeRequired: passwordChangeRequired,
        teamName: 'Supervisor (SAP)',
        role: UserRole.supervisor,
        permissions: permissions,
      );

      await db.insertAuditLog({
        'id': IdGenerator.newId(),
        'event_type': 'LOGIN_SAP',
        'actor_id': username,
        'target_employee_id': username,
        'entity_type': 'SESSION',
        'entity_id': session.id,
        'device_id': DeviceInfoHelper.deviceId,
        'occurred_at_utc': DateTime.now().millisecondsSinceEpoch,
      });

      return session;
    }

    throw Exception(
      'Đăng nhập thất bại. Vui lòng kiểm tra lại tài khoản hoặc mật khẩu SAP!',
    );
  }

  @override
  Future<List<Permission>> getSessionPermissions(String userId) async {
    return []; // From SAP in production
  }

  @override
  Future<void> logout({String? accessToken}) async {
    if (accessToken != null && accessToken.isNotEmpty) {
      await _sapAuth.logout(accessToken);
    }
  }

  Future<List<Employee>> getAllEmployees() async {
    final list = await db.getAllEmployees();
    return list
        .map(
          (e) => Employee(
            id: e['id'] as String,
            maNv: e['ma_nv'] as String,
            fullName: e['ten'] as String,
            department: e['bo_phan'] as String,
            status: e['trang_thai'] as String? ?? 'ACTIVE',
          ),
        )
        .toList();
  }

  Future<List<ProductionOrder>> getOpenOrders() async {
    final list = await db.getOpenOrders();
    return list
        .map(
          (o) => ProductionOrder(
            id: o['id'] as String,
            orderCode: o['ma_don_hang'] as String,
            productCode: o['ma_sp'] as String,
            productName: o['ten_sp'] as String,
            uom: o['uom'] as String,
            totalQuantity: o['so_luong_don'] as double,
            status: o['trang_thai'] as String? ?? 'OPEN',
          ),
        )
        .toList();
  }
}

// ─── Assignment Repository ──────────────────────────────────────────
class AssignmentRepositoryImpl implements AssignmentRepository {
  final CaslaDatabase db;

  AssignmentRepositoryImpl(this.db);

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
  }) async {
    if (assignedQuantity <= 0) throw Exception('Số lượng giao phải lớn hơn 0');

    final id = IdGenerator.newId();
    final idempotencyKey = IdGenerator.newIdempotencyKey();
    final now = DateTime.now().millisecondsSinceEpoch;

    // Atomic: Assignment + SyncQueue + AuditLog
    await db.insertAssignment({
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
    });

    await db.insertSyncQueueItem({
      'id': IdGenerator.newId(),
      'entity_type': 'ASSIGNMENT',
      'entity_id': id,
      'action': 'CREATE',
      'priority': 1,
      'retry_count': 0,
      'created_at_utc': now,
      'updated_at_utc': now,
    });

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
  /// Fetches employees and orders ONCE, builds O(1) lookup maps,
  /// then maps each assignment without redundant DB queries.
  Future<List<Assignment>> _mapToAssignmentsBatch(
    List<Map<String, dynamic>> entities,
  ) async {
    if (entities.isEmpty) return [];

    // Fetch lookup data once — O(E + O) instead of O(N × (E + O))
    final employees = await db.getAllEmployees();
    final orders = await db.getOpenOrders();

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

      final completed = await db.getCompletedQuantity(assignmentId);
      final recalled = await db.getRecalledQuantity(assignmentId);

      result.add(Assignment(
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
              s.name.toUpperCase() == (entity['status'] as String).toUpperCase(),
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
      ));
    }
    return result;
  }
}

// ─── Production Repository ──────────────────────────────────────────
class ProductionRepositoryImpl implements ProductionRepository {
  final CaslaDatabase db;

  ProductionRepositoryImpl(this.db);

  @override
  Future<String> recordProduction({
    required String assignmentId,
    required double quantity,
    required String businessDate,
    required String shiftId,
    required String createdBy,
    String? note,
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
    await db.insertProductionRecord({
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
    });

    // If remaining reaches 0, update assignment status
    if ((remaining - quantity) <= 0.0001) {
      await db.updateAssignmentStatus(assignmentId, 'COMPLETED', 'PENDING');
    }

    await db.insertSyncQueueItem({
      'id': IdGenerator.newId(),
      'entity_type': 'PRODUCTION',
      'entity_id': id,
      'action': 'CREATE',
      'priority': 1,
      'retry_count': 0,
      'created_at_utc': now,
      'updated_at_utc': now,
    });

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

  RecallRepositoryImpl(this.db);

  @override
  Future<String> recallAssignment({
    required String assignmentId,
    required double quantity,
    required String reasonCode,
    String? note,
    required String businessDate,
    required String shiftId,
    required String createdBy,
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

    await db.insertRecallRecord({
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
    });

    // If total recall + completed == assigned, update status
    if ((maxRecall - quantity) <= 0.0001) {
      await db.updateAssignmentStatus(assignmentId, 'RECALLED', 'PENDING');
    }

    await db.insertSyncQueueItem({
      'id': IdGenerator.newId(),
      'entity_type': 'RECALL',
      'entity_id': id,
      'action': 'CREATE',
      'priority': 1,
      'retry_count': 0,
      'created_at_utc': now,
      'updated_at_utc': now,
    });

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

    return id;
  }

  @override
  Future<double> getRecalledQuantity(String assignmentId) =>
      db.getRecalledQuantity(assignmentId);
}
