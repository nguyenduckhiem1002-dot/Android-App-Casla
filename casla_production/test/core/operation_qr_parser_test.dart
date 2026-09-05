import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/core/utils/operation_qr_parser.dart';

void main() {
  test('parses the operation QR fields and keeps the original payload', () {
    const raw = '{"ProductionOrder":"000001000020",'
        '"Operation":"0010","ProductCode":"200009017",'
        '"ProductName":"XE-EU24122750-G-V1-2cm",'
        '"WorkCenter":"67110016","OperationQuantity":"4.000,000 KG",'
        '"UnitOfMeasure":"KG"}';

    final result = OperationQrParser.parse(raw);

    expect(result.isValid, isTrue);
    expect(result.productionOrder, '000001000020');
    expect(result.operation, '0010');
    expect(result.productName, 'XE-EU24122750-G-V1-2cm');
    expect(result.operationQuantity, 4000);
    expect(result.rawPayload, raw);
  });

  test('parses Vietnamese labels from a printed QR payload', () {
    final result = OperationQrParser.parse(
      'Lệnh SX: 000001000020|Công đoạn: 0010|Mã hàng: 200009017|'
      'Tên hàng: XE-EU24122750-G-V1-2cm',
    );

    expect(result.isValid, isTrue);
    expect(result.displayProductName, 'XE-EU24122750-G-V1-2cm');
  });

  test('rejects a product code without operation identity', () {
    expect(
      OperationQrParser.parse('{"ProductCode":"200009017"}').isValid,
      isFalse,
    );
  });
}
