import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/domain/policies/grouped_confirmation.dart';
import 'package:flutter_test/flutter_test.dart';

Assignment lot(
  String id, {
  required double assigned,
  double completed = 0,
  double recalled = 0,
  int createdAtUtc = 0,
  String operation = '0020',
  String uom = 'CHC',
}) => Assignment(
  id: id,
  workerId: 'worker',
  workerMaNv: 'NV',
  workerName: 'A',
  teamId: 'XM2.002',
  orderId: 'order',
  orderCode: '010140000365',
  productionOrder: '010140000365',
  operation: operation,
  productCode: 'SP',
  productName: 'Túi',
  uom: uom,
  assignedQuantity: assigned,
  completedQuantity: completed,
  recalledQuantity: recalled,
  businessDate: '2026-09-23',
  shiftId: 'DAY',
  status: AssignmentStatus.open,
  createdBy: 'SAP',
  idempotencyKey: id,
  syncStatus: SyncStatus.synced,
  createdAtUtc: createdAtUtc,
);

void main() {
  // The screenshot case: 85 left of 100, 333 of 333, 1.000 of 1.000.
  final lots = [
    lot('c', assigned: 1000, createdAtUtc: 30),
    lot('a', assigned: 100, completed: 15, createdAtUtc: 10),
    lot('b', assigned: 333, createdAtUtc: 20),
  ];

  test('groups by order, operation and unit; totals are summed', () {
    final groups = groupConfirmationTargets([
      ...lots,
      lot('x', assigned: 5, operation: '0030'),
      lot('y', assigned: 5, uom: 'KG'),
    ]);
    expect(groups, hasLength(3));
    final total = aggregateConfirmationGroup(groups.first);
    expect(total.remaining, 1418);
    expect(total.assignedQuantity, 1433);
    expect(groups.first.map((a) => a.id), ['a', 'b', 'c']);
  });

  test('completion fills the oldest allocation first', () {
    final parts = splitGroupedConfirmation(lots, completed: 500, recalled: 0);
    expect(parts.map((p) => '${p.assignment.id}:${p.completed}'), [
      'a:85.0',
      'b:333.0',
      'c:82.0',
    ]);
  });

  test('recall takes what completion left, oldest first', () {
    final parts = splitGroupedConfirmation(lots, completed: 90, recalled: 400);
    expect(
      parts.map((p) => '${p.assignment.id}:${p.completed}/${p.recalled}'),
      ['a:85.0/0.0', 'b:5.0/328.0', 'c:0.0/72.0'],
    );
  });

  test('decimals stay exact at SAP scale', () {
    final parts = splitGroupedConfirmation(
      [
        lot('a', assigned: 0.3, createdAtUtc: 1),
        lot('b', assigned: 0.3, createdAtUtc: 2),
      ],
      completed: 0.6,
      recalled: 0,
    );
    expect(parts.map((p) => p.completed), [0.3, 0.3]);
  });

  test('what the group cannot hold goes on the newest allocation', () {
    // 1.418 left in all; one more than that is still confirmed.
    final parts = splitGroupedConfirmation(lots, completed: 1419, recalled: 0);
    expect(parts.map((p) => '${p.assignment.id}:${p.completed}'), [
      'a:85.0',
      'b:333.0',
      'c:1001.0',
    ]);
  });

  test('defects beyond the balance follow the surplus', () {
    final parts = splitGroupedConfirmation(
      [
        lot('a', assigned: 10, createdAtUtc: 1),
        lot('b', assigned: 10, completed: 10, createdAtUtc: 2),
      ],
      completed: 12,
      defect: 3,
      recalled: 0,
    );
    // `b` has nothing left, yet it is the last lot the worker was given.
    expect(parts.map((p) => '${p.assignment.id}:${p.completed}/${p.defect}'), [
      'a:10.0/0.0',
      'b:2.0/3.0',
    ]);
  });

  test('a recall beyond what the group holds is refused', () {
    expect(
      () => splitGroupedConfirmation(lots, completed: 0, recalled: 1419),
      throwsArgumentError,
    );
  });
}
