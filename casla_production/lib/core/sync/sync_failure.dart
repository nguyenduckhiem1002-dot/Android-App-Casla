// Sync — failure classification & retry backoff
// Spec: Section 4.7 (Đồng bộ offline)
//
// The single most important rule in this file: a network failure and a
// business-rule rejection must never be treated the same way. Queuing a
// rejected record for retry means the user hits "Thử lại" forever on a record
// SAP will never accept, and the bad record stays in the queue indefinitely.

import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import '../../data/sap/odata_error.dart';
import '../../data/sap/sap_odata_client.dart';

/// What the sync engine should do about a failed push.
enum SyncFailureKind {
  /// Network or server-side hiccup. Stays PENDING and retries with backoff.
  transient,

  /// Credentials or CSRF token went stale. The engine re-authenticates once per
  /// pass and retries the item; if it still fails it is queued like any other
  /// [transient] failure rather than marked FAILED — a SAP auth outage must not
  /// bury a shift's production behind manual supervisor action.
  auth,

  /// SAP rejected the payload on its merits. Retrying cannot help — the record
  /// becomes FAILED and waits for a supervisor.
  permanent,

  /// The push needs a live worker-password re-entry the automatic engine
  /// cannot supply on its own — see `SyncPushRequest.workerPassword`. Not the
  /// same as [permanent]: the record is fine, it just needs a human to type
  /// the password again before the *next* attempt, not a supervisor override.
  needsVerification,
}

/// A classified push failure, ready to be written to `sync_queue`.
class SyncFailure {
  final SyncFailureKind kind;

  /// Stable machine code stored in `sync_queue.last_error_code`.
  final String code;

  /// Vietnamese text shown to the supervisor on S12.
  final String message;

  const SyncFailure({
    required this.kind,
    required this.code,
    required this.message,
  });

  bool get isRetryable =>
      kind != SyncFailureKind.permanent &&
      kind != SyncFailureKind.needsVerification;

  @override
  String toString() => 'SyncFailure($kind, $code, $message)';
}

/// Thrown by a gateway when a mutation needs the worker's own password and
/// this call has none to send.
///
/// The automatic background engine can never supply one — see
/// `SyncPushRequest.workerPassword` — so this is not a transient failure to
/// retry blindly; it needs a human to re-enter the password before the next
/// attempt.
class WorkerVerificationRequiredException implements Exception {
  const WorkerVerificationRequiredException();

  @override
  String toString() => 'WorkerVerificationRequiredException';
}

/// Thrown by `SapPpOpAllocGateway` when a `SYNC_RECEIPT_NOT_FOUND` /
/// `SYNC_RECEIPT_DUPLICATE` response was followed by a `getSyncStatus` call
/// that still couldn't prove a commit.
///
/// Per the backend's own contract this is explicitly not a rejection — "NOT
/// FOUND" means unproven, not failed — so it is classified [transient] and
/// retried with the exact same command and `SyncItemUUID`, never [permanent].
class SapReceiptUnconfirmedException implements Exception {
  final String code;

  const SapReceiptUnconfirmedException(this.code);

  @override
  String toString() => 'SapReceiptUnconfirmedException($code)';
}

/// Maps a thrown error onto a [SyncFailure].
///
/// Defaults lean toward [SyncFailureKind.transient] for anything network-shaped
/// and [SyncFailureKind.permanent] for anything SAP answered deliberately.
/// Guessing "transient" on a real rejection only delays the failure; guessing
/// "permanent" on a flaky connection loses a day of production data.
SyncFailure classifySyncError(Object error) {
  if (error is WorkerVerificationRequiredException) {
    return const SyncFailure(
      kind: SyncFailureKind.needsVerification,
      code: 'NEEDS_WORKER_VERIFICATION',
      message: 'Cần nhập lại mật khẩu xác nhận của công nhân để đồng bộ.',
    );
  }

  if (error is SapReceiptUnconfirmedException) {
    return SyncFailure(
      kind: SyncFailureKind.transient,
      code: error.code,
      message: 'SAP chưa xác nhận được giao dịch. Sẽ tự động thử lại.',
    );
  }

  if (error is SapBusinessError) return _classifySapBusinessError(error);

  if (error is SapConfigurationException) {
    return SyncFailure(
      kind: SyncFailureKind.permanent,
      code: 'ERR_CONFIG',
      message: error.message,
    );
  }

  if (error is DioException) return _classifyDio(error);

  if (error is SocketException || error is HttpException) {
    return const SyncFailure(
      kind: SyncFailureKind.transient,
      code: 'ERR_NETWORK',
      message: 'Không có kết nối tới SAP. Sẽ tự động thử lại.',
    );
  }

  return SyncFailure(
    kind: SyncFailureKind.permanent,
    code: 'ERR_UNKNOWN',
    message: 'Lỗi không xác định: $error',
  );
}

