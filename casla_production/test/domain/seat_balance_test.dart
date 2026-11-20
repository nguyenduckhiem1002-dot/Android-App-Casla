import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/seat_balance.dart';
import 'package:flutter_test/flutter_test.dart';

WorkHistoryEntry row(
  String uuid,
  String type,
  double quantity, {
  double defect = 0,
  required int minute,
  String status = 'POSTED',
}) => WorkHistoryEntry(
  transactionUuid: uuid,
  executionDate: DateTime(2026, 10, 23, 8, minute),
  reportedWorkDate: DateTime(2026, 10, 23),
  workerId: 'CL400082',
  workerName: 'Đinh Thị Thu',
  productionOrder: '010140000380',
  operation: '0010',
  operationName: 'May miệng thân',
  productName: 'TM',
  productCode: '200009410',
  salesOrder: '',
  salesOrderItem: '',
  plant: '1000',
  workCenter: 'CL100077',
  workId: 'XM1',
  transactionType: type,
  quantity: quantity,
  defectQuantity: defect,
  unitOfMeasure: 'CHC',
  transactionStatus: status,
);

void main() {
  test('an over-confirmation counts against allocations given later', () {
    // 1.000 given, 1.500 confirmed, then 700 given: the sum is 200.
    final remaining = settleSeatBalance(
      seatEventsFromHistory([
        row('1', 'INITIAL_ASSIGN', 1000, minute: 0),
        row('2', 'CONFIRM', 1500, minute: 10),
        row('3', 'INITIAL_ASSIGN', 700, minute: 20),
      ]),
    );
    expect(remaining, 200);
  });

  test('the order of the rows does not matter', () {
    final remaining = settleSeatBalance(
      seatEventsFromHistory([
        row('1', 'INITIAL_ASSIGN', 1000, minute: 0),
        row('2', 'INITIAL_ASSIGN', 700, minute: 5),
        row('3', 'CONFIRM', 1500, minute: 10),
      ]),
    );
    expect(remaining, 200);
  });

  test('five lots, one over-confirmation, one top-up', () {
    final remaining = settleSeatBalance(
      seatEventsFromHistory([
        for (var i = 0; i < 5; i++)
          row('a$i', 'INITIAL_ASSIGN', 1000, minute: i),
        row('c', 'CONFIRM', 6000, minute: 10),
        row('b', 'INITIAL_ASSIGN', 1000, minute: 20),
      ]),
    );
    expect(remaining, 0);
  });

  test('a seat over-confirmed beyond its allocations goes negative', () {
    final remaining = settleSeatBalance(
      seatEventsFromHistory([
        row('a', 'INITIAL_ASSIGN', 1000, minute: 0),
        row('c', 'CONFIRM', 1500, minute: 10),
      ]),
    );
    expect(remaining, -500);
  });

  test('carry-over, recall, defects and reversals move the seat', () {
    final remaining = settleSeatBalance(
      seatEventsFromHistory([
        row('r', 'REASSIGN', 500, minute: 0),
        row('k', 'RECALL', 100, minute: 1),
        row('c', 'CONFIRM', 200, defect: 50, minute: 2),
        row('v', 'REVERSE', 200, defect: 50, minute: 3),
        row('x', 'CONFIRM', 30, minute: 4, status: 'REJECTED'),
      ]),
    );
    expect(remaining, 400);
  });

  test('rows posted at the same instant simply add up', () {
    final at = DateTime.utc(2026, 10, 23);
    final remaining = settleSeatBalance([
      SeatEvent(at: at, delta: -300, order: 'b'),
      SeatEvent(at: at, delta: 1000, order: 'a'),
    ]);
    expect(remaining, 700);
  });

  test('unknown row types do not move the seat', () {
    expect(seatEffect(transactionType: 'TRANSFER', quantity: 5), isNull);
    expect(
      seatEffect(transactionType: 'confirm', quantity: 5, defectQuantity: 1),
      -6,
    );
  });

  test('per unit, seats are settled apart and then added up', () {
    final byUnit = settledRemainingByUnit([
      // Seat A: 1.000 given, 1.500 confirmed, 700 given, 200 confirmed.
      row('a1', 'INITIAL_ASSIGN', 1000, minute: 0),
      row('a2', 'CONFIRM', 1500, minute: 1),
      row('a3', 'INITIAL_ASSIGN', 700, minute: 2),
      row('a4', 'CONFIRM', 200, minute: 3),
      // Seat B, another operation of the same unit: 300 open.
      WorkHistoryEntry(
        transactionUuid: 'b1',
        executionDate: DateTime(2026, 10, 23, 9),
        workerId: 'CL400082',
        workerName: 'Đinh Thị Thu',
        productionOrder: '010140000380',
        operation: '0020',
        plant: '1000',
        workCenter: 'CL100077',
        transactionType: 'INITIAL_ASSIGN',
        quantity: 300,
        unitOfMeasure: 'chc',
        transactionStatus: 'POSTED',
      ),
      // Another unit entirely.
      WorkHistoryEntry(
        transactionUuid: 'c1',
        executionDate: DateTime(2026, 10, 23, 9),
        workerId: 'CL400082',
        workerName: 'Đinh Thị Thu',
        productionOrder: '010140000381',
        operation: '0010',
        plant: '1000',
        workCenter: 'CL100077',
        transactionType: 'INITIAL_ASSIGN',
        quantity: 40,
        unitOfMeasure: 'BOO',
        transactionStatus: 'POSTED',
      ),
    ]);
    expect(byUnit, {'CHC': 300, 'BOO': 40});
  });
}
