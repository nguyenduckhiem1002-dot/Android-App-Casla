import 'dart:convert';

/// The operation/product QR is untrusted input. Keep the original payload so
/// the selected operation can be traced locally, while exposing only the
/// fields needed by the SAP write contract and the UI.
class OperationQrResult {
  final bool isValid;
  final String rawPayload;
  final String productionOrder;
  final String operation;
  final String productCode;
  final String productName;
  final String workCenter;
  final String workCenterDescription;
  final String orderCode;
  final double? operationQuantity;
  final String unitOfMeasure;
  final String? error;

  const OperationQrResult({
    required this.isValid,
    required this.rawPayload,
    required this.productionOrder,
    required this.operation,
    required this.productCode,
    required this.productName,
    required this.workCenter,
    required this.workCenterDescription,
    required this.orderCode,
    required this.operationQuantity,
    required this.unitOfMeasure,
    this.error,
  });

  factory OperationQrResult.invalid(String rawPayload, [String message = 'Mã QR công đoạn không hợp lệ']) {
    return OperationQrResult(
      isValid: false,
      rawPayload: rawPayload,
      productionOrder: '',
      operation: '',
      productCode: '',
      productName: '',
      workCenter: '',
      workCenterDescription: '',
      orderCode: '',
      operationQuantity: null,
      unitOfMeasure: '',
      error: message,
    );
  }

  String get displayProductName =>
      productName.isNotEmpty ? productName : productCode;
}

class OperationQrParser {
  OperationQrParser._();

  static const int maxInputCharacters = 8192;

  static OperationQrResult parse(String rawCode) {
    if (rawCode.length > maxInputCharacters || rawCode.contains('\u0000')) {
      return OperationQrResult.invalid(rawCode);
    }
    final input = rawCode.trim();
    if (input.isEmpty) return OperationQrResult.invalid(rawCode);

    if (input.startsWith('{') && input.endsWith('}')) {
      try {
        final decoded = jsonDecode(input);
        if (decoded is Map) return _fromFields(input, decoded);
      } on FormatException {
        return OperationQrResult.invalid(rawCode);
      }
    }

    final fields = <String, String>{};
    final pairPattern = RegExp(
      r'([^:=|;\n\r]{1,48})\s*[:=]\s*([^|;\n\r]+)',
      caseSensitive: false,
    );
    for (final match in pairPattern.allMatches(input)) {
      fields[match.group(1)!.trim()] = match.group(2)!.trim();
    }
    if (fields.isNotEmpty) {
      final parsed = _fromFields(input, fields);
      if (parsed.isValid) return parsed;
    }

    // A bare production-order/operation pair is accepted only when it is
    // explicitly delimited; never guess from an arbitrary product name.
    final parts = input.split(RegExp(r'\s*[|;/]\s*'));
    final looksLikeProductionOrder = RegExp(r'^\d{8,12}$').hasMatch(parts[0].trim());
    final looksLikeOperation = RegExp(r'^\d{4}$').hasMatch(parts[1].trim());
    if (parts.length >= 2 &&
        looksLikeProductionOrder &&
        looksLikeOperation) {
      return OperationQrResult(
        isValid: true,
        rawPayload: input,
        productionOrder: parts[0].trim(),
        operation: parts[1].trim(),
        productCode: parts.length > 2 ? parts[2].trim() : '',
        productName: parts.length > 3 ? parts[3].trim() : '',
        workCenter: '',
        workCenterDescription: '',
        orderCode: '',
        operationQuantity: null,
        unitOfMeasure: '',
      );
    }

    return OperationQrResult.invalid(rawCode);
  }

  static OperationQrResult _fromFields(String raw, Map fields) {
    final normalized = <String, dynamic>{};
    for (final entry in fields.entries) {
      normalized[_normalizeKey(entry.key.toString())] = entry.value;
    }

    final productionOrder = _firstValue(normalized, const [
      'productionorder',
      'manufacturingorder',
      'lenhsx',
      'lenhsanxuat',
      'lệnhsảnxuất',
    ]);
    final operation = _firstValue(normalized, const [
      'operation',
      'operationno',
      'congdoan',
      'congdoanlenhsx',
      'côngđoạn',
    ]);
    if (productionOrder.isEmpty || operation.isEmpty) {
      return OperationQrResult.invalid(raw);
    }

    final quantityRaw = _firstValue(normalized, const [
      'operationquantity',
      'quantity',
      'slcdoan',
      'slcongdoan',
      'soluongcongdoan',
    ]);

    return OperationQrResult(
      isValid: true,
      rawPayload: raw,
      productionOrder: productionOrder,
      operation: operation,
      productCode: _firstValue(normalized, const [
        'productcode',
        'materialcode',
        'material',
        'mahang',
        'masp',
      ]),
      productName: _firstValue(normalized, const [
        'productname',
        'tenhang',
        'tensp',
      ]),
      workCenter: _firstValue(normalized, const [
        'workcenter',
        'workcenterid',
        'mawc',
      ]),
      workCenterDescription: _firstValue(normalized, const [
        'workcenterdescription',
        'workcentername',
        'motawc',
      ]),
      orderCode: _firstValue(normalized, const [
        'ordercode',
        'madonhang',
        'donhang',
      ]),
      operationQuantity: _parseQuantity(quantityRaw),
      unitOfMeasure: _firstValue(normalized, const [
        'unitofmeasure',
        'uom',
        'donvitinh',
      ]),
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

  static double? _parseQuantity(String raw) {
    if (raw.isEmpty) return null;
    final match = RegExp(r'-?[\d.,]+').firstMatch(raw);
    if (match == null) return null;
    var value = match.group(0)!;
    if (value.contains(',') && value.contains('.')) {
      value = value.replaceAll('.', '').replaceFirst(',', '.');
    } else if (value.contains(',')) {
      value = value.replaceFirst(',', '.');
    }
    return double.tryParse(value);
  }
}
