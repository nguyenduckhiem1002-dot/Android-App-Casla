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
import '../../domain/policies/production_math.dart';
import '../../core/utils/device_info.dart';
import '../../core/utils/sap_entry_time.dart';
import '../../domain/entities/operation_access.dart';
import '../../domain/entities/work_history.dart';
import 'odata_error.dart';
import 'sap_odata_client.dart';
import 'sap_session_provider.dart';

/// `com.sap.gateway.srvd_a2x.zui_pp_opalloc.v0001` — from the published EDMX.
/// See the matching constant in `sap_auth_controller.dart` for why this is a
/// literal rather than derived.
const String _kNamespace = 'com.sap.gateway.srvd_a2x.zui_pp_opalloc.v0001';
const String _kEntitySet = 'OperationAllocations';
// Use the action path from the supplied OpenAPI contract. SAP__self is
// the service namespace alias; it does not change action parameters.
const String _kStaticActionBinding = 'SAP__self';
const Duration _historyReceiveTimeout = Duration(seconds: 60);

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

  /// Clears request-scoped SAP transport state when the app changes identity.
  /// The gateway owns this client, so no old CSRF token or cookies can leak
  /// into the next login's write/history requests.
  void resetTransportSession() {
    client.setAuthToken(null);
    client.resetCsrfSession();
  }

  @override
  Future<SapWriteResult> push(SyncPushRequest request) async {
    final sessionGeneration = session.generation;
    final accessToken = session.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      if (!session.isGenerationCurrent(sessionGeneration)) {
        throw const SapSessionInvalidatedException();
      }
      // Nothing to send with — the engine's auth-refresh path handles this
      // exactly like an expired token.
      throw const SapBusinessError('TOKEN_INVALID_OR_EXPIRED');
    }
    _ensureSessionCurrent(sessionGeneration, accessToken);

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
        return _submitInitialAssign(
          request,
          accessToken,
          deviceId,
          sessionGeneration,
        );
      case 'PRODUCTION':
      case 'PRODUCTION_RECORD':
        return _submitConfirm(
          request,
          accessToken,
          deviceId,
          sessionGeneration,
        );
      case 'RECALL':
      case 'RECALL_RECORD':
        return _submitRecall(request, accessToken, deviceId, sessionGeneration);
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
    int sessionGeneration,
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
      sessionGeneration: sessionGeneration,
      params: {
        'ProductionOrder': keys.productionOrder,
        'Operation': keys.operation,
        // Freeze the exact work context selected when this assignment was
        // created. `to_id` is the local column that stores SAP WorkID.
        'WorkID': (assignment['to_id'] ?? '').toString().trim(),
        // Always present: the gateway rejects the call when a declared
        // parameter is missing ("No value for mandatory parameter"), even
        // though the backend treats an empty one as "no position". It is part
        // of SAP's idempotency payload, which is why it is frozen on the row.
        'PositionID': _text(assignment['position_id']),
        'ToWorkerID': workerCode,
        'Quantity': _quantity(assignment['assigned_quantity']),
        'UnitOfMeasure': _unitOfMeasure(assignment, order),
        ..._executionTime(assignment),
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
    int sessionGeneration,
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
      sessionGeneration: sessionGeneration,
      params: {
        'ProductionOrder': keys.productionOrder,
        'Operation': keys.operation,
        // Confirming must use the assignment's original location, even when
        // the worker or supervisor has since changed work contexts.
        'WorkID': (assignment['to_id'] ?? '').toString().trim(),
        'WorkerID': workerCode,
        'Quantity': _quantity(record['quantity']),
        'DefectQuantity': _quantity(record['defect_quantity']),
        'UnitOfMeasure': _unitOfMeasure(record, order),
        ..._executionTime(record),
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
    int sessionGeneration,
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
      sessionGeneration: sessionGeneration,
      params: {
        'ProductionOrder': keys.productionOrder,
        'Operation': keys.operation,
        'WorkID': (assignment['to_id'] ?? '').toString().trim(),
        'WorkerID': workerCode,
        'Quantity': _quantity(record['quantity']),
        'UnitOfMeasure': _unitOfMeasure(record, order),
        ..._executionTime(record),
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
    required int sessionGeneration,
    required Map<String, dynamic> params,
  }) async {
    try {
      // Same CSRF dance SapAuthController does before every mutating POST —
      // this service is behind the same SAP Gateway CSRF protection.
      _ensureSessionCurrent(sessionGeneration, accessToken);
      await client.fetchCsrfToken();
      _ensureSessionCurrent(sessionGeneration, accessToken);
      final response = await client.dio.post(
        '$_kEntitySet/$_kNamespace.$action',
        data: params,
      );
      _ensureSessionCurrent(sessionGeneration, accessToken);
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
        return _reconcile(
          request,
          accessToken,
          deviceId,
          sessionGeneration: sessionGeneration,
          ambiguousCode: code,
        );
      }
      rethrowAsBusinessError(error);
    }
  }

  /// `getSyncStatus` — the reconciliation call for an ambiguous receipt.
  Future<SapWriteResult> _reconcile(
    SyncPushRequest request,
    String accessToken,
    String deviceId, {
    required int sessionGeneration,
    required String ambiguousCode,
  }) async {
    try {
      _ensureSessionCurrent(sessionGeneration, accessToken);
      await client.fetchCsrfToken();
      _ensureSessionCurrent(sessionGeneration, accessToken);
      final response = await client.dio.post(
        '$_kEntitySet/$_kNamespace.getSyncStatus',
        data: {
          'AccessToken': accessToken,
          'DeviceID': deviceId,
          'SyncItemUUID': request.idempotencyKey,
        },
      );
      _ensureSessionCurrent(sessionGeneration, accessToken);
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
  /// own rows back no matter what WorkerID this app sends here. WorkID is an
  /// optional filter that pins the report to one posting location.
  ///
  /// The access token is short-lived (30 minutes — see `ZA_MOB_LoginResult`'s
  /// `ExpiresAt`), and unlike a queued mutation this call has no engine
  /// wrapping it with a refresh-and-retry. Without doing that here, the
  /// history screen would show a raw TOKEN_INVALID_OR_EXPIRED error on every
  /// ordinary expiry — refreshed once, transparently, before giving up.
  Future<WorkHistoryResult> getWorkHistory({
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? shiftId,
    String? workId,
    String? productionOrder,
    String? operation,
  }) async {
    try {
      return await _getWorkHistoryOnce(
        range,
        dateFrom: dateFrom,
        dateTo: dateTo,
        shiftId: shiftId,
        workId: workId,
        productionOrder: productionOrder,
        operation: operation,
      );
    } on SapSessionInvalidatedException {
      rethrow;
    } catch (error) {
      if (classifySyncError(error).kind != SyncFailureKind.auth) rethrow;
      // A revoked session (e.g. right after a password change) fails the
      // refresh too; that failure — not the original one — is what the
      // caller should see and act on ("phiên đăng nhập đã hết hạn").
      if (!await refreshSession()) rethrow;
      return _getWorkHistoryOnce(
        range,
        dateFrom: dateFrom,
        dateTo: dateTo,
        shiftId: shiftId,
        workId: workId,
        productionOrder: productionOrder,
        operation: operation,
      );
    }
  }

  /// Checks the scanned operation against the manager's current SAP scope and
  /// returns the server-side quantity snapshot used by the assignment form.
  ///
  /// This is intentionally a live call. The caller is still responsible for
  /// adding local pending transactions because SAP cannot see writes that are
  /// queued on this device yet.
  Future<OperationAccessResult> checkOperationAccess({
    required String productionOrder,
    required String operation,
    required String workId,
    required String shiftId,
    required DateTime executedAt,
  }) async {
    try {
      return await _checkOperationAccessOnce(
        productionOrder: productionOrder,
        operation: operation,
        workId: workId,
        shiftId: shiftId,
        executedAt: executedAt,
      );
    } on SapSessionInvalidatedException {
      rethrow;
    } catch (error) {
      if (classifySyncError(error).kind != SyncFailureKind.auth) rethrow;
      if (!await refreshSession()) rethrow;
      return _checkOperationAccessOnce(
        productionOrder: productionOrder,
        operation: operation,
        workId: workId,
        shiftId: shiftId,
        executedAt: executedAt,
      );
    }
  }

  Future<OperationAccessResult> _checkOperationAccessOnce({
    required String productionOrder,
    required String operation,
    required String workId,
    required String shiftId,
    required DateTime executedAt,
  }) async {
    final normalizedOrder = productionOrder.trim();
    final normalizedOperation = operation.trim();
    final normalizedWorkId = workId.trim();
    final normalizedShiftId = shiftId.trim();
    if (normalizedOrder.isEmpty || normalizedOperation.isEmpty) {
      throw const SapBusinessError('ORDER_OPERATION_REQUIRED');
    }
    if (normalizedWorkId.isEmpty || normalizedShiftId.isEmpty) {
      throw const SapBusinessError('WORK_CONTEXT_REQUIRED');
    }
    if (normalizedOrder.length > 12 ||
        normalizedOperation.length > 4 ||
        normalizedWorkId.length > 30 ||
        normalizedShiftId.length > 10) {
      throw const SapBusinessError('INVALID_PARAMETER');
    }

    final sessionGeneration = session.generation;
    final accessToken = session.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      if (!session.isGenerationCurrent(sessionGeneration)) {
        throw const SapSessionInvalidatedException();
      }
      throw const SapBusinessError('TOKEN_INVALID_OR_EXPIRED');
    }
    _ensureSessionCurrent(sessionGeneration, accessToken);
    final deviceId = DeviceInfoHelper.deviceId;

    final scannedAt = SapEntryTime.fromInstant(executedAt);

    try {
      _ensureSessionCurrent(sessionGeneration, accessToken);
      await client.fetchCsrfToken();
      _ensureSessionCurrent(sessionGeneration, accessToken);
      final response = await client.dio.post(
        '$_kEntitySet/$_kStaticActionBinding.checkOperationAccess',
        data: {
          'AccessToken': accessToken,
          'DeviceID': deviceId,
          'ProductionOrder': normalizedOrder,
          'Operation': normalizedOperation,
          'WorkID': normalizedWorkId,
          'ShiftID': normalizedShiftId,
          // A live call, never retried under an idempotency key, so it has no
          // older format to stay compatible with.
          'EntryDate': scannedAt.date,
          'EntryTime': scannedAt.time,
        },
        options: Options(receiveTimeout: const Duration(seconds: 20)),
      );
      _ensureSessionCurrent(sessionGeneration, accessToken);
      return OperationAccessResult.fromJson(odataActionResult(response));
    } on DioException catch (error) {
      rethrowAsBusinessError(error);
    }
  }

  Future<WorkHistoryResult> _getWorkHistoryOnce(
    HistoryRange range, {
    DateTime? dateFrom,
    DateTime? dateTo,
    String? shiftId,
    String? workId,
    String? productionOrder,
    String? operation,
  }) async {
    final sessionGeneration = session.generation;
    final accessToken = session.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      if (!session.isGenerationCurrent(sessionGeneration)) {
        throw const SapSessionInvalidatedException();
      }
      throw const SapBusinessError('TOKEN_INVALID_OR_EXPIRED');
    }
    _ensureSessionCurrent(sessionGeneration, accessToken);
    final deviceId = DeviceInfoHelper.deviceId;

    if ((dateFrom == null) != (dateTo == null) ||
        (range == HistoryRange.custom && dateFrom == null)) {
      throw ArgumentError('Bộ lọc lịch sử cần đủ ngày bắt đầu và kết thúc.');
    }
    if (dateFrom != null &&
        dateTo != null &&
        DateTime(
          dateFrom.year,
          dateFrom.month,
          dateFrom.day,
        ).isAfter(DateTime(dateTo.year, dateTo.month, dateTo.day))) {
      throw ArgumentError('Ngày bắt đầu không được sau ngày kết thúc.');
    }
    final dateFromStr = dateFrom != null
        ? '${dateFrom.year.toString().padLeft(4, '0')}-${dateFrom.month.toString().padLeft(2, '0')}-${dateFrom.day.toString().padLeft(2, '0')}'
        : null;
    final dateToStr = dateTo != null
        ? '${dateTo.year.toString().padLeft(4, '0')}-${dateTo.month.toString().padLeft(2, '0')}-${dateTo.day.toString().padLeft(2, '0')}'
        : null;
    // Published bindings require both Edm.Date parameters. When the caller
    // selected a server-relative filter, materialize the same window here so
    // the request remains valid and the dates visibly match that filter.
    final today = DateTime.now();
    final dateOnly = DateTime(today.year, today.month, today.day);
    final windowFrom =
        dateFrom ??
        switch (range) {
          HistoryRange.day => dateOnly,
          HistoryRange.week => dateOnly.subtract(const Duration(days: 6)),
          HistoryRange.month => dateOnly.subtract(const Duration(days: 29)),
          HistoryRange.custom => dateOnly,
        };
    final windowTo = dateTo ?? dateOnly;
    String formatDate(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    final requestDateFrom = dateFromStr ?? formatDate(windowFrom);
    final requestDateTo = dateToStr ?? formatDate(windowTo);
    final normalizedShiftId = shiftId?.trim() ?? '';
    final normalizedWorkId = workId?.trim() ?? '';
    final normalizedProductionOrder = productionOrder?.trim() ?? '';
    final normalizedOperation = operation?.trim() ?? '';
    if (normalizedProductionOrder.isEmpty != normalizedOperation.isEmpty) {
      throw ArgumentError('Bộ lọc cần cả LSX và mã công đoạn.');
    }
    for (final field in <String, (String, int)>{
      'WorkID': (normalizedWorkId, 30),
      'ShiftID': (normalizedShiftId, 10),
      'ProductionOrder': (normalizedProductionOrder, 12),
      'Operation': (normalizedOperation, 4),
    }.entries) {
      if (field.value.$1.length > field.value.$2) {
        throw ArgumentError('${field.key} vượt độ dài API cho phép.');
      }
    }
    // Preserve D/W/M semantics for server-relative filters. An explicit
    // calendar window uses C so SAP honours the exact DateFrom/DateTo values.
    final rangeCode = dateFromStr != null && dateToStr != null
        ? HistoryRange.custom.code
        : range.code;

    try {
      _ensureSessionCurrent(sessionGeneration, accessToken);
      await client.fetchCsrfToken();
      _ensureSessionCurrent(sessionGeneration, accessToken);
      final payload = <String, dynamic>{
        'AccessToken': accessToken,
        'DeviceID': deviceId,
        'RangeCode': rangeCode,
        'DateFrom': requestDateFrom,
        'DateTo': requestDateTo,
        'WorkerID': '',
        'ShiftID': normalizedShiftId,
        'SummaryOnly': false,
      };
      // Empty strings mean no filter in ZA_PP_HistQuery. All parameters
      // belong to the published action signature, including unused filters.
      payload.addAll({
        'WorkID': normalizedWorkId,
        'ProductionOrder': normalizedProductionOrder,
        'Operation': normalizedOperation,
      });
      final response = await client.dio.post(
        '$_kEntitySet/$_kStaticActionBinding.getWorkHistory',
        data: payload,
        options: Options(receiveTimeout: _historyReceiveTimeout),
      );
      _ensureSessionCurrent(sessionGeneration, accessToken);
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
    final executedAt = _parseDate(
      json['ExecutionAt'] ??
          json['executionAt'] ??
          json['ExecutedAt'] ??
          json['executedAt'],
    )?.toLocal();
    final executionDate =
        executedAt ??
        _parseDate(json['ExecutionDate'] ?? json['executionDate'])?.toLocal() ??
        DateTime.now();
    // The shift's business date. ExecutionDate is written as the work date on
    // current services, so it is the fallback; ExecutedAt never is (a night
    // shift posts after midnight). Date-only values are taken as calendar
    // components, never shifted through a time zone.
    DateTime? businessDay(Object? value) {
      final parsed = _parseDate(value);
      // An initial ABAP date may arrive as "0000-00-00", which Dart happily
      // normalises into a nonsense year.
      if (parsed == null || parsed.year < 2000) return null;
      return DateTime(parsed.year, parsed.month, parsed.day);
    }

    return WorkHistoryEntry(
      transactionUuid: (json['TransactionUUID'] ?? '').toString(),
      executionDate: executionDate,
      // PostingDate is the same shift date under the name newer services
      // report it by.
      reportedWorkDate:
          businessDay(json['PostingDate']) ??
          businessDay(json['WorkDate'] ?? json['workDate']) ??
          businessDay(json['ExecutionDate'] ?? json['executionDate']),
      workerId: (json['WorkerID'] ?? '').toString(),
      workerName: (json['WorkerName'] ?? '').toString(),
      productionOrder: (json['ProductionOrder'] ?? '').toString(),
      operation: (json['Operation'] ?? '').toString(),
      operationName:
          (json['OperationName'] ?? json['OperationDescription'] ?? '')
              .toString(),
      productName: (json['ProductName'] ?? json['MaterialName'] ?? '')
          .toString(),
      // The history response names the material key `Product`; accept the
      // older aliases as a fallback for already-published service bindings.
      productCode:
          (json['Product'] ?? json['ProductCode'] ?? json['MaterialCode'] ?? '')
              .toString(),
      salesOrder:
          (json['SalesOrder'] ??
                  json['salesOrder'] ??
                  json['salesorder'] ??
                  json['Salesorder'] ??
                  '')
              .toString(),
      salesOrderItem:
          (json['SalesOrderItem'] ??
                  json['salesOrderItem'] ??
                  json['salesorderitem'] ??
                  json['SalesOrderitem'] ??
                  json['Salesorderitem'] ??
                  '')
              .toString(),
      plant: (json['Plant'] ?? '').toString(),
      workCenter: (json['WorkCenter'] ?? '').toString(),
      workId: (json['WorkID'] ?? json['work_id'] ?? '').toString(),
      positionId: _text(json['PositionID']).toUpperCase(),
      originPositionId: _text(json['OriginPositionID']).toUpperCase(),
      transactionType: (json['TransactionType'] ?? '').toString(),
      quantity: _parseQuantity(json['Quantity']),
      defectQuantity: _parseQuantity(
        json['DefectQuantity'] ?? json['defect_quantity'],
      ),
      unitOfMeasure: (json['UnitOfMeasure'] ?? '').toString(),
      transactionStatus: (json['TransactionStatus'] ?? '').toString(),
      originalTransactionUuid: (json['OriginalTransactionUUID'] ?? '')
          .toString(),
    );
  }

  static WorkHistorySummary _summaryFromJson(Map<String, dynamic> json) {
    final assigned = _parseQuantity(json['AssignedQuantity']);
    final completed = _parseQuantity(json['CompletedQuantity']);
    final remaining = _parseQuantity(json['RemainingQuantity']);
    return WorkHistorySummary(
      workerId: (json['WorkerID'] ?? '').toString(),
      workerName: (json['WorkerName'] ?? '').toString(),
      assignedQuantity: assigned,
      completedQuantity: completed,
      defectQuantity: _parseQuantity(
        json['DefectQuantity'] ?? json['defect_quantity'],
      ),
      remainingQuantity: remaining,
      // Older bindings omit it; SAP's own identity recovers it there.
      recalledQuantity: json.containsKey('RecalledQuantity')
          ? _parseQuantity(json['RecalledQuantity'])
          : (assigned -
                    completed -
                    _parseQuantity(
                      json['DefectQuantity'] ?? json['defect_quantity'],
                    ) -
                    remaining)
                .clamp(0.0, double.infinity),
      unitOfMeasure: (json['UnitOfMeasure'] ?? '').toString(),
      transactionCount: (json['TransactionCount'] as num?)?.toInt() ?? 0,
      workId: (json['WorkID'] ?? json['work_id'] ?? '').toString(),
      workName: (json['WorkName'] ?? '').toString(),
      boPhan: (json['BoPhan'] ?? '').toString(),
      location: (json['Location'] ?? '').toString(),
    );
  }

  /// `Edm.Date` comes back as an ISO date string; `Edm.Decimal` (IEEE754
  /// Compatible, same as the write side) comes back as a numeric string —
  /// both need parsing rather than a direct cast.
  static DateTime? _parseDate(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    final text = value.toString().trim();
    final sapEpoch = RegExp(
      r'^/Date\((-?\d+)(?:[+-]\d+)?\)/$',
    ).firstMatch(text);
    if (sapEpoch != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        int.parse(sapEpoch.group(1)!),
        isUtc: true,
      );
    }
    return DateTime.tryParse(text);
  }

  static double _parseQuantity(Object? value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0.0;
  }

  /// The unit this transaction was entered in, not the one the order carries
  /// today.
  ///
  /// `orders.uom` is rewritten in place by every operation QR scan, so reading
  /// it here would push a queued transaction under a unit nobody entered.
  /// `zbp_r_pp_opalloc` compares the unit when it matches an idempotency key,
  /// so that re-send comes back rejected rather than de-duplicated. Rows
  /// created before schema v5 have no frozen unit and fall back to the order.
  static String _unitOfMeasure(
    Map<String, dynamic> source,
    Map<String, dynamic>? order,
  ) {
    final frozen = source['unit_of_measure']?.toString();
    if (frozen != null && frozen.isNotEmpty) return frozen;
    return order?['uom']?.toString() ?? '';
  }

  static String? _requireWorkerPassword(SyncPushRequest request) {
    final password = request.workerPassword;
    if (password == null || password.isEmpty) {
      throw const WorkerVerificationRequiredException();
    }
    return password;
  }

  /// Encode Edm.Decimal as a string to retain the SAP three-decimal scale.
  /// SapODataClient explicitly declares IEEE754Compatible=true in Content-Type
  /// and Accept; string decimals are NOT the default for plain application/json.
  static String _text(Object? value) => value?.toString().trim() ?? '';

  static String _quantity(Object? value) {
    final quantity = value is num ? value.toDouble() : 0.0;
    // Repositories already store at this scale, so this only formats — it is
    // no longer the place where a 4th decimal quietly disappears.
    return ProductionMath.toSapScale(
      quantity,
    ).toStringAsFixed(ProductionMath.sapQuantityScale);
  }

  static String? _nullIfEmpty(Object? value) {
    final text = value?.toString();
    return (text == null || text.isEmpty) ? null : text;
  }

  /// When and in which shift a queued transaction happened.
  ///
  /// A row created since schema v18 carries the moment of entry as Vietnam
  /// wall-clock `entry_date` / `entry_time`, sent with the shift's own date as
  /// PostingDate (on a night shift that is the day before the entry date).
  /// A row queued by an older build has neither and keeps the UTC format it
  /// was first sent in: SAP compares a retry with the first attempt to the
  /// second and answers IDEMPOTENCY_KEY_REUSED when they differ.
  static Map<String, Object?> _executionTime(Map<String, dynamic> row) {
    final entryDate = _text(row['entry_date']);
    final entryTime = _text(row['entry_time']);
    if (entryDate.isEmpty || entryTime.isEmpty) {
      return {
        'ExecutionDate': row['business_date'],
        'ShiftID': row['shift_id'],
        'ExecutedAt': _executedAt(row['occurred_at_utc']),
      };
    }
    return {
      'ShiftID': row['shift_id'],
      'EntryDate': entryDate,
      'EntryTime': entryTime,
      'PostingDate': row['business_date'],
    };
  }

  static String? _executedAt(Object? value) {
    final millis = value is num ? value.toInt() : int.tryParse('$value');
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      millis,
      isUtc: true,
    ).toIso8601String();
  }

  void _ensureSessionCurrent(int expectedGeneration, String expectedToken) {
    if (!session.isGenerationCurrent(expectedGeneration) ||
        session.accessToken != expectedToken) {
      throw const SapSessionInvalidatedException();
    }
  }
}
