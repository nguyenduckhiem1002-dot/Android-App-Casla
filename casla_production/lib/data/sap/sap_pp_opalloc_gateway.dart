// SAP Integration — Production write gateway
// SAP Service: ZUI_PP_OPALLOC (RAP OData V4, entity set `OperationAllocations`)
//
// Maps a queued `sync_queue` item onto the matching static facade action —
// `submitInitialAssign` / `submitConfirm` / `submitRecall` — and reconciles
// the two receipt-ambiguity codes the backend documents as "not a rejection"
// (`SYNC_RECEIPT_NOT_FOUND` / `SYNC_RECEIPT_DUPLICATE`) via `getSyncStatus`
// before giving up on a push.
//
// `submitTransfer` / `submitReverse` are not wired here: nothing in this app
// today produces a TRANSFER or REVERSE queue entry to push.

import 'package:dio/dio.dart';

import '../../core/database/casla_database.dart';
import '../../core/sync/sap_write_gateway.dart';
import '../../core/sync/sync_failure.dart';
import '../../core/utils/device_info.dart';
import '../../domain/entities/work_history.dart';
import 'odata_error.dart';
import 'sap_odata_client.dart';
import 'sap_session_provider.dart';

/// `com.sap.gateway.srvd_a2x.zui_pp_opalloc.v0001` — from the published EDMX.
/// See the matching constant in `sap_auth_controller.dart` for why this is a
/// literal rather than derived.
const String _kNamespace = 'com.sap.gateway.srvd_a2x.zui_pp_opalloc.v0001';
const String _kEntitySet = 'OperationAllocations';

/// The two codes the backend documents as "not proven, not a rejection" — see
/// `zbp_r_pp_opalloc`'s `report_failure(text: 'SYNC_RECEIPT_...')` calls and
/// `IMPLEMENTATION_STATUS.md`'s idempotency section.
const Set<String> _ambiguousReceiptCodes = {
  'SYNC_RECEIPT_NOT_FOUND',
  'SYNC_RECEIPT_DUPLICATE',
};

class SapPpOpAllocGateway implements SapWriteGateway {
  final CaslaDatabase db;
  final SapODataClient client;
  final SapSessionProvider session;

  SapPpOpAllocGateway({
    required this.db,
    required this.client,
    required this.session,
  });

  @override
  Future<bool> refreshSession() => session.refreshSession();

  @override
  Future<SapWriteResult> push(SyncPushRequest request) async {
    final accessToken = session.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      // Nothing to send with — the engine's auth-refresh path handles this
      // exactly like an expired token.
      throw const SapBusinessError('TOKEN_INVALID_OR_EXPIRED');
    }

    final syncItemUUID = request.idempotencyKey;
    if (syncItemUUID == null || syncItemUUID.isEmpty) {
      // A queue row without an idempotency key is a bug upstream — SAP would
      // reject it with SYNC_ITEM_REQUIRED anyway; failing fast here skips a
      // pointless round trip and says so directly.
      throw const SapBusinessError('SYNC_ITEM_REQUIRED');
    }

    final deviceId = DeviceInfoHelper.deviceId;

