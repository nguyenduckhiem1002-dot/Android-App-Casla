import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/history_worker_filter.dart';
import 'package:flutter_test/flutter_test.dart';

WorkHistoryEntry _entry(String id, String worker, {String name = ''}) =>
    WorkHistoryEntry(
      transactionUuid: id,
      executionDate: DateTime(2026, 10, 23, 8),
      workerId: worker,
      workerName: name,
      productionOrder: '010140000380',
      operation: '0010',
      plant: '1000',
      workCenter: 'CL100077',
      transactionType: 'INITIAL_ASSIGN',
      quantity: 10,
      unitOfMeasure: 'CHC',
      transactionStatus: 'POSTED',
    );

WorkHistorySummary _worker(String id, String name) => WorkHistorySummary(
  workerId: id,
  workerName: name,
  assignedQuantity: 10,
  completedQuantity: 0,
  remainingQuantity: 10,
  unitOfMeasure: 'CHC',
  transactionCount: 1,
);

void main() {
  final team = WorkHistoryResult(
    scopeCode: 'T',
    dateFrom: DateTime(2026, 10, 23),
    dateTo: DateTime(2026, 10, 23),
    isTruncated: false,
    entries: [
      _entry('1', 'CL400001', name: 'Đỗ Thị Chi'),
      // A ledger row without a name: matched by the summary's name.
      _entry('2', 'CL400082'),
    ],
    workers: [
      _worker('CL400001', 'Đỗ Thị Chi'),
      _worker('CL400082', 'Đinh Thị Thu'),
    ],
  );

  test('matches a name without accents or case, and a code in part', () {
    expect(
      historyWorkerMatches(
        workerId: 'CL400082',
        workerName: 'Đinh Thị Thu',
        query: 'DINH thi',
      ),
      isTrue,
    );
    expect(
      historyWorkerMatches(
        workerId: 'CL400082',
        workerName: 'Đinh Thị Thu',
        query: '0082',
      ),
      isTrue,
    );
    expect(
      historyWorkerMatches(
        workerId: 'CL400082',
        workerName: 'Đinh Thị Thu',
        query: 'chi',
      ),
      isFalse,
    );
  });

  test('narrows rows and totals to the matching workers', () {
    final thu = filterHistoryByWorker(team, 'thu');
    expect(thu.entries.map((e) => e.transactionUuid), ['2']);
    expect(thu.workers.map((w) => w.workerId), ['CL400082']);
    expect(thu.scopeCode, 'T');
  });

  test('a blank query keeps everything', () {
    expect(identical(filterHistoryByWorker(team, '  '), team), isTrue);
  });

  test('counts distinct workers', () {
    expect(historyWorkerCount(team), 2);
  });

  test('departments are named from the summary and filtered by WorkID', () {
    WorkHistoryEntry at(String id, String worker, String workId) =>
        WorkHistoryEntry(
          transactionUuid: id,
          executionDate: DateTime(2026, 10, 23, 8),
          workerId: worker,
          workerName: '',
          productionOrder: '010140000380',
          operation: '0010',
          plant: '1000',
          workCenter: 'CL100077',
          workId: workId,
          transactionType: 'INITIAL_ASSIGN',
          quantity: 10,
          unitOfMeasure: 'CHC',
          transactionStatus: 'POSTED',
        );
    final history = WorkHistoryResult(
      scopeCode: 'T',
      dateFrom: DateTime(2026, 10, 23),
      dateTo: DateTime(2026, 10, 23),
      isTruncated: false,
      entries: [at('1', 'A', 'XM1'), at('2', 'B', 'XM2'), at('3', 'C', 'XM3')],
      workers: const [
        WorkHistorySummary(
          workerId: 'A',
          workerName: 'An',
          assignedQuantity: 10,
          completedQuantity: 0,
          remainingQuantity: 10,
          unitOfMeasure: 'CHC',
          transactionCount: 1,
          workId: 'XM1',
          workName: 'Giải chuyền 1',
        ),
        WorkHistorySummary(
          workerId: 'B',
          workerName: 'Bình',
          assignedQuantity: 10,
          completedQuantity: 0,
          remainingQuantity: 10,
          unitOfMeasure: 'CHC',
          transactionCount: 1,
          workId: 'XM2',
          boPhan: 'May quai',
        ),
        // No WorkID on the summary: kept by its row in XM3.
        WorkHistorySummary(
          workerId: 'C',
          workerName: 'Cường',
          assignedQuantity: 10,
          completedQuantity: 0,
          remainingQuantity: 10,
          unitOfMeasure: 'CHC',
          transactionCount: 1,
        ),
      ],
    );
    expect(historyDepartments(history).map((d) => d.label), [
      'Giải chuyền 1 · XM1',
      'May quai · XM2',
      'XM3',
    ]);
    final xm3 = filterHistoryByWorkId(history, 'xm3');
    expect(xm3.entries.map((e) => e.transactionUuid), ['3']);
    expect(xm3.workers.map((w) => w.workerId), ['C']);
    expect(identical(filterHistoryByWorkId(history, null), history), isTrue);
    // The search box finds a department by code or name.
    expect(
      filterHistoryByWorker(history, 'may quai').workers.map((w) => w.workerId),
      ['B'],
    );
    expect(
      filterHistoryByWorker(
        history,
        'XM1',
      ).entries.map((e) => e.transactionUuid),
      ['1'],
    );
  });
}
