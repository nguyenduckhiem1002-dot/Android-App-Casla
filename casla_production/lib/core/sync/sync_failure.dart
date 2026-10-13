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
const Set<String> _sapRefreshableAuthCodes = {
  'AUTH_FAILED',
  'EMPTY_TOKEN',
  'TOKEN_INVALID_OR_EXPIRED',
  'DEVICE_MISMATCH',
};

/// Backend business codes for which the operator can correct the selection or
/// refresh the balance and then send again. These are deliberately explicit:
/// a generic suffix match would accidentally make a new security or ledger
/// code retry forever.
const Set<String> _sapRetryableBusinessCodes = {
  // ExecutedAt is fixed when the work is entered while SAP's clock keeps
  // moving: a device clock running a little fast resolves itself on retry.
  'EXECUTED_AT_IN_FUTURE',
  'WORK_NOT_FOUND',
  'MANUFACTURING_ORDER_NOT_FOUND',
  'MANUFACTURING_OPERATION_NOT_FOUND',
  'MANUFACTURING_OPERATION_AMBIGUOUS',
  'OPERATION_MASTER_NOT_FOUND',
  'OPERATION_MASTER_AMBIGUOUS',
  'OPERATION_QUANTITY_EXCEEDED',
  'CONFIRM_QUANTITY_EXCEEDED',
  'SOURCE_BALANCE_INSUFFICIENT',
  'WORKER_BALANCE_NOT_FOUND',
  'REVERSE_BALANCE_INCONSISTENT',
  'CONFIRM_ORIGINAL_QUANTITY_EXCEEDED',
  'SYNC_RECEIPT_NOT_FOUND',
};

/// New RAP contract codes must win over a free-form OData message. The legacy
/// mobile-handled codes are intentionally absent so their existing behavior is
/// preserved for backward compatibility.
const Set<String> _codeFirstBusinessCodes = {
  'AUTH_FAILED',
  'EMPTY_TOKEN',
  'TOKEN_INVALID_OR_EXPIRED',
  'DEVICE_MISMATCH',
  'PASSWORD_CHANGE_REQUIRED',
  'USER_INACTIVE',
  'WORKER_AUTH_FAILED',
  'MANAGER_OPERATION_NOT_ALLOWED',
  'WORKER_OPERATION_NOT_ALLOWED',
  'WORKER_ASSIGNMENT_EXPIRED',
  'WORK_NOT_FOUND',
  'MISSING_PERMISSION',
  'WORK_CONTEXT_MISMATCH',
  'WORK_OPERATION_MISMATCH',
  'OPERATION_DEPARTMENT_MISMATCH',
  'MANUFACTURING_ORDER_NOT_FOUND',
  'MANUFACTURING_OPERATION_NOT_FOUND',
  'MANUFACTURING_OPERATION_AMBIGUOUS',
  'MANUFACTURING_ORDER_NOT_RELEASED',
  'OPERATION_MARKED_FOR_DELETION',
  'OPERATION_CONTROL_PROFILE_REQUIRED',
  'OPERATION_CONTROL_PROFILE_INVALID',
  'OPERATION_STANDARD_TEXT_REQUIRED',
  'OPERATION_MASTER_NOT_FOUND',
  'OPERATION_MASTER_AMBIGUOUS',
  'OPERATION_MASTER_DATA_INCOMPLETE',
  'SHIFT_AND_EXECUTED_AT_REQUIRED',
  'EXECUTION_DATE_REQUIRED',
  'SHIFT_CONFIG_INVALID',
  'SHIFT_CONFIG_AMBIGUOUS',
  'SHIFT_NOT_APPLICABLE',
  'SHIFT_WORK_DATE_MISMATCH',
  'OUTSIDE_SHIFT',
  'EXECUTED_AT_IN_FUTURE',
  'UNIT_OF_MEASURE_MISMATCH',
  'ALLOCATION_SCOPE_MISMATCH',
  'OPERATION_QUANTITY_EXCEEDED',
  'CONFIRM_QUANTITY_EXCEEDED',
  'SOURCE_BALANCE_INSUFFICIENT',
  'WORKER_BALANCE_NOT_FOUND',
  'WORKER_BALANCE_DUPLICATE',
  'REVERSE_BALANCE_INCONSISTENT',
  'CONFIRM_ORIGINAL_TRANSACTION_INVALID',
  'CONFIRM_ORIGINAL_QUANTITY_EXCEEDED',
  'CONFIRM_ORIGINAL_CONTEXT_MISMATCH',
  'ASSIGNMENT_GROUP_INVALID',
  'RECALL_NOT_ALLOWED',
  'RECALL_ORIGINAL_CONTEXT_MISMATCH',
  // getWorkHistory (zcl_pp_work_history).
  'OPERATION_FILTER_INCOMPLETE',
  'RANGE_INVALID',
  'RANGE_IN_FUTURE',
  'RANGE_TOO_WIDE',
  'WORKER_NOT_MAPPED',
  'RECALL_ORIGINAL_QUANTITY_EXCEEDED',
  'SYNC_ITEM_REQUIRED',
  'SYNC_RECEIPT_DUPLICATE',
  'SYNC_RECEIPT_NOT_FOUND',
  'IDEMPOTENCY_KEY_REUSED',
  'TRANSACTION_ALREADY_REVERSED',
  'NOTHING_TO_REVERSE',
  'ORIGINAL_TRANSACTION_INVALID',
  'ORIGINAL_TRANSACTION_TYPE_INVALID',
  'ORIGINAL_TRANSACTION_WORKER_MISMATCH',
};

