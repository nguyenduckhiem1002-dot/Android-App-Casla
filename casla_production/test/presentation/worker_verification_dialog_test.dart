import 'package:casla_production/presentation/widgets/worker_verification_dialog.dart';
import 'package:casla_production/app/theme/casla_colors.dart';
import 'package:casla_production/app/theme/casla_theme.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _open(
  WidgetTester tester, {
  required String workerName,
  WorkerQuantitySummary? summary,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: CaslaTheme.light,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showWorkerVerificationDialog(
              context,
              workerName: workerName,
              actionLabel: 'xác nhận số đạt, số phế và thu hồi lên SAP',
              summary: summary,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  // Long figures in all three tiles: the tightest the summary gets.
  const wideSummary = WorkerQuantitySummary(
    workerCode: 'CL400111',
    uom: 'M2',
    completed: 12500.125,
    defect: 1250.5,
    recalled: 10000.75,
  );
  // A long total on the one line an assignment shows.
  const wideAssigned = WorkerQuantitySummary(
    workerCode: 'CL400111',
    uom: 'M2',
    assigned: 125000.125,
  );
  // A long total on the one line a multi-operation confirmation shows; its
  // caption is the longest.
  const wideCompletedTotal = WorkerQuantitySummary(
    workerCode: 'CL400111',
    uom: 'M2',
    completedTotal: 125000.125,
  );
  for (final (size, label, summary) in [
    for (final size in const [Size(320, 480), Size(360, 640), Size(640, 360)])
      for (final (String label, WorkerQuantitySummary? summary) in const [
        ('', null),
        (' with the quantity summary', wideSummary),
        (' with the quantity given', wideAssigned),
        (' with the total completed', wideCompletedTotal),
      ])
        (size, label, summary),
  ]) {
    testWidgets('PDA $size keyboard does not overlap password field and actions'
        '$label', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final keyboardHeight = size.height < 400 ? 140.0 : 220.0;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          theme: CaslaTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showWorkerVerificationDialog(
                  context,
                  workerName: 'Test 1',
                  actionLabel: 'gửi phân công lên SAP',
                  summary: summary,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byType(TextField));
      await tester.pumpAndSettle();
      final field = tester.getRect(find.byType(TextField));
      final cancel = tester.getRect(find.widgetWithText(TextButton, 'Hủy'));
      expect(field.overlaps(cancel), isFalse);
      expect(
        tester.getRect(find.byType(FilledButton)).bottom,
        lessThanOrEqualTo(size.height - keyboardHeight),
      );
      await tester.enterText(find.byType(TextField), 'test-password');
      await tester.tap(find.text('Xác minh & gửi SAP'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'keyboard and button submitting together only close the dialog once',
    (tester) async {
      final observer = _PopObserver();
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showWorkerVerificationDialog(
                    context,
                    workerName: 'Công nhân A',
                    actionLabel: 'nhận sản phẩm',
                  );
                },
                child: const Text('Mở xác minh'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Mở xác minh'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'test-password');
      final keyboardSubmit = tester
          .widget<TextField>(find.byType(TextField))
          .onSubmitted!;
      final buttonSubmit = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      keyboardSubmit('test-password');
      buttonSubmit();
      await tester.pumpAndSettle();
      expect(observer.pops, 1);
      expect(result, 'test-password');
      expect(find.text('Mở xác minh'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Mở xác minh'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
  );

  testWidgets('summary shows every figure the worker signs for', (
    tester,
  ) async {
    await _open(
      tester,
      workerName: 'Nguyễn Văn An',
      summary: const WorkerQuantitySummary(
        workerCode: 'CL400111',
        uom: 'CAI',
        completed: 120,
        defect: 3,
        recalled: 10,
      ),
    );

    // One plain frame holds all three figures, each in the same ink.
    final frame = find.byKey(const ValueKey('worker-quantity-summary'));
    expect(frame, findsOneWidget);
    for (final figure in ['120', '3', '10']) {
      final text = tester.widget<Text>(
        find.descendant(of: frame, matching: find.text(figure)),
      );
      expect(text.style?.color, CaslaColors.primaryNavy);
    }
    expect(find.text('Số đạt'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);
    expect(find.text('Số phế'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Thu hồi'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(
      find.text('Nguyễn Văn An · CL400111', findRichText: true),
      findsOneWidget,
    );
    // Only who signs and the figures: no operation line, no balance left
    // afterwards, no sentence and no password note.
    expect(find.textContaining('LSX'), findsNothing);
    expect(find.text('Còn lại sau khi gửi'), findsNothing);
    expect(find.textContaining('cần nhập mật khẩu SAP'), findsNothing);
    expect(find.textContaining('không được lưu trên thiết bị'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an assignment shows the quantity given on one line', (
    tester,
  ) async {
    await _open(
      tester,
      workerName: 'Bùi Văn Luận',
      summary: const WorkerQuantitySummary(
        workerCode: 'CL400082',
        uom: 'CAI',
        assigned: 120,
      ),
    );

    final frame = find.byKey(const ValueKey('worker-assigned-total'));
    expect(frame, findsOneWidget);
    expect(
      find.descendant(of: frame, matching: find.text('SỐ LƯỢNG GIAO')),
      findsOneWidget,
    );
    expect(find.descendant(of: frame, matching: find.text('120')), findsOne);
    expect(
      find.text('Bùi Văn Luận · CL400082', findRichText: true),
      findsOneWidget,
    );
    // No confirmation figures and no sentence beside it.
    expect(find.byKey(const ValueKey('worker-quantity-summary')), findsNothing);
    expect(find.textContaining('cần nhập mật khẩu SAP'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('several operations confirmed at once show their total '
      'completed on one line', (tester) async {
    await _open(
      tester,
      workerName: 'Bùi Văn Luận',
      summary: const WorkerQuantitySummary(
        workerCode: 'CL400082',
        uom: 'CAI',
        completedTotal: 120,
      ),
    );

    final frame = find.byKey(const ValueKey('worker-completed-total'));
    expect(frame, findsOneWidget);
    expect(
      find.descendant(of: frame, matching: find.text('SỐ LƯỢNG HOÀN THÀNH')),
      findsOneWidget,
    );
    expect(find.descendant(of: frame, matching: find.text('120')), findsOne);
    expect(
      find.text('Bùi Văn Luận · CL400082', findRichText: true),
      findsOneWidget,
    );
    // Only the total: no given line, no per-figure tiles, no sentence.
    expect(find.byKey(const ValueKey('worker-assigned-total')), findsNothing);
    expect(find.byKey(const ValueKey('worker-quantity-summary')), findsNothing);
    expect(find.textContaining('cần nhập mật khẩu SAP'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('summary hides zero figures and a code equal to the name', (
    tester,
  ) async {
    await _open(
      tester,
      workerName: 'CL400111',
      summary: const WorkerQuantitySummary(
        workerCode: 'CL400111',
        uom: 'CAI',
        completed: 50,
      ),
    );

    expect(find.text('Số đạt'), findsOneWidget);
    expect(find.text('Số phế'), findsNothing);
    expect(find.text('Thu hồi'), findsNothing);
    expect(find.text('CL400111', findRichText: true), findsOneWidget);
    expect(find.textContaining(' · ', findRichText: true), findsNothing);
  });

  testWidgets('without a summary the dialog keeps its sentence', (
    tester,
  ) async {
    await _open(tester, workerName: 'Công nhân A');

    expect(
      find.text(
        'Công nhân A cần nhập mật khẩu SAP để xác nhận số đạt, số phế và '
        'thu hồi lên sap.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('không được lưu trên thiết bị'), findsNothing);
  });

  test('forAssignment carries the worker code, unit and figures', () {
    final summary = WorkerQuantitySummary.forAssignment(
      const Assignment(
        id: 'a1',
        workerId: 'w1',
        workerMaNv: ' CL400111 ',
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
      ),
      completed: 120,
      defect: 3,
      recalled: 10,
    );

    expect(summary.workerCode, 'CL400111');
    expect(summary.uom, 'CAI');
    expect(summary.completed, 120);
    expect(summary.defect, 3);
    expect(summary.recalled, 10);
  });

  testWidgets('worker password opts out of platform autofill', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showWorkerVerificationDialog(
                context,
                workerName: 'Công nhân A',
                actionLabel: 'xác nhận sản lượng',
              ),
              child: const Text('Mở xác minh'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Mở xác minh'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autofillHints, isNull);
    expect(field.enableIMEPersonalizedLearning, isFalse);
  });
}

class _PopObserver extends NavigatorObserver {
  int pops = 0;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
  }
}
