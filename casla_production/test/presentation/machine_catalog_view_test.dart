import 'package:casla_production/app/theme/casla_theme.dart';
import 'package:casla_production/data/sap/odata_error.dart';
import 'package:casla_production/data/sap/sap_position_gateway.dart';
import 'package:casla_production/domain/entities/worker_position.dart';
import 'package:casla_production/features/supervisor/widgets/machine_catalog_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _wc = 'CL100077';

class _FakeApi implements PositionApi {
  /// SAP since 2026-11-05: the worker comes with the machine.
  List<MachineOption> machines = [
    const MachineOption(
      machineId: 'A1',
      machineName: 'Máy may 1 kim',
      workCenter: _wc,
      positionId: 'A-01',
      workerId: '10000001',
      workerName: 'Nguyễn Văn An',
    ),
    // Older backend row: attached, no worker fields. The board fills it.
    const MachineOption(
      machineId: 'A2',
      machineName: 'Máy may 2 kim',
      workCenter: _wc,
      positionId: 'A-02',
    ),
    const MachineOption(
      machineId: 'B7',
      machineName: 'Máy ép',
      workCenter: 'CL100078',
      positionId: 'B-01',
    ),
    const MachineOption(machineId: 'VLT16', machineName: 'Máy vắt sổ 16'),
  ];
  List<PositionSeat> seats = [
    const PositionSeat(
      workCenter: _wc,
      positionId: 'A-02',
      machineId: 'A2',
      workerId: '10000002',
      workerName: 'Trần Thị Bình',
    ),
  ];
  final calls = <String>[];
  Object? failMachines;
  Object? failBoard;

  @override
  Future<PositionBoard> getBoard({
    String workCenter = '',
    String workerId = '',
  }) async {
    calls.add('board $workCenter');
    if (failBoard != null) throw failBoard!;
    return PositionBoard(workCenterCount: 1, seats: List.of(seats));
  }

  @override
  Future<MachineCatalog> getMachines() async {
    calls.add('machines');
    if (failMachines != null) throw failMachines!;
    return MachineCatalog(machines: List.of(machines));
  }

  @override
  Future<PositionCommandResult> createPosition({
    required String workCenter,
    required String positionId,
    required String machineId,
  }) async => throw UnimplementedError();

  @override
  Future<PositionCommandResult> changeMachine({
    required String workCenter,
    required String positionId,
    required String machineId,
  }) async => throw UnimplementedError();

  @override
  Future<PositionCommandResult> detachMachine({
    required String workCenter,
    required String positionId,
  }) async => throw UnimplementedError();

  @override
  Future<PositionCommandResult> transferWorker({
    required String workCenter,
    required String positionId,
    required String workerId,
  }) async => throw UnimplementedError();
}

