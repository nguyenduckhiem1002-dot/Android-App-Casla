import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Writes decoded QR values to the Flutter run console for local debugging.
/// Credentials are removed recursively before anything reaches logcat.
void logScanPayload(String payload, {required String source}) {
  if (!kDebugMode) return;

  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException {
    // Some printed SAP labels encode fields as delimited/plain text instead
    // of JSON. Keep their content visible in debug builds so parser failures
    // can be diagnosed from the PDA terminal just like JSON QR payloads.
    final safeText = payload
        .replaceAll(_sensitiveField, r'$1[REDACTED]')
        .replaceAll('\r', r'\r')
        .replaceAll('\n', r'\n');
    debugPrint(
      'QR_PAYLOAD source=$source nonJson length=${payload.length} value=$safeText',
    );
    return;
  }

  final safeValue = _redactSecrets(decoded);
  final formatted = const JsonEncoder.withIndent('  ').convert(safeValue);
  debugPrint('QR_PAYLOAD source=$source\n$formatted');
}

Object? _redactSecrets(Object? value) {
  if (value is Map) {
    return value.map((key, nestedValue) {
      final name = key.toString();
      return MapEntry(
        name,
        _sensitiveKey.hasMatch(name)
            ? '[REDACTED]'
            : _redactSecrets(nestedValue),
      );
    });
  }
  if (value is List) return value.map(_redactSecrets).toList(growable: false);
  return value;
}

final RegExp _sensitiveKey = RegExp(
  r'(password|passwd|pwd|token|authorization|secret|credential|api[_-]?key)',
  caseSensitive: false,
);

final RegExp _sensitiveField = RegExp(
  r'((?:password|passwd|pwd|token|authorization|secret|credential|api[_-]?key)\s*[:=]\s*)([^,;|\r\n]+)',
  caseSensitive: false,
);
