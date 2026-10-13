import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/presentation/widgets/confirmation_target_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Assignment target(
  String id,
  double qty, {
  String operation = '0020',
  int createdAtUtc = 0,
}) => Assignment(
  id: id,
  workerId: 'worker',
  workerMaNv: 'NV',
  workerName: 'Khiêm',
  teamId: 'XM2.002',
  orderId: 'order',
  orderCode: '010140000365',
  productionOrder: '010140000365',
  operation: operation,
  operationName: 'May Miệng hông 2 đường chỉ',
  productCode: 'SP',
  productName: 'Túi',
  uom: 'CHC',
  assignedQuantity: qty,
  completedQuantity: 0,
  recalledQuantity: 0,
  businessDate: '2026-09-23',
  shiftId: 'DAY',
  status: AssignmentStatus.open,
  createdBy: 'SAP',
  idempotencyKey: id,
  syncStatus: SyncStatus.synced,
  createdAtUtc: createdAtUtc,
);

void main() {
  Future<List<Assignment>?> pick(
    WidgetTester tester,
    List<Assignment> targets, {
    Size size = const Size(375, 812),
    String? tapText,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List<Assignment>? selected;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.5),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await pickConfirmationGroup(context, targets);
              },
              child: const Text('Mở'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Mở'));
    await tester.pumpAndSettle();
    if (tapText != null) {
      final line = find.textContaining(tapText);
      await tester.scrollUntilVisible(
        line,
        120,
        scrollable: find.byType(Scrollable),
      );
      await tester.pumpAndSettle();
      await tester.tap(line);
      await tester.pumpAndSettle();
    }
    return selected;
  }

  testWidgets('lots of one order and operation open as one, oldest first', (
    tester,
  ) async {
    final selected = await pick(tester, [
      target('newest', 1000, createdAtUtc: 30),
      target('oldest', 100, createdAtUtc: 10),
      target('middle', 333, createdAtUtc: 20),
    ]);
    expect(find.text('Chọn công đoạn cần xác nhận'), findsNothing);
    expect(selected?.map((a) => a.id), ['oldest', 'middle', 'newest']);
  });

  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    testWidgets('different operations still ask, with group totals at $size', (
      tester,
    ) async {
      final selected = await pick(
        tester,
        [
          target('a', 100),
          target('b', 333),
          target('other', 50, operation: '0030'),
        ],
        size: size,
        tapText: 'Còn 433 CHC',
      );
      expect(find.textContaining('2 lần giao'), findsNothing);
      expect(selected?.map((a) => a.id).toSet(), {'a', 'b'});
      expect(tester.takeException(), isNull);
    });
  }
}