void main() {
  late _FakeApi api;
  late GlobalKey<MachineCatalogViewState> key;
  var manualInputs = 0;

  setUp(() {
    api = _FakeApi();
    key = GlobalKey<MachineCatalogViewState>();
    manualInputs = 0;
  });

  Future<void> pumpView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: CaslaTheme.light,
          home: Scaffold(
            body: MachineCatalogView(
              key: key,
              api: api,
              workCenter: _wc,
              onScan: () => manualInputs++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists every machine with its position and worker', (
    tester,
  ) async {
    await pumpView(tester);

    expect(api.calls, ['machines', 'board ']);
    expect(find.text('Tất cả · 4'), findsOneWidget);
    expect(find.text('Hoạt động · 2'), findsOneWidget);
    expect(find.text('Thiếu CN · 1'), findsOneWidget);
    expect(find.text('Chưa bố trí · 1'), findsOneWidget);
    expect(find.text('Hoạt động'), findsNWidgets(2));
    expect(find.text('Thiếu CN'), findsOneWidget);
    expect(find.text('Chưa bố trí'), findsOneWidget);
    expect(find.text('A1 · Máy may 1 kim'), findsOneWidget);
    expect(find.text('Vị trí A-01'), findsOneWidget);
    expect(find.text('Nguyễn Văn An · 10000001'), findsOneWidget);
    // Worker joined from the board for the row SAP sent without one.
    expect(find.text('Trần Thị Bình · 10000002'), findsOneWidget);
    // Another Work Center is named; its worker is unknown to the board.
    expect(find.text('Vị trí B-01 · xưởng CL100078'), findsOneWidget);
    expect(find.text('Vị trí chưa có công nhân'), findsOneWidget);
    expect(find.text('Chưa gắn vị trí nào'), findsOneWidget);
  });

  testWidgets('a scan of a machine label opens its detail', (tester) async {
    await pumpView(tester);

    expect(await key.currentState!.handleScan('a1'), isTrue);
    await tester.pumpAndSettle();

    expect(find.text('Chi tiết máy'), findsOneWidget);
    expect(find.text('Hoạt động: có vị trí, có công nhân'), findsOneWidget);
    expect(find.text('Nguyễn Văn An · 10000001'), findsNWidgets(2));

    await tester.tap(find.text('Đóng'));
    await tester.pumpAndSettle();
    // The search now holds the scanned code: only that machine is listed.
    expect(find.text('A1 · Máy may 1 kim'), findsOneWidget);
    expect(find.text('A2 · Máy may 2 kim'), findsNothing);
  });

  testWidgets('a machine of another Work Center explains the move and scope', (
    tester,
  ) async {
    await pumpView(tester);

    expect(await key.currentState!.handleScan('B7'), isTrue);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Máy đang gắn ở xưởng CL100078. Gắn máy này ở xưởng khác thì máy '
        'được chuyển sang, vị trí cũ trống mã máy. Nếu xưởng CL100078 ngoài '
        'phạm vi quyền của bạn thì SAP từ chối (MACHINE_IN_USE).',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an unknown machine is reported and nothing opens', (
    tester,
  ) async {
    await pumpView(tester);

    expect(await key.currentState!.handleScan('X999'), isFalse);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Máy X999 không có trong danh mục'),
      findsOneWidget,
    );
    expect(find.text('Chi tiết máy'), findsNothing);

    expect(await key.currentState!.handleScan('{"MaNV":"10000003"}'), isFalse);
    await tester.pumpAndSettle();
    expect(find.textContaining('không phải nhãn máy'), findsOneWidget);
  });

  testWidgets('filters, search and manual input', (tester) async {
    await pumpView(tester);

    // The chip row scrolls sideways; the last chip may sit off-screen.
    await tester.ensureVisible(find.text('Chưa bố trí · 1'));
    await tester.tap(find.text('Chưa bố trí · 1'));
    await tester.pumpAndSettle();
    expect(find.text('VLT16 · Máy vắt sổ 16'), findsOneWidget);
    expect(find.text('A1 · Máy may 1 kim'), findsNothing);

    await tester.ensureVisible(find.text('Tất cả · 4'));
    await tester.tap(find.text('Tất cả · 4'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Quét mã máy'));
    expect(manualInputs, 1);

    await tester.enterText(find.byType(TextField), 'bình');
    await tester.pumpAndSettle();
    expect(find.text('A2 · Máy may 2 kim'), findsOneWidget);
    expect(find.text('A1 · Máy may 1 kim'), findsNothing);
  });

  testWidgets('the board failing does not hide the catalog', (tester) async {
    api.failBoard = Exception('offline');
    await pumpView(tester);

    expect(find.text('A1 · Máy may 1 kim'), findsOneWidget);
    expect(find.text('Nguyễn Văn An · 10000001'), findsOneWidget);
    // Without the board the older-backend row has no worker.
    expect(find.text('Trần Thị Bình · 10000002'), findsNothing);
  });

  testWidgets('a SAP rejection shows code-first with retry', (tester) async {
    api.failMachines = const SapBusinessError('MISSING_PERMISSION');
    await pumpView(tester);

    expect(find.textContaining('Chưa tải được danh mục máy'), findsOneWidget);
    expect(find.textContaining('PP_POS_MANAGE'), findsOneWidget);

    api.failMachines = null;
    await tester.tap(find.text('Thử lại'));
    await tester.pumpAndSettle();
    expect(find.text('A1 · Máy may 1 kim'), findsOneWidget);
  });
}
