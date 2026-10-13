import 'dart:async';

import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/sap_shift_controller.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/domain/entities/mutation_receipt.dart';
import 'package:casla_production/domain/policies/multi_confirmation.dart';
import 'package:casla_production/features/supervisor/screens/s15_multi_confirm_screen.dart';
import 'package:casla_production/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Assignment _lot(
  String id, {
  required String operation,
  required String name,
  required double assigned,
  double completed = 0,
  String uom = 'CHC',
  String orderId = 'order',
  int at = 1,
}) => Assignment(
  id: id,
  workerId: 'worker',
  workerMaNv: 'CL400096',
  workerName: 'Nguyễn Thị Thắm',
  teamId: 'XM2.001',
  orderId: orderId,
  orderCode: 'LSX01',
  productionOrder: '100000000123',
  operation: operation,
  operationName: name,
  productCode: 'SP01',
  productName: 'Sản phẩm',
  uom: uom,
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

class _Database implements CaslaDatabase {
  final payloads = <String, String>{};

  @override
  Future<Map<String, dynamic>?> getOrderById(String id) async =>
      payloads.containsKey(id)
      ? {'id': id, 'operation_qr_payload': payloads[id]}
      : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Production implements ProductionRepositoryImpl {
  final sent = <String>[];
  final refuse = <String, String>{};

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
  }) async {
    final code = refuse[assignmentId];
    if (code != null) {
      return MutationReceipt(
        id: assignmentId,
        state: MutationDeliveryState.discarded,
        code: code,
        message: 'SAP từ chối ($code).',
      );
    }
    sent.add('$assignmentId:$quantity');
    return MutationReceipt(
      id: assignmentId,
      state: MutationDeliveryState.synced,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _State extends ChangeNotifier implements AppState {
  @override
  final _Database db = _Database();
  @override
  final _Production productionRepo = _Production();
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

void main() {
  // May miệng túi: two allocations, 300 left in all. May thân sau: 450 left.
  // Đóng nút: 120 left, so it caps a confirmation of all three.
  final pocket = [
    _lot(
      'pocket-new',
      operation: '0010',
      name: 'May miệng túi',
      assigned: 200,
      at: 2,
    ),
    _lot(
      'pocket-old',
      operation: '0010',
      name: 'May miệng túi',
      assigned: 150,
      completed: 50,
    ),
  ];
  final back = [
    _lot('back', operation: '0020', name: 'May thân sau', assigned: 450),
  ];
  final button = [
    _lot(
      'button',
      operation: '0030',
      name: 'Đóng nút',
      assigned: 120,
      orderId: 'order-button',
    ),
  ];

  test('the group with the least left caps the quantity', () {
    final tightest = tightestConfirmationGroup([pocket, back, button])!;

    expect(tightest.remaining, 120);
    expect(confirmationGroupName(tightest.group), 'Đóng nút');
    expect(confirmationGroupRemaining(pocket), 300);
    expect(tightestConfirmationGroup(const []), isNull);
  });

  late _State state;

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<List<Assignment>>? groups,
    Map<String, dynamic>? worker,
  }) async {
    tester.view.physicalSize = const Size(440, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Danh sách công nhân')),
          routes: [
            GoRoute(
              path: 'multi',
              builder: (_, _) => S15MultiConfirmScreen(
                worker:
                    worker ??
                    {
                      'id': 'worker',
                      'ma_nv': 'CL400096',
                      'ten': 'Nguyễn Thị Thắm',
                      'bo_phan': 'MAY MIỆNG-XM2',
                    },
                groups: groups ?? [pocket, back, button],
                now: () => DateTime(2026, 9, 22, 9),
              ),
            ),
          ],
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
    unawaited(router.push('/multi'));
    await tester.pumpAndSettle();
  }

  setUp(() => state = _State());

  /// The submit button spins for as long as a password prompt or a result
  /// dialog is open, so `pumpAndSettle` would never return there.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('the list shows names only until a row is opened', (
    tester,
  ) async {
    await pumpScreen(tester);

    expect(find.text('May miệng túi'), findsOneWidget);
    expect(find.text('May thân sau'), findsOneWidget);
    expect(find.text('Đóng nút'), findsOneWidget);
    expect(find.text('Lệnh SX'), findsNothing);
    expect(find.text('Còn lại'), findsNothing);

    await tester.tap(find.byTooltip('Chi tiết May miệng túi'));
    await tester.pump();

    expect(find.text('Lệnh SX'), findsOneWidget);
    expect(find.text('350 CHC · 2 lần giao'), findsOneWidget);
    expect(find.text('300 CHC'), findsOneWidget);
  });

  testWidgets('one quantity is confirmed on every ticked operation', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Chọn tất cả'));
    await tester.pump();
    expect(find.text('Theo công đoạn còn ít nhất: Đóng nút'), findsOneWidget);
    expect(find.text('120 CHC'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '100');
    await tester.pump();
    expect(find.textContaining('Vượt số còn lại'), findsNothing);
    await tester.tap(find.text('Xác nhận 3 công đoạn'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await settle(tester);

    // 100 each; the older allocation of the split group closes first.
    expect(state.productionRepo.sent, [
      'pocket-old:100.0',
      'back:100.0',
      'button:100.0',
    ]);
    expect(find.text('Đã xác nhận 3 công đoạn'), findsOneWidget);

    await tester.tap(find.text('Đã hiểu'));
    await tester.pumpAndSettle();
    expect(find.text('Danh sách công nhân'), findsOneWidget);
  });

  testWidgets('more than the tightest operation has left is still confirmed', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Chọn tất cả'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '200');
    await tester.pump();
    // A warning under the field, not an error that blocks the button.
    expect(
      find.text('Vượt số còn lại của Đóng nút (120 CHC).'),
      findsOneWidget,
    );

    await tester.tap(find.text('Xác nhận 3 công đoạn'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await settle(tester);

    // Đóng nút had 120 left and takes the whole 200 all the same.
    expect(state.productionRepo.sent, [
      'pocket-old:100.0',
      'pocket-new:100.0',
      'back:200.0',
      'button:200.0',
    ]);
    expect(find.text('Đã xác nhận 3 công đoạn'), findsOneWidget);
  });

  testWidgets('a refused operation is reported beside the saved ones', (
    tester,
  ) async {
    state.productionRepo.refuse['back'] = 'CONFIRM_QUANTITY_EXCEEDED';
    await pumpScreen(tester, groups: [pocket, back]);

    await tester.tap(find.text('Chọn tất cả'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '50');
    await tester.pump();
    await tester.tap(find.text('Xác nhận 2 công đoạn'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await settle(tester);

    expect(find.text('Đã xác nhận 1/2 công đoạn'), findsOneWidget);
    expect(find.text('Đã gửi SAP'), findsOneWidget);
    expect(find.textContaining('Chưa xác nhận: SAP từ chối'), findsOneWidget);
  });

  testWidgets('operations counted in another unit cannot share a quantity', (
    tester,
  ) async {
    final packing = [
      _lot(
        'pack',
        operation: '0040',
        name: 'Đóng gói',
        assigned: 80,
        uom: 'ST',
      ),
    ];
    await pumpScreen(tester, groups: [back, packing]);

    await tester.tap(find.text('May thân sau'));
    await tester.pump();
    await tester.tap(find.text('Đóng gói'));
    await tester.pump();

    expect(
      find.text('Đóng gói tính theo ST, không xác nhận chung với CHC.'),
      findsOneWidget,
    );
    expect(find.text('Xác nhận sản lượng'), findsWidgets);
    expect(find.text('Xác nhận 2 công đoạn'), findsNothing);
  });

  testWidgets('a worker of another department is confirmed like any other', (
    tester,
  ) async {
    state.db.payloads['order-button'] =
        '{"lenh_san_xuat":"100000000123","cong_doan":"0030","bo_phan":"KLQ MAY ĐÁY-XM2"}';
    await pumpScreen(tester, groups: [back, button]);

    await tester.tap(find.text('Chọn tất cả'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '10');
    await tester.pump();
    // The worker's department is not compared with the operation's any more.
    expect(find.textContaining('khác bộ phận'), findsNothing);

    await tester.tap(find.text('Xác nhận 2 công đoạn'));
    await settle(tester);
    expect(find.textContaining('cảnh báo cần xác nhận'), findsNothing);
    expect(find.text('Vẫn xác nhận'), findsNothing);
    expect(find.text('Xác minh công nhân'), findsOneWidget);
  });
}
