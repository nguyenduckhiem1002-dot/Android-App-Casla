import 'package:casla_production/domain/entities/entities.dart';
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

  group('workIdsOfWorkCenter', () {
    UserWorkContext context(
      String id,
      String workCenter, {
      String plant = '6711',
    }) => UserWorkContext(
      workId: id,
      workName: id,
      plant: plant,
      workCenter: workCenter,
    );
    final contexts = [
      context('XM1-LT', 'CL100075'),
      context('XM1-QUAI', 'CL100075'),
      context('XM2-CTP', 'CL100076'),
      context('XM2-MM', 'cl100076 '),
      context('BT1', 'CL100090', plant: '6712'),
      context('', 'CL100076'),
    ];

    test('keeps the departments of the active work center only', () {
      expect(
        workIdsOfWorkCenter(contexts, active: context('XM2-CTP', 'CL100076')),
        {'XM2-CTP', 'XM2-MM'},
      );
      expect(
        workIdsOfWorkCenter(contexts, active: context('XM1-LT', 'CL100075')),
        {'XM1-LT', 'XM1-QUAI'},
      );
    });

    test('another plant with the same work center code is not the same', () {
      expect(
        workIdsOfWorkCenter([
          context('A', 'CL100090', plant: '6711'),
          ...contexts,
        ], active: context('BT1', 'CL100090', plant: '6712')),
        {'BT1'},
      );
    });

    test('cannot narrow without a work center or a match', () {
      expect(workIdsOfWorkCenter(contexts, active: null), isNull);
      expect(workIdsOfWorkCenter(contexts, active: context('X', '')), isNull);
      expect(
        workIdsOfWorkCenter(contexts, active: context('X', 'CL100099')),
        isNull,
      );
      expect(
        workIdsOfWorkCenter(const [], active: context('X', 'CL100076')),
        isNull,
      );
    });

    test('the filter list offers the active work center only', () {
      // A supervisor on CL100076 authorized for CL100075 too: the list
      // matches "Tất cả tổ" and leaves the other work center out.
      expect(
        workContextsOfWorkCenter(
          contexts,
          active: context('XM2-CTP', 'CL100076'),
        ).map((c) => c.workId),
        ['XM2-CTP', 'XM2-MM'],
      );
      expect(
        workContextsOfWorkCenter(
          contexts,
          active: context('BT1', 'CL100090', plant: '6712'),
        ).map((c) => c.workId),
        ['BT1'],
      );
    });

    test('a history filter adds the departments booked in the work center', () {
      WorkHistoryEntry booked(String workId, String center, String plant) =>
          WorkHistoryEntry(
            transactionUuid: '$workId-$center',
            executionDate: DateTime(2026, 9, 9),
            workerId: 'worker',
            workerName: '',
            productionOrder: 'order',
            operation: '0010',
            plant: plant,
            workCenter: center,
            workId: workId,
            transactionType: 'INITIAL_ASSIGN',
            quantity: 1,
            unitOfMeasure: 'KG',
            transactionStatus: 'POSTED',
          );
      final history = result([
        booked('xm2-extra', 'CL100076', '6711'),
        booked('XM1-LT', 'CL100075', '6711'),
        booked('OTHER-PLANT', 'CL100076', '6799'),
        booked('', 'CL100076', '6711'),
      ]);
      expect(
        historyFilterWorkIds(
          history,
          contexts,
          active: context('XM2-CTP', 'CL100076'),
        ),
        {'XM2-CTP', 'XM2-MM', 'XM2-EXTRA'},
      );
      // No shift (the worker role): nothing is narrowed.
      expect(historyFilterWorkIds(history, contexts, active: null), isNull);
    });

    test('the filter list keeps every context when it cannot narrow', () {
      expect(workContextsOfWorkCenter(contexts, active: null), contexts);
      expect(
        workContextsOfWorkCenter(contexts, active: context('X', 'CL100099')),
        contexts,
      );
    });
  });
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
