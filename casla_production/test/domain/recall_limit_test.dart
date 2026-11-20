// The recall form's cap must be the one SAP refuses against.

import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:flutter_test/flutter_test.dart';

Assignment lot({
  required double assigned,
  double completed = 0,
  double recalled = 0,
  double? seatRemaining,
}) => Assignment(
  id: 'lot',
  workerId: 'worker',
  workerMaNv: 'NV',
  workerName: 'A',
  teamId: 'XM2.002',
  orderId: 'order',
  orderCode: '010140000380',
  productionOrder: '010140000380',
  operation: '0010',
  productCode: 'SP',
  productName: 'Túi',
  uom: 'CHC',
  assignedQuantity: assigned,
  completedQuantity: completed,
  recalledQuantity: recalled,
  businessDate: '2026-10-27',
  shiftId: 'DAY',
  status: AssignmentStatus.open,
  createdBy: 'SAP',
  idempotencyKey: 'lot',
  syncStatus: SyncStatus.synced,
  seatRemaining: seatRemaining,
);

void main() {
  test('without a settled seat the lot figure is the cap', () {
    expect(lot(assigned: 1000, completed: 300).recallLimit, 700);
  });

  test('the seat balance caps a lot that still looks open on its own', () {
    // 1.000 given, 1.500 confirmed on it, then 700 given: this second lot
    // is untouched on paper, yet the worker holds only 200 on the seat.
    expect(lot(assigned: 700, seatRemaining: 200).recallLimit, 200);
  });

  test('a seat driven negative leaves nothing to recall', () {
    expect(lot(assigned: 700, seatRemaining: -500).recallLimit, 0);
  });

  test('a seat above the lot figure does not raise it', () {
    expect(
      lot(assigned: 1000, completed: 300, seatRemaining: 900).recallLimit,
      700,
    );
  });
}
