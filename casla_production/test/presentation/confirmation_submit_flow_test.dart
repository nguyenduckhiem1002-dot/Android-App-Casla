import 'dart:async';

import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/sap_shift_controller.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/domain/entities/mutation_receipt.dart';
import 'package:casla_production/features/supervisor/screens/s08_assignment_detail_screen.dart';
import 'package:casla_production/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const assignment = Assignment(
  id: 'assignment',
  workerId: 'worker',
  workerMaNv: 'NV01',
  workerName: 'Công nhân',
  teamId: '',
  orderId: 'order',
  orderCode: 'LSX01',
  productCode: 'SP01',
  productName: 'Sản phẩm',
  uom: 'CHC',
  assignedQuantity: 1000,
  completedQuantity: 20,
  recalledQuantity: 1,
  businessDate: '2026-09-22',
  shiftId: '1',
  status: AssignmentStatus.open,
  createdBy: 'supervisor',
  idempotencyKey: 'key',
  syncStatus: SyncStatus.synced,
);

class _Database implements CaslaDatabase {
  @override
  Stream<List<Map<String, dynamic>>> watchRecordsByAssignment(String id) =>
      Stream.value([]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Assignments implements AssignmentRepositoryImpl {
  Assignment current = assignment;
  final Map<String, Assignment> byId = {};
  @override
  Stream<Assignment?> watchAssignment(String id) =>
      Stream.value(byId[id] ?? current);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Production implements ProductionRepositoryImpl {
  final result = Completer<MutationReceipt>();
  double? expected;
  double? quantitySent;
  bool autoSync = false;
  final sent = <String>[];
  @override
  Future<MutationReceipt> recordProduction({
    required String assignmentId,
    required double quantity,
    double defectQuantity = 0,
    required String businessDate,
    required String shiftId,
    required String createdBy,
    String? note,
    String? workerPassword,
    double? expectedRemaining,
  }) {
    expected = expectedRemaining;
    quantitySent = quantity;
    sent.add('$assignmentId:$quantity:$expectedRemaining');
    if (autoSync) {
      return Future.value(
        MutationReceipt(id: assignmentId, state: MutationDeliveryState.synced),
      );
    }
    return result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _State extends ChangeNotifier implements AppState {
  @override
  final db = _Database();
  @override
  final _Assignments assignmentRepo = _Assignments();
  @override
  final _Production productionRepo = _Production();
  @override
  final _Recall recallRepo = _Recall();
  @override
  UserSession? get currentSession => null;
  @override
  UserWorkContext? get activeWorkContext => null;
  @override
  SapShift get activeShift => SapShift.fromJson({'ShiftID': '1'});
  @override
  DateTime get activeBusinessDate => DateTime(2026, 9, 22);
  @override
  int get sessionGeneration => 1;
  @override
  bool isSessionGenerationCurrent(int generation) => true;
  @override
  Future<T> runCriticalOperation<T>(Future<T> Function() action) => action();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Recall implements RecallRepositoryImpl {
  int calls = 0;
  @override
  Future<MutationReceipt> recallAssignment({
    required String assignmentId,
    required double quantity,
    required String reasonCode,
    String? note,
    required String businessDate,
    required String shiftId,
    required String createdBy,
    String? workerPassword,
  }) async {
    calls++;
    return const MutationReceipt(
      id: 'recall',
      state: MutationDeliveryState.synced,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One allocation of the same worker, order and operation.
Assignment _lot(String id, double assigned, double completed, int at) =>
    Assignment(
      id: id,
      workerId: 'worker',
      workerMaNv: 'NV01',
      workerName: 'Công nhân',
      teamId: '',
      orderId: 'order',
      orderCode: 'LSX01',
      productionOrder: '010140000365',
      operation: '0020',
      productCode: 'SP01',
      productName: 'Sản phẩm',
      uom: 'CHC',
      assignedQuantity: assigned,
      completedQuantity: completed,
      recalledQuantity: 0,
      businessDate: '2026-09-22',
      shiftId: '1',
      status: AssignmentStatus.open,
      createdBy: 'supervisor',
      idempotencyKey: id,
      syncStatus: SyncStatus.synced,
      createdAtUtc: at,
    );

void main() {
  testWidgets('grouped lots confirm as one total, split oldest first', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _State();
    state.productionRepo.autoSync = true;
    final older = _lot('older', 100, 15, 1);
    final newer = _lot('newer', 333, 0, 2);
    state.assignmentRepo.byId.addAll({'older': older, 'newer': newer});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStateProvider.overrideWith((ref) => state)],
        child: MaterialApp(
          home: S08AssignmentDetailScreen(
            assignment: older,
            openConfirmation: true,
            confirmationGroup: [newer, older],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('418 CHC'), findsWidgets);
    expect(find.textContaining('gộp 2 lần giao'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '120');
    await tester.pump();
    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await tester.pumpAndSettle();
    expect(state.productionRepo.sent, ['older:85.0:null', 'newer:35.0:null']);
    expect(find.text('Xác nhận thành công'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('more than the group has left warns and is still confirmed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _State();
    state.productionRepo.autoSync = true;
    final older = _lot('older', 100, 15, 1);
    final newer = _lot('newer', 333, 0, 2);
    state.assignmentRepo.byId.addAll({'older': older, 'newer': newer});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStateProvider.overrideWith((ref) => state)],
        child: MaterialApp(
          home: S08AssignmentDetailScreen(
            assignment: older,
            openConfirmation: true,
            confirmationGroup: [newer, older],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('418 CHC'), findsWidgets);

    // 418 left in all; 500 is a warning under the field, not an error.
    await tester.enterText(find.byType(TextField).first, '500');
    await tester.pump();
    expect(find.text('Vượt số còn lại 418 CHC.'), findsOneWidget);
    expect(find.textContaining('vượt quá'), findsNothing);

    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await tester.pumpAndSettle();

    // The older lot closes at its 85; the surplus lands on the newest one.
    expect(state.productionRepo.sent, ['older:85.0:null', 'newer:415.0:null']);
    expect(find.text('Xác nhận thành công'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('direct form uses current balance instead of route snapshot', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _State();
    // Same assignment ID, stale route balance, refreshed durable balance.
    state.assignmentRepo.current = assignment.copyWith(
      completedQuantity: 900,
      recalledQuantity: 0,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStateProvider.overrideWith((ref) => state)],
        child: const MaterialApp(
          home: S08AssignmentDetailScreen(
            assignment: assignment,
            openConfirmation: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('100 CHC'), findsWidgets);
    expect(find.text('979 CHC'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'SAP rejection stops combined recall and keeps entered quantities',
    (tester) async {
      tester.view.physicalSize = const Size(420, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = _State();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appStateProvider.overrideWith((ref) => state)],
          child: const MaterialApp(
            home: S08AssignmentDetailScreen(
              assignment: assignment,
              openConfirmation: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '10');
      await tester.pump();
      await tester.tap(find.text('Có thu hồi'));
      await tester.pump();
      await tester.tap(find.text('Xác nhận'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'password');
      await tester.tap(find.text('Xác minh & gửi SAP'));
      await tester.pump();
      state.productionRepo.result.complete(
        const MutationReceipt(
          id: 'rejected',
          state: MutationDeliveryState.rejected,
          code: 'OPERATION_QUANTITY_EXCEEDED',
          message: 'Vượt sản lượng công đoạn',
        ),
      );
      await tester.pumpAndSettle();
      expect(state.recallRepo.calls, 0);
      expect(find.text('Đã lưu xác nhận'), findsNothing);
      await tester.tap(find.text('Đã hiểu'));
      await tester.pumpAndSettle();
      expect(find.text('Nhập số hoàn thành'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  for (final systemBack in [false, true]) {
    testWidgets(
      'direct confirmation returns once without detail page ($systemBack)',
      (tester) async {
        tester.view.physicalSize = const Size(420, 1500);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => Scaffold(
                body: TextButton(
                  onPressed: () => context.push('/confirm'),
                  child: const Text('Chọn nhân viên'),
                ),
              ),
            ),
            GoRoute(
              path: '/confirm',
              builder: (context, state) => const S08AssignmentDetailScreen(
                assignment: assignment,
                openConfirmation: true,
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appStateProvider.overrideWith((ref) => _State())],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.tap(find.text('Chọn nhân viên'));
        await tester.pumpAndSettle();
        expect(find.text('Nhập số hoàn thành'), findsOneWidget);
        expect(find.text('Nhập ít nhất một số lượng'), findsNothing);
        expect(find.text('Lịch sử giao dịch'), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byTooltip('Quay lại'));
        }
        await tester.pumpAndSettle();
        expect(find.text('Chọn nhân viên'), findsOneWidget);
        // Reopening quickly must not be closed by a delayed pop from the last form.
        await tester.tap(find.text('Chọn nhân viên'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Nhập số hoàn thành'), findsOneWidget);
        expect(find.text('Lịch sử giao dịch'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final fails in [false, true]) {
    testWidgets('keeps quantity form during submit and result (fails=$fails)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = _State();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appStateProvider.overrideWith((ref) => state)],
          child: const MaterialApp(
            home: S08AssignmentDetailScreen(assignment: assignment),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Xác nhận hoàn thành'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nhập số còn lại'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recall-quantity')), findsNothing);
      await tester.tap(find.text('Có thu hồi'));
      await tester.pumpAndSettle();
      final recallField = find.byKey(const ValueKey('recall-quantity'));
      expect(tester.widget<TextField>(recallField).controller!.text, '979');
      await tester.enterText(find.byType(TextField).first, '970');
      await tester.pump();
      expect(tester.widget<TextField>(recallField).controller!.text, '970');
      await tester.enterText(recallField, '20');
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, '969');
      await tester.pump();
      expect(tester.widget<TextField>(recallField).controller!.text, '20');
      await tester.tap(find.text('Có thu hồi'));
      await tester.pumpAndSettle();
      expect(recallField, findsNothing);
      expect(find.text('Thu hồi lượt này'), findsNothing);
      await tester.enterText(find.byType(TextField).first, '969');
      await tester.pump();
      await tester.tap(find.text('Xác nhận'));
      await tester.pumpAndSettle();
      // Cancelling verification must leave the entered quantity intact.
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(find.text('969'), findsOneWidget);
      await tester.tap(find.text('Xác nhận'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'password');
      await tester.tap(find.text('Xác minh & gửi SAP'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Đang xử lý xác nhận'), findsOneWidget);
      expect(find.text('Nhập số còn lại'), findsOneWidget);
      expect(find.text('969'), findsOneWidget);
      expect(state.productionRepo.expected, 979);
      expect(state.productionRepo.quantitySent, 10);
      expect(tester.takeException(), isNull);
      if (fails) {
        state.productionRepo.result.completeError(Exception('Lỗi kiểm tra'));
      } else {
        state.productionRepo.result.complete(
          const MutationReceipt(
            id: 'record',
            state: MutationDeliveryState.synced,
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Đang xử lý xác nhận'), findsNothing);
      expect(find.text('Nhập số còn lại'), findsOneWidget);
      await tester.tap(find.text('Đã hiểu'));
      await tester.pumpAndSettle();
      expect(
        find.text('Nhập số còn lại'),
        fails ? findsOneWidget : findsNothing,
      );
      if (fails) expect(find.text('969'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
