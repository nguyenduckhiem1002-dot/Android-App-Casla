// Data Layer — Repository Implementations
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
// Spec: Section 9.1 (Business contracts)
// Each transaction: Entity + SyncQueue + AuditLog atomic

import '../../core/config/app_config.dart';
import '../../core/database/casla_database.dart';
import '../../core/telemetry/field_telemetry.dart';
import '../../core/sync/sap_write_gateway.dart';
import '../../core/sync/sync_failure.dart';
import '../../core/sync/sync_push.dart';
import '../../core/sync/verified_sync_coordinator.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/device_info.dart';
import '../../core/utils/sap_entry_time.dart';
import 'package:flutter/foundation.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/mutation_receipt.dart';
import '../../domain/entities/work_history.dart';
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
    _sapClient = SapODataClient(baseUrl: AppConfig.sapAuthServiceUrl);
    _sapAuth = SapAuthController(_sapClient);
  }

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

    _validateAuthResult(result);

    final authorization = parseAuthorization(
      permissions: result.permissions,
      workContexts: result.workContexts,
    );

    // Priority 1: Check if LoginResult already contains profile fields (fast & immune to DCL).
    // Priority 2: Fallback to getUserDetail (if backend hasn't enriched LoginResult yet).
    String fullName = result.fullName;
    String email = result.email;
    String maNv = result.workerId.isNotEmpty ? result.workerId : username;

    if (fullName.isEmpty || email.isEmpty) {
      final detail = await _sapAuth.getUserDetail(result.userUuid);
      if (fullName.isEmpty) {
        fullName = (detail?['FullName'] ?? username).toString();
      }
      if (email.isEmpty) {
        email = (detail?['Email'] ?? '').toString();
      }
      if (maNv == username &&
          detail?['WorkerID'] != null &&
          detail!['WorkerID'].toString().isNotEmpty) {
        maNv = detail['WorkerID'].toString();
      }
    }

    final session = UserSession(
      id: result.userUuid,
      maNv: maNv,
      fullName: fullName.isNotEmpty ? fullName : username,
      email: email,
      teamName: authorization.workContexts.isNotEmpty
          ? authorization.workContexts.first.workName
          : '',
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
      passwordChangeRequired: result.passwordChangeRequired,
      role: authorization.role,
      permissions: authorization.permissions,
      toIds: authorization.workContexts.map((w) => w.workId).toList(),
      workContexts: _toUserWorkContexts(authorization.workContexts),
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

  /// Refreshes the active account while re-reading SAP's effective grants.
  ///
  /// A refresh result is not merely a new access token: permissions and work
  /// contexts may have been changed on SAP since login. Returning a fully
  /// rebuilt [UserSession] lets [SessionCoordinator] fail closed when the
  /// identity or the refreshed scope no longer matches the signed-in user.
  Future<UserSession?> refreshSession(UserSession current) async {
    if (current.refreshToken.trim().isEmpty) return null;

    final result = await _sapAuth.refresh(
      refreshToken: current.refreshToken,
      deviceId: await DeviceInfoHelper.getDeviceId(),
    );
    if (!result.isSuccess) return null;
    _validateAuthResult(result);

    // Never accept a token response for another account, even if a faulty or
    // compromised upstream returned an otherwise well-formed payload.
    if (result.userUuid != current.id) return null;

    final authorization = parseAuthorization(
      permissions: result.permissions,
      workContexts: result.workContexts,
    );
    final workerId = result.workerId.trim().isNotEmpty
        ? result.workerId.trim()
        : current.maNv;

    return UserSession(
      id: result.userUuid,
      maNv: workerId,
      fullName: result.fullName.trim().isNotEmpty
          ? result.fullName.trim()
          : current.fullName,
      email: result.email.trim().isNotEmpty
          ? result.email.trim()
          : current.email,
      teamName: authorization.workContexts.isNotEmpty
          ? authorization.workContexts.first.workName
          : current.teamName,
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
      passwordChangeRequired: result.passwordChangeRequired,
      role: authorization.role,
      permissions: authorization.permissions,
      toIds: authorization.workContexts.map((work) => work.workId).toList(),
      workContexts: _toUserWorkContexts(authorization.workContexts),
    );
  }

  static List<UserWorkContext> _toUserWorkContexts(
    List<SapWorkContext> workContexts,
  ) => workContexts
      .map(
        (work) => UserWorkContext(
          workId: work.workId,
          workName: work.workName,
          plant: work.plant,
          plantName: work.plantName,
          workCenter: work.workCenter,
          workCenterName: work.workCenterName,
          boPhan: work.boPhan,
          location: work.location,
        ),
      )
      .toList(growable: false);

  static void _validateAuthResult(SapLoginResult result) {
    if (result.userUuid.trim().isEmpty ||
        result.accessToken.trim().isEmpty ||
        result.refreshToken.trim().isEmpty) {
      throw Exception('SAP trả về phiên đăng nhập không hợp lệ.');
    }
  }

  /// Clears the shared auth client's transient SAP state. This is deliberately
  /// separate from remote logout, which uses its own client below so a slow
  /// revoke cannot restore cookies into a newer login attempt.
  void resetTransportSession() {
    _sapClient.setAuthToken(null);
    _sapClient.resetCsrfSession();
  }

  @override
  Future<void> logout({String? accessToken}) async {
    if (accessToken == null || accessToken.isEmpty) return;

    // AppState clears the shared login client before starting this best-effort
    // revoke. Keep the revoke completely isolated: resetting the shared
    // client here after a new login has started would invalidate that login's
    // in-flight CSRF fetch and make the next POST fail without a token.
    final logoutClient = SapODataClient(baseUrl: AppConfig.sapAuthServiceUrl);
    try {
      await SapAuthController(logoutClient).logout(
        accessToken: accessToken,
        deviceId: await DeviceInfoHelper.getDeviceId(),
      );
    } finally {
      logoutClient.dio.close(force: true);
    }
  }

  /// The FuncIDs SAP actually issues for this app.
  ///
  /// SAP sends no explicit Role claim (`ZA_MOB_LoginResult` has no `Role`
  /// field), so the app derives one from the FuncID set login/refresh return.
  /// The vocabulary is short because the backend only gates one thing on a
  /// FuncID: `zbp_r_pp_opalloc`'s `initialAssign` calls `validate_token` with
  /// `required_func = 'PP_INITIAL_ASSIGN'`. `transfer`, `recall` and `confirm`
  /// pass no `required_func` at all — they are gated by `has_work_scope` plus
  /// `verify_worker_password` instead. `PP_HIST_SELF`/`PP_HIST_TEAM` are read
  /// scopes checked in `zcl_pp_work_history`.
  ///
  /// Holding `PP_INITIAL_ASSIGN` is therefore the only signal SAP gives that
  /// an account is a supervisor.
  static const _funcInitialAssign = 'PP_INITIAL_ASSIGN';
  static const _funcHistSelf = 'PP_HIST_SELF';
  static const _funcHistTeam = 'PP_HIST_TEAM';
  static const _funcPositionManage = 'PP_POS_MANAGE';

  /// Granted to every supervisor session.
  ///
  /// These have no SAP counterpart — they are app-local screen gates from the
  /// old spec (see [Permission]). The backend re-checks work scope and the
  /// worker password on every write regardless, so gating them client-side is
  /// navigation ergonomics, not security.
  static const _supervisorPermissions = {
    Permission.assignQuantity,
    Permission.recallAssignment,
    Permission.viewTeamProduction,
    Permission.viewEmployeeHistory,
    Permission.viewSyncStatus,
    Permission.switchUser,
  };

  /// Converts the permissions/work-contexts SAP returned into the app
  /// session's role/permission/scope claims.
  ///
  /// The app serves two roles:
  /// - `PP_INITIAL_ASSIGN` → [UserRole.supervisor], which also needs at least
  ///   one Work Context (Plant/WorkCenter): the supervisor screens scope by
  ///   team, and `has_work_scope` rejects every write outside it anyway;
  /// - a history scope alone (`PP_HIST_SELF` and/or `PP_HIST_TEAM`, see
  ///   `zcl_pp_work_history`) with no Work Context required →
  ///   [UserRole.worker], who only reaches the read-only history screen.
  ///   `getWorkHistory` resolves the worker's own id server-side from the
  ///   authenticated account, so no local Work Context is needed.
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
    final historyPermissions = <Permission>{
      if (funcIds.contains(_funcHistSelf)) Permission.viewOwnProductionHistory,
      if (funcIds.contains(_funcHistTeam)) Permission.viewTeamProductionHistory,
    };

    if (funcIds.contains(_funcInitialAssign)) {
      if (workContexts.isEmpty) {
        throw Exception('Tài khoản chưa được phân phạm vi tổ sản xuất.');
      }
      return (
        role: UserRole.supervisor,
        permissions: {
          ...historyPermissions,
          ..._supervisorPermissions,
          // Only a supervisor gets the Vị trí tab; SAP re-checks the function
          // and its Work Center scope on every position call.
          if (funcIds.contains(_funcPositionManage)) Permission.managePositions,
        },
        workContexts: workContexts,
      );
    }

    if (historyPermissions.isNotEmpty) {
      return (
        role: UserRole.worker,
        permissions: historyPermissions,
        workContexts: workContexts,
      );
    }

    throw Exception('Tài khoản chưa được cấp quyền sử dụng ứng dụng.');
  }
}