/// Failures of a live submit where the device got no clear answer from SAP:
/// the request timed out, never reached SAP, or SAP may have committed it
/// without the device seeing the receipt. Only these keep the transaction on
/// the device (holding its quantity) and park it on the Đồng bộ tab.
///
/// Every other failure is an answer SAP actually gave — wrong worker password,
/// inactive account, missing authority, quantity exceeded, ... Nothing was
/// committed, so the live write is rolled back and reported in a red popup
/// instead of holding quantity for a record nobody can send.
const Set<String> liveDeliveryHoldCodes = {
  'ERR_TIMEOUT',
  'HTTP_408',
  'HTTP_504',
  // The request did not reach SAP (network down, gateway could not forward).
  'ERR_NETWORK',
  'ERR_CANCELLED',
  'ERR_TLS',
  'ERR_CONFIG',
  'HTTP_502',
  'HTTP_503',
  // SAP may have committed; the receipt must be reconciled, never dropped.
  'SYNC_RECEIPT_NOT_FOUND',
  'SYNC_RECEIPT_DUPLICATE',
  // Local failure with no SAP answer (e.g. an unreadable response after the
  // write may have landed) — ambiguous, so hold rather than drop.
  'ERR_UNKNOWN',
  'NEEDS_WORKER_VERIFICATION',
};

/// Whether a live submit refused with [code] is rolled back on the device.
bool isLiveRejectionDiscarded(String? code) =>
    code != null && !liveDeliveryHoldCodes.contains(code);

/// Receipt ambiguity is normally reconciled by the gateway. The codes remain
/// in the vocabulary as a safe fallback if a response reaches this classifier
/// before that reconciliation completes.

