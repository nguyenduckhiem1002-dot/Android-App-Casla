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
    test('takes the newest assignment of that worker that has a position', () {
      final position = groupPositionFromHistory([
        _entry(worker: 'CL400096', position: 'G05', hour: 8),
        _entry(worker: 'CL400096', position: '', hour: 9),
        _entry(worker: 'CL400096', position: 'g07', hour: 10),
        _entry(worker: 'CL400112', position: 'G12', hour: 11),
      ], workerId: 'cl400096');

      expect(position, 'G07');
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

    test('no earlier position leaves the choice free', () {
      expect(conflict(null, 'G07'), isNull);
      expect(conflict('', null), isNull);
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
}
