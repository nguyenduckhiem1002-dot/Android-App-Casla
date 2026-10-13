import 'quantity_formatter.dart';
import 'scanned_json.dart';

/// The operation/product QR is untrusted input. Keep the original payload so
/// the selected operation can be traced locally, while exposing only the
/// fields needed by the SAP write contract and the UI.
class OperationQrResult {
  final bool isValid;
  final String rawPayload;
  final String productionOrder;
  final String operation;
  final String operationName;
  final String productCode;
  final String productName;
  final String salesOrder;
  final String salesOrderItem;
  final String boPhan;
  final String workCenter;
  final String plant;
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
    this.operationName = '',
    required this.productCode,
    required this.productName,
    this.salesOrder = '',
    this.salesOrderItem = '',
    this.boPhan = '',
    required this.workCenter,
    required this.plant,
    required this.workCenterDescription,
    required this.orderCode,
    required this.operationQuantity,
    required this.unitOfMeasure,
    this.error,
  });

  factory OperationQrResult.invalid(
    String rawPayload, [
    String message = 'Mã QR công đoạn không hợp lệ',
  ]) {
    return OperationQrResult(
      isValid: false,
      rawPayload: rawPayload,
      productionOrder: '',
      operation: '',
      operationName: '',
      productCode: '',
      productName: '',
      salesOrder: '',
      salesOrderItem: '',
      boPhan: '',
      workCenter: '',
      plant: '',
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
    final input = ScannedJson.normalizeText(rawCode.trim());
    if (input.isEmpty) return OperationQrResult.invalid(rawCode);

    final json = ScannedJson.decodeObject(input);
    if (json.fields != null) return _fromFields(input, json.fields!);
    if (json.isDamaged && _looksLikeOperationJson(input)) {
      // A reader that stopped mid-payload (a line break sent as Enter, a
      // stalled keyboard wedge) leaves an unclosed object. Never salvage the
      // fields that did arrive: a partial label could drop the work center or
      // the quantity. Ask for a clean read instead.
      return OperationQrResult.invalid(
        rawCode,
        'Mã QR công đoạn bị đọc thiếu hoặc sai định dạng. Hãy quét lại.',
      );
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
    final looksLikeProductionOrder =
        parts.isNotEmpty && RegExp(r'^\d{8,12}$').hasMatch(parts[0].trim());
    final looksLikeOperation =
        parts.length > 1 && RegExp(r'^\d{4}$').hasMatch(parts[1].trim());
    if (parts.length >= 2 && looksLikeProductionOrder && looksLikeOperation) {
      return OperationQrResult(
        isValid: true,
        rawPayload: input,
        productionOrder: parts[0].trim(),
        operation: parts[1].trim(),
        operationName: parts.length > 4 ? parts[4].trim() : '',
        productCode: parts.length > 2 ? parts[2].trim() : '',
        productName: parts.length > 3 ? parts[3].trim() : '',
        salesOrder: '',
        salesOrderItem: '',
        boPhan: '',
        workCenter: '',
        plant: '',
        workCenterDescription: '',
        orderCode: '',
        operationQuantity: null,
        unitOfMeasure: '',
      );
    }

    return OperationQrResult.invalid(rawCode);
  }

  /// A damaged payload that still names an operation-label key.
  static bool _looksLikeOperationJson(String input) {
    final keys = RegExp(
      r'"([^"\\]{1,48})"\s*:',
    ).allMatches(input).map((match) => _normalizeKey(match.group(1)!));
    const operationKeys = {
      'productionorder',
      'manufacturingorder',
      'lenhsx',
      'lenhsanxuat',
      'operation',
      'congdoan',
      'slcongdoan',
      'tencongdoan',
    };
    return keys.any(operationKeys.contains);
  }

  static OperationQrResult _fromFields(String raw, Map fields) {
    final normalized = <String, dynamic>{};
    for (final entry in fields.entries) {
      normalized[_normalizeKey(entry.key.toString())] = entry.value;
    }

    // A label that printed these as JSON numbers lost their leading zeros;
    // SAP keys are fixed-width (AUFNR 12, VORNR 4), so restore them.
    final productionOrder = _sapKey(normalized, const [
      'productionorder',
      'manufacturingorder',
      'lenhsx',
      'lenhsanxuat',
      'lệnhsảnxuất',
    ], width: 12);
    final operation = _sapKey(normalized, const [
      'operation',
      'operationno',
      'congdoan',
      'congdoanlenhsx',
      'côngđoạn',
    ], width: 4);
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
    final explicitUnit = _firstValue(normalized, const [
      'unit',
      'unitofmeasure',
      'uom',
      'donvitinh',
    ]);
    // Printed legacy labels append the SAP unit to the formatted quantity.
    // A separate field wins when present; keep supporting labels already printed.
    final suffixUnit =
        RegExp(
          r'^\s*-?[\d.,]+\s+([^\s]+)\s*$',
        ).firstMatch(quantityRaw)?.group(1) ??
        '';

    return OperationQrResult(
      isValid: true,
      rawPayload: raw,
      productionOrder: productionOrder,
      operation: operation,
      operationName: _firstValue(normalized, const [
        'operationname',
        'operationdescription',
        'tencongdoan',
        'motacongdoan',
      ]),
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
      salesOrder: _firstValue(normalized, const [
        'salesorder',
        'salesorderid',
        'so',
      ]),
      salesOrderItem: _firstValue(normalized, const [
        'salesorderitem',
        'salesorderitemid',
        'soitem',
      ]),
      boPhan: _firstValue(normalized, const [
        'bophan',
        'department',
        'departmentname',
        'tenbophan',
      ]),
      workCenter: _firstValue(normalized, const [
        'workcenter',
        'workcenterid',
        'mawc',
      ]),
      plant: _firstValue(normalized, const [
        'plant',
        'plantcode',
        'werks',
        'nhamay',
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
      unitOfMeasure: explicitUnit.isNotEmpty ? explicitUnit : suffixUnit,
    );
  }

  static String _normalizeKey(String key) {
    var value = key.toLowerCase();
    const accents = {
      'á': 'a',
      'à': 'a',
      'ả': 'a',
      'ã': 'a',
      'ạ': 'a',
      'ă': 'a',
      'ắ': 'a',
      'ằ': 'a',
      'ẳ': 'a',
      'ẵ': 'a',
      'ặ': 'a',
      'â': 'a',
      'ấ': 'a',
      'ầ': 'a',
      'ẩ': 'a',
      'ẫ': 'a',
      'ậ': 'a',
      'đ': 'd',
      'é': 'e',
      'è': 'e',
      'ẻ': 'e',
      'ẽ': 'e',
      'ẹ': 'e',
      'ê': 'e',
      'ế': 'e',
      'ề': 'e',
      'ể': 'e',
      'ễ': 'e',
      'ệ': 'e',
      'í': 'i',
      'ì': 'i',
      'ỉ': 'i',
      'ĩ': 'i',
      'ị': 'i',
      'ó': 'o',
      'ò': 'o',
      'ỏ': 'o',
      'õ': 'o',
      'ọ': 'o',
      'ô': 'o',
      'ố': 'o',
      'ồ': 'o',
      'ổ': 'o',
      'ỗ': 'o',
      'ộ': 'o',
      'ơ': 'o',
      'ớ': 'o',
      'ờ': 'o',
      'ở': 'o',
      'ỡ': 'o',
      'ợ': 'o',
      'ú': 'u',
      'ù': 'u',
      'ủ': 'u',
      'ũ': 'u',
      'ụ': 'u',
      'ư': 'u',
      'ứ': 'u',
      'ừ': 'u',
      'ử': 'u',
      'ữ': 'u',
      'ự': 'u',
      'ý': 'y',
      'ỳ': 'y',
      'ỷ': 'y',
      'ỹ': 'y',
      'ỵ': 'y',
    };
    for (final entry in accents.entries) {
      value = value.replaceAll(entry.key, entry.value);
    }
    return value.replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static String _sapKey(
    Map<String, dynamic> fields,
    List<String> keys, {
    required int width,
  }) {
    for (final key in keys) {
      final value = fields[_normalizeKey(key)];
      if (value is int && value >= 0) {
        return value.toString().padLeft(width, '0');
      }
    }
    return _firstValue(fields, keys);
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
    return parseLocalizedQuantity(raw);
  }
}
