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

  bool get isRetryable => kind != SyncFailureKind.permanent;

  @override
  String toString() => 'SyncFailure($kind, $code, $message)';
}

/// Maps a thrown error onto a [SyncFailure].
///
/// Defaults lean toward [SyncFailureKind.transient] for anything network-shaped
/// and [SyncFailureKind.permanent] for anything SAP answered deliberately.
/// Guessing "transient" on a real rejection only delays the failure; guessing
/// "permanent" on a flaky connection loses a day of production data.
SyncFailure classifySyncError(Object error) {
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
String? _sapErrorMessage(DioException error) {
  final data = error.response?.data;
  if (data is! Map) return null;

  final errorNode = data['error'];
  if (errorNode is! Map) return null;

  final message = errorNode['message'];
  if (message is String && message.trim().isNotEmpty) return message.trim();
  if (message is Map) {
    final value = message['value'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
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