// ─── Assignment Repository ──────────────────────────────────────────
String? _blankToNull(String? value) {
  final trimmed = value?.trim().toUpperCase() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

class AssignmentRepositoryImpl implements AssignmentRepository {
  final CaslaDatabase db;
  final SapWriteGateway gateway;

  AssignmentRepositoryImpl(this.db, {required this.gateway});

  @override
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
    String? positionId,
    String? machineId,
  }) async {
    // Round to SAP's scale once, here, so the row we store locally and the
    // payload the gateway formats can never disagree. `quan(15,3)` is what
    // ztb_pp_alloc_txn holds; a 4th decimal is silently lost in transit.
    final scaledQuantity = ProductionMath.toSapScale(assignedQuantity);
    if (!assignedQuantity.isFinite || scaledQuantity <= 0) {
      throw Exception('Số lượng giao phải là một số dương hợp lệ');
    }

    final id = IdGenerator.newId();
    final idempotencyKey = IdGenerator.newIdempotencyKey();
    final now = DateTime.now().millisecondsSinceEpoch;
    final enteredAt = SapEntryTime.fromEpochMillis(now);

    // Freeze the unit now. `orders.uom` is rewritten by the next operation QR
    // scan, and this transaction may not reach SAP until long after that.
    final order = await db.getOrderById(orderId);
    final unitOfMeasure = (order?['uom'] ?? '').toString();

    // Atomic: Assignment + SyncQueue + AuditLog
    final assignmentRow = {
      'id': id,
      'nhan_vien_id': workerId,
      'don_hang_id': orderId,
      'to_id': teamId,
      'assigned_quantity': scaledQuantity,
      'unit_of_measure': unitOfMeasure,
      'business_date': businessDate,
      'shift_id': shiftId,
      'status': 'OPEN',
      'note': note,
      'position_id': _blankToNull(positionId),
      'machine_id': _blankToNull(machineId),
      'created_by': createdBy,
      'occurred_at_utc': now,
      'entry_date': enteredAt.date,
      'entry_time': enteredAt.time,
      'device_id': DeviceInfoHelper.deviceId,
      'sync_status': 'PENDING',
      'idempotency_key': idempotencyKey,
      'created_at_utc': now,
    };
    final queueItem = {
      'id': IdGenerator.newId(),
      'entity_type': 'ASSIGNMENT',
      'entity_id': id,
      'action': 'CREATE',
      'payload_summary':
          'Phân công · +${ProductionMath.formatQuantity(scaledQuantity)}',
      'idempotency_key': idempotencyKey,
      'device_id': DeviceInfoHelper.deviceId,
      'priority': 1,
      'retry_count': 0,
      'created_at_utc': now,
      'updated_at_utc': now,
    };
    final auditLog = {
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
    };

    await db.createAssignmentAtomically(
      assignment: assignmentRow,
      queueItem: queueItem,
      auditLog: auditLog,
    );

    // Spec 4.7: "Có mạng/API tốt → gửi ngay". Every mutation on this backend
    // needs the worker's own password; without one this call still isn't a
    // no-op — it immediately marks the item NEEDS_VERIFICATION rather than
    // leaving it looking like ordinary PENDING work the background engine
    // will get to on its own (it never can, for this backend — see
    // `SyncPushRequest.workerPassword`).
    final failure = await pushAndRecord(
      database: db,
      gateway: gateway,
      backoff: SyncBackoff(),
      queueItem: queueItem,
      source: assignmentRow,
      workerPassword: workerPassword,
    );

    return _liveMutationReceipt(db, id, queueItem, failure);
  }

  @override
  Stream<List<Assignment>> watchWorkerAssignments(
    String workerId, {
    String? fromBusinessDate,
    String? toBusinessDate,
    String? shiftId,
  }) {
    return db.watchAssignmentsByWorker(workerId).asyncMap((entities) async {
      return _mapToAssignmentsBatch(
        entities,
        fromBusinessDate: fromBusinessDate,
        toBusinessDate: toBusinessDate,
        shiftId: shiftId,
      );
    });
  }

  @override
  Stream<List<Assignment>> watchAssignmentsByTeams(
    List<String> teamIds, {
    String? fromBusinessDate,
    String? toBusinessDate,
    String? shiftId,
  }) {
    final normalized = teamIds
        .map((teamId) => teamId.trim())
        .where((teamId) => teamId.isNotEmpty)
        .toSet()
        .toList(growable: false);
    return db.watchAssignmentsByTeams(normalized).asyncMap((entities) async {
      return _mapToAssignmentsBatch(
        entities,
        fromBusinessDate: fromBusinessDate,
        toBusinessDate: toBusinessDate,
        shiftId: shiftId,
      );
    });
  }

  @override
  Stream<Assignment?> watchAssignment(String id) {
    return db.watchAssignmentById(id).asyncMap((entity) async {
      if (entity == null) return null;
      final results = await _mapToAssignmentsBatch([entity]);
      return results.isEmpty ? null : results.first;
    });
  }

  @override
  Future<Assignment?> getAssignmentById(String id) async {
    final entity = await db.getAssignmentById(id);
    if (entity == null) return null;
    final results = await _mapToAssignmentsBatch([entity]);
    return results.isNotEmpty ? results.first : null;
  }

  /// Maps only the selected assignments from one consistent display snapshot.
  Future<List<Assignment>> _mapToAssignmentsBatch(
    List<Map<String, dynamic>> entities, {
    String? fromBusinessDate,
    String? toBusinessDate,
    String? shiftId,
  }) async {
    if (entities.isEmpty) return [];

    final snapshots = await db.getAssignmentDisplayRows(
      entities.map((entity) => entity['id'] as String),
      fromBusinessDate: fromBusinessDate,
      toBusinessDate: toBusinessDate,
      shiftId: shiftId,
    );

    final result = <Assignment>[];
    for (final entity in snapshots) {
      final empId = entity['nhan_vien_id'] as String;
      final orderId = entity['don_hang_id'] as String;
      final assignmentId = entity['id'] as String;

      final completed = (entity['completed_quantity'] as num).toDouble();
      final defect = (entity['defect_quantity'] as num).toDouble();
      final recalled = (entity['recalled_quantity'] as num).toDouble();

      result.add(
        Assignment(
          id: assignmentId,
          workerId: empId,
          workerMaNv: entity['worker_code'] as String? ?? empId,
          workerName: entity['worker_name'] as String? ?? 'Công nhân',
          teamId: entity['to_id'] as String,
          orderId: orderId,
          orderCode: entity['order_code'] as String? ?? orderId,
          productionOrder:
              entity['order_production_order'] as String? ??
              entity['order_code'] as String? ??
              '',
          operation: entity['order_operation'] as String? ?? '',
          operationName: entity['order_operation_name'] as String? ?? '',
          productCode: entity['product_code'] as String? ?? 'SP',
          productName: entity['product_name'] as String? ?? 'Sản phẩm',
          plant: entity['order_plant'] as String? ?? '',
          workCenter: entity['order_work_center'] as String? ?? '',
          uom: entity['display_uom'] as String? ?? 'cái',
          assignedQuantity: entity['assigned_quantity'] as double,
          completedQuantity: completed,
          defectQuantity: defect,
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
          sapId: entity['sap_id']?.toString() ?? '',
          syncStatus: SyncStatus.fromStorage(entity['sync_status']),
          createdAtUtc: (entity['created_at_utc'] as num?)?.toInt() ?? 0,
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
  final VerifiedSyncCoordinator verifiedSync;

  ProductionRepositoryImpl(
    this.db, {
    required this.gateway,
    required this.verifiedSync,
  });

  @override
  Future<MutationReceipt> recordProduction({
    required String assignmentId,
    required double quantity,
    double defectQuantity = 0,
    required String businessDate,
    required String shiftId,
    required String createdBy,
    String? note,
    String? workerPassword,
    double? expectedRemaining,
  }) async {
    final assignment = await db.getAssignmentById(assignmentId);
    if (assignment == null) throw Exception('Phân công không tồn tại');

    final statusStr = assignment['status'] as String;
    if (statusStr.toUpperCase() != 'OPEN') {
      throw Exception('Phân công đã đóng hoặc bị thu hồi');
    }

    final completed = await db.getCompletedQuantity(assignmentId);
    final defect = await db.getDefectQuantity(assignmentId);
    final recalled = await db.getRecalledQuantity(assignmentId);
    final assignedQty = assignment['assigned_quantity'] as double;
    final effective = ProductionMath.calculateEffectiveAssigned(
      assignedQty,
      recalled,
    );
    final remaining = ProductionMath.calculateRemaining(
      effective,
      completed + defect,
    );

    if (expectedRemaining != null &&
        ProductionMath.toSapScale(expectedRemaining) !=
            ProductionMath.toSapScale(remaining)) {
      throw Exception(
        'Số lượng còn lại đã thay đổi. Vui lòng mở lại và kiểm tra số liệu.',
      );
    }

    // Round good and defective quantities at the same point so the local row
    // and SAP request carry identical values.
    final scaledQuantity = ProductionMath.toSapScale(quantity);
    final scaledDefectQuantity = ProductionMath.toSapScale(defectQuantity);
    if (!quantity.isFinite ||
        !defectQuantity.isFinite ||
        scaledQuantity < 0 ||
        scaledDefectQuantity < 0 ||
        scaledQuantity + scaledDefectQuantity <= 0) {
      throw Exception('Số hoàn thành và số phế không hợp lệ.');
    }

    final id = IdGenerator.newId();
    final idempotencyKey = IdGenerator.newIdempotencyKey();
    final now = DateTime.now().millisecondsSinceEpoch;
    final enteredAt = SapEntryTime.fromEpochMillis(now);

    // Atomic: ProductionRecord + SyncQueue + AuditLog
    final recordRow = {
      'id': id,
      'phan_cong_id': assignmentId,
      'quantity': scaledQuantity,
      'defect_quantity': scaledDefectQuantity,
      'unit_of_measure': assignment['unit_of_measure'],
      'business_date': businessDate,
      'shift_id': shiftId,
      'note': note,
      'created_by': createdBy,
      'occurred_at_utc': now,
      'entry_date': enteredAt.date,
      'entry_time': enteredAt.time,
      'device_id': DeviceInfoHelper.deviceId,
      'sync_status': 'PENDING',
      'idempotency_key': idempotencyKey,
      'created_at_utc': now,
    };
    final queueItem = {
      'id': IdGenerator.newId(),
      'entity_type': 'PRODUCTION',
      'entity_id': id,
      'action': 'CREATE',
      'payload_summary':
          'Xác nhận hoàn thành · '
          '+${ProductionMath.formatQuantity(scaledQuantity)}'
          '${scaledDefectQuantity > 0 ? ' · phế ${ProductionMath.formatQuantity(scaledDefectQuantity)}' : ''}',
      'idempotency_key': idempotencyKey,
      'device_id': DeviceInfoHelper.deviceId,
      'priority': 1,
      'retry_count': 0,
      'created_at_utc': now,
      'updated_at_utc': now,
    };
    final auditLog = {
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
    };

    await db.recordProductionAtomically(
      record: recordRow,
      queueItem: queueItem,
      auditLog: auditLog,
      expectedRemaining: expectedRemaining,
    );

    if (workerPassword?.isNotEmpty == true) {
      // This may also push an unsynced parent assignment first. Sending the
      // child directly would omit OriginalTransactionUUID and break lineage.
      final report = await verifiedSync.syncVerifiedWorkerChain(
        anchorQueueItemId: queueItem['id'] as String,
        workerPassword: workerPassword!,
      );
      return _verifiedMutationReceipt(db, id, queueItem, report);
    }

    final failure = await pushAndRecord(
      database: db,
      gateway: gateway,
      backoff: SyncBackoff(),
      queueItem: queueItem,
      source: recordRow,
      workerPassword: workerPassword,
    );

    return _liveMutationReceipt(db, id, queueItem, failure);
  }

  @override
  Future<double> getCompletedQuantity(String assignmentId) =>
      db.getCompletedQuantity(assignmentId);
}

// ─── Recall Repository ──────────────────────────────────────────────
class RecallRepositoryImpl implements RecallRepository {
  final CaslaDatabase db;
  final SapWriteGateway gateway;
  final VerifiedSyncCoordinator verifiedSync;

  RecallRepositoryImpl(
    this.db, {
    required this.gateway,
    required this.verifiedSync,
  });

  @override
  Future<MutationReceipt> recallAssignment({
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

    final completed =
        await db.getCompletedQuantity(assignmentId) +
        await db.getDefectQuantity(assignmentId);
    final recalled = await db.getRecalledQuantity(assignmentId);
    final assignedQty = assignment['assigned_quantity'] as double;
    final maxRecall = ProductionMath.calculateMaxRecall(
      assignedQty,
      completed,
      recalled,
    );

    final scaledQuantity = ProductionMath.toSapScale(quantity);
    final validationErr = ProductionMath.validateRecallEntry(
      scaledQuantity,
      maxRecall,
      reasonCode,
      note,
    );
    if (validationErr != null) throw Exception(validationErr);

    final id = IdGenerator.newId();
    final idempotencyKey = IdGenerator.newIdempotencyKey();
    final now = DateTime.now().millisecondsSinceEpoch;
    final enteredAt = SapEntryTime.fromEpochMillis(now);

    final recallRow = {
      'id': id,
      'phan_cong_id': assignmentId,
      'quantity': scaledQuantity,
      'unit_of_measure': assignment['unit_of_measure'],
      'reason_code': reasonCode,
      'note': note,
      'business_date': businessDate,
      'shift_id': shiftId,
      'created_by': createdBy,
      'occurred_at_utc': now,
      'entry_date': enteredAt.date,
      'entry_time': enteredAt.time,
      'device_id': DeviceInfoHelper.deviceId,
      'sync_status': 'PENDING',
      'idempotency_key': idempotencyKey,
      'created_at_utc': now,
    };
    final queueItem = {
      'id': IdGenerator.newId(),
      'entity_type': 'RECALL',
      'entity_id': id,
      'action': 'CREATE',
      'payload_summary':
          'Thu hồi phân công · -${ProductionMath.formatQuantity(scaledQuantity)}',
      'idempotency_key': idempotencyKey,
      'device_id': DeviceInfoHelper.deviceId,
      'priority': 1,
      'retry_count': 0,
      'created_at_utc': now,
      'updated_at_utc': now,
    };
    final auditLog = {
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
    };

    await db.recallAssignmentAtomically(
      record: recallRow,
      queueItem: queueItem,
      auditLog: auditLog,
    );

    if (workerPassword?.isNotEmpty == true) {
      final report = await verifiedSync.syncVerifiedWorkerChain(
        anchorQueueItemId: queueItem['id'] as String,
        workerPassword: workerPassword!,
      );
      return _verifiedMutationReceipt(db, id, queueItem, report);
    }

    final failure = await pushAndRecord(
      database: db,
      gateway: gateway,
      backoff: SyncBackoff(),
      queueItem: queueItem,
      source: recallRow,
      workerPassword: workerPassword,
    );

    return _liveMutationReceipt(db, id, queueItem, failure);
  }

  @override
  Future<double> getRecalledQuantity(String assignmentId) =>
      db.getRecalledQuantity(assignmentId);
}

// ─── Work History Repository ─────────────────────────────────────────

typedef WorkHistoryLoader =
    Future<WorkHistoryResult> Function({
      required HistoryRange range,
      DateTime? dateFrom,
      DateTime? dateTo,
      String? shiftId,
      String? productionOrder,
      String? operation,
    });

typedef WorkHistoryLoaderWithWorkId =
    Future<WorkHistoryResult> Function({
      required HistoryRange range,
      DateTime? dateFrom,
      DateTime? dateTo,
      String? shiftId,
      String? workId,
      String? productionOrder,
      String? operation,
    });

class WorkHistorySessionChangedException implements Exception {
  const WorkHistorySessionChangedException();

  @override
  String toString() => 'WorkHistorySessionChangedException';
}

class WorkHistoryRepositoryImpl implements WorkHistoryRepository {
  final CaslaDatabase db;
  final WorkHistoryLoader? loadRemote;
  final String? Function() cacheSubject;
  final Duration freshFor;
  final FieldTelemetry telemetry;
  final DateTime Function() _now;
  final bool Function(String subject) _isCacheSubjectCurrent;
  final FutureOr<void> Function(String subject)? _onAuthorizationRejected;

  final Map<String, Future<WorkHistoryResult>> _inFlight = {};
  // ignore: close_sinks
  // Closed explicitly by [dispose], which AppState owns for the app lifetime.
  final _updates = StreamController<_WorkHistoryUpdate>.broadcast();
  // ignore: close_sinks
  // Closed by [dispose] together with [_updates].
  final _staleSignals = StreamController<void>.broadcast();

  /// Newer SAP bindings accept WorkID on the history action. Keep the
  /// original loader callback source-compatible for tests/embedders that
  /// still implement the pre-WorkID contract.
  final WorkHistoryLoaderWithWorkId? loadRemoteWithWorkId;

  WorkHistoryRepositoryImpl(
    this.db, {
    this.loadRemote,
    this.loadRemoteWithWorkId,
    required this.cacheSubject,
    this.freshFor = const Duration(minutes: 2),
    FieldTelemetry? telemetry,
    DateTime Function()? now,
    bool Function(String subject)? isCacheSubjectCurrent,
    FutureOr<void> Function(String subject)? onAuthorizationRejected,
  }) : telemetry = telemetry ?? FieldTelemetry.instance,
       _now = now ?? DateTime.now,
       _isCacheSubjectCurrent = isCacheSubjectCurrent ?? ((_) => true),
       _onAuthorizationRejected = onAuthorizationRejected;

  /// The SQLite namespace of a cache subject.
  ///
  /// A subject may be `<lifetime>@<namespace>`. The lifetime part rejects
  /// results and authorization failures that belong to an earlier login; the
  /// namespace (account, endpoint, authorization scope) is what is stored, so
  /// the same account keeps its offline snapshots across logins and restarts.
  static String storageNamespace(String subject) {
    final separator = subject.indexOf('@');
    return separator < 0 ? subject : subject.substring(separator + 1);
  }

  bool _sharesCurrentNamespace(String subject) {
    final current = cacheSubject()?.trim();
    return current != null &&
        current.isNotEmpty &&
        storageNamespace(current) == storageNamespace(subject);
  }

  @override
  Future<WorkHistoryResult> getWorkHistory({
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? shiftId,
    String? workId,
    String? productionOrder,
    String? operation,
    bool forceRefresh = false,
  }) async {
    final subject = cacheSubject()?.trim();
    if (subject == null || subject.isEmpty) {
      final stopwatch = Stopwatch()..start();
      try {
        final result = await _loadRemote(
          range: range,
          dateFrom: dateFrom,
          dateTo: dateTo,
          shiftId: shiftId,
          workId: workId,
          productionOrder: productionOrder,
          operation: operation,
        );
        stopwatch.stop();
        telemetry.recordDuration(
          FieldMetric.workHistoryRemoteSuccess,
          stopwatch.elapsed,
        );
        return result;
      } catch (_) {
        stopwatch.stop();
        telemetry.recordDuration(
          FieldMetric.workHistoryRemoteFailure,
          stopwatch.elapsed,
        );
        rethrow;
      }
    }

    _ensureSubjectCurrent(subject);

    final cacheKey = _cacheKey(
      subject: subject,
      range: range,
      dateFrom: dateFrom,
      dateTo: dateTo,
      shiftId: shiftId,
      workId: workId,
      productionOrder: productionOrder,
      operation: operation,
    );
    // A forced refresh must join the in-flight map before any SQLite await.
    // Otherwise an already-running SWR refresh can finish while this request
    // is reading cache, disappear from _inFlight, and cause a duplicate SAP call.
    if (forceRefresh) {
      return _refresh(
        cacheKey: cacheKey,
        subject: subject,
        range: range,
        dateFrom: dateFrom,
        dateTo: dateTo,
        shiftId: shiftId,
        workId: workId,
        productionOrder: productionOrder,
        operation: operation,
      );
    }

    final cached = await _readCache(cacheKey);
    _ensureSubjectCurrent(subject);
    if (cached != null) {
      // Cache snapshots written before the local order metadata was learned
      // can have blank descriptive fields. Apply the same exact
      // ProductionOrder + Operation fallback used for live SAP responses so
      // an otherwise fresh snapshot does not permanently render placeholders.
      var cachedResult = await _enrichHistoryWithOrderCache(cached.result);
      cachedResult = await _enrichHistoryWithPriorCache(cachedResult, subject);
      _ensureSubjectCurrent(subject);
      final age = _now().difference(cached.fetchedAt);
      if (age >= freshFor) {
        telemetry.increment(FieldMetric.workHistoryStaleHit);
        unawaited(
          _ignoreRefreshFailure(
            _refresh(
              cacheKey: cacheKey,
              subject: subject,
              range: range,
              dateFrom: dateFrom,
              dateTo: dateTo,
              shiftId: shiftId,
              workId: workId,
              productionOrder: productionOrder,
              operation: operation,
            ),
          ),
        );
      } else {
        telemetry.increment(FieldMetric.workHistoryCacheHit);
      }
      return cachedResult;
    }

    telemetry.increment(FieldMetric.workHistoryCacheMiss);
    return _refresh(
      cacheKey: cacheKey,
      subject: subject,
      range: range,
      dateFrom: dateFrom,
      dateTo: dateTo,
      shiftId: shiftId,
      workId: workId,
      productionOrder: productionOrder,
      operation: operation,
    );
  }

  @override
  Stream<WorkHistoryResult> watchWorkHistory({
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? shiftId,
    String? workId,
    String? productionOrder,
    String? operation,
  }) {
    final subject = cacheSubject()?.trim();
    if (subject == null || subject.isEmpty) {
      // Detail screens can be rebuilt while a route transition or hot reload
      // is still tearing down the previous StreamBuilder subscription. Keep
      // this watcher multi-subscription safe so a second listener does not
      // turn a recoverable refresh into a generic error page.
      return Stream<WorkHistoryResult>.fromFuture(
        getWorkHistory(
          range: range,
          dateFrom: dateFrom,
          dateTo: dateTo,
          shiftId: shiftId,
          workId: workId,
          productionOrder: productionOrder,
          operation: operation,
        ),
      ).asBroadcastStream();
    }
    final cacheKey = _cacheKey(
      subject: subject,
      range: range,
      dateFrom: dateFrom,
      dateTo: dateTo,
      shiftId: shiftId,
      workId: workId,
      productionOrder: productionOrder,
      operation: operation,
    );

    late final StreamController<WorkHistoryResult> controller;
    StreamSubscription<_WorkHistoryUpdate>? updatesSubscription;
    StreamSubscription<void>? staleSubscription;
    var isLoading = false;
    WorkHistoryResult? lastEmitted;
    _WorkHistoryUpdate? pendingUpdate;

    void emitIfNew(WorkHistoryResult result) {
      if (controller.isClosed || identical(lastEmitted, result)) return;
      lastEmitted = result;
      controller.add(result);
    }

    void emitUpdate(_WorkHistoryUpdate update) {
      if (controller.isClosed || !_isCacheSubjectCurrent(subject)) return;
      final result = update.result;
      if (result != null) {
        emitIfNew(result);
      } else {
        controller.addError(update.error!, update.stackTrace);
      }
    }

    Future<void> emitCurrent() async {
      if (isLoading || controller.isClosed) return;
      isLoading = true;
      try {
        final result = await getWorkHistory(
          range: range,
          dateFrom: dateFrom,
          dateTo: dateTo,
          shiftId: shiftId,
          workId: workId,
          productionOrder: productionOrder,
          operation: operation,
        );
        if (_isCacheSubjectCurrent(subject)) {
          emitIfNew(result);
        }
      } catch (error, stackTrace) {
        pendingUpdate = null;
        if (!controller.isClosed) controller.addError(error, stackTrace);
      } finally {
        isLoading = false;
        final update = pendingUpdate;
        pendingUpdate = null;
        if (update != null) emitUpdate(update);
      }
    }

    controller = StreamController<WorkHistoryResult>.broadcast(
      onListen: () {
        // Subscribe before the first get: a SWR refresh that finishes while
        // the initial cached value is emitted still reaches this stream.
        updatesSubscription = _updates.stream
            .where((update) => update.cacheKey == cacheKey)
            .listen((update) {
              // A very fast refresh may finish before the initial cache read
              // reaches the listener. Emit cache first, then its newer update.
              if (isLoading) {
                pendingUpdate = update;
              } else {
                emitUpdate(update);
              }
            });
        staleSubscription = _staleSignals.stream.listen((_) {
          if (controller.isClosed || !_isCacheSubjectCurrent(subject)) return;
          void refreshNow() => unawaited(
            _ignoreRefreshFailure(
              _refresh(
                cacheKey: cacheKey,
                subject: subject,
                range: range,
                dateFrom: dateFrom,
                dateTo: dateTo,
                shiftId: shiftId,
                workId: workId,
                productionOrder: productionOrder,
                operation: operation,
              ),
            ),
          );
          // A request already in flight may have left before SAP accepted the
          // write; joining it would store the old report as fresh again.
          final pending = _inFlight[_inFlightKey(subject, cacheKey)];
          if (pending == null) {
            refreshNow();
          } else {
            unawaited(
              pending
                  .then<void>((_) {}, onError: (Object _) {})
                  .then((_) => refreshNow()),
            );
          }
        });
        unawaited(emitCurrent());
      },
      onCancel: () async {
        await staleSubscription?.cancel();
        await updatesSubscription?.cancel();
        if (!controller.isClosed) await controller.close();
      },
    );
    return controller.stream;
  }

  /// Marks every cached window of the current subject stale after SAP
  /// accepted a write, and makes each open watcher re-read SAP.
  ///
  /// The snapshots stay readable: offline, screens keep showing them (plus the
  /// local overlay) instead of an empty state.
  Future<void> invalidateCurrentSubject() async {
    final subject = cacheSubject()?.trim();
    if (subject == null || subject.isEmpty) return;
    await db.expireWorkHistoryCacheForSubject(storageNamespace(subject));
    if (!_staleSignals.isClosed && _isCacheSubjectCurrent(subject)) {
      _staleSignals.add(null);
    }
  }

  Future<void> _ignoreRefreshFailure(Future<WorkHistoryResult> refresh) async {
    try {
      await refresh;
    } catch (_) {
      // SWR keeps the last good snapshot visible while offline. A pull-to-
      // refresh uses forceRefresh and still surfaces the live failure.
    }
  }

  Future<WorkHistoryResult> _loadRemote({
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? shiftId,
    String? workId,
    String? productionOrder,
    String? operation,
  }) {
    final loader = loadRemoteWithWorkId;
    if (loader != null) {
      return loader(
        range: range,
        dateFrom: dateFrom,
        dateTo: dateTo,
        shiftId: shiftId,
        workId: workId,
        productionOrder: productionOrder,
        operation: operation,
      );
    }
    return loadRemote!(
      range: range,
      dateFrom: dateFrom,
      dateTo: dateTo,
      shiftId: shiftId,
      productionOrder: productionOrder,
      operation: operation,
    );
  }

  Future<WorkHistoryResult> _refresh({
    required String cacheKey,
    required String subject,
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? shiftId,
    String? workId,
    String? productionOrder,
    String? operation,
  }) async {
    // Keyed by the full subject: a request from an earlier login must not be
    // joined by this one, even though both share the stored snapshot.
    final inFlightKey = _inFlightKey(subject, cacheKey);
    final existing = _inFlight[inFlightKey];
    if (existing != null) return existing;

    final future = _refreshOnce(
      cacheKey: cacheKey,
      subject: subject,
      range: range,
      dateFrom: dateFrom,
      dateTo: dateTo,
      shiftId: shiftId,
      workId: workId,
      productionOrder: productionOrder,
      operation: operation,
    );
    _inFlight[inFlightKey] = future;

    try {
      return await future;
    } catch (error, stackTrace) {
      if (!_updates.isClosed && _isCacheSubjectCurrent(subject)) {
        _updates.add(
          _WorkHistoryUpdate.failed(
            cacheKey: cacheKey,
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
      rethrow;
    } finally {
      if (identical(_inFlight[inFlightKey], future)) {
        final _ = _inFlight.remove(inFlightKey);
      }
    }
  }

  Future<WorkHistoryResult> _refreshOnce({
    required String cacheKey,
    required String subject,
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? shiftId,
    String? workId,
    String? productionOrder,
    String? operation,
  }) async {
    _ensureSubjectCurrent(subject);
    final stopwatch = Stopwatch()..start();
    late WorkHistoryResult result;
    try {
      final remoteResult = await _loadRemote(
        range: range,
        dateFrom: dateFrom,
        dateTo: dateTo,
        shiftId: shiftId,
        workId: workId,
        productionOrder: productionOrder,
        operation: operation,
      );
      result = await _enrichHistoryWithOrderCache(remoteResult);
      result = await _enrichHistoryWithPriorCache(result, subject);
      stopwatch.stop();
      telemetry.recordDuration(
        FieldMetric.workHistoryRemoteSuccess,
        stopwatch.elapsed,
      );
    } catch (error) {
      stopwatch.stop();
      telemetry.recordDuration(
        FieldMetric.workHistoryRemoteFailure,
        stopwatch.elapsed,
      );
      if (classifySyncError(error).kind == SyncFailureKind.auth) {
        await _handleAuthorizationRejected(subject);
      }
      rethrow;
    }
    _ensureSubjectCurrent(subject);
    final fetchedAt = _now();

    await db.replaceWorkHistoryCache(
      cacheKey: cacheKey,
      subjectId: storageNamespace(subject),
      rangeCode: range.code,
      requestDateFrom: _dateKeyOrNull(dateFrom),
      requestDateTo: _dateKeyOrNull(dateTo),
      scopeCode: result.scopeCode,
      resultDateFrom: _dateKey(result.dateFrom),
      resultDateTo: _dateKey(result.dateTo),
      isTruncated: result.isTruncated,
      fetchedAtUtc: fetchedAt.millisecondsSinceEpoch,
      entries: [
        for (final entry in result.entries)
          {
            'transaction_uuid': entry.transactionUuid,
            'execution_date': entry.executionDate.toIso8601String(),
            'work_date': entry.reportedWorkDate == null
                ? null
                : _dateKey(entry.reportedWorkDate!),
            'original_transaction_uuid': entry.originalTransactionUuid,
            'worker_id': entry.workerId,
            'worker_name': entry.workerName,
            'production_order': entry.productionOrder,
            'operation': entry.operation,
            'operation_name': entry.operationName,
            'product_name': entry.productName,
            'product_code': entry.productCode,
            'sales_order': entry.salesOrder,
            'sales_order_item': entry.salesOrderItem,
            'plant': entry.plant,
            'work_center': entry.workCenter,
            'work_id': entry.workId,
            'position_id': entry.positionId,
            'origin_position_id': entry.originPositionId,
            'transaction_type': entry.transactionType,
            'quantity': entry.quantity,
            'defect_quantity': entry.defectQuantity,
            'unit_of_measure': entry.unitOfMeasure,
            'transaction_status': entry.transactionStatus,
          },
      ],
      workers: [
        for (final worker in result.workers)
          {
            'worker_id': worker.workerId,
            'worker_name': worker.workerName,
            'assigned_quantity': worker.assignedQuantity,
            'completed_quantity': worker.completedQuantity,
            'defect_quantity': worker.defectQuantity,
            'remaining_quantity': worker.remainingQuantity,
            'unit_of_measure': worker.unitOfMeasure,
            'transaction_count': worker.transactionCount,
            'work_id': worker.workId,
            'work_name': worker.workName,
            'bo_phan': worker.boPhan,
            'location': worker.location,
          },
      ],
    );

    final employeeNames = <String, String>{};
    for (final worker in result.workers) {
      if (worker.workerId.isNotEmpty) {
        employeeNames[worker.workerId] = worker.workerName;
      }
    }
    for (final entry in result.entries) {
      if (entry.workerId.isNotEmpty) {
        employeeNames.putIfAbsent(entry.workerId, () => entry.workerName);
      }
    }
    await db.upsertEmployeesBatch([
      for (final worker in employeeNames.entries)
        {'worker_id': worker.key, 'worker_name': worker.value},
    ]);

    if (!_isCacheSubjectCurrent(subject)) {
      // A logout/scope change happened while SQLite was committing. Cache data
      // is disposable, so remove the old namespace rather than retain it —
      // unless the same account and scope logged in again and now owns it.
      if (!_sharesCurrentNamespace(subject)) {
        await db.clearWorkHistoryCacheForSubject(storageNamespace(subject));
      }
      throw const WorkHistorySessionChangedException();
    }
    if (!_updates.isClosed) {
      _updates.add(_WorkHistoryUpdate(cacheKey: cacheKey, result: result));
    }

    return result;
  }

  Future<WorkHistoryResult> _enrichHistoryWithOrderCache(
    WorkHistoryResult result,
  ) async {
    final metadata = await db.getOrderMetadataBySapKeys(
      result.entries.map((entry) => (entry.productionOrder, entry.operation)),
    );
    if (metadata.isEmpty) return result;

    final entries = result.entries
        .map((entry) {
          final order =
              metadata['${entry.productionOrder}\u0000${entry.operation}'];
          if (order == null ||
              (entry.operationName.isNotEmpty &&
                  entry.productName.isNotEmpty &&
                  entry.productCode.isNotEmpty &&
                  entry.salesOrder.isNotEmpty &&
                  entry.salesOrderItem.isNotEmpty)) {
            return entry;
          }
          return WorkHistoryEntry(
            transactionUuid: entry.transactionUuid,
            executionDate: entry.executionDate,
            reportedWorkDate: entry.reportedWorkDate,
            workerId: entry.workerId,
            workerName: entry.workerName,
            productionOrder: entry.productionOrder,
            operation: entry.operation,
            operationName: entry.operationName.isNotEmpty
                ? entry.operationName
                : order['operation_name']?.toString() ?? '',
            productName: entry.productName.isNotEmpty
                ? entry.productName
                : order['ten_sp']?.toString() ?? '',
            productCode: entry.productCode.isNotEmpty
                ? entry.productCode
                : order['ma_sp']?.toString() ?? '',
            salesOrder: entry.salesOrder.isNotEmpty
                ? entry.salesOrder
                : order['sales_order']?.toString() ?? '',
            salesOrderItem: entry.salesOrderItem.isNotEmpty
                ? entry.salesOrderItem
                : order['sales_order_item']?.toString() ?? '',
            plant: entry.plant,
            workCenter: entry.workCenter,
            workId: entry.workId,
            positionId: entry.positionId,
            originPositionId: entry.originPositionId,
            transactionType: entry.transactionType,
            quantity: entry.quantity,
            defectQuantity: entry.defectQuantity,
            unitOfMeasure: entry.unitOfMeasure,
            transactionStatus: entry.transactionStatus,
            originalTransactionUuid: entry.originalTransactionUuid,
          );
        })
        .toList(growable: false);
    return WorkHistoryResult(
      scopeCode: result.scopeCode,
      dateFrom: result.dateFrom,
      dateTo: result.dateTo,
      isTruncated: result.isTruncated,
      entries: entries,
      workers: result.workers,
    );
  }

  Future<WorkHistoryResult> _enrichHistoryWithPriorCache(
    WorkHistoryResult result,
    String subject,
  ) async {
    final metadata = await db.getHistoryMetadataBySapKeysForSubject(
      storageNamespace(subject),
      result.entries.map(
        (entry) => (entry.productionOrder, entry.operation, entry.plant),
      ),
    );
    if (metadata.isEmpty) return result;
    final entries = result.entries
        .map((entry) {
          final cached =
              metadata['${entry.productionOrder}\u0000${entry.operation}\u0000${entry.plant}'];
          if (cached == null) return entry;
          return WorkHistoryEntry(
            transactionUuid: entry.transactionUuid,
            executionDate: entry.executionDate,
            reportedWorkDate: entry.reportedWorkDate,
            workerId: entry.workerId,
            workerName: entry.workerName,
            productionOrder: entry.productionOrder,
            operation: entry.operation,
            operationName: entry.operationName.isNotEmpty
                ? entry.operationName
                : cached['operation_name']?.toString() ?? '',
            productName: entry.productName.isNotEmpty
                ? entry.productName
                : cached['product_name']?.toString() ?? '',
            productCode: entry.productCode.isNotEmpty
                ? entry.productCode
                : cached['product_code']?.toString() ?? '',
            salesOrder: entry.salesOrder.isNotEmpty
                ? entry.salesOrder
                : cached['sales_order']?.toString() ?? '',
            salesOrderItem: entry.salesOrderItem.isNotEmpty
                ? entry.salesOrderItem
                : cached['sales_order_item']?.toString() ?? '',
            plant: entry.plant,
            workCenter: entry.workCenter,
            workId: entry.workId,
            positionId: entry.positionId,
            originPositionId: entry.originPositionId,
            transactionType: entry.transactionType,
            quantity: entry.quantity,
            defectQuantity: entry.defectQuantity,
            unitOfMeasure: entry.unitOfMeasure,
            transactionStatus: entry.transactionStatus,
            originalTransactionUuid: entry.originalTransactionUuid,
          );
        })
        .toList(growable: false);
    return WorkHistoryResult(
      scopeCode: result.scopeCode,
      dateFrom: result.dateFrom,
      dateTo: result.dateTo,
      isTruncated: result.isTruncated,
      entries: entries,
      workers: result.workers,
    );
  }

  void _ensureSubjectCurrent(String subject) {
    if (!_isCacheSubjectCurrent(subject)) {
      throw const WorkHistorySessionChangedException();
    }
  }

  Future<void> _handleAuthorizationRejected(String subject) async {
    // A 401 for a token an earlier login already revoked says nothing about
    // the current session or its snapshots.
    if (!_isCacheSubjectCurrent(subject)) return;
    await db.clearWorkHistoryCacheForSubject(storageNamespace(subject));
    final callback = _onAuthorizationRejected;
    if (callback != null) await callback(subject);
  }

  void dispose() {
    _updates.close();
    _staleSignals.close();
  }

  Future<_CachedWorkHistory?> _readCache(String cacheKey) async {
    final raw = await db.getWorkHistoryCache(cacheKey);
    if (raw == null) return null;

    try {
      final meta = Map<String, dynamic>.from(raw['meta'] as Map);
      final entries = (raw['entries'] as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .map(
            (row) => WorkHistoryEntry(
              transactionUuid: row['transaction_uuid']?.toString() ?? '',
              executionDate: DateTime.parse(
                row['execution_date'] as String,
              ).toLocal(),
              // Calendar date only ("2026-09-24"): parsed as local midnight.
              reportedWorkDate: DateTime.tryParse(
                row['work_date']?.toString() ?? '',
              ),
              originalTransactionUuid:
                  row['original_transaction_uuid']?.toString() ?? '',
              workerId: row['worker_id']?.toString() ?? '',
              workerName: row['worker_name']?.toString() ?? '',
              productionOrder: row['production_order']?.toString() ?? '',
              operation: row['operation']?.toString() ?? '',
              operationName: row['operation_name']?.toString() ?? '',
              productName: row['product_name']?.toString() ?? '',
              productCode: row['product_code']?.toString() ?? '',
              salesOrder: row['sales_order']?.toString() ?? '',
              salesOrderItem: row['sales_order_item']?.toString() ?? '',
              plant: row['plant']?.toString() ?? '',
              workCenter: row['work_center']?.toString() ?? '',
              workId: row['work_id']?.toString() ?? '',
              positionId: row['position_id']?.toString() ?? '',
              originPositionId: row['origin_position_id']?.toString() ?? '',
              transactionType: row['transaction_type']?.toString() ?? '',
              quantity: (row['quantity'] as num).toDouble(),
              defectQuantity: (row['defect_quantity'] as num?)?.toDouble() ?? 0,
              unitOfMeasure: row['unit_of_measure']?.toString() ?? '',
              transactionStatus: row['transaction_status']?.toString() ?? '',
            ),
          )
          .toList(growable: false);
      final workers = (raw['workers'] as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .map(
            (row) => WorkHistorySummary(
              workerId: row['worker_id']?.toString() ?? '',
              workerName: row['worker_name']?.toString() ?? '',
              assignedQuantity: (row['assigned_quantity'] as num).toDouble(),
              completedQuantity: (row['completed_quantity'] as num).toDouble(),
              defectQuantity: (row['defect_quantity'] as num?)?.toDouble() ?? 0,
              remainingQuantity: (row['remaining_quantity'] as num).toDouble(),
              // Not stored in the cache; SAP's identity recovers it.
              recalledQuantity:
                  ((row['assigned_quantity'] as num) -
                          (row['completed_quantity'] as num) -
                          ((row['defect_quantity'] as num?) ?? 0) -
                          (row['remaining_quantity'] as num))
                      .toDouble()
                      .clamp(0.0, double.infinity),
              unitOfMeasure: row['unit_of_measure']?.toString() ?? '',
              transactionCount: (row['transaction_count'] as num).toInt(),
              workId: row['work_id']?.toString() ?? '',
              workName: row['work_name']?.toString() ?? '',
              boPhan: row['bo_phan']?.toString() ?? '',
              location: row['location']?.toString() ?? '',
            ),
          )
          .toList(growable: false);

      return _CachedWorkHistory(
        result: WorkHistoryResult(
          scopeCode: meta['scope_code']?.toString() ?? '',
          dateFrom: DateTime.parse(meta['result_date_from'] as String),
          dateTo: DateTime.parse(meta['result_date_to'] as String),
          isTruncated: meta['is_truncated'] == 1,
          entries: entries,
          workers: workers,
        ),
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(
          meta['fetched_at_utc'] as int,
        ),
      );
    } catch (_) {
      // Cache rows are expendable. A malformed/old snapshot must never block a
      // live SAP read after an app upgrade.
      return null;
    }
  }

  String _cacheKey({
    required String subject,
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? shiftId,
    String? workId,
    String? productionOrder,
    String? operation,
  }) {
    final anchor = _dateKey(_now());
    final from =
        _dateKeyOrNull(dateFrom) ??
        (range == HistoryRange.custom ? '-' : anchor);
    final to =
        _dateKeyOrNull(dateTo) ?? (range == HistoryRange.custom ? '-' : anchor);
    return '${storageNamespace(subject)}|${range.code}|$from|$to|'
        '${shiftId?.trim() ?? ''}|'
        '${workId?.trim() ?? ''}|'
        '${productionOrder?.trim() ?? ''}|${operation?.trim() ?? ''}';
  }

  static String _inFlightKey(String subject, String cacheKey) =>
      '$subject\u0000$cacheKey';

  static String _dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static String? _dateKeyOrNull(DateTime? value) =>
      value == null ? null : _dateKey(value);
}

class _CachedWorkHistory {
  final WorkHistoryResult result;
  final DateTime fetchedAt;

  const _CachedWorkHistory({required this.result, required this.fetchedAt});
}

class _WorkHistoryUpdate {
  final String cacheKey;
  final WorkHistoryResult? result;
  final Object? error;
  final StackTrace? stackTrace;

  const _WorkHistoryUpdate({
    required this.cacheKey,
    required WorkHistoryResult this.result,
  }) : error = null,
       stackTrace = null;

  const _WorkHistoryUpdate.failed({
    required this.cacheKey,
    required Object this.error,
    required this.stackTrace,
  }) : result = null;
}

/// Rolls back a transaction the operator just entered when SAP answered with
/// an error (see `isLiveRejectionDiscarded`). Only timeouts and requests that
/// never reached SAP are kept on the device and hold their quantity.
/// The queue row may be FAILED, NEEDS_VERIFICATION or — for a child whose
/// parent was the one refused — still PENDING.
Future<MutationReceipt> _discardRefusedMutation(
  CaslaDatabase db,
  String id,
  Map<String, dynamic> queueItem, {
  required String code,
  required String message,
}) async {
  await db.deleteSyncQueueItem(queueItem['id'] as String, allowPending: true);
  return MutationReceipt(
    id: id,
    state: MutationDeliveryState.discarded,
    code: code,
    message: message,
  );
}

Future<MutationReceipt> _liveMutationReceipt(
  CaslaDatabase db,
  String id,
  Map<String, dynamic> queueItem,
  SyncFailure? failure,
) async {
  if (failure != null && isLiveRejectionDiscarded(failure.code)) {
    return _discardRefusedMutation(
      db,
      id,
      queueItem,
      code: failure.code,
      message: failure.message,
    );
  }
  return _mutationReceipt(id, failure);
}

MutationReceipt _mutationReceipt(String id, SyncFailure? failure) {
  if (failure == null) {
    return MutationReceipt(id: id, state: MutationDeliveryState.synced);
  }
  final state = switch (failure.kind) {
    SyncFailureKind.needsVerification =>
      MutationDeliveryState.needsVerification,
    SyncFailureKind.permanent => MutationDeliveryState.rejected,
    SyncFailureKind.transient ||
    SyncFailureKind.auth => MutationDeliveryState.queued,
  };
  return MutationReceipt(
    id: id,
    state: state,
    code: failure.code,
    message: failure.message,
  );
}

Future<MutationReceipt> _verifiedMutationReceipt(
  CaslaDatabase db,
  String id,
  Map<String, dynamic> queueItem,
  VerifiedSyncReport report,
) async {
  if (report.outcome == VerifiedSyncOutcome.synced) {
    return MutationReceipt(id: id, state: MutationDeliveryState.synced);
  }
  if (isLiveRejectionDiscarded(report.failureCode)) {
    // Also when the refused item was an unsynced parent sent ahead of this
    // one: the parent was already on the Đồng bộ tab, but the transaction the
    // operator just entered is dropped rather than queued behind it.
    return _discardRefusedMutation(
      db,
      id,
      queueItem,
      code: report.failureCode!,
      message: report.message,
    );
  }

  final queued = await db.getSyncQueueItemById(queueItem['id'] as String);
  final status = queued?['status']?.toString();
  final code = queued?['last_error_code']?.toString();
  final state = status == 'NEEDS_VERIFICATION' || code == 'WORKER_AUTH_FAILED'
      ? MutationDeliveryState.needsVerification
      : status == 'FAILED' || report.outcome == VerifiedSyncOutcome.rejected
      ? MutationDeliveryState.rejected
      : MutationDeliveryState.queued;
  return MutationReceipt(
    id: id,
    state: state,
    code: code,
    message: queued?['last_error_message']?.toString() ?? report.message,
  );
}
