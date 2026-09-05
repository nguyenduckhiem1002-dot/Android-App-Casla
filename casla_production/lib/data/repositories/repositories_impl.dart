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
    );
  }

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
    try {
      if (accessToken != null && accessToken.isNotEmpty) {
        // A new instance has no shared CSRF/cookie jar with a login or refresh
        // already in progress. Its `finally` still clears its own state.
        final logoutClient = SapODataClient(
          baseUrl: AppConfig.sapAuthServiceUrl,
        );
        await SapAuthController(logoutClient).logout(
          accessToken: accessToken,
          deviceId: await DeviceInfoHelper.getDeviceId(),
        );
      }
    } finally {
      resetTransportSession();
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
        permissions: {...historyPermissions, ..._supervisorPermissions},
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
  }) async {
    if (!assignedQuantity.isFinite || assignedQuantity <= 0) {
      throw Exception('Số lượng giao phải là một số dương hợp lệ');
    }

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
    final queueItem = {
      'id': IdGenerator.newId(),
      'entity_type': 'ASSIGNMENT',
      'entity_id': id,
      'action': 'CREATE',
      'payload_summary': 'Phân công · +${assignedQuantity.toStringAsFixed(0)}',
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

    return _mutationReceipt(id, failure);
  }

  @override
  Stream<List<Assignment>> watchWorkerAssignments(String workerId) {
    return db.watchAssignmentsByWorker(workerId).asyncMap((entities) async {
      return _mapToAssignmentsBatch(entities);
    });
  }

  @override
  Stream<List<Assignment>> watchAssignmentsByTeams(List<String> teamIds) {
    final normalized = teamIds
        .map((teamId) => teamId.trim())
        .where((teamId) => teamId.isNotEmpty)
        .toSet()
        .toList(growable: false);
    return db.watchAssignmentsByTeams(normalized).asyncMap((entities) async {
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
    List<Map<String, dynamic>> entities,
  ) async {
    if (entities.isEmpty) return [];

    final snapshots = await db.getAssignmentDisplayRows(
      entities.map((entity) => entity['id'] as String),
    );

    final result = <Assignment>[];
    for (final entity in snapshots) {
      final empId = entity['nhan_vien_id'] as String;
      final orderId = entity['don_hang_id'] as String;
      final assignmentId = entity['id'] as String;

      final completed = (entity['completed_quantity'] as num).toDouble();
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
          productCode: entity['product_code'] as String? ?? 'SP',
          productName: entity['product_name'] as String? ?? 'Sản phẩm',
          uom: entity['unit_of_measure'] as String? ?? 'cái',
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
          syncStatus: SyncStatus.fromStorage(entity['sync_status']),
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
    final queueItem = {
      'id': IdGenerator.newId(),
      'entity_type': 'PRODUCTION',
      'entity_id': id,
      'action': 'CREATE',
      'payload_summary':
          'Xác nhận hoàn thành · +${quantity.toStringAsFixed(0)}',
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

    return _mutationReceipt(id, failure);
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
                  syncStatus: SyncStatus.fromStorage(r['sync_status']),
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
    final queueItem = {
      'id': IdGenerator.newId(),
      'entity_type': 'RECALL',
      'entity_id': id,
      'action': 'CREATE',
      'payload_summary': 'Thu hồi phân công · -${quantity.toStringAsFixed(0)}',
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

    return _mutationReceipt(id, failure);
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
    });

class WorkHistorySessionChangedException implements Exception {
  const WorkHistorySessionChangedException();

  @override
  String toString() => 'WorkHistorySessionChangedException';
}

class WorkHistoryRepositoryImpl implements WorkHistoryRepository {
  final CaslaDatabase db;
  final WorkHistoryLoader loadRemote;
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

  WorkHistoryRepositoryImpl(
    this.db, {
    required this.loadRemote,
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

  @override
  Future<WorkHistoryResult> getWorkHistory({
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
    bool forceRefresh = false,
  }) async {
    final subject = cacheSubject()?.trim();
    if (subject == null || subject.isEmpty) {
      final stopwatch = Stopwatch()..start();
      try {
        final result = await loadRemote(
          range: range,
          dateFrom: dateFrom,
          dateTo: dateTo,
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
      );
    }

    final cached = await _readCache(cacheKey);
    _ensureSubjectCurrent(subject);
    if (cached != null) {
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
            ),
          ),
        );
      } else {
        telemetry.increment(FieldMetric.workHistoryCacheHit);
      }
      return cached.result;
    }

    telemetry.increment(FieldMetric.workHistoryCacheMiss);
    return _refresh(
      cacheKey: cacheKey,
      subject: subject,
      range: range,
      dateFrom: dateFrom,
      dateTo: dateTo,
    );
  }

  @override
  Stream<WorkHistoryResult> watchWorkHistory({
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) {
    final subject = cacheSubject()?.trim();
    if (subject == null || subject.isEmpty) {
      return Stream<WorkHistoryResult>.fromFuture(
        getWorkHistory(range: range, dateFrom: dateFrom, dateTo: dateTo),
      );
    }
    final cacheKey = _cacheKey(
      subject: subject,
      range: range,
      dateFrom: dateFrom,
      dateTo: dateTo,
    );

    late final StreamController<WorkHistoryResult> controller;
    StreamSubscription<_WorkHistoryUpdate>? updatesSubscription;
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

    controller = StreamController<WorkHistoryResult>(
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
        unawaited(emitCurrent());
      },
      onCancel: () async {
        await updatesSubscription?.cancel();
        if (!controller.isClosed) await controller.close();
      },
    );
    return controller.stream;
  }

  Future<void> _ignoreRefreshFailure(Future<WorkHistoryResult> refresh) async {
    try {
      await refresh;
    } catch (_) {
      // SWR keeps the last good snapshot visible while offline. A pull-to-
      // refresh uses forceRefresh and still surfaces the live failure.
    }
  }

  Future<WorkHistoryResult> _refresh({
    required String cacheKey,
    required String subject,
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    final existing = _inFlight[cacheKey];
    if (existing != null) return existing;

    final future = _refreshOnce(
      cacheKey: cacheKey,
      subject: subject,
      range: range,
      dateFrom: dateFrom,
      dateTo: dateTo,
    );
    _inFlight[cacheKey] = future;

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
      if (identical(_inFlight[cacheKey], future)) {
        final _ = _inFlight.remove(cacheKey);
      }
    }
  }

  Future<WorkHistoryResult> _refreshOnce({
    required String cacheKey,
    required String subject,
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
  }) async {
    _ensureSubjectCurrent(subject);
    final stopwatch = Stopwatch()..start();
    late final WorkHistoryResult result;
    try {
      result = await loadRemote(
        range: range,
        dateFrom: dateFrom,
        dateTo: dateTo,
      );
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
      subjectId: subject,
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
            'execution_date': _dateKey(entry.executionDate),
            'worker_id': entry.workerId,
            'worker_name': entry.workerName,
            'production_order': entry.productionOrder,
            'operation': entry.operation,
            'plant': entry.plant,
            'work_center': entry.workCenter,
            'transaction_type': entry.transactionType,
            'quantity': entry.quantity,
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
            'remaining_quantity': worker.remainingQuantity,
            'unit_of_measure': worker.unitOfMeasure,
            'transaction_count': worker.transactionCount,
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
      // is disposable, so remove the old namespace rather than retain it.
      await db.clearWorkHistoryCacheForSubject(subject);
      throw const WorkHistorySessionChangedException();
    }
    if (!_updates.isClosed) {
      _updates.add(_WorkHistoryUpdate(cacheKey: cacheKey, result: result));
    }

    return result;
  }

  void _ensureSubjectCurrent(String subject) {
    if (!_isCacheSubjectCurrent(subject)) {
      throw const WorkHistorySessionChangedException();
    }
  }

  Future<void> _handleAuthorizationRejected(String subject) async {
    await db.clearWorkHistoryCacheForSubject(subject);
    final callback = _onAuthorizationRejected;
    if (callback != null) await callback(subject);
  }

  void dispose() {
    _updates.close();
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
              executionDate: DateTime.parse(row['execution_date'] as String),
              workerId: row['worker_id']?.toString() ?? '',
              workerName: row['worker_name']?.toString() ?? '',
              productionOrder: row['production_order']?.toString() ?? '',
              operation: row['operation']?.toString() ?? '',
              plant: row['plant']?.toString() ?? '',
              workCenter: row['work_center']?.toString() ?? '',
              transactionType: row['transaction_type']?.toString() ?? '',
              quantity: (row['quantity'] as num).toDouble(),
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
              remainingQuantity: (row['remaining_quantity'] as num).toDouble(),
              unitOfMeasure: row['unit_of_measure']?.toString() ?? '',
              transactionCount: (row['transaction_count'] as num).toInt(),
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
  }) {
    final anchor = _dateKey(_now());
    final from =
        _dateKeyOrNull(dateFrom) ??
        (range == HistoryRange.custom ? '-' : anchor);
    final to =
        _dateKeyOrNull(dateTo) ?? (range == HistoryRange.custom ? '-' : anchor);
    return '$subject|${range.code}|$from|$to';
  }

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
    message: report.message,
  );
}
