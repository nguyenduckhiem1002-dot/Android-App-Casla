import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/history_work_context.dart';
import 'package:flutter_test/flutter_test.dart';

WorkHistoryEntry entry(String workId, double quantity) => WorkHistoryEntry(
  transactionUuid: '$workId-$quantity',
  executionDate: DateTime(2026, 10, 19),
  workerId: 'W1',
  workerName: 'Worker',
  productionOrder: 'order',
  operation: '0010',
  plant: '6711',
  workCenter: 'WC',
  workId: workId,
  transactionType: 'INITIAL_ASSIGN',
  quantity: quantity,
  unitOfMeasure: 'KG',
  transactionStatus: 'POSTED',
);

WorkHistorySummary summary(String workerId, String workId) =>
    WorkHistorySummary(
      workerId: workerId,
      workerName: workerId,
      assignedQuantity: 10,
      completedQuantity: 0,
      remainingQuantity: 10,
      unitOfMeasure: 'KG',
      transactionCount: 1,
      workId: workId,
    );

WorkHistoryResult result({
  required List<WorkHistoryEntry> entries,
  required List<WorkHistorySummary> workers,
  bool truncated = false,
}) => WorkHistoryResult(
  scopeCode: 'T',
  dateFrom: DateTime(2026, 10, 19),
  dateTo: DateTime(2026, 10, 19),
  isTruncated: truncated,
  entries: entries,
  workers: workers,
);

void main() {
  final sap = result(
    entries: [entry('TO_A', 1), entry('TO_B', 2), entry('TO_C', 3)],
    workers: [
      summary('W1', 'TO_A'),
      summary('W2', 'TO_B'),
      summary('W3', 'TO_C'),
    ],
    truncated: true,
  );

  test('keeps only the selected contexts, for several at once', () {
    final scoped = historyForWorkIds(sap, {'TO_A', 'TO_C'});
    expect(scoped.workers.map((w) => w.workerId), ['W1', 'W3']);
    expect(scoped.entries.map((e) => e.workId), ['TO_A', 'TO_C']);
    // Totals come from SAP's full scan, so a cut entry list is still usable.
    expect(scoped.isTruncated, isTrue);
  });

  test('an empty selection is every authorized context', () {
    expect(identical(historyForWorkIds(sap, const {}), sap), isTrue);
    expect(identical(historyForWorkIds(sap, {' '}), sap), isTrue);
  });

  test('an unknown context yields an empty report, not an error', () {
    final scoped = historyForWorkIds(sap, {'TO_Z'});
    expect(scoped.workers, isEmpty);
    expect(scoped.entries, isEmpty);
  });

  test('totals without a WorkID cannot be split by context', () {
    final legacy = result(
      entries: [entry('TO_A', 1)],
      workers: [summary('W1', '')],
    );
    expect(() => historyForWorkIds(legacy, {'TO_A'}), throwsFormatException);
  });
}