/// Friendly Vietnamese text for the codes worth explaining specifically.
/// Anything else falls back to a generic "SAP đã từ chối" message that still
/// carries the raw code for a supervisor to search on.
const Map<String, String> _sapBusinessMessages = {
  'SAP_SHIFT_CONTRACT_OUTDATED':
      'API phân công trên SAP chưa được publish với tham số ca làm việc. '
      'Hãy activate và publish lại service binding ZAPI_PP_OPALLOC; giao dịch vẫn được giữ trên thiết bị.',
  'SAP_PAYLOAD_FORMAT_ERROR':
      'SAP không đọc được định dạng dữ liệu gửi lên. '
      'Cần kiểm tra phiên bản ứng dụng và hợp đồng API; giao dịch vẫn được giữ trên thiết bị.',
  'SABP_BEHV/100':
      'SAP gặp lỗi khi xử lý lịch sử giao việc. Vui lòng thử lại; nếu lỗi tiếp tục, '
      'quản trị viên cần kiểm tra log ST22 trên SAP.',
  'DEVICE_MISMATCH':
      'Token không thuộc thiết bị này. Vui lòng đăng nhập lại trên thiết bị này.',
  'MISSING_PERMISSION': 'Tài khoản không có quyền thực hiện chức năng này.',
  'WORKER_AUTH_FAILED': 'Mật khẩu xác nhận của công nhân không đúng.',
  'AUTH_FAILED': 'Không thể xác thực yêu cầu. Vui lòng đăng nhập lại.',
  'EMPTY_TOKEN': 'Phiên đăng nhập không hợp lệ. Vui lòng đăng nhập lại.',
  'TOKEN_INVALID_OR_EXPIRED':
      'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.',
  'PASSWORD_CHANGE_REQUIRED': 'Tài khoản cần đổi mật khẩu trước khi tiếp tục.',
  'USER_INACTIVE': 'Tài khoản đã bị khóa hoặc ngừng hoạt động trên SAP.',
  'MANAGER_OPERATION_NOT_ALLOWED':
      'Quản lý không có quyền với công đoạn trong phiên làm việc này.',
  'WORKER_OPERATION_NOT_ALLOWED':
      'Công nhân không có quyền với bộ phận của công đoạn.',
  'WORKER_ASSIGNMENT_EXPIRED':
      'Phân công của công nhân đã hết hiệu lực trong ngày làm việc.',
  'WORK_NOT_FOUND': 'Không tìm thấy phiên làm việc. Vui lòng chọn lại.',
  // submitInitialAssign/Confirm/Recall with a PositionID that has no active
  // row in the operation's Work Center (docs/POSITION_MANAGEMENT.md).
  'POSITION_NOT_ACTIVE':
      'Vị trí chưa tồn tại trên hệ thống. Vui lòng tạo ở phần Vị trí.',
  // Proposed for submitInitialAssign: a top-up whose PositionID differs from
  // the one its assignment group already uses. The form checks this before
  // sending; SAP has to refuse it too for other devices and queued writes.
  'POSITION_GROUP_MISMATCH':
      'Tồn tại phân công của lệnh, công đoạn tại vị trí khác.',
  'WORK_OPERATION_MISMATCH':
      'Vị trí làm việc không khớp với công đoạn. Vui lòng chọn lại.',
  'OPERATION_DEPARTMENT_MISMATCH':
      'Bộ phận của công đoạn không khớp cấu hình vị trí làm việc.',
  'WORK_CONTEXT_NOT_ALLOWED':
      'Công đoạn được giao không thuộc phiên làm việc được chọn.',
  'WORKER_NOT_ALLOWED':
      'Công đoạn được giao không thuộc phiên làm việc được chọn.',
  'WORK_CONTEXT_MISMATCH':
      'Công đoạn được giao không thuộc phiên làm việc được chọn.',
  'WORK_CONTEXT_REQUIRED': 'Chưa chọn bộ phận làm việc cho thao tác này.',
  'INVALID_PARAMETER': 'Thông tin công đoạn hoặc ca làm việc không hợp lệ.',
  'OPERATION_NOT_ALLOWED': 'Công đoạn không thuộc bộ phận hoặc ca đang chọn.',
  'OPERATION_ACCESS_DENIED': 'Công đoạn không thuộc bộ phận hoặc ca đang chọn.',
  'UNIT_OF_MEASURE_MISMATCH':
      'Đơn vị số lượng không khớp với đơn vị của công đoạn trên SAP.',
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
  'OPERATION_CONTROL_PROFILE_REQUIRED':
      'Công đoạn đang thiếu control key trên SAP.',
  'OPERATION_MARKED_FOR_DELETION': 'Công đoạn đã bị đánh dấu xoá trên SAP.',
  'OPERATION_STANDARD_TEXT_REQUIRED':
      'Công đoạn thiếu mã công đoạn chuẩn trên SAP.',
  'OPERATION_MASTER_NOT_FOUND':
      'Công đoạn chưa được khai báo trong dữ liệu master SAP.',
  'OPERATION_MASTER_AMBIGUOUS':
      'Dữ liệu master công đoạn trên SAP chưa xác định duy nhất.',
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
  'SHIFT_AND_EXECUTED_AT_REQUIRED':
      'Thiếu ca làm việc hoặc thời điểm thực hiện.',
  'EXECUTION_DATE_REQUIRED': 'Thiếu ngày thực hiện.',
  'SHIFT_CONFIG_INVALID': 'Cấu hình ca làm việc không hợp lệ trên SAP.',
  'SHIFT_CONFIG_AMBIGUOUS': 'Có nhiều cấu hình ca cùng hiệu lực trên SAP.',
  'SHIFT_NOT_APPLICABLE':
      'Ca không áp dụng cho thời điểm tạo giao dịch đã lưu. Kiểm tra giờ ca và thời điểm giao dịch; nhập lại mật khẩu không sửa được lỗi này.'
      ' Nếu đây là giao dịch nhập bù sau giờ kết thúc ca: SAP hiện chưa cho phép nhập sau ca, cần cập nhật phía SAP.',
  'SHIFT_WORK_DATE_MISMATCH':
      'Ngày làm việc đã lưu không khớp ngày của ca tại thời điểm tạo giao dịch. Đổi ca/ngày trong cài đặt không thay đổi bản ghi cũ. Hãy kiểm tra ngày và thời điểm giao dịch.',
  'OUTSIDE_SHIFT':
      'Thời điểm tạo giao dịch đã lưu nằm ngoài giờ ca. Kiểm tra cấu hình ca và thời điểm giao dịch.'
      ' Nếu đây là giao dịch nhập bù sau giờ kết thúc ca: SAP hiện chưa cho phép nhập sau ca, cần cập nhật phía SAP.',
  'EXECUTED_AT_IN_FUTURE':
      'Giờ trên máy đang nhanh hơn giờ SAP. Giao dịch sẽ tự gửi lại sau ít '
      'phút.',
  'ALLOCATION_SCOPE_MISMATCH':
      'Lần giao gốc thuộc bộ phận, ca hoặc ngày làm việc khác với giao dịch '
      'này. Hãy chọn đúng ca và bộ phận của lần giao rồi thử lại.',
  'OPERATION_QUANTITY_EXCEEDED':
      'Tổng giao vượt sản lượng công đoạn. Vui lòng cập nhật số dư.',
  'CONFIRM_QUANTITY_EXCEEDED':
      'Số lượng xác nhận vượt số dư công nhân. Vui lòng cập nhật lại.',
  'SOURCE_BALANCE_INSUFFICIENT': 'Số dư nguồn không đủ để thực hiện giao dịch.',
  'WORKER_BALANCE_NOT_FOUND':
      'Công nhân chưa có phân bổ để xác nhận hoặc thu hồi.',
  'WORKER_BALANCE_DUPLICATE':
      'Có nhiều số dư cho cùng công nhân và công đoạn. Vui lòng báo quản trị.',
  'REVERSE_BALANCE_INCONSISTENT':
      'Số dư không nhất quán khi hoàn tác. Vui lòng báo quản trị.',
  'CONFIRM_ORIGINAL_TRANSACTION_INVALID':
      'Giao dịch gốc không hợp lệ để xác nhận.',
  'CONFIRM_ORIGINAL_QUANTITY_EXCEEDED':
      'Xác nhận vượt số lượng còn lại của nhóm giao (gồm tồn từ ngày trước và '
      'phần giao bổ sung). Vui lòng tải lại số còn lại.',
  'CONFIRM_ORIGINAL_CONTEXT_MISMATCH':
      'Bộ phận hoặc ca đang chọn khác với nhóm giao gốc. Hãy chọn đúng ca và '
      'bộ phận của lần giao.',
  'ASSIGNMENT_GROUP_INVALID':
      'Nhóm giao trong ngày có liên kết giao dịch gốc không hợp lệ. Dừng giao '
      'bổ sung và báo quản trị kiểm tra dữ liệu.',
  'RECALL_NOT_ALLOWED':
      'Không thể thu hồi theo giao dịch gốc này hoặc số dư công nhân không đủ.',
  'OPERATION_FILTER_INCOMPLETE': 'Bộ lọc cần cả lệnh sản xuất và mã công đoạn.',
  'RANGE_INVALID': 'Khoảng ngày xem lịch sử không hợp lệ.',
  'RANGE_IN_FUTURE':
      'Ngày xem lịch sử vượt quá ngày hiện tại trên SAP. Hãy chọn ngày trước '
      'đó hoặc thử lại sau ít phút.',
  'RANGE_TOO_WIDE':
      'Khoảng ngày quá dài (SAP cho tối đa 92 ngày một lần xem). Hãy chọn '
      'khoảng ngắn hơn.',
  'WORKER_NOT_MAPPED':
      'Tài khoản chưa được gắn mã công nhân trên SAP. Liên hệ quản trị.',
  'RECALL_ORIGINAL_CONTEXT_MISMATCH':
      'Bộ phận hoặc ca đang chọn khác với nhóm giao gốc. Hãy chọn đúng ca và '
      'bộ phận của lần giao rồi thu hồi.',
  'RECALL_ORIGINAL_QUANTITY_EXCEEDED':
      'Thu hồi vượt số lượng còn lại của nhóm giao. Vui lòng tải lại số còn lại.',
  'SYNC_RECEIPT_DUPLICATE':
      'Giao dịch đồng bộ đã có nhiều receipt. Không gửi lại.',
  'SYNC_RECEIPT_NOT_FOUND':
      'Chưa xác nhận được receipt. Ứng dụng sẽ kiểm tra lại trạng thái.',
  'IDEMPOTENCY_KEY_REUSED':
      'Khóa đồng bộ đã được dùng cho dữ liệu khác. Vui lòng tạo giao dịch mới.',
  'TRANSACTION_ALREADY_REVERSED': 'Giao dịch này đã được hoàn tác.',
  'NOTHING_TO_REVERSE': 'Không có giao dịch hợp lệ để hoàn tác.',
  'ORIGINAL_TRANSACTION_INVALID':
      'Giao dịch gốc không tồn tại hoặc không hợp lệ.',
  'ORIGINAL_TRANSACTION_TYPE_INVALID':
      'Loại giao dịch gốc không được phép trong flow này.',
  'ORIGINAL_TRANSACTION_WORKER_MISMATCH': 'Giao dịch gốc thuộc công nhân khác.',
};

