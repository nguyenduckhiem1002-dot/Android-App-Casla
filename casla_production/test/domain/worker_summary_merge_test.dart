import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/worker_summary_merge.dart';
import 'package:flutter_test/flutter_test.dart';

WorkHistorySummary row(
  String worker,
  String workId,
  String unit,
  double assigned, {
  double completed = 0,
  double recalled = 0,
}) => WorkHistorySummary(
  workerId: worker,
  workerName: 'Worker $worker',
  assignedQuantity: assigned,
  completedQuantity: completed,
  recalledQuantity: recalled,
  remainingQuantity: assigned - completed - recalled,
  unitOfMeasure: unit,
  transactionCount: 1,
  workId: workId,
);

void main() {
  test('one worker split by WorkID is added up per unit', () {
    // Yesterday's balance carried over on the old position, plus a new
    // assignment today on another one: the screenshot's 1.418 + 1.
    final merged = mergeWorkerSummaries([
      row('KHIEMND1', 'WORK-OLD', 'CHC', 1418),
      row('khiemnd1', 'WORK-NEW', 'CHC', 1, recalled: 0),
      row('OTHER', 'WORK-NEW', 'CHC', 50),
    ]);

    final khiem = merged.singleWhere((r) => r.workerId == 'KHIEMND1');
    expect(khiem.assignedQuantity, 1419);
    expect(khiem.remainingQuantity, 1419);
    expect(khiem.workId, isEmpty, reason: 'no single position covers both');
    expect(merged, hasLength(2));
  });

  test('different units are never added together', () {
    final merged = mergeWorkerSummaries([
      row('NV01', 'W', 'CHC', 10),
      row('NV01', 'W', 'KG', 2.5),
    ]);
    expect(merged, hasLength(2));
  });
}
