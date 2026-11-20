// The question shown by "Thu hồi không mật khẩu" on the worker list: the
// worker, the total taken back and one line per order/operation.

import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/domain/policies/recall_all.dart';
import 'package:casla_production/presentation/widgets/recall_all_confirm_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Assignment _lot(
  String id, {
  required String operation,
  required double assigned,
  String position = '',
  String uom = 'CHC',
}) => Assignment(
  id: id,
  workerId: 'worker',
  workerMaNv: 'CL400082',
  workerName: 'Bùi Văn Luận',
  teamId: 'WORK-A',
  orderId: 'order-$operation',
  orderCode: '104000000225',
  productionOrder: '104000000225',
  operation: operation,
  productCode: 'SP01',
  productName: 'Sản phẩm',
  uom: uom,
  assignedQuantity: assigned,
  completedQuantity: 0,
  recalledQuantity: 0,
  businessDate: '2026-11-19',
  shiftId: '1',
  status: AssignmentStatus.open,
  createdBy: 'supervisor',
  idempotencyKey: id,
  syncStatus: SyncStatus.synced,
  positionId: position,
);

Future<bool?> _open(WidgetTester tester, List<RecallAllLine> lines) async {
  bool? answer;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer = await showRecallAllConfirmDialog(
              context,
              workerName: 'Bùi Văn Luận',
              workerCode: 'CL400082',
              lines: lines,
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return answer;
}

void main() {
  final lines = planRecallAll([
    _lot('a', operation: '0010', assigned: 1000),
    _lot('b', operation: '0020', assigned: 2000),
    _lot('c', operation: '0030', assigned: 2000),
  ]);

  testWidgets('names the worker, the total and every order', (tester) async {
    await _open(tester, lines);

    expect(find.text('Thu hồi không mật khẩu'), findsOneWidget);
    expect(find.textContaining('Bùi Văn Luận'), findsOneWidget);
    expect(find.textContaining('CL400082'), findsOneWidget);
    expect(find.text('TỔNG THU HỒI'), findsOneWidget);
    // 1.000 + 2.000 + 2.000, one unit: the bare figure.
    expect(find.text('5.000'), findsOneWidget);
    expect(find.text('104000000225.0010'), findsOneWidget);
    expect(find.text('104000000225.0020'), findsOneWidget);
    expect(find.text('1.000 CHC'), findsOneWidget);
    expect(find.text('2.000 CHC'), findsNWidgets(2));
  });

  testWidgets('answers true only for "Thu hồi & gửi SAP"', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer = await showRecallAllConfirmDialog(
                context,
                workerName: 'Bùi Văn Luận',
                workerCode: 'CL400082',
                lines: lines,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thu hồi & gửi SAP'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  test('units are totalled apart, never added together', () {
    final mixed = planRecallAll([
      _lot('a', operation: '0010', assigned: 1000),
      _lot('b', operation: '0020', assigned: 12.5, uom: 'KG'),
      _lot('c', operation: '0030', assigned: 500),
    ]);

    expect(recallAllTotals(mixed), {'CHC': 1500.0, 'KG': 12.5});
  });

  test('two positions of one order/operation are told apart', () {
    final seats = planRecallAll([
      _lot('blank', operation: '0010', assigned: 100),
      _lot('tr1', operation: '0010', assigned: 800, position: 'TR1'),
      _lot('other', operation: '0020', assigned: 50),
    ]);

    expect(
      [for (final line in seats) recallAllLineLabel(line, seats)],
      [
        '104000000225.0010 · không vị trí',
        '104000000225.0010 · TR1',
        '104000000225.0020',
      ],
    );
  });
}