/// Converts known SAP business codes and local exceptions into safe UI text.
/// Raw OData payloads, tokens and password values are never shown to users.
String _sapBusinessMessage(SapBusinessError error) {
  final mapped = _sapBusinessMessages[error.code];
  final nestedCode = error.message?.trim();
  final nestedMapped = nestedCode == null
      ? null
      : _sapBusinessMessages[nestedCode];
  if (_codeFirstBusinessCodes.contains(error.code)) {
    return mapped ??
        nestedMapped ??
        error.message ??
        'SAP từ chối yêu cầu (mã ${error.code}).';
  }
  return nestedMapped ??
      error.message ??
      mapped ??
      'SAP từ chối yêu cầu (mã ${error.code}).';
}

String friendlySapErrorMessage(Object error) {
  if (error is SapBusinessError) {
    return _sapBusinessMessage(error);
  }
  return error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
}

SyncFailure _classifySapBusinessError(SapBusinessError error) {
  final nestedCode = error.message?.trim();
  final effective =
      !_codeFirstBusinessCodes.contains(error.code) &&
          nestedCode != null &&
          _sapBusinessMessages.containsKey(nestedCode)
      ? SapBusinessError(
          nestedCode,
          httpStatus: error.httpStatus,
          message: error.message,
        )
      : error;

  if (_sapRefreshableAuthCodes.contains(effective.code)) {
    return SyncFailure(
      kind: SyncFailureKind.auth,
      code: effective.code,
      message: _sapBusinessMessage(effective),
    );
  }

  // A wrong worker password does not invalidate the business transaction.
  // Automatic retry still cannot help, but a human can immediately recover by
  // entering the correct password on S12, so surface it as verification work
  // rather than an irreversible rejection.
  if (effective.code == 'WORKER_AUTH_FAILED') {
    return SyncFailure(
      kind: SyncFailureKind.needsVerification,
      code: effective.code,
      message: _sapBusinessMessage(effective),
    );
  }

  if (_sapRetryableBusinessCodes.contains(effective.code)) {
    return SyncFailure(
      kind: SyncFailureKind.transient,
      code: effective.code,
      message: _sapBusinessMessage(effective),
    );
  }

  return SyncFailure(
    kind: SyncFailureKind.permanent,
    code: effective.code,
    message: _sapBusinessMessage(effective),
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