SyncFailure _classifyDio(DioException error) {
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.transformTimeout:
      // A timeout does NOT mean SAP rejected the write — it may well have
      // committed and lost the response. Retrying is only safe because every
      // payload carries an idempotency key that SAP de-duplicates on.
      return const SyncFailure(
        kind: SyncFailureKind.transient,
        code: 'ERR_TIMEOUT',
        message: 'SAP không phản hồi kịp. Sẽ tự động thử lại.',
      );

    case DioExceptionType.connectionError:
      return const SyncFailure(
        kind: SyncFailureKind.transient,
        code: 'ERR_NETWORK',
        message: 'Mất kết nối mạng. Sẽ tự động thử lại khi có mạng.',
      );

    case DioExceptionType.cancel:
      return const SyncFailure(
        kind: SyncFailureKind.transient,
        code: 'ERR_CANCELLED',
        message: 'Yêu cầu bị hủy. Sẽ thử lại.',
      );

    case DioExceptionType.badCertificate:
      // Retrying a rejected certificate on the same host produces the same
      // rejection; this needs an operator, not a backoff timer.
      return const SyncFailure(
        kind: SyncFailureKind.permanent,
        code: 'ERR_TLS',
        message: 'Chứng chỉ SAP không hợp lệ. Liên hệ quản trị hệ thống.',
      );

    case DioExceptionType.badResponse:
      return _classifyStatus(error.response?.statusCode, error);

    case DioExceptionType.unknown:
      // Dio funnels raw socket failures here on some platforms. Treat an
      // unlabelled failure as network trouble rather than burning the record.
      return const SyncFailure(
        kind: SyncFailureKind.transient,
        code: 'ERR_NETWORK',
        message: 'Không gửi được tới SAP. Sẽ tự động thử lại.',
      );
  }
}

SyncFailure _classifyStatus(int? status, DioException error) {
  if (status == null) {
    return const SyncFailure(
      kind: SyncFailureKind.transient,
      code: 'ERR_NETWORK',
      message: 'SAP không trả về mã trạng thái. Sẽ tự động thử lại.',
    );
  }

  final code = 'HTTP_$status';

  if (status == 401 || status == 403) {
    return SyncFailure(
      kind: SyncFailureKind.auth,
      code: code,
      message: 'Phiên SAP đã hết hạn. Đang xác thực lại.',
    );
  }

  // 408 Request Timeout and 429 Too Many Requests are explicit "come back
  // later" answers, not rejections.
  if (status == 408 || status == 429) {
    return SyncFailure(
      kind: SyncFailureKind.transient,
      code: code,
      message: 'SAP đang bận. Sẽ tự động thử lại.',
    );
  }

  if (status >= 500) {
    return SyncFailure(
      kind: SyncFailureKind.transient,
      code: code,
      message: 'SAP gặp sự cố ($status). Sẽ tự động thử lại.',
    );
  }

  if (status >= 400) {
    return SyncFailure(
      kind: SyncFailureKind.permanent,
      code: code,
      message: _sapErrorMessage(error) ?? 'SAP từ chối bản ghi (mã $status).',
    );
  }

  return SyncFailure(
    kind: SyncFailureKind.permanent,
    code: code,
    message: 'SAP trả về mã không mong đợi ($status).',
  );
}

/// Digs the human-readable reason out of an OData error envelope.
///
/// SAP nests it as `{"error": {"message": {"value": "..."}}}`; older services
/// flatten `message` to a plain string.
String? _sapErrorMessage(DioException error) => odataErrorMessage(error);

// ─── ZUI_PP_OPALLOC / ZUI_MOB_AUTH business-code vocabulary ────────────────
//
// This backend answers EVERY rejection — auth, live-guard, business-rule —
// with the same HTTP 400 and puts the actual reason in the error message as a
// short machine code (see zcl_mob_token_validator, zcl_pp_operation_guard,
// zbp_r_pp_opalloc's report_failure calls). The generic status-based
// classification above would bucket all of these as `permanent`, which is
// wrong for a token that just needs a refresh — hence this table.

/// Codes that mean "the access token is stale" — refreshable, so the engine
/// retries via [SyncFailureKind.auth] rather than giving up.
const Set<String> _sapRefreshableAuthCodes = {'TOKEN_INVALID_OR_EXPIRED'};

/// `SYNC_RECEIPT_NOT_FOUND` / `SYNC_RECEIPT_DUPLICATE` are deliberately absent
/// here: resolving them needs an extra `getSyncStatus` call, which only the
/// gateway itself can make (see `SapPpOpAllocGateway`) — by the time an error
/// reaches this function, that reconciliation has already happened.

