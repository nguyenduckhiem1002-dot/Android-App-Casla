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
  double defect = 0,
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
  defectQuantity: defect,
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

  /// Sales order and item of an order, by local order id.
  final salesOrders = <String, (String, String)>{};

  @override
  Future<Map<String, dynamic>?> getOrderById(String id) async =>
      payloads.containsKey(id) || salesOrders.containsKey(id)
      ? {
          'id': id,
          'operation_qr_payload': payloads[id],
          'sales_order': salesOrders[id]?.$1,
          'sales_order_item': salesOrders[id]?.$2,
        }
      : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Production implements ProductionRepositoryImpl {
  final sent = <String>[];
  final refuse = <String, String>{};

  /// Assignments whose write is saved on the device but not accepted by SAP.
  final hold = <String, MutationReceipt>{};

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
    final held = hold[assignmentId];
    if (held != null) return held;
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

  test('the group with the least left is the one a figure is warned on', () {
    final tightest = tightestConfirmationGroup([pocket, back, button])!;

    expect(tightest.remaining, 120);
    expect(confirmationGroupName(tightest.group), 'Đóng nút');
    expect(confirmationGroupRemaining(pocket), 300);
    expect(tightestConfirmationGroup(const []), isNull);
  });

  test('each operation takes the typed figure, or what it has left', () {
    final typed = multiConfirmationQuantities(
      [pocket, back, button],
      confirmRemaining: false,
      entered: 100,
    );
    expect(typed, [100, 100, 100]);
    expect(multiConfirmationTotal(typed), 300);

    final left = multiConfirmationQuantities([
      pocket,
      back,
      button,
    ], confirmRemaining: true);
    expect(left, [300, 450, 120]);
    expect(multiConfirmationTotal(left), 870);
    expect(multiConfirmationTotal(const []), 0);
  });

  late _State state;

  /// What the screen's route popped with.
  late Future<Object?> popped;

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<List<Assignment>>? groups,
    Map<String, dynamic>? worker,
    // What a fresh read finds open after a confirmation: nothing, unless a
    // test leaves the worker something.
    List<List<Assignment>> stillOpen = const [],
    Size size = const Size(440, 2000),
  }) async {
    tester.view.physicalSize = size;
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
                reloadGroups: () async => stillOpen,
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
    popped = router.push<Object?>('/multi');
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

  /// The password popup shows [total] as the quantity completed, with the
  /// worker's code beside the name.
  void expectCompletedTotal(String total) {
    final frame = find.byKey(const ValueKey('worker-completed-total'));
    expect(frame, findsOneWidget);
    expect(
      find.descendant(of: frame, matching: find.text('SỐ LƯỢNG HOÀN THÀNH')),
      findsOneWidget,
    );
    expect(find.descendant(of: frame, matching: find.text(total)), findsOne);
    expect(
      find.text('Nguyễn Thị Thắm · CL400096', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('cần nhập mật khẩu SAP'), findsNothing);
  }

  testWidgets('each operation shows where it comes from and its figures', (
    tester,
  ) async {
    state.db.salesOrders['order-button'] = ('10000456', '010');
    await pumpScreen(tester);

    expect(find.text('May miệng túi'), findsOneWidget);
    expect(find.text('May thân sau'), findsOneWidget);
    expect(find.text('Đóng nút'), findsOneWidget);
    expect(find.text('LSX: 100000000123'), findsNWidgets(3));
    expect(find.text('Công đoạn: 0010'), findsOneWidget);
    expect(find.text('Công đoạn: 0030'), findsOneWidget);
    // Sales order and product head each card. Only Đóng nút's order
    // carries a sales order.
    expect(find.text('Sản phẩm'), findsNWidgets(3));
    expect(find.text('10000456/010'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2));
    expect(find.text('Giao hiệu lực'), findsNWidgets(3));
    expect(find.text('Đã xác nhận'), findsNWidgets(3));
    expect(find.text('Còn lại'), findsNWidgets(3));
    // May miệng túi: 350 given over two allocations, 50 done, 300 left.
    expect(find.text('350'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(find.text('300'), findsOneWidget);
    // The figures carry no unit, and nothing has to be opened to see them.
    expect(find.text('300 CHC'), findsNothing);
    expect(find.byTooltip('Chi tiết May miệng túi'), findsNothing);
  });

  testWidgets('what was confirmed counts scrap beside good output', (
    tester,
  ) async {
    final sleeve = [
      _lot(
        'sleeve',
        operation: '0050',
        name: 'May tay áo',
        assigned: 2000,
        completed: 480,
        defect: 5,
      ),
    ];
    await pumpScreen(tester, groups: [sleeve, back]);

    // 480 good and 5 scrapped were confirmed; both came off the 2.000.
    expect(find.text('485'), findsOneWidget);
    expect(find.text('480'), findsNothing);
    expect(find.text('1.515'), findsOneWidget);
  });

  testWidgets('the submit button stays above the soft keyboard', (
    tester,
  ) async {
    await pumpScreen(tester);
    final submit = find.byKey(const Key('multi-confirm-submit'));
    expect(submit, findsOneWidget);

    // A keyboard covering the lower 900 px of a 2000 px screen.
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();

    expect(submit, findsOneWidget);
    expect(tester.getBottomLeft(submit).dy, lessThanOrEqualTo(2000 - 900));
  });

  testWidgets('the quantity and the buttons stay put under a long list', (
    tester,
  ) async {
    // Six operations on a screen that shows two of them.
    final many = [
      for (var index = 0; index < 6; index++)
        [
          _lot(
            'lot-$index',
            operation: '00${index + 1}0',
            name: 'Công đoạn $index',
            assigned: 100,
          ),
        ],
    ];
    await pumpScreen(tester, groups: many, size: const Size(440, 720));

    final panel = find.byKey(const Key('multi-confirm-panel'));
    Finder pinned(Finder what) => find.descendant(of: panel, matching: what);
    final field = pinned(find.byType(TextField));
    final submit = pinned(find.byKey(const Key('multi-confirm-submit')));
    expect(field, findsOneWidget);
    expect(submit, findsOneWidget);
    expect(
      pinned(find.byKey(const Key('multi-confirm-detail'))),
      findsOneWidget,
    );
    expect(
      pinned(find.byKey(const Key('multi-confirm-total'))),
      findsOneWidget,
    );
    // The "what is left" tick box is not pinned: it ends the list.
    final remaining = find.byKey(const Key('multi-confirm-remaining'));
    expect(pinned(remaining), findsNothing);
    expect(remaining, findsNothing);
    // On screen without scrolling, the last operation is not.
    expect(tester.getRect(field).top, greaterThan(0));
    expect(tester.getRect(submit).bottom, lessThanOrEqualTo(720));
    expect(find.text('Công đoạn 5'), findsNothing);

    // Scrolling the list to its end leaves the panel where it was.
    final before = tester.getRect(field);
    // A lazy list only guesses its length: one drag can stop short.
    for (var pass = 0; pass < 3; pass++) {
      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pumpAndSettle();
    }
    expect(find.text('Công đoạn 5'), findsOneWidget);
    expect(remaining, findsOneWidget);
    expect(
      tester.getRect(remaining).bottom,
      lessThanOrEqualTo(tester.getRect(panel).top),
    );
    expect(tester.getRect(field), before);
  });

  testWidgets('one quantity is confirmed on every ticked operation', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Chọn tất cả'));
    await tester.pump();
    // No ceiling is announced and nothing fills one in.
    expect(find.text('Xác nhận tối đa'), findsNothing);
    expect(find.textContaining('Theo công đoạn còn ít nhất'), findsNothing);
    expect(find.text('Điền tối đa'), findsNothing);
    expect(find.text('Tổng: 0'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '100');
    await tester.pump();
    expect(find.textContaining('Vượt số còn lại'), findsNothing);
    // 100 on each of the three.
    expect(find.text('Tổng: 300'), findsOneWidget);
    await tester.tap(find.byKey(const Key('multi-confirm-submit')));
    await settle(tester);
    // The worker signs the same total as the form: 100 on each of three.
    expectCompletedTotal('300');
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

    // Nothing is left for this worker: back to the list to pick another.
    await tester.tap(find.text('Đã hiểu'));
    await tester.pumpAndSettle();
    expect(find.text('Danh sách công nhân'), findsOneWidget);
    expect(await popped, isTrue);
  });

  testWidgets('what is left of every ticked operation is confirmed', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Chọn tất cả'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '100');
    await tester.pump();
    await tester.tap(find.byKey(const Key('multi-confirm-remaining')));
    await tester.pump();

    // The typed figure is dropped and the field closed: each operation
    // confirms its own balance, 300 + 450 + 120.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
    expect(field.controller!.text, isEmpty);
    expect(find.text('Tổng: 870'), findsOneWidget);
    expect(find.textContaining('Mỗi công đoạn xác nhận'), findsNothing);

    await tester.tap(find.byKey(const Key('multi-confirm-submit')));
    await settle(tester);
    // Each operation's own balance, added up.
    expectCompletedTotal('870');
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await settle(tester);

    // One transaction per operation, on its oldest open lot.
    expect(state.productionRepo.sent, [
      'pocket-old:300.0',
      'back:450.0',
      'button:120.0',
    ]);
    expect(find.text('Đã xác nhận 3 công đoạn'), findsOneWidget);
    expect(
      find.text('Hết số còn lại của từng công đoạn cho Nguyễn Thị Thắm.'),
      findsOneWidget,
    );
    expect(find.text('May miệng túi · 300 CHC'), findsOneWidget);
    expect(find.text('Đóng nút · 120 CHC'), findsOneWidget);
  });

  testWidgets('the list stays while the worker still has work to confirm', (
    tester,
  ) async {
    final backLeft = [
      _lot(
        'back',
        operation: '0020',
        name: 'May thân sau',
        assigned: 450,
        completed: 100,
      ),
    ];
    await pumpScreen(tester, groups: [back, button], stillOpen: [backLeft]);

    await tester.tap(find.text('Chọn tất cả'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('multi-confirm-remaining')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('multi-confirm-submit')));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await settle(tester);
    await tester.tap(find.text('Đã hiểu'));
    await tester.pumpAndSettle();

    // Still here, with the fresh balances and a clean form.
    expect(find.text('Danh sách công nhân'), findsNothing);
    expect(find.text('May thân sau'), findsOneWidget);
    expect(find.text('Đóng nút'), findsNothing);
    expect(find.text('350'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(field.enabled, isFalse);
    expect(find.text('Tổng: 0'), findsOneWidget);
  });

  testWidgets('the operation detail opens for exactly one ticked operation', (
    tester,
  ) async {
    await pumpScreen(tester);
    bool detailEnabled() =>
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('multi-confirm-detail')),
            )
            .onPressed !=
        null;

    expect(find.text('Chi tiết công đoạn'), findsOneWidget);
    expect(find.textContaining('Nhập số phế hoặc thu hồi'), findsNothing);
    expect(detailEnabled(), isFalse);

    await tester.tap(find.text('May thân sau'));
    await tester.pump();
    expect(detailEnabled(), isTrue);

    await tester.tap(find.text('Đóng nút'));
    await tester.pump();
    expect(detailEnabled(), isFalse);
  });

  testWidgets('the QR button goes back to scan another worker', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const Key('multi-confirm-scan-worker')));
    await tester.pumpAndSettle();

    expect(find.text('Danh sách công nhân'), findsOneWidget);
    expect(await popped, S15MultiConfirmScreen.scanAnotherWorker);
    expect(state.productionRepo.sent, isEmpty);
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

    await tester.tap(find.byKey(const Key('multi-confirm-submit')));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await settle(tester);

    // Đóng nút had 120 left and takes the whole 200 all the same; each
    // operation gets one transaction with the entered figure, on its oldest
    // open lot.
    expect(state.productionRepo.sent, [
      'pocket-old:200.0',
      'back:200.0',
      'button:200.0',
    ]);
    expect(find.text('Đã xác nhận 3 công đoạn'), findsOneWidget);
    await tester.tap(find.text('Đã hiểu'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.byKey(const Key('multi-confirm-submit')));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await settle(tester);

    expect(find.text('Đã xác nhận 1/2 công đoạn'), findsOneWidget);
    expect(find.text('Đã gửi SAP'), findsOneWidget);
    expect(find.textContaining('Chưa xác nhận: SAP từ chối'), findsOneWidget);
  });

  testWidgets('a part only saved on the device is not counted as confirmed', (
    tester,
  ) async {
    state.productionRepo.hold['back'] = const MutationReceipt(
      id: 'back',
      state: MutationDeliveryState.queued,
      message: 'SAP không phản hồi kịp.',
    );
    await pumpScreen(tester, groups: [pocket, back]);

    await tester.tap(find.text('Chọn tất cả'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '50');
    await tester.pump();
    await tester.tap(find.byKey(const Key('multi-confirm-submit')));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await settle(tester);

    expect(
      find.text('Đã xác nhận 1/2 công đoạn, 1 chờ gửi SAP'),
      findsOneWidget,
    );
    expect(find.text('Đã gửi SAP'), findsOneWidget);
    expect(
      find.textContaining('Chưa gửi SAP. Đã lưu trên máy, chờ đồng bộ.'),
      findsOneWidget,
    );
    expect(find.textContaining('SAP không phản hồi kịp.'), findsOneWidget);
    expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
    expect(find.text('Đã xác nhận 2 công đoạn'), findsNothing);
  });

  testWidgets('nothing accepted by SAP is never titled as confirmed', (
    tester,
  ) async {
    state.productionRepo.hold['pocket-old'] = const MutationReceipt(
      id: 'pocket-old',
      state: MutationDeliveryState.needsVerification,
    );
    state.productionRepo.hold['back'] = const MutationReceipt(
      id: 'back',
      state: MutationDeliveryState.queued,
    );
    await pumpScreen(tester, groups: [pocket, back]);

    await tester.tap(find.text('Chọn tất cả'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '50');
    await tester.pump();
    await tester.tap(find.byKey(const Key('multi-confirm-submit')));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await settle(tester);

    expect(
      find.text('Chưa gửi được SAP, 2 công đoạn mới lưu trên máy'),
      findsOneWidget,
    );
    // The cards behind the dialog label a column "Đã xác nhận"; the dialog
    // itself must not claim anything was confirmed.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Đã xác nhận'),
      ),
      findsNothing,
    );
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
    // Only the first one stays ticked.
    final ticked = tester
        .widgetList<Checkbox>(find.byType(Checkbox))
        .where((box) => box.value == true);
    expect(ticked, hasLength(1));
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
    expect(find.textContaining('khác tổ'), findsNothing);

    await tester.tap(find.byKey(const Key('multi-confirm-submit')));
    await settle(tester);
    expect(find.textContaining('cảnh báo cần xác nhận'), findsNothing);
    expect(find.text('Vẫn xác nhận'), findsNothing);
    expect(find.text('Xác minh công nhân'), findsOneWidget);
  });
}
