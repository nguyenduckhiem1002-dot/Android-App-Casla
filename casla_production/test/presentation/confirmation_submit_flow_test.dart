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
  double? defectSent;
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
    defectSent = defectQuantity;
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
  _State({
    this.permissions = const {
      Permission.confirmProduction,
      Permission.recallAssignment,
    },
  });

  /// The SAP functions of the signed-in supervisor (PP_CONFIRM / PP_RECALL).
  final Set<Permission> permissions;

  @override
  final db = _Database();
  @override
  final _Assignments assignmentRepo = _Assignments();
  @override
  final _Production productionRepo = _Production();
  @override
  final _Recall recallRepo = _Recall();
  @override
  UserSession? get currentSession => UserSession(
    id: 'supervisor-session',
    maNv: '',
    fullName: 'Supervisor',
    teamName: '',
    role: UserRole.supervisor,
    permissions: permissions,
  );
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
  double? quantitySent;
  String? passwordSent;
  bool? withoutPasswordSent;
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
    double? seatCeiling,
    bool withoutWorkerPassword = false,
  }) async {
    calls++;
    quantitySent = quantity;
    passwordSent = workerPassword;
    withoutPasswordSent = withoutWorkerPassword;
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
  testWidgets('grouped lots confirm as one total in one transaction', (
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
    // One transaction with the entered total, on the oldest open lot.
    expect(state.productionRepo.sent, ['older:120.0:null']);
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

    // Sent exactly as entered, as one transaction on the oldest open lot.
    expect(state.productionRepo.sent, ['older:500.0:null']);
    expect(find.text('Xác nhận thành công'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'entering what is left lets defects exceed it with a warning, like '
    'entering what was finished',
    (tester) async {
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
              confirmationGroup: [newer, older],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Nhập số còn lại'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '400');
      await tester.pump();
      await tester.ensureVisible(find.text('Có số lượng phế'));
      await tester.tap(find.text('Có số lượng phế'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('defect-quantity')),
        '50',
      );
      await tester.pump();

      // 400 left plus 50 defective is more than the 418 on the seat: a
      // warning under the field, not an error, and the form still sends.
      expect(find.textContaining('vượt quá'), findsNothing);
      expect(
        find.text(
          'Tổng số phế và số còn lại vượt 418 CHC; số hoàn thành tính là '
          '0 CHC.',
        ),
        findsOneWidget,
      );

      await tester.ensureVisible(find.text('Xác nhận'));
      await tester.tap(find.text('Xác nhận'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'password');
      await tester.tap(find.text('Xác minh & gửi SAP'));
      await tester.pumpAndSettle();

      // Good 0, defective 50, guarded by the lot's own balance of 85.
      expect(state.productionRepo.sent, ['older:0.0:85.0']);
      expect(state.productionRepo.defectSent, 50);
      expect(find.text('Xác nhận thành công'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

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
          home: S08AssignmentDetailScreen(assignment: assignment),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('100 CHC'), findsWidgets);
    expect(find.text('979 CHC'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('a lot spent on paper keeps the seat balance it opened with', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = _State();
    state.productionRepo.autoSync = true;
    // 1.000 given and confirmed in full, yet SAP still holds 500 on the seat
    // (an over-confirmation cleared earlier, a later allocation reopened it).
    // The row read back from the database carries no seat figure.
    final spent = assignment.copyWith(
      completedQuantity: 1000,
      recalledQuantity: 0,
    );
    state.assignmentRepo.current = spent;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStateProvider.overrideWith((ref) => state)],
        child: MaterialApp(
          home: S08AssignmentDetailScreen(
            assignment: spent.copyWith(seatRemaining: 500),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('500 CHC'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, '300');
    await tester.pump();
    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await tester.pumpAndSettle();
    expect(state.productionRepo.sent, ['assignment:300.0:null']);
    expect(find.text('Xác nhận thành công'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
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
            home: S08AssignmentDetailScreen(assignment: assignment),
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
    testWidgets('leaving the form returns to its opener once ($systemBack)', (
      tester,
    ) async {
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
            builder: (context, state) =>
                const S08AssignmentDetailScreen(assignment: assignment),
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
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('what is left after confirming takes the recall off too', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStateProvider.overrideWith((ref) => _State())],
        child: const MaterialApp(
          home: S08AssignmentDetailScreen(assignment: assignment),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 979 left, 100 finished: 879 stay with the worker.
    await tester.enterText(find.byType(TextField).first, '100');
    await tester.pump();
    expect(find.text('879 CHC'), findsOneWidget);
    await tester.tap(find.text('Có thu hồi'));
    await tester.pumpAndSettle();
    // The recall is prefilled with everything left, so nothing stays.
    expect(find.text('879 CHC'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('recall-quantity')), '20');
    await tester.pump();
    expect(find.text('859 CHC'), findsOneWidget);
    expect(find.text('879 CHC'), findsNothing);
    // The bar still shows what was left to recall from.
    expect(find.text('còn 879 CHC'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final fails in [false, true]) {
    testWidgets('keeps quantity form during submit and result (fails=$fails)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final state = _State();
      // The form is a pushed page: a saved confirmation pops it.
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
            builder: (context, state) =>
                const S08AssignmentDetailScreen(assignment: assignment),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appStateProvider.overrideWith((ref) => state)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.tap(find.text('Chọn nhân viên'));
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

  group('form entries follow the SAP function of each operation', () {
    Future<void> pumpForm(
      WidgetTester tester,
      Set<Permission> permissions,
    ) async {
      tester.view.physicalSize = const Size(420, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(
              (ref) => _State(permissions: permissions),
            ),
          ],
          child: const MaterialApp(
            home: S08AssignmentDetailScreen(assignment: assignment),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('PP_CONFIRM alone: confirm without any recall control', (
      tester,
    ) async {
      await pumpForm(tester, {Permission.confirmProduction});

      expect(find.text('Nhập số còn lại'), findsOneWidget);
      expect(find.text('Có thu hồi'), findsNothing);
      expect(find.byKey(const ValueKey('recall-quantity')), findsNothing);
    });

    testWidgets('PP_RECALL alone: the form holds only the recall entry', (
      tester,
    ) async {
      await pumpForm(tester, {Permission.recallAssignment});

      expect(find.text('Nhập số còn lại'), findsNothing);
      expect(find.text('Nhập số hoàn thành'), findsNothing);
      expect(find.text('Có số lượng phế'), findsNothing);
      expect(find.text('Có thu hồi'), findsOneWidget);
      final recallField = find.byKey(const ValueKey('recall-quantity'));
      expect(recallField, findsOneWidget);
      // Ticked and filled with the balance: the form is ready to submit.
      expect(
        tester.widget<TextField>(recallField).controller!.text,
        isNotEmpty,
      );
      expect(find.text('Còn lại sau thu hồi'), findsOneWidget);
      expect(find.text('Ghi nhận hoàn thành'), findsNothing);
    });

    testWidgets('PP_INITIAL_ASSIGN alone: no entry form at all', (
      tester,
    ) async {
      await pumpForm(tester, {Permission.assignQuantity});

      expect(find.text('Không có quyền xác nhận'), findsOneWidget);
      expect(find.text('Nhập số hoàn thành'), findsNothing);
      expect(find.text('Có thu hồi'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });

    group('PP_RECALL_NOPASS: thu hồi không cần mật khẩu', () {
      const noPasswordBox = ValueKey('recall-without-password');
      const recallField = ValueKey('recall-quantity');
      const entryLock = ValueKey('confirm-entry-lock');
      const withAddOn = {
        Permission.confirmProduction,
        Permission.recallAssignment,
        Permission.recallWithoutPassword,
      };

      Future<_State> pumpConfirmation(
        WidgetTester tester,
        Set<Permission> permissions,
      ) async {
        tester.view.physicalSize = const Size(420, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final state = _State(permissions: permissions);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appStateProvider.overrideWith((ref) => state)],
            child: const MaterialApp(
              home: S08AssignmentDetailScreen(assignment: assignment),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return state;
      }

      Future<void> tickRecall(WidgetTester tester) async {
        await tester.tap(find.text('Có thu hồi'));
        await tester.pumpAndSettle();
      }

      Future<void> tickNoPassword(WidgetTester tester) async {
        await tester.ensureVisible(find.byKey(noPasswordBox));
        await tester.tap(find.byKey(noPasswordBox));
        await tester.pumpAndSettle();
      }

      bool entriesLocked(WidgetTester tester) =>
          tester.widget<IgnorePointer>(find.byKey(entryLock)).ignoring;

      testWidgets('the box shows only once "Có thu hồi" is ticked', (
        tester,
      ) async {
        await pumpConfirmation(tester, withAddOn);

        expect(find.byKey(noPasswordBox), findsNothing);
        await tickRecall(tester);
        expect(find.byKey(noPasswordBox), findsOneWidget);
        expect(find.text('Thu hồi không cần mật khẩu'), findsOneWidget);
        // Not ticked yet: everything is still an ordinary entry.
        expect(entriesLocked(tester), isFalse);
        expect(tester.widget<TextField>(find.byKey(recallField)).enabled, true);
      });

      testWidgets('ticked: one recall of what is left, no password asked', (
        tester,
      ) async {
        final state = await pumpConfirmation(tester, withAddOn);

        // A quantity typed before the tick must not travel with the recall.
        await tester.enterText(find.byType(TextField).first, '100');
        await tester.pump();
        await tickRecall(tester);
        await tickNoPassword(tester);

        // No confirmed, scrap or recall quantity can be entered any more.
        expect(entriesLocked(tester), isTrue);
        final recall = tester.widget<TextField>(find.byKey(recallField));
        expect(recall.enabled, isFalse);
        // 1000 given, 20 confirmed, 1 recalled: 979 left, all of it recalled.
        expect(recall.controller!.text, '979');
        expect(find.text('Ghi nhận hoàn thành'), findsNothing);
        // Nothing to edit, so no hint text under the locked quantity either.
        expect(find.textContaining('Có thể sửa số lượng'), findsNothing);

        await tester.tap(find.text('Thu hồi'));
        await tester.pumpAndSettle();
        // The supervisor confirms the figure; the password popup never opens.
        expect(find.text('Xác minh & gửi SAP'), findsNothing);
        await tester.tap(find.text('Thu hồi & gửi SAP'));
        await tester.pumpAndSettle();

        expect(state.recallRepo.calls, 1);
        expect(state.recallRepo.quantitySent, 979);
        expect(state.recallRepo.withoutPasswordSent, isTrue);
        expect(state.recallRepo.passwordSent, isNull);
        expect(state.productionRepo.sent, isEmpty);
        expect(find.text('Xác nhận thành công'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });

      testWidgets('cancelling the question sends nothing', (tester) async {
        final state = await pumpConfirmation(tester, withAddOn);

        await tickRecall(tester);
        await tickNoPassword(tester);
        await tester.tap(find.text('Thu hồi'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Hủy'));
        await tester.pumpAndSettle();

        expect(state.recallRepo.calls, 0);
        // The sheet is still there, still ticked.
        expect(entriesLocked(tester), isTrue);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });

      testWidgets('unticked again: the usual flow with the password', (
        tester,
      ) async {
        final state = await pumpConfirmation(tester, withAddOn);
        state.productionRepo.autoSync = true;

        await tickRecall(tester);
        await tickNoPassword(tester);
        await tickNoPassword(tester);

        expect(entriesLocked(tester), isFalse);
        expect(tester.widget<TextField>(find.byKey(recallField)).enabled, true);

        // 10 finished: the recall, still automatic, follows to 969.
        await tester.enterText(find.byType(TextField).first, '10');
        await tester.pump();
        await tester.tap(find.text('Xác nhận'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'password');
        await tester.tap(find.text('Xác minh & gửi SAP'));
        await tester.pumpAndSettle();

        expect(state.productionRepo.quantitySent, 10);
        expect(state.recallRepo.calls, 1);
        expect(state.recallRepo.quantitySent, 969);
        expect(state.recallRepo.withoutPasswordSent, isFalse);
        expect(state.recallRepo.passwordSent, 'password');
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });

      testWidgets('unticking "Có thu hồi" drops the password-less recall too', (
        tester,
      ) async {
        await pumpConfirmation(tester, withAddOn);

        await tickRecall(tester);
        await tickNoPassword(tester);
        expect(entriesLocked(tester), isTrue);

        await tester.ensureVisible(find.text('Có thu hồi'));
        await tester.tap(find.text('Có thu hồi'));
        await tester.pumpAndSettle();

        expect(entriesLocked(tester), isFalse);
        expect(find.byKey(noPasswordBox), findsNothing);
        expect(find.text('Xác nhận'), findsOneWidget);
      });

      testWidgets('PP_RECALL without the add-on: no tick box', (tester) async {
        await pumpConfirmation(tester, {
          Permission.confirmProduction,
          Permission.recallAssignment,
        });

        await tickRecall(tester);
        expect(find.byKey(recallField), findsOneWidget);
        expect(find.byKey(noPasswordBox), findsNothing);
        expect(find.text('Thu hồi không cần mật khẩu'), findsNothing);
      });

      testWidgets('recall-only account: the box is there from the start', (
        tester,
      ) async {
        final state = await pumpConfirmation(tester, {
          Permission.recallAssignment,
          Permission.recallWithoutPassword,
        });

        // "Có thu hồi" opens ticked for PP_RECALL alone.
        expect(find.byKey(noPasswordBox), findsOneWidget);
        await tickNoPassword(tester);
        expect(
          tester.widget<TextField>(find.byKey(recallField)).enabled,
          false,
        );

        await tester.tap(find.text('Thu hồi'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Thu hồi & gửi SAP'));
        await tester.pumpAndSettle();

        expect(state.recallRepo.quantitySent, 979);
        expect(state.recallRepo.withoutPasswordSent, isTrue);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    });
  });
}