/// Friendly Vietnamese text for the codes worth explaining specifically.
/// Anything else falls back to a generic "SAP đã từ chối" message that still
/// carries the raw code for a supervisor to search on.
const Map<String, String> _sapBusinessMessages = {
  'AUTH_FAILED': 'Không thể xác thực phiên đăng nhập. Vui lòng đăng nhập lại.',
  'DEVICE_MISMATCH':
      'Token không thuộc thiết bị này. Vui lòng đăng nhập lại trên thiết bị này.',
  'USER_INACTIVE': 'Tài khoản đã bị vô hiệu hoá trên SAP.',
  'PASSWORD_CHANGE_REQUIRED': 'Tài khoản cần đổi mật khẩu trước khi tiếp tục.',
  'MISSING_PERMISSION': 'Tài khoản không có quyền thực hiện thao tác này.',
  'WORKER_AUTH_FAILED': 'Mật khẩu xác nhận của công nhân không đúng.',
  'SYNC_ITEM_REQUIRED': 'Thiếu mã đồng bộ trong yêu cầu (lỗi ứng dụng).',
  'BUSINESS_VALIDATION_FAILED':
      'SAP từ chối bản ghi do vi phạm quy tắc nghiệp vụ (số lượng, trạng thái...).',
  'MANUFACTURING_ORDER_NOT_FOUND': 'Không tìm thấy lệnh sản xuất trên SAP.',
  'MANUFACTURING_ORDER_NOT_RELEASED':
      'Lệnh sản xuất chưa release hoặc đã đóng trên SAP.',
  'MANUFACTURING_OPERATION_NOT_FOUND':
      'Không tìm thấy công đoạn trên lệnh sản xuất.',
  'MANUFACTURING_OPERATION_AMBIGUOUS':
      'Công đoạn không xác định duy nhất trên SAP.',
  'OPERATION_CONTROL_PROFILE_INVALID':
      'Công đoạn không thuộc control profile hợp lệ (YBP1).',
  'OPERATION_MARKED_FOR_DELETION': 'Công đoạn đã bị đánh dấu xoá trên SAP.',
  'OPERATION_STANDARD_TEXT_REQUIRED':
      'Công đoạn thiếu mã công đoạn chuẩn trên SAP.',
  'OPERATION_MASTER_DATA_INCOMPLETE': 'Dữ liệu công đoạn trên SAP chưa đầy đủ.',
  'WORK_CENTER_NOT_FOUND':
      'Không tìm thấy nơi làm việc (Work Center) trên SAP.',
  'WORK_CENTER_AMBIGUOUS': 'Work Center không xác định duy nhất trên SAP.',
  'ORDER_OPERATION_REQUIRED': 'Thiếu số lệnh sản xuất hoặc công đoạn.',
  'OPERATION_SNAPSHOT_DUPLICATE':
      'Dữ liệu công đoạn bị trùng lặp trên SAP — cần kiểm tra thủ công.',
  'OPERATION_SNAPSHOT_CREATE_FAILED':
      'Không tạo được snapshot công đoạn trên SAP.',
  'OPERATION_SNAPSHOT_UPDATE_FAILED':
      'Không cập nhật được snapshot công đoạn trên SAP.',
};

SyncFailure _classifySapBusinessError(SapBusinessError error) {
  if (_sapRefreshableAuthCodes.contains(error.code)) {
    return SyncFailure(
      kind: SyncFailureKind.auth,
      code: error.code,
      message: 'Phiên SAP đã hết hạn. Đang làm mới và thử lại.',
    );
  }

  return SyncFailure(
    kind: SyncFailureKind.permanent,
    code: error.code,
    message:
        _sapBusinessMessages[error.code] ??
        'SAP từ chối yêu cầu (mã ${error.code}).',
  );
}

/// Exponential backoff with jitter for transient failures.
///
/// Jitter matters here: a whole shift's worth of PDAs lose Wi-Fi at the same
/// moment and would otherwise retry in lockstep, hammering SAP at each step.
class SyncBackoff {
  static const Duration base = Duration(seconds: 15);
  static const Duration max = Duration(minutes: 15);

  /// Records pending longer than this warrant a supervisor warning; they are
  /// never dropped (Spec 4.7).
  static const Duration staleAfter = Duration(hours: 24);

  final Random _random;

  SyncBackoff({Random? random}) : _random = random ?? Random();

  /// Delay before attempt number [retryCount] + 1.
  Duration delayFor(int retryCount) {
    final exponent = retryCount.clamp(0, 20);
    final rawMs = base.inMilliseconds * pow(2, exponent);
    final cappedMs = rawMs > max.inMilliseconds ? max.inMilliseconds : rawMs;
    // ±20% jitter.
    final jitter = 0.8 + _random.nextDouble() * 0.4;
    return Duration(milliseconds: (cappedMs * jitter).round());
  }

  /// Absolute epoch-ms timestamp to store in `sync_queue.next_retry_at_utc`.
  int nextRetryAtUtc(int retryCount, {DateTime? now}) {
    final from = now ?? DateTime.now();
    return from.add(delayFor(retryCount)).millisecondsSinceEpoch;
  }
}
