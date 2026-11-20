import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/history_totals.dart';
import 'package:flutter_test/flutter_test.dart';

WorkHistoryEntry _row(
  String type,
  double quantity, {
  double defect = 0,
  String status = 'POSTED',
  String unit = 'CHC',
  int hour = 8,
}) => WorkHistoryEntry(
  transactionUuid: '$type-$quantity-$hour',
  executionDate: DateTime(2026, 10, 23, hour),
  workerId: 'CL400001',
  workerName: 'Đỗ Thị Chi',
  productionOrder: '010140000380',
  operation: '0010',
  plant: '1000',
  workCenter: 'CL100077',
  transactionType: type,
  quantity: quantity,
  defectQuantity: defect,
  unitOfMeasure: unit,
  transactionStatus: status,
);

WorkHistorySummary _summary(
  String unit, {
  required double given,
  required double completed,
  double defect = 0,
  double recalled = 0,
  required double remaining,
  String workId = 'XM1',
}) => WorkHistorySummary(
  workerId: 'CL400001',
  workerName: 'Đỗ Thị Chi',
  assignedQuantity: given,
  completedQuantity: completed,
  defectQuantity: defect,
  recalledQuantity: recalled,
  remainingQuantity: remaining,
  unitOfMeasure: unit,
  transactionCount: 1,
  workId: workId,
);

void main() {
  group('historyGroupTotals', () {
    test('an operation card adds up, scrap and recall included', () {
      final totals = historyGroupTotals([
        _row('INITIAL_ASSIGN', 1000),
        _row('REASSIGN', 20, hour: 7),
        _row('CONFIRM', 600, defect: 30, hour: 9),
        _row('RECALL', 100, hour: 10),
      ]);

      expect(totals.unit, 'CHC');
      expect(totals.given, 1000);
      expect(totals.carriedOver, 20);
      expect(totals.completed, 600);
      expect(totals.defect, 30);
      expect(totals.recalled, 100);
      expect(totals.remaining, 290);
      expect(
        totals.given + totals.carriedOver,
        totals.completed + totals.defect + totals.recalled + totals.remaining,
      );
    });

    test('a reversal gives back its good and scrap quantity', () {
      final totals = historyGroupTotals([
        _row('INITIAL_ASSIGN', 500),
        _row('CONFIRM', 200, defect: 10, hour: 9),
        _row('REVERSE', 50, defect: 5, hour: 10),
      ]);

      expect(totals.completed, 150);
      expect(totals.defect, 5);
      expect(totals.remaining, 345);
    });

    test('a row SAP refused moves nothing', () {
      final totals = historyGroupTotals([
        _row('INITIAL_ASSIGN', 100),
        _row('CONFIRM', 80, defect: 5, status: 'FAILED', hour: 9),
        _row('RECALL', 20, status: 'failed', hour: 10),
      ]);

      expect(totals.completed, 0);
      expect(totals.defect, 0);
      expect(totals.recalled, 0);
      expect(totals.remaining, 100);
    });

    test('an over-confirmation leaves a negative balance, as SAP sums it', () {
      final totals = historyGroupTotals([
        _row('INITIAL_ASSIGN', 1000),
        _row('CONFIRM', 1500, hour: 9),
        _row('INITIAL_ASSIGN', 700, hour: 10),
      ]);

      expect(totals.given, 1700);
      expect(totals.remaining, 200);
    });
  });

  group('historyUnitTotals', () {
    test('rows of one unit are added; another unit stays apart', () {
      final units = historyUnitTotals([
        _summary(
          'CHC',
          given: 1000,
          completed: 600,
          defect: 30,
          recalled: 100,
          remaining: 270,
        ),
        // The same worker in another department (SAP splits by WorkID).
        _summary(
          'chc',
          given: 200,
          completed: 50,
          remaining: 150,
          workId: 'XM2',
        ),
        _summary('KG', given: 40, completed: 10, remaining: 30),
      ]);

      expect(units, hasLength(2));
      final pieces = units.first;
      expect(pieces.given, 1200);
      expect(pieces.completed, 650);
      expect(pieces.defect, 30);
      expect(pieces.recalled, 100);
      expect(pieces.remaining, 420);
      expect(
        pieces.given,
        pieces.completed + pieces.defect + pieces.recalled + pieces.remaining,
      );
      expect(units.last.unit, 'KG');
    });

    test('no summaries give no units', () {
      expect(historyUnitTotals(const []), isEmpty);
    });
  });
}
