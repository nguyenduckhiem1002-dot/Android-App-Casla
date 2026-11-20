import 'package:casla_production/domain/entities/operation_access.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses operation totals including the open quantity', () {
    final access = OperationAccessResult.fromJson({
      'IsAllowed': 'X',
      'OperationQuantity': '1500.000',
      'CurrentAssignedQuantity': '800.000',
      'RemainingQuantity': '200.000',
      'OpenQuantity': '300.000',
      'UnassignedQuantity': '700.000',
    });
    expect(access.isAllowed, isTrue);
    expect(access.remainingQuantity, 200);
    expect(access.openQuantity, 300);
    expect(access.unassignedQuantity, 700);
  });

  test('open quantity defaults to zero when SAP does not send it', () {
    final access = OperationAccessResult.fromJson({'IsAllowed': true});
    expect(access.openQuantity, 0);
  });
}
