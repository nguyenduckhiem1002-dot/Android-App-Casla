import 'package:casla_production/app/theme/casla_spacing.dart';
import 'package:casla_production/app/theme/casla_theme.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/domain/policies/recall_all.dart';
import 'package:casla_production/presentation/widgets/recall_all_confirm_dialog.dart';
import 'package:casla_production/presentation/widgets/sync_failure_dialog.dart';
import 'package:casla_production/presentation/widgets/worker_verification_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _lot = Assignment(
  id: 'a1',
  workerId: 'w1',
  workerMaNv: 'CL400111',
  workerName: 'Nguyễn Văn An',
  teamId: 't1',
  orderId: 'o1',
  orderCode: 'OC1',
  productionOrder: '1000234',
  operation: '0010',
  operationName: 'Cắt đá',
  productCode: 'p1',
  productName: 'Đá',
  uom: 'CAI',
  assignedQuantity: 150,
  completedQuantity: 0,
  recalledQuantity: 0,
  businessDate: '2026-11-17',
  shiftId: 's1',
  status: AssignmentStatus.open,
  createdBy: 'sup',
  idempotencyKey: 'k1',
  syncStatus: SyncStatus.synced,
);

void main() {
  // A plain popup and the ones that used to set their own side gap, each
  // opened the way the screens open it.
  final popups = <String, Future<Object?> Function(BuildContext)>{
    // A short title and message: the test font draws every letter 1 em
    // wide, so a longer text would fill the screen on its own and hide a
    // popup that shrinks to its text.
    'plain': (context) => showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Lỗi'),
        content: const Text('OK'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Đã hiểu'),
          ),
        ],
      ),
    ),
    'worker password': (context) => showWorkerVerificationDialog(
      context,
      workerName: 'Nguyễn Văn An',
      actionLabel: 'gửi xác nhận lên SAP',
      summary: const WorkerQuantitySummary(
        uom: 'CAI',
        workerCode: 'CL400111',
        completedTotal: 120,
      ),
    ),
    'recall all': (context) => showRecallAllConfirmDialog(
      context,
      workerName: 'Nguyễn Văn An',
      workerCode: 'CL400111',
      lines: const [
        RecallAllLine(members: [_lot], target: _lot, quantity: 150),
      ],
    ),
    'sync failure': (context) => showSyncFailureDialog(
      context,
      data: const SyncFailureDialogData(
        message: 'SAP từ chối giao dịch.',
        guidance: 'Kiểm tra lại số lượng rồi gửi lại.',
      ),
    ),
  };

  Future<void> pumpAndOpen(
    WidgetTester tester,
    Future<Object?> Function(BuildContext) open,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: CaslaTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => open(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  /// The popup's own surface, inside the screen-wide [Dialog] padding.
  Finder surface() => find
      .descendant(of: find.byType(Dialog), matching: find.byType(Material))
      .first;

  BorderRadiusGeometry radiusOf(WidgetTester tester) =>
      (tester.widget<Material>(surface()).shape! as RoundedRectangleBorder)
          .borderRadius;

  for (final MapEntry(key: name, value: open) in popups.entries) {
    testWidgets('the $name popup keeps the shared side gap and corners', (
      tester,
    ) async {
      await pumpAndOpen(tester, open);

      final rect = tester.getRect(surface());
      expect(rect.left, CaslaDialog.sideGap);
      expect(rect.width, 360 - 2 * CaslaDialog.sideGap);
      expect(radiusOf(tester), BorderRadius.circular(CaslaDialog.radius));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the date picker has the same corners as the other popups', (
    tester,
  ) async {
    // Its size is the calendar's own, so only the corners are shared.
    await pumpAndOpen(
      tester,
      (context) => showDatePicker(
        context: context,
        initialDate: DateTime(2026, 11, 19),
        firstDate: DateTime(2026),
        lastDate: DateTime(2027),
      ),
    );

    expect(radiusOf(tester), BorderRadius.circular(CaslaDialog.radius));
    expect(tester.takeException(), isNull);
  });
}
