import 'dart:convert';

/// Parsed employee identifier from an untrusted QR payload.
class WorkerQrResult {
  final bool isValid;
  final String maNv;
  final String? error;

  const WorkerQrResult({required this.isValid, required this.maNv, this.error});

  factory WorkerQrResult.invalid([String message = 'Mã QR không hợp lệ']) {
    return WorkerQrResult(isValid: false, maNv: '', error: message);
  }

  factory WorkerQrResult.success(String maNv) {
    return WorkerQrResult(isValid: true, maNv: maNv.trim());
  }
}

/// Extracts only an employee code from a QR payload.
///
/// Names, roles and team scope are never trusted from QR input; callers must
/// resolve the code against authorized master data before using it.
class WorkerQrParser {
  WorkerQrParser._();

  static WorkerQrResult parse(String rawCode) {
    final input = rawCode.trim();
    if (input.isEmpty) return WorkerQrResult.invalid();

    if (input.startsWith('{') && input.endsWith('}')) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map) {
          for (final key in const [
            'ma_nv',
            'ma_nhan_vien',
            'manv',
            'userId',
            'id',
            'code',
          ]) {
            final value = decoded[key]?.toString().trim() ?? '';
            if (_isEmployeeCode(value)) return WorkerQrResult.success(value);
          }
        }
      } on FormatException {
        return WorkerQrResult.invalid();
      }
    }

    final keyedCode = RegExp(
      r'(?:Mã nhân viên|Mã NV|MaNV|UserId|ID|Code)\s*[:=]\s*([^\n\r;|]+)',
      caseSensitive: false,
    ).firstMatch(input)?.group(1)?.trim();
    if (keyedCode != null && _isEmployeeCode(keyedCode)) {
      return WorkerQrResult.success(keyedCode);
    }

    for (final delimiter in const ['|', ';', ' - ', '\t']) {
      if (!input.contains(delimiter)) continue;
      final code = input.split(delimiter).first.trim();
      if (_isEmployeeCode(code)) return WorkerQrResult.success(code);
    }

    if (_isEmployeeCode(input)) return WorkerQrResult.success(input);
    return WorkerQrResult.invalid();
  }

  static bool _isEmployeeCode(String value) {
    return RegExp(
      r'^(?:NV\d+|MNV\d+|\d{4,10})$',
      caseSensitive: false,
    ).hasMatch(value);
  }
}
