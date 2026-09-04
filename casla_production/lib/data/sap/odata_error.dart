// SAP Integration — OData V4 error envelope
//
// Every mobile-facing RAP service in this backend (ZUI_MOB_AUTH,
// ZUI_PP_OPALLOC) reports a business rejection through the standard RAP
// `failed`/`reported` mechanism, which OData V4 surfaces as an HTTP error
// response body shaped like:
//
//   { "error": { "code": "...", "message": "AUTH_FAILED" } }
//
// `message` is not free text here — the ABAP handlers pass the exact business
// code as the message (`report_failure(text: 'AUTH_FAILED')`), so extracting it
// is how callers recover which specific rule rejected the request.

import 'package:dio/dio.dart';

/// Pulls the business error code/message out of an OData V4 error envelope.
///
/// Handles both the plain-string `message` form and the nested
/// `message: {value: "..."}` form some SAP stacks use; returns null for
/// anything that isn't this shape (a gateway timeout's HTML error page, a
/// malformed body) rather than throwing.
String? odataErrorMessage(DioException error) {
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

/// A parsed rejection from a mobile RAP action, once the caller knows the
/// error envelope's `message` *is* a business code from this backend rather
/// than arbitrary text (an HTML gateway error page, a generic 500).
class SapBusinessError implements Exception {
  /// The exact code the ABAP handler passed to `report_failure`, e.g.
  /// `'AUTH_FAILED'`, `'WORKER_AUTH_FAILED'`, `'BUSINESS_VALIDATION_FAILED'`.
  final String code;

  final int? httpStatus;

  const SapBusinessError(this.code, {this.httpStatus});

  @override
  String toString() => 'SapBusinessError($code, http $httpStatus)';
}

/// Converts a failed OData V4 action call into a [SapBusinessError] when the
/// response carries a recognizable business code, otherwise rethrows the
/// original [DioException] untouched so generic classification still applies.
Never rethrowAsBusinessError(DioException error) {
  final code = odataErrorMessage(error);
  if (code != null) {
    throw SapBusinessError(code, httpStatus: error.response?.statusCode);
  }
  throw error;
}

/// Unwraps a successful OData V4 action response body.
///
/// A bound action with a complex-type `ReturnType` answers with the plain
/// JSON object at the top level (plus an `@odata.context` key) — there is no
/// `d` envelope; that wrapping is OData V2 only.
Map<String, dynamic> odataActionResult(Response<dynamic> response) {
  final data = response.data;
  if (data is Map) return Map<String, dynamic>.from(data);
  throw Exception('SAP trả về phản hồi không hợp lệ.');
}
