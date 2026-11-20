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
  String positionId = '',
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
  positionId: positionId,
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

  test('each position is its own group; a spent seat is not the target', () {
    // 010140000381/0020 on 2026-11-11: 100 + 100 unplaced, 200 recalled on
    // the first lot only (the second still shows 100 on this device), then
    // 800 at TR1. The confirmation must land on TR1, not on the blank lot.
    final groups = groupConfirmationTargets([
      lot(
        'a',
        assigned: 100,
        recalled: 200,
        createdAtUtc: 10,
      ).copyWith(seatRemaining: 0),
      lot('b', assigned: 100, createdAtUtc: 20).copyWith(seatRemaining: 0),
      lot(
        'tr1',
        assigned: 800,
        createdAtUtc: 30,
        positionId: 'TR1',
      ).copyWith(seatRemaining: 800),
    ]);
    expect(groups, hasLength(2));
    final open = groups
        .where((group) => group.any((member) => member.canConfirm))
        .toList();
    expect(open.single.map((a) => a.id), ['tr1']);
    expect(confirmationTarget(open.single).positionId, 'TR1');
    expect(aggregateConfirmationGroup(open.single).positionId, 'TR1');
  });

  test('a grouped confirmation is one transaction on the oldest lot', () {
    final parts = splitGroupedConfirmation(lots, completed: 500, recalled: 0);
    expect(parts.map((p) => '${p.assignment.id}:${p.completed}'), ['a:500.0']);
  });

  test('a lot closed by an over-confirmation is skipped as the target', () {
    // 1.000 given, 1.500 confirmed on it (closed), then 700 given.
    final members = [
      lot(
        'old',
        assigned: 1000,
        completed: 1500,
        createdAtUtc: 10,
      ).copyWith(status: AssignmentStatus.completed),
      lot('new', assigned: 700, createdAtUtc: 20),
    ];
    final parts = splitGroupedConfirmation(
      members,
      completed: 200,
      recalled: 0,
    );
    expect(parts.map((p) => '${p.assignment.id}:${p.completed}'), [
      'new:200.0',
    ]);
    expect(confirmationTarget(members).id, 'new');
  });

  test('the group total shows the settled seat balance, not the sum', () {
    final members = [
      lot(
        'old',
        assigned: 1000,
        completed: 1500,
        createdAtUtc: 10,
      ).copyWith(status: AssignmentStatus.completed, seatRemaining: 700),
      lot('new', assigned: 700, createdAtUtc: 20).copyWith(seatRemaining: 700),
    ];
    final total = aggregateConfirmationGroup(members);
    expect(total.assignedQuantity, 1700);
    expect(total.completedQuantity, 1500);
    expect(total.remaining, 200);
    expect(total.groupRemaining, 700);
    // A recall is bounded by the seat balance.
    expect(
      () => splitGroupedConfirmation(members, completed: 0, recalled: 701),
      throwsArgumentError,
    );
    expect(
      splitGroupedConfirmation(
        members,
        completed: 0,
        recalled: 700,
      ).single.recalled,
      700,
    );
  });

  test('the settled balance follows what this device wrote since', () {
    final opened = [
      lot(
        'old',
        assigned: 1000,
        completed: 1500,
        createdAtUtc: 10,
      ).copyWith(status: AssignmentStatus.completed, seatRemaining: 700),
      lot('new', assigned: 700, createdAtUtc: 20).copyWith(seatRemaining: 700),
    ];
    final current = [
      lot(
        'old',
        assigned: 1000,
        completed: 1500,
        createdAtUtc: 10,
      ).copyWith(status: AssignmentStatus.completed),
      lot('new', assigned: 700, completed: 200, recalled: 50, createdAtUtc: 20),
      lot('top', assigned: 100, createdAtUtc: 30),
    ];
    expect(carrySeatRemaining(opened: opened, current: current), 550);
    expect(
      carrySeatRemaining(
        opened: [lot('x', assigned: 1)],
        current: [lot('x', assigned: 1)],
      ),
      isNull,
    );
  });

  test('recall rides on the same single transaction', () {
    final parts = splitGroupedConfirmation(lots, completed: 90, recalled: 400);
    expect(
      parts.map((p) => '${p.assignment.id}:${p.completed}/${p.recalled}'),
      ['a:90.0/400.0'],
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
    expect(parts.map((p) => p.completed), [0.6]);
  });

  test('completion beyond the group balance is sent exactly as entered', () {
    // 1.418 left in all; SAP clears the seat and keeps the entered figure.
    final parts = splitGroupedConfirmation(lots, completed: 1419, recalled: 0);
    expect(parts.map((p) => '${p.assignment.id}:${p.completed}'), ['a:1419.0']);
  });

  test('defects travel with the same transaction', () {
    final parts = splitGroupedConfirmation(
      [
        lot('a', assigned: 10, createdAtUtc: 1),
        lot('b', assigned: 10, completed: 10, createdAtUtc: 2),
      ],
      completed: 12,
      defect: 3,
      recalled: 0,
    );
    expect(parts.map((p) => '${p.assignment.id}:${p.completed}/${p.defect}'), [
      'a:12.0/3.0',
    ]);
  });

  test('nothing entered means nothing to send', () {
    expect(splitGroupedConfirmation(lots, completed: 0, recalled: 0), isEmpty);
  });

  test('a recall beyond what the group holds is refused', () {
    expect(
      () => splitGroupedConfirmation(lots, completed: 0, recalled: 1419),
      throwsArgumentError,
    );
  });
}
