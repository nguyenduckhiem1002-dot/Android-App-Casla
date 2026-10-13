import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/history_work_context.dart';
import 'package:flutter_test/flutter_test.dart';

WorkHistoryEntry entry(String center, String type, double quantity) =>
    WorkHistoryEntry(
      transactionUuid: '$center-$type',
      executionDate: DateTime(2026, 9, 9),
      workerId: 'worker',
      workerName: 'Worker without local membership',
      productionOrder: 'order',
      operation: '0010',
      plant: '6711',
      workCenter: center,
      transactionType: type,
      quantity: quantity,
      unitOfMeasure: 'KG',
      transactionStatus: 'POSTED',
    );
WorkHistoryResult result(
  List<WorkHistoryEntry> entries, {
  bool truncated = false,
}) => WorkHistoryResult(
  scopeCode: 'T',
  dateFrom: DateTime(2026, 9, 9),
  dateTo: DateTime(2026, 9, 9),
  isTruncated: truncated,
  entries: entries,
  workers: const [],
);
void main() {
  test('same worker in two work centers is summarized by ledger location', () {
    final report = historyForWorkContext(
      result([
        entry('A', 'INITIAL_ASSIGN', 100),
        entry('B', 'INITIAL_ASSIGN', 200),
        entry('A', 'CONFIRM', 20),
        entry('A', 'RECALL', 10),
        entry('A', 'REVERSE', 5),
        entry('A', 'CORRECTION', -2),
      ]),
      plant: '6711',
      workCenter: 'A',
    );
    // Gross, like SAP's AssignedQuantity; the recall has its own figure.
    expect(report.workers.single.assignedQuantity, 100);
    expect(report.workers.single.recalledQuantity, 10);
    expect(report.workers.single.completedQuantity, 13);
    expect(report.workers.single.remainingQuantity, 77);
    expect(report.entries.every((e) => e.workCenter == 'A'), isTrue);
  });
  test('the carried-over balance counts only on the first day', () {
    WorkHistoryEntry on(DateTime day, String type, double qty) =>
        entry('A', type, qty).copyWithDate(day);
    final report = historyForWorkContext(
      WorkHistoryResult(
        scopeCode: 'T',
        dateFrom: DateTime(2026, 9, 23),
        dateTo: DateTime(2026, 9, 24),
        isTruncated: false,
        entries: [
          on(DateTime(2026, 9, 23), 'REASSIGN', 967),
          on(DateTime(2026, 9, 23), 'INITIAL_ASSIGN', 100),
          // Tomorrow's snapshot of the same unfinished work is not new work.
          on(DateTime(2026, 9, 24), 'REASSIGN', 900),
          on(DateTime(2026, 9, 24), 'INITIAL_ASSIGN', 50),
        ],
        workers: const [],
      ),
      plant: '6711',
      workCenter: 'A',
    );
    expect(report.workers.single.assignedQuantity, 967 + 100 + 50);
    expect(report.workers.single.remainingQuantity, 967 + 100 + 50);
  });

  test(
    'truncated ledger and ambiguous transfer cannot produce false totals',
    () {
      expect(
        () => historyForWorkContext(
          result([], truncated: true),
          plant: '6711',
          workCenter: 'A',
        ),
        throwsFormatException,
      );
      expect(
        () => historyForWorkContext(
          result([entry('A', 'TRANSFER', 10)]),
          plant: '6711',
          workCenter: 'A',
        ),
        throwsFormatException,
      );
    },
  );
}

extension on WorkHistoryEntry {
  WorkHistoryEntry copyWithDate(DateTime day) => WorkHistoryEntry(
    transactionUuid: '$transactionUuid-${day.day}',
    executionDate: day,
    workerId: workerId,
    workerName: workerName,
    productionOrder: productionOrder,
    operation: operation,
    plant: plant,
    workCenter: workCenter,
    transactionType: transactionType,
    quantity: quantity,
    unitOfMeasure: unitOfMeasure,
    transactionStatus: transactionStatus,
  );
}
