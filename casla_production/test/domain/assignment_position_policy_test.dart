import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/assignment_position_policy.dart';
import 'package:flutter_test/flutter_test.dart';

WorkHistoryEntry _entry({
  required String worker,
  required String position,
  String type = 'INITIAL_ASSIGN',
  int hour = 8,
}) => WorkHistoryEntry(
  transactionUuid: '$worker-$position-$hour',
  executionDate: DateTime(2026, 10, 5, hour),
  workerId: worker,
  workerName: worker,
  productionOrder: '100000000123',
  operation: '0010',
  plant: '1000',
  workCenter: 'CL100077',
  transactionType: type,
  quantity: 10,
  unitOfMeasure: 'CHC',
  transactionStatus: 'POSTED',
  positionId: position,
);

void main() {
  group('groupPositionFromHistory', () {
    test('takes the newest assignment of that worker', () {
      final position = groupPositionFromHistory([
        _entry(worker: 'CL400096', position: 'G05', hour: 8),
        _entry(worker: 'CL400096', position: '', hour: 9),
        _entry(worker: 'CL400096', position: 'g07', hour: 10),
        _entry(worker: 'CL400112', position: 'G12', hour: 11),
      ], workerId: 'cl400096');

      expect(position, 'G07');
    });

    test('a newest assignment without a position holds its own place', () {
      final position = groupPositionFromHistory([
        _entry(worker: 'CL400096', position: 'G05', hour: 8),
        _entry(worker: 'CL400096', position: '', hour: 9),
      ], workerId: 'CL400096');

      expect(position, '');
    });

    test('ignores confirmations, recalls and other workers', () {
      final position = groupPositionFromHistory([
        _entry(worker: 'CL400096', position: 'G05', type: 'CONFIRM'),
        _entry(worker: 'CL400096', position: 'G05', type: 'RECALL'),
        _entry(worker: 'CL400112', position: 'G12'),
      ], workerId: 'CL400096');

      expect(position, isNull);
    });
  });

  group('groupPositionConflict', () {
    String? conflict(String? group, String? selected) => groupPositionConflict(
      groupPositionId: group,
      selectedPositionId: selected,
      productionOrder: '100000000123',
      operation: '0010',
    );

    test('the same position, in any letter case, is fine', () {
      expect(conflict('G05', 'g05'), isNull);
    });

    test('no earlier assignment leaves the choice free', () {
      expect(conflict(null, 'G07'), isNull);
      expect(conflict(null, null), isNull);
      expect(conflict('', null), isNull);
    });

    test('work given without a position must be settled before a position', () {
      expect(
        conflict('', 'G07'),
        'Tồn tại phân công của lệnh 100000000123, công đoạn 0010 chưa gắn vị '
        'trí. Xác nhận hoặc thu hồi hết phân công đó rồi mới giao ở vị trí G07.',
      );
    });

    test('dropping the position is refused and names the one to scan', () {
      final message = conflict('G05', null);

      expect(
        message,
        'Tồn tại phân công của lệnh 100000000123, công đoạn 0010 tại vị trí '
        'G05. Hãy quét vị trí G05 để giao tiếp.',
      );
    });

    test('another position is refused and names both', () {
      final message = conflict('G05', 'G07');

      expect(
        message,
        'Tồn tại phân công của lệnh 100000000123, công đoạn 0010 tại vị trí '
        'G05. Không thể giao ở vị trí G07.',
      );
    });
  });

  group('openGroupPositionFromHistory', () {
    WorkHistoryEntry row(String type, double quantity, {double defect = 0}) =>
        WorkHistoryEntry(
          transactionUuid: '$type-$quantity-$defect',
          executionDate: DateTime(2026, 10, 5, 8),
          workerId: 'CL400096',
          workerName: 'CL400096',
          productionOrder: '100000000123',
          operation: '0010',
          plant: '1000',
          workCenter: 'CL100077',
          transactionType: type,
          quantity: quantity,
          defectQuantity: defect,
          unitOfMeasure: 'CHC',
          transactionStatus: 'POSTED',
          positionId: 'D2-5',
        );
    WorkHistorySummary total(double remaining) => WorkHistorySummary(
      workerId: 'cl400096',
      workerName: 'CL400096',
      assignedQuantity: 10,
      completedQuantity: 10 - remaining,
      remainingQuantity: remaining,
      unitOfMeasure: 'CHC',
      transactionCount: 2,
    );
    WorkHistoryResult history(
      List<WorkHistoryEntry> entries, {
      List<WorkHistorySummary> workers = const [],
    }) => WorkHistoryResult(
      scopeCode: 'T',
      dateFrom: DateTime(2026, 10, 5),
      dateTo: DateTime(2026, 10, 5),
      isTruncated: false,
      entries: entries,
      workers: workers,
    );
    String? open(WorkHistoryResult result) =>
        openGroupPositionFromHistory(result, workerId: 'CL400096');

    test('an open group keeps its position', () {
      expect(
        open(history([row('INITIAL_ASSIGN', 10), row('CONFIRM', 4)])),
        'D2-5',
      );
      expect(
        open(history([row('INITIAL_ASSIGN', 10)], workers: [total(6)])),
        'D2-5',
      );
    });

    test('a fully recalled group frees the position', () {
      expect(
        open(history([row('INITIAL_ASSIGN', 10), row('RECALL', 10)])),
        isNull,
      );
    });

    test('confirmed, defective and recalled down to zero frees it', () {
      expect(
        open(
          history([
            row('INITIAL_ASSIGN', 10),
            row('CONFIRM', 5, defect: 2),
            row('RECALL', 3),
          ]),
        ),
        isNull,
      );
    });

    test("SAP's own total decides when it is present", () {
      expect(
        open(history([row('INITIAL_ASSIGN', 10)], workers: [total(0)])),
        isNull,
      );
    });

    test('a reversed confirmation reopens the group', () {
      expect(
        open(
          history([
            row('INITIAL_ASSIGN', 10),
            row('CONFIRM', 10),
            row('REVERSE', 10),
          ]),
        ),
        'D2-5',
      );
    });

    test('a transfer without direction keeps the check conservative', () {
      expect(
        open(
          history([
            row('INITIAL_ASSIGN', 10),
            row('TRANSFER', 10),
            row('RECALL', 10),
          ]),
        ),
        'D2-5',
      );
    });
  });

  group('openGroupPosition', () {
    WorkHistoryEntry row(
      String type,
      double quantity, {
      double defect = 0,
      String position = 'A-04',
      int hour = 8,
    }) => WorkHistoryEntry(
      transactionUuid: '$type-$quantity-$defect-$hour',
      executionDate: DateTime(2026, 10, 29, hour),
      workerId: 'CL1HA001',
      workerName: 'HA Văn Thủy',
      productionOrder: '010140000374',
      operation: '0040',
      plant: '1000',
      workCenter: 'XM1',
      transactionType: type,
      quantity: quantity,
      defectQuantity: defect,
      unitOfMeasure: 'CHC',
      transactionStatus: 'POSTED',
      positionId: position,
    );
    WorkHistoryResult history(List<WorkHistoryEntry> entries) =>
        WorkHistoryResult(
          scopeCode: 'T',
          dateFrom: DateTime(2026, 10, 29),
          dateTo: DateTime(2026, 10, 29),
          isTruncated: false,
          entries: entries,
          workers: const [],
        );
    GroupAssignmentLedger ledger({
      String? position = 'A-04',
      required double remaining,
      double unsent = 0,
    }) => GroupAssignmentLedger(
      hasRows: true,
      position: position,
      remaining: remaining,
      unsentDelta: unsent,
    );
    String? open({GroupAssignmentLedger? local, WorkHistoryResult? history}) =>
        openGroupPosition(local: local, history: history, workerId: 'cl1ha001');

    test('a seat confirmed below zero against carried-over work frees the '
        'position even while the lot held here looks untouched', () {
      // Given 610 today at A-04 on this device; SAP also carries 2.000 from
      // the day before and a 3.000 + 20 confirmation booked on that pile.
      expect(
        open(
          local: ledger(remaining: 610),
          history: history([
            row('REASSIGN', 2000, position: '', hour: 6),
            row('INITIAL_ASSIGN', 610),
            row('CONFIRM', 3000, defect: 20, hour: 9),
          ]),
        ),
        isNull,
      );
    });

    test('an open seat keeps the position SAP recorded', () {
      expect(
        open(
          local: ledger(remaining: 610),
          history: history([row('INITIAL_ASSIGN', 610), row('CONFIRM', 100)]),
        ),
        'A-04',
      );
    });

    test('a lot not yet sent keeps the seat open', () {
      // SAP's pile is spent; a top-up of 5 at A-04 still waits in the queue.
      expect(
        open(
          local: ledger(remaining: 5, unsent: 5),
          history: history([row('INITIAL_ASSIGN', 10), row('CONFIRM', 10)]),
        ),
        'A-04',
      );
      // And when SAP never saw the group at all, the queued lot is the group.
      expect(
        open(local: ledger(remaining: 5, unsent: 5), history: history([])),
        'A-04',
      );
    });

    test('a confirmation not yet sent settles the seat', () {
      expect(
        open(
          local: ledger(remaining: 0, unsent: -10),
          history: history([row('INITIAL_ASSIGN', 10)]),
        ),
        isNull,
      );
    });

    test('without SAP the rows held here decide', () {
      expect(open(local: ledger(remaining: 610)), 'A-04');
      expect(open(local: ledger(remaining: 0)), isNull);
      expect(open(local: ledger(remaining: -410)), isNull);
      expect(open(), isNull);
    });

    test('a transfer without direction keeps the check conservative', () {
      expect(
        open(
          local: ledger(remaining: 0),
          history: history([
            row('INITIAL_ASSIGN', 10),
            row('TRANSFER', 10),
            row('RECALL', 10),
          ]),
        ),
        'A-04',
      );
    });

    test(
      'SAP rows of another device bind a position this device never saw',
      () {
        expect(
          open(local: null, history: history([row('INITIAL_ASSIGN', 10)])),
          'A-04',
        );
      },
    );
  });
}
