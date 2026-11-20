import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/worker_seat_from_history.dart';
import 'package:flutter_test/flutter_test.dart';

WorkHistoryEntry _row({
  required String worker,
  required DateTime at,
  String position = '',
  String origin = '',
  String type = 'INITIAL_ASSIGN',
}) => WorkHistoryEntry(
  transactionUuid: '$worker-${at.toIso8601String()}-$type',
  executionDate: at,
  workerId: worker,
  workerName: worker,
  productionOrder: '010140000380',
  operation: '0010',
  plant: '1000',
  workCenter: 'CL100076',
  transactionType: type,
  quantity: 100,
  unitOfMeasure: 'ST',
  transactionStatus: 'POSTED',
  positionId: position,
  originPositionId: origin,
);

void main() {
  final d1 = DateTime(2026, 11, 3);
  final d2 = DateTime(2026, 11, 4);

  test('the newest row with a position wins', () {
    final entries = [
      _row(worker: 'CL400115', at: d2, position: 'VT-002', type: 'TRANSFER'),
      _row(worker: 'CL400115', at: d1, position: 'VT-001'),
      _row(worker: 'CL400116', at: d2, position: 'VT-009'),
    ];
    expect(latestWorkerPosition(entries, 'cl400115'), 'VT-002');
    expect(latestWorkerPosition(entries, 'CL400116'), 'VT-009');
  });

  test('rows without a position are skipped, the own seat is a fallback', () {
    final entries = [
      _row(worker: 'CL400115', at: d2, type: 'CONFIRM'),
      _row(worker: 'CL400115', at: d1, origin: 'vt-001'),
    ];
    expect(latestWorkerPosition(entries, 'CL400115'), 'VT-001');
  });

  test('nothing in the window names a position', () {
    expect(
      latestWorkerPosition([_row(worker: 'CL400115', at: d1)], 'CL400115'),
      '',
    );
    expect(latestWorkerPosition(const [], 'CL400115'), '');
  });

  test('same day: the first listed row is the newest', () {
    final entries = [
      _row(worker: 'CL400115', at: d2, position: 'VT-003'),
      _row(worker: 'CL400115', at: d2, position: 'VT-001'),
    ];
    expect(latestWorkerPosition(entries, 'CL400115'), 'VT-003');
  });
}
