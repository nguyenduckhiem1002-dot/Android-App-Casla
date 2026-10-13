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

import 'dart:convert';

import 'package:dio/dio.dart';

Map<dynamic, dynamic>? _odataErrorEnvelope(DioException error) {
  Object? data = error.response?.data;
  if (data is String) {
    final text = data.trim();
    if (text.startsWith('{')) {
      try {
        data = jsonDecode(text);
      } on FormatException {
        return null;
      }
    }
  }
  return data is Map ? data : null;
}

/// Pulls the business error code/message out of an OData V4 error envelope.
///
/// Handles both the plain-string `message` form and the nested
/// `message: {value: "..."}` form some SAP stacks use; returns null for
/// anything that isn't this shape (a gateway timeout's HTML error page, a
/// malformed body) rather than throwing.
String? odataErrorMessage(DioException error) {
  final data = _odataErrorEnvelope(error);
  if (data == null) return null;

  final errorNode = data['error'];
  if (errorNode is! Map) return null;

  final message = errorNode['message'];
  String? raw;
  if (message is String && message.trim().isNotEmpty) raw = message.trim();
  if (message is Map) {
    final value = message['value'];
    if (value is String && value.trim().isNotEmpty) raw = value.trim();
  }
  // RAP can put the actionable `%msg` in `details`/`innererror` while the
  // top-level message remains the generic `SABP_BEHV/100` text. Recover the
  // stable machine code from nested reported/failed entries as well.
  final nestedCode = _findNestedBusinessCode(errorNode);
  if (nestedCode != null) return nestedCode;
  if (raw == null) return null;

  // SAP business codes are returned as the complete message. Do not extract
  // an uppercase suffix: ordinary text often ends with words such as `SAP`
  // or field names such as `WorkerID`.
  return raw;
}

String? _findNestedBusinessCode(Map<dynamic, dynamic> errorNode) {
  Object? walk(Object? value, {bool root = false}) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key?.toString().toLowerCase() ?? '';
        final child = entry.value;
        if (!root && (key == 'code' || key == 'message' || key == '%msg')) {
          final text = child is Map ? child['value'] : child;
          if (text is String &&
              RegExp(r'^[A-Z][A-Z0-9_]{2,80}$').hasMatch(text.trim())) {
            return text.trim();
          }
        }
        final found = walk(child);
        if (found is String) return found;
      }
    } else if (value is Iterable) {
      for (final child in value) {
        final found = walk(child);
        if (found is String) return found;
      }
    }
    return null;
  }

  // Skip the top-level `error.code` (usually `SABP_BEHV/100`) and inspect its
  // reported/failed details for the business code.
  for (final entry in errorNode.entries) {
    if (entry.key?.toString().toLowerCase() == 'code') continue;
    final found = walk(entry.value);
    if (found is String) return found;
  }
  return null;
}

String? _odataErrorCode(DioException error) {
  final data = _odataErrorEnvelope(error);
  final errorNode = data?['error'];
  if (errorNode is! Map) return null;
  final code = errorNode['code']?.toString().trim();
  return code == null || code.isEmpty ? null : code;
}

Iterable<String> _errorTexts(Object? value) sync* {
  if (value is String) {
    yield value;
  } else if (value is Map) {
    for (final child in value.values) {
      yield* _errorTexts(child);
    }
  } else if (value is Iterable) {
    for (final child in value) {
      yield* _errorTexts(child);
    }
  }
}

bool _isOutdatedShiftContract(DioException error) {
  final data = _odataErrorEnvelope(error);
  if (data == null) return false;
  for (final text in _errorTexts(data['error'])) {
    final normalized = text.toLowerCase();
    final mentionsNewField =
        normalized.contains('shiftid') || normalized.contains('executedat');
    final rejectsField =
        normalized.contains('does not exist') ||
        normalized.contains('not found') ||
        normalized.contains('not defined') ||
        normalized.contains('not allowed') ||
        normalized.contains('unknown') ||
        normalized.contains('unexpected') ||
        normalized.contains('invalid parameter') ||
        normalized.contains('invalid property');
    if (mentionsNewField && rejectsField) return true;
  }
  return false;
}

/// A bounded, secret-free diagnosis suitable for logs and support reports.
/// Never returns the raw response message because Gateway errors may echo
/// request values. Known business codes and technical OData codes are safe.
String? odataSafeDiagnostic(DioException error) {
  if (_isOutdatedShiftContract(error)) return 'SAP_SHIFT_CONTRACT_OUTDATED';

  final message = odataErrorMessage(error);
  if (message != null && RegExp(r'^[A-Z][A-Z0-9_]{2,80}$').hasMatch(message)) {
    return message;
  }

  final code = _odataErrorCode(error);
  if (code != null &&
      code.length <= 120 &&
      RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(code)) {
    return code;
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
  final String? message;

  const SapBusinessError(this.code, {this.httpStatus, this.message});

  @override
  String toString() => 'SapBusinessError($code, http $httpStatus)';
}

/// Converts a failed OData V4 action call into a [SapBusinessError] when the
/// response carries a recognizable business code, otherwise rethrows the
/// original [DioException] untouched so generic classification still applies.
Never rethrowAsBusinessError(DioException error) {
  if (_isOutdatedShiftContract(error)) {
    throw SapBusinessError(
      'SAP_SHIFT_CONTRACT_OUTDATED',
      httpStatus: error.response?.statusCode,
    );
  }
  final code = odataErrorMessage(error);
  // This Gateway parser message is technical, not an ABAP business code.
  // Keep diagnostics stable without showing raw server text as a worker error.
  if (code == 'Error while parsing an XML stream') {
    throw SapBusinessError(
      'SAP_PAYLOAD_FORMAT_ERROR',
      httpStatus: error.response?.statusCode,
    );
  }
  if (code != null && RegExp(r'^[A-Z][A-Z0-9_]{2,80}$').hasMatch(code)) {
    throw SapBusinessError(code, httpStatus: error.response?.statusCode);
  }
  if (code != null) {
    throw SapBusinessError(
      _odataErrorCode(error) ??
          'SAP_HTTP_${error.response?.statusCode ?? 'ERROR'}',
      httpStatus: error.response?.statusCode,
      message: code,
    );
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
