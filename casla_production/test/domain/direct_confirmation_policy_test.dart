import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/domain/policies/direct_confirmation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('confirmation scope excludes open work from another department', () {
    final currentDepartment = _assignment(
      id: 'completed-current',
      productionOrder: '010140000365',
      operation: '0010',
      teamId: 'MAY-MIENG-XM2',
      completedQuantity: 100,
    );
    final otherDepartment = _assignment(
      id: 'open-other',
      productionOrder: '010140000365',
      operation: '0030',
      teamId: 'GAP-TUI-XM2',
    );

    expect(
      actionableAssignmentsForConfirmationScope([
        currentDepartment,
        otherDepartment,
      ], workContextId: 'MAY-MIENG-XM2'),
      isEmpty,
    );
  });
}

Assignment _assignment({
  required String id,
  required String productionOrder,
  required String operation,
  String teamId = 'team',
  double completedQuantity = 0,
  int createdAtUtc = 0,
}) => Assignment(
  id: id,
  workerId: 'worker',
  workerMaNv: 'NV01',
  workerName: 'Công nhân',
  teamId: teamId,
  orderId: '$productionOrder-$operation',
  orderCode: productionOrder,
  productionOrder: productionOrder,
  operation: operation,
  productCode: 'SP01',
  productName: 'Sản phẩm',
  uom: 'CHC',
  assignedQuantity: 100,
  completedQuantity: completedQuantity,
  recalledQuantity: 0,
  businessDate: '2026-09-22',
  shiftId: 'DAY',
  status: AssignmentStatus.open,
  createdBy: 'supervisor',
  idempotencyKey: id,
  syncStatus: SyncStatus.synced,
  createdAtUtc: createdAtUtc,
);
