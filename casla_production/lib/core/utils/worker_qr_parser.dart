import 'dart:convert';

/// Parsed employee identifier from an untrusted QR payload.
class WorkerQrResult {
  final bool isValid;
  final String maNv;
  final DateTime? validFrom;
  final DateTime? validTo;
  final String? error;

  const WorkerQrResult({
    required this.isValid,
    required this.maNv,
    this.validFrom,
    this.validTo,
    this.error,
  });

  factory WorkerQrResult.invalid([String message = 'Mã QR không hợp lệ']) {
    return WorkerQrResult(isValid: false, maNv: '', error: message);
  }

  factory WorkerQrResult.success(
    String maNv, {
    DateTime? validFrom,
    DateTime? validTo,
  }) {
    return WorkerQrResult(
      isValid: true,
      maNv: maNv.trim(),
      validFrom: validFrom,
      validTo: validTo,
    );
  }

  bool isEffectiveOn(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    final startsBeforeOrOn = validFrom == null || !day.isBefore(validFrom!);
    final endsAfterOrOn = validTo == null || !day.isAfter(validTo!);
    return startsBeforeOrOn && endsAfterOrOn;
  }
}

/// Extracts only an employee code from a QR payload.
///
/// Names, roles and team scope are never trusted from QR input; callers must
/// resolve the code against authorized master data before using it.
class WorkerQrParser {
  WorkerQrParser._();

  /// Above the practical payload size used by worker QR codes, while bounding
  /// JSON/regex work for untrusted camera, manual and hardware input.
  static const int maxInputCharacters = 4096;

  static WorkerQrResult parse(String rawCode) {
    if (rawCode.length > maxInputCharacters || rawCode.contains('\u0000')) {
      return WorkerQrResult.invalid();
    }

    final input = rawCode.trim();
    if (input.isEmpty) return WorkerQrResult.invalid();

    if (input.startsWith('{') && input.endsWith('}')) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map) {
          return _fromFields(decoded);
        }
      } on FormatException {
        return WorkerQrResult.invalid();
      }
    }

    final keyedFields = <String, String>{};
    final pairPattern = RegExp(
      r'([^:=|;\n\r]{1,40})\s*[:=]\s*([^|;\n\r]+)',
      caseSensitive: false,
    );
    for (final match in pairPattern.allMatches(input)) {
      keyedFields[match.group(1)!.trim()] = match.group(2)!.trim();
    }
    if (keyedFields.isNotEmpty) {
      final parsed = _fromFields(keyedFields);
      if (parsed.isValid) return parsed;
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

  static WorkerQrResult _fromFields(Map fields) {
    final normalized = <String, dynamic>{};
    for (final entry in fields.entries) {
      normalized[_normalizeKey(entry.key.toString())] = entry.value;
    }

    final maNv = _firstValue(normalized, const [
      'manv',
      'manhanvien',
      'userid',
      'workerid',
      'id',
      'code',
      'mãnv',
      'mãnhânviên',
    ]);
    if (!_isEmployeeCode(maNv)) return WorkerQrResult.invalid();

    final from = _readDate(
      normalized,
      const [
        'validfrom',
        'fromdate',
        'ngayhieuluc',
        'tungay',
        'ngaybatdau',
      ],
    );
    final to = _readDate(
      normalized,
      const [
        'validto',
        'todate',
        'enddate',
        'ngayhethieuluc',
        'denngay',
        'ngayketthuc',
      ],
    );
    if (from.invalid || to.invalid) {
      return WorkerQrResult.invalid('Ngày hiệu lực trên mã QR không hợp lệ');
    }
    if (from.value != null && to.value != null && from.value!.isAfter(to.value!)) {
      return WorkerQrResult.invalid('Khoảng ngày hiệu lực trên mã QR không hợp lệ');
    }

    return WorkerQrResult.success(
      maNv,
      validFrom: from.value,
      validTo: to.value,
    );
  }

  static String _normalizeKey(String key) {
    var value = key.toLowerCase();
    const accents = {
      'á': 'a', 'à': 'a', 'ả': 'a', 'ã': 'a', 'ạ': 'a', 'ă': 'a',
      'ắ': 'a', 'ằ': 'a', 'ẳ': 'a', 'ẵ': 'a', 'ặ': 'a', 'â': 'a',
      'ấ': 'a', 'ầ': 'a', 'ẩ': 'a', 'ẫ': 'a', 'ậ': 'a', 'đ': 'd',
      'é': 'e', 'è': 'e', 'ẻ': 'e', 'ẽ': 'e', 'ẹ': 'e', 'ê': 'e',
      'ế': 'e', 'ề': 'e', 'ể': 'e', 'ễ': 'e', 'ệ': 'e', 'í': 'i',
      'ì': 'i', 'ỉ': 'i', 'ĩ': 'i', 'ị': 'i', 'ó': 'o', 'ò': 'o',
      'ỏ': 'o', 'õ': 'o', 'ọ': 'o', 'ô': 'o', 'ố': 'o', 'ồ': 'o',
      'ổ': 'o', 'ỗ': 'o', 'ộ': 'o', 'ơ': 'o', 'ớ': 'o', 'ờ': 'o',
      'ở': 'o', 'ỡ': 'o', 'ợ': 'o', 'ú': 'u', 'ù': 'u', 'ủ': 'u',
      'ũ': 'u', 'ụ': 'u', 'ư': 'u', 'ứ': 'u', 'ừ': 'u', 'ử': 'u',
      'ữ': 'u', 'ự': 'u', 'ý': 'y', 'ỳ': 'y', 'ỷ': 'y', 'ỹ': 'y',
      'ỵ': 'y',
    };
    for (final entry in accents.entries) {
      value = value.replaceAll(entry.key, entry.value);
    }
    return value.replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static String _firstValue(Map<String, dynamic> fields, List<String> keys) {
    for (final key in keys) {
      final value = fields[_normalizeKey(key)]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static ({DateTime? value, bool invalid}) _readDate(
    Map<String, dynamic> fields,
    List<String> keys,
  ) {
    final raw = _firstValue(fields, keys);
    if (raw.isEmpty) return (value: null, invalid: false);

    final compact = RegExp(r'^\d{8}$').firstMatch(raw);
    if (compact != null) {
      final parsed = DateTime.tryParse(
        '${raw.substring(0, 4)}-${raw.substring(4, 6)}-${raw.substring(6, 8)}',
      );
      return (value: parsed, invalid: parsed == null);
    }

    final slash = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(raw);
    if (slash != null) {
      final parsed = DateTime.tryParse(
        '${slash.group(3)}-${slash.group(2)!.padLeft(2, '0')}-${slash.group(1)!.padLeft(2, '0')}',
      );
      return (value: parsed, invalid: parsed == null);
    }

    final parsed = DateTime.tryParse(raw);
    return (value: parsed, invalid: parsed == null);
  }

  static bool _isEmployeeCode(String value) {
    // Real cards include short numeric codes ("2"), mixed codes ("A1"),
    // usernames ("bachdv") and prefixed IDs ("NC000002"). Reject URLs and
    // punctuation payloads without imposing an NV/MNV-only format.
    return RegExp(r'^[A-Za-z0-9][A-Za-z0-9_]{0,31}$').hasMatch(value);
  }
}
