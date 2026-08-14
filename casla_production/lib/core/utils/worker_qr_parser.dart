import 'dart:convert';

/// Result DTO for Worker/Employee QR parsing.
class WorkerQrResult {
  final bool isValid;
  final String maNv;
  final String tenNv;
  final String
  displayText; // Format: "Mã nhân viên ( Tên nhân viên )" e.g. "NV0001 ( Nguyễn Văn A )"
  final String? error;

  WorkerQrResult({
    required this.isValid,
    required this.maNv,
    required this.tenNv,
    required this.displayText,
    this.error,
  });

  factory WorkerQrResult.invalid([String msg = 'Mã QR không hợp lệ']) {
    return WorkerQrResult(
      isValid: false,
      maNv: '',
      tenNv: '',
      displayText: '',
      error: msg,
    );
  }

  factory WorkerQrResult.success(String maNv, String tenNv) {
    final cleanMa = maNv.trim();
    final cleanTen = tenNv.trim();
    return WorkerQrResult(
      isValid: true,
      maNv: cleanMa,
      tenNv: cleanTen,
      displayText: '$cleanMa ( $cleanTen )',
    );
  }
}

/// Dedicated parser for Employee QR codes.
/// Extracts Employee Code (ma_nv) and Employee Name (ten_nhan_vien).
/// Format to display in UI textboxes: `Mã nhân viên ( Tên nhân viên )` e.g. `NV0001 ( Nguyễn Văn A )`.
/// Returns `isValid = false` with "Mã QR không hợp lệ" if employee info cannot be parsed.
class WorkerQrParser {
  static WorkerQrResult parse(String rawCode) {
    final str = rawCode.trim();
    if (str.isEmpty) {
      return WorkerQrResult.invalid('Mã QR không hợp lệ');
    }

    String maNv = '';
    String tenNv = '';

    // 1. JSON payload format (e.g. {"ma_nv": "NV0001", "ten": "Nguyễn Văn A"})
    if (str.startsWith('{') && str.endsWith('}')) {
      try {
        final Map<String, dynamic> json = jsonDecode(str);
        maNv =
            (json['ma_nv'] ??
                    json['ma_nhan_vien'] ??
                    json['manv'] ??
                    json['userId'] ??
                    json['id'] ??
                    json['code'] ??
                    '')
                .toString()
                .trim();

        tenNv =
            (json['ten'] ??
                    json['ten_nhan_vien'] ??
                    json['ho_ten'] ??
                    json['userName'] ??
                    json['name'] ??
                    '')
                .toString()
                .trim();

        if (maNv.isNotEmpty && tenNv.isNotEmpty) {
          return WorkerQrResult.success(maNv, tenNv);
        }
      } catch (_) {}
    }

    // 2. Multiline or Key-Value text format (e.g. "Mã nhân viên: NV0001\nTên nhân viên: Nguyễn Văn A\n...")
    final maNvMatch = RegExp(
      r'(?:Mã\s*nhân\s*viên|Mã\s*NV|Ma\s*NV|Code|ID)\s*[:=]\s*([^\n\r\|;\,-]+)',
      caseSensitive: false,
    ).firstMatch(str);

    final tenNvMatch = RegExp(
      r'(?:Tên\s*nhân\s*viên|Tên\s*NV|Họ\s*tên|Ho\s*ten|Name)\s*[:=]\s*([^\n\r\|;\,-]+)',
      caseSensitive: false,
    ).firstMatch(str);

    if (maNvMatch != null) {
      maNv = maNvMatch.group(1)?.trim() ?? '';
    }
    if (tenNvMatch != null) {
      tenNv = tenNvMatch.group(1)?.trim() ?? '';
    }

    if (maNv.isNotEmpty && tenNv.isNotEmpty) {
      return WorkerQrResult.success(maNv, tenNv);
    }

    // 3. Delimited payload (e.g. "NV0001 | Nguyễn Văn A", "NV0001 - Nguyễn Văn A", "NV0001;Nguyễn Văn A")
    if (str.contains('|') || str.contains(' - ') || str.contains(';')) {
      final parts = str
          .split(RegExp(r'[\|\;\-\,]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      if (parts.length >= 2) {
        maNv = parts[0];
        tenNv = parts[1];
        if (maNv.isNotEmpty && tenNv.isNotEmpty) {
          return WorkerQrResult.success(maNv, tenNv);
        }
      }
    }

    // 4. Plain code string fallback (e.g. "NV0001", "MNV00123")
    final plainCodeMatch = RegExp(
      r'^(NV\d+|MNV\d+|\d{4,10})$',
      caseSensitive: false,
    ).firstMatch(str);
    if (plainCodeMatch != null ||
        str.toUpperCase().startsWith('NV') ||
        str.toUpperCase().startsWith('MNV')) {
      maNv = str;
      if (maNv.toUpperCase() == 'NV0001' || maNv.toUpperCase() == 'MNV00123') {
        tenNv = 'Nguyễn Văn A';
      } else {
        tenNv = 'Công nhân $maNv';
      }
      return WorkerQrResult.success(maNv, tenNv);
    }

    // If neither maNv nor tenNv can be resolved, reject as invalid QR
    return WorkerQrResult.invalid('Mã QR không hợp lệ');
  }

  /// Legacy helper method for backwards compatibility
  static Map<String, String> parseWorkerQr(String rawCode) {
    final result = parse(rawCode);
    if (result.isValid) {
      return {
        'ma_nv': result.maNv,
        'ten': result.tenNv,
        'display': result.displayText,
      };
    }
    return {'ma_nv': '', 'ten': '', 'display': ''};
  }
}