    switch (request.entityType) {
      case 'ASSIGNMENT':
        return _submitInitialAssign(request, accessToken, deviceId);
      case 'PRODUCTION':
      case 'PRODUCTION_RECORD':
        return _submitConfirm(request, accessToken, deviceId);
      case 'RECALL':
      case 'RECALL_RECORD':
        return _submitRecall(request, accessToken, deviceId);
      default:
        throw StateError(
          'ZUI_PP_OPALLOC không hỗ trợ entity_type "${request.entityType}".',
        );
    }
  }

  Future<SapWriteResult> _submitInitialAssign(
    SyncPushRequest request,
    String accessToken,
    String deviceId,
  ) async {
    final assignment = request.source;
    final keys = await db.getSapOperationKeys(assignment['id'] as String);
    if (keys == null) {
      throw const SapBusinessError('ORDER_OPERATION_REQUIRED');
    }
    final order = await db.getOrderById(assignment['don_hang_id'] as String);
    final worker = await db.getEmployeeById(
      assignment['nhan_vien_id'] as String,
    );
    final workerCode = worker?['ma_nv'] as String?;
    if (workerCode == null || workerCode.isEmpty) {
      throw StateError('Không resolve được mã nhân viên cho phân công.');
    }

    return _submitAction(
      action: 'submitInitialAssign',
      request: request,
      accessToken: accessToken,
      deviceId: deviceId,
      params: {
        'ProductionOrder': keys.productionOrder,
        'Operation': keys.operation,
        'ToWorkerID': workerCode,
        'Quantity': _quantity(assignment['assigned_quantity']),
        'UnitOfMeasure': order?['uom'] ?? '',
        'ExecutionDate': assignment['business_date'],
        'AccessToken': accessToken,
        'DeviceID': deviceId,
        'WorkerPassword': _requireWorkerPassword(request),
        'SyncItemUUID': request.idempotencyKey,
      },
    );
  }

  Future<SapWriteResult> _submitConfirm(
    SyncPushRequest request,
    String accessToken,
    String deviceId,
  ) async {
    final record = request.source;
    final assignmentId = record['phan_cong_id'] as String;
    final assignment = await db.getAssignmentById(assignmentId);
    if (assignment == null) {
      throw const SapBusinessError('ORDER_OPERATION_REQUIRED');
    }
    final keys = await db.getSapOperationKeys(assignmentId);
    if (keys == null) {
      throw const SapBusinessError('ORDER_OPERATION_REQUIRED');
    }
    final order = await db.getOrderById(assignment['don_hang_id'] as String);
    final worker = await db.getEmployeeById(
      assignment['nhan_vien_id'] as String,
    );
    final workerCode = worker?['ma_nv'] as String?;
    if (workerCode == null || workerCode.isEmpty) {
      throw StateError('Không resolve được mã nhân viên cho phân công.');
    }

    return _submitAction(
      action: 'submitConfirm',
      request: request,
      accessToken: accessToken,
      deviceId: deviceId,
      params: {
        'ProductionOrder': keys.productionOrder,
        'Operation': keys.operation,
        'WorkerID': workerCode,
        'Quantity': _quantity(record['quantity']),
        'UnitOfMeasure': order?['uom'] ?? '',
        'ExecutionDate': record['business_date'],
        // The assignment's own SAP lineage, if `submitInitialAssign` already
        // synced it — optional per the EDMX, so a not-yet-synced assignment
        // (still PENDING) simply omits it rather than blocking the confirm.
        'OriginalTransactionUUID': _nullIfEmpty(assignment['sap_id']),
        'AccessToken': accessToken,
        'DeviceID': deviceId,
        'WorkerPassword': _requireWorkerPassword(request),
        'SyncItemUUID': request.idempotencyKey,
      },
    );
  }

  Future<SapWriteResult> _submitRecall(
    SyncPushRequest request,
    String accessToken,
    String deviceId,
  ) async {
    final record = request.source;
    final assignmentId = record['phan_cong_id'] as String;
    final assignment = await db.getAssignmentById(assignmentId);
    if (assignment == null) {
      throw const SapBusinessError('ORDER_OPERATION_REQUIRED');
    }
    final keys = await db.getSapOperationKeys(assignmentId);
    if (keys == null) {
      throw const SapBusinessError('ORDER_OPERATION_REQUIRED');
    }
    final order = await db.getOrderById(assignment['don_hang_id'] as String);
    final worker = await db.getEmployeeById(
      assignment['nhan_vien_id'] as String,
    );
    final workerCode = worker?['ma_nv'] as String?;
    if (workerCode == null || workerCode.isEmpty) {
      throw StateError('Không resolve được mã nhân viên cho phân công.');
    }

    return _submitAction(
      action: 'submitRecall',
      request: request,
      accessToken: accessToken,
      deviceId: deviceId,
      params: {
        'ProductionOrder': keys.productionOrder,
        'Operation': keys.operation,
        'WorkerID': workerCode,
        'Quantity': _quantity(record['quantity']),
        'UnitOfMeasure': order?['uom'] ?? '',
        'ExecutionDate': record['business_date'],
        'OriginalTransactionUUID': _nullIfEmpty(assignment['sap_id']),
        'AccessToken': accessToken,
        'DeviceID': deviceId,
        'WorkerPassword': _requireWorkerPassword(request),
        'SyncItemUUID': request.idempotencyKey,
      },
    );
  }

  /// Posts one static facade action and parses `ZA_PP_CommandResult`.
  ///
  /// Reconciles the two receipt-ambiguity codes via `getSyncStatus` before
  /// giving up — per the backend's own contract, `SYNC_RECEIPT_NOT_FOUND` is
  /// "not proven yet", not a rejection.
  Future<SapWriteResult> _submitAction({
    required String action,
    required SyncPushRequest request,
    required String accessToken,
    required String deviceId,
    required Map<String, dynamic> params,
  }) async {
    try {
      // Same CSRF dance SapAuthController does before every mutating POST —
      // this service is behind the same SAP Gateway CSRF protection.
      await client.fetchCsrfToken();
      final response = await client.dio.post(
        '$_kEntitySet/$_kNamespace.$action',
        data: params,
      );
      final body = odataActionResult(response);
      final status = (body['Status'] ?? '').toString();

      if (status != 'SUCCESS') {
        // Not observed in the current ABAP source — rejections go through the
        // OData error envelope instead — but fail closed rather than report a
        // push that SAP didn't actually confirm.
        final errorCode = (body['ErrorCode'] ?? '').toString();
        throw SapBusinessError(
          errorCode.isNotEmpty ? errorCode : 'UNEXPECTED_STATUS_$status',
        );
      }

      return SapWriteResult(sapId: _nullIfEmpty(body['TransactionUUID']));
    } on DioException catch (error) {
      final code = odataErrorMessage(error);
      if (code != null && _ambiguousReceiptCodes.contains(code)) {
        return _reconcile(request, accessToken, deviceId, ambiguousCode: code);
      }
      rethrowAsBusinessError(error);
    }
  }

  /// `getSyncStatus` — the reconciliation call for an ambiguous receipt.
  Future<SapWriteResult> _reconcile(
    SyncPushRequest request,
    String accessToken,
    String deviceId, {
    required String ambiguousCode,
  }) async {
    try {
      await client.fetchCsrfToken();
      final response = await client.dio.post(
        '$_kEntitySet/$_kNamespace.getSyncStatus',
        data: {
          'AccessToken': accessToken,
          'DeviceID': deviceId,
          'SyncItemUUID': request.idempotencyKey,
        },
      );
      final body = odataActionResult(response);
      final status = (body['Status'] ?? '').toString();

      if (status == 'SUCCESS') {
        // SAP proves the ledger already holds this SyncItemUUID — treat
        // exactly like a fresh success.
        return SapWriteResult(
          sapId: _nullIfEmpty(body['TransactionUUID']),
          wasDuplicate: true,
        );
      }

      // NOT_FOUND: the backend cannot prove a commit. Its own contract is
      // explicit that this must not become a business failure — queue it for
      // another attempt with the exact same SyncItemUUID.
      throw SapReceiptUnconfirmedException(ambiguousCode);
    } on DioException catch (error) {
      // getSyncStatus itself failed (e.g. the token expired in between) —
      // classify *that* failure instead of the original ambiguous one.
      rethrowAsBusinessError(error);
    }
  }

  /// `getWorkHistory` — a live read, not a queued mutation. Scope
  /// (self/team) is decided entirely server-side from the account's RBAC
  /// functions (`zcl_pp_work_history`); a worker-only account always gets its
  /// own rows back no matter what, so there is no worker id to pass here.
  Future<WorkHistoryResult> getWorkHistory({
    required HistoryRange range,
  }) async {
    final accessToken = session.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      throw const SapBusinessError('TOKEN_INVALID_OR_EXPIRED');
    }
    final deviceId = DeviceInfoHelper.deviceId;

    try {
      await client.fetchCsrfToken();
      final response = await client.dio.post(
        '$_kEntitySet/$_kNamespace.getWorkHistory',
        data: {
          'AccessToken': accessToken,
          'DeviceID': deviceId,
          'RangeCode': range.code,
          'WorkerID': '',
          'SummaryOnly': false,
        },
      );
      return _parseHistoryResult(odataActionResult(response));
    } on DioException catch (error) {
      rethrowAsBusinessError(error);
    }
  }

  static WorkHistoryResult _parseHistoryResult(Map<String, dynamic> body) {
    final entries = (body['_Entries'] as List? ?? const [])
        .map((e) => _entryFromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final workers = (body['_Workers'] as List? ?? const [])
        .map((w) => _summaryFromJson(Map<String, dynamic>.from(w as Map)))
        .toList();

    return WorkHistoryResult(
      scopeCode: (body['ScopeCode'] ?? '').toString(),
      dateFrom: _parseDate(body['DateFrom']) ?? DateTime.now(),
      dateTo: _parseDate(body['DateTo']) ?? DateTime.now(),
      isTruncated: body['IsTruncated'] == true,
      entries: entries,
      workers: workers,
    );
  }

  static WorkHistoryEntry _entryFromJson(Map<String, dynamic> json) {
    return WorkHistoryEntry(
      transactionUuid: (json['TransactionUUID'] ?? '').toString(),
      executionDate: _parseDate(json['ExecutionDate']) ?? DateTime.now(),
      workerId: (json['WorkerID'] ?? '').toString(),
      workerName: (json['WorkerName'] ?? '').toString(),
      productionOrder: (json['ProductionOrder'] ?? '').toString(),
      operation: (json['Operation'] ?? '').toString(),
      plant: (json['Plant'] ?? '').toString(),
      workCenter: (json['WorkCenter'] ?? '').toString(),
      transactionType: (json['TransactionType'] ?? '').toString(),
      quantity: _parseQuantity(json['Quantity']),
      unitOfMeasure: (json['UnitOfMeasure'] ?? '').toString(),
      transactionStatus: (json['TransactionStatus'] ?? '').toString(),
    );
  }

  static WorkHistorySummary _summaryFromJson(Map<String, dynamic> json) {
    return WorkHistorySummary(
      workerId: (json['WorkerID'] ?? '').toString(),
      workerName: (json['WorkerName'] ?? '').toString(),
      assignedQuantity: _parseQuantity(json['AssignedQuantity']),
      completedQuantity: _parseQuantity(json['CompletedQuantity']),
      remainingQuantity: _parseQuantity(json['RemainingQuantity']),
      unitOfMeasure: (json['UnitOfMeasure'] ?? '').toString(),
      transactionCount: (json['TransactionCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// `Edm.Date` comes back as an ISO date string; `Edm.Decimal` (IEEE754
  /// Compatible, same as the write side) comes back as a numeric string —
  /// both need parsing rather than a direct cast.
  static DateTime? _parseDate(Object? value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static double _parseQuantity(Object? value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  static String? _requireWorkerPassword(SyncPushRequest request) {
    final password = request.workerPassword;
    if (password == null || password.isEmpty) {
      throw const WorkerVerificationRequiredException();
    }
    return password;
  }

  /// `Edm.Decimal` on this service is IEEE754Compatible — SAP Gateway's
  /// default for RAP OData V4 — so it must travel as a JSON string, not a
  /// bare number, or a strict client-side encoder would send it as a float
  /// and risk precision loss on the 3-decimal scale SAP expects.
  static String _quantity(Object? value) {
    final quantity = value is num ? value.toDouble() : 0.0;
    return quantity.toStringAsFixed(3);
  }

  static String? _nullIfEmpty(Object? value) {
    final text = value?.toString();
    return (text == null || text.isEmpty) ? null : text;
  }
}
