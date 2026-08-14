// SAP Integration — OData Input Sanitizer
// Security: Prevents OData injection by escaping special characters
// in user-provided values before embedding in OData query parameters.

/// Escapes a string value for safe use inside OData single-quoted parameters.
///
/// OData string literals are wrapped in single quotes: `'value'`.
/// If the value itself contains a single quote, it must be doubled: `''`.
/// This prevents injection of OData query operators or path segments.
///
/// Example:
///   sanitizeODataValue("O'Brien") → "O''Brien"
///   sanitizeODataValue("admin'; DROP TABLE--") → "admin''; DROP TABLE--"
class ODataSanitizer {
  ODataSanitizer._();

  /// Escape single quotes for OData string parameters.
  /// SAP OData uses `''` to represent a literal single quote inside a string.
  static String escapeValue(String value) {
    return value.replaceAll("'", "''");
  }

  /// Validate and sanitize a UUID string (only hex digits and dashes allowed).
  static String sanitizeUuid(String uuid) {
    final cleaned = uuid.replaceAll(RegExp(r"['\s]"), '');
    if (!RegExp(r'^[0-9a-fA-F\-]+$').hasMatch(cleaned)) {
      throw ArgumentError('Invalid UUID format: $uuid');
    }
    return cleaned;
  }
}
