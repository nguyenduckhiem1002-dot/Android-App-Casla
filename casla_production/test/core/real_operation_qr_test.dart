import 'package:casla_production/core/scanner/scan_intent.dart';
import 'package:flutter_test/flutter_test.dart';

/// The exact payload a TC22 read off a real production label on the floor,
/// captured during PDA commissioning. Field names are the Vietnamese
/// snake_case ones SAP emits, not the English aliases the parser documents
/// first — this is the shape that actually has to work.
const String _realOperationQr =
    '{"lenh_san_xuat":"010010000022","cong_doan":"0010",'
    '"ten_cong_doan":"Kéo sợi Quai","work_center":"67110006",'
    '"mo_ta_wc":"Kéo sợi Quai","sl_cong_doan":"10","unit":"KG",'
    '"ma_hang":"000000000200009035","ten_hang":"KQ-186(QK)",'
    '"control_key":"YBP1","standard_value_key":""}';

void main() {
  test('a real shop-floor operation QR is classified and fully parsed', () {
    final scanned = ScanClassifier.classify(_realOperationQr);

    expect(scanned.kind, ScannedCodeKind.operation);

    final operation = scanned.operation!;
    expect(operation.productionOrder, '010010000022');
    expect(operation.operation, '0010');
    expect(operation.workCenter, '67110006');
    expect(operation.workCenterDescription, 'Kéo sợi Quai');
    expect(operation.productCode, '000000000200009035');
    expect(operation.productName, 'KQ-186(QK)');
    expect(operation.operationQuantity, 10);

    // The unit drives the quantity field's suffix and the success message, so a
    // KG operation must never fall back to the old hardcoded "cái".
    expect(operation.unitOfMeasure, 'KG');
  });

  test('the operation parser wins over the worker parser on this payload', () {
    // WorkerQrParser ends in a permissive bare-token fallback. Classifying
    // operation-first is what stops a production label being filed as a person.
    expect(
      ScanClassifier.classify(_realOperationQr).isWorker,
      isFalse,
    );
  });
}
