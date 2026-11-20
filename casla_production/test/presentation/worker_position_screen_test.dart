import 'dart:async';

import 'package:casla_production/app/router/app_route_observer.dart';
import 'package:casla_production/app/theme/casla_theme.dart';
import 'package:casla_production/core/scanner/barcode_scan_event.dart';
import 'package:casla_production/core/scanner/barcode_scanner.dart';
import 'package:casla_production/core/scanner/scan_feedback.dart';
import 'package:casla_production/core/scanner/scanner_preferences.dart';
import 'package:casla_production/data/sap/odata_error.dart';
import 'package:casla_production/data/sap/sap_position_gateway.dart';
import 'package:casla_production/domain/entities/worker_position.dart';
import 'package:casla_production/features/supervisor/screens/s14_worker_position_screen.dart';
import 'package:casla_production/presentation/widgets/adaptive_barcode_scanner_view.dart';
import 'package:casla_production/presentation/widgets/scan_slot_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _wc = 'CL100077';

class _FakeApi implements PositionApi {
  List<PositionSeat> seats = [
    const PositionSeat(
      workCenter: _wc,
      positionId: 'G01',
      machineId: 'M101',
      workerId: '10000001',
      workerName: 'Nguyễn Văn An',
    ),
    const PositionSeat(workCenter: _wc, positionId: 'G02', machineId: 'M102'),
  ];
  final calls = <String>[];
  Object? failTransfer;
  Object? failMachines;
  Object? failMachineChange;
  Object? failDetach;
  List<MachineOption> otherWorkCenterMachines = const [];

  @override
  Future<PositionBoard> getBoard({
    String workCenter = '',
    String workerId = '',
  }) async {
    calls.add('board');
    return PositionBoard(workCenterCount: 1, seats: List.of(seats));
  }

  @override
  Future<MachineCatalog> getMachines() async {
    calls.add('machines');
    if (failMachines != null) throw failMachines!;
    return MachineCatalog(
      machines: [
        for (final seat in seats)
          MachineOption(
            machineId: seat.machineId,
            machineName: 'Máy ${seat.machineId}',
            workCenter: seat.workCenter,
            positionId: seat.positionId,
          ),
        const MachineOption(machineId: 'M109', machineName: 'Máy dự phòng'),
        ...otherWorkCenterMachines,
      ],
    );
  }

  @override
  Future<PositionCommandResult> createPosition({
    required String workCenter,
    required String positionId,
    required String machineId,
  }) async {
    calls.add('create $workCenter $positionId $machineId');
    seats.add(
      PositionSeat(
        workCenter: workCenter,
        positionId: positionId,
        machineId: machineId,
      ),
    );
    return const PositionCommandResult(status: 'SUCCESS');
  }

  @override
  Future<PositionCommandResult> changeMachine({
    required String workCenter,
    required String positionId,
    required String machineId,
  }) async {
    calls.add('machine $positionId $machineId');
    if (failMachineChange != null) throw failMachineChange!;
    return const PositionCommandResult(status: 'SUCCESS');
  }

  @override
  Future<PositionCommandResult> detachMachine({
    required String workCenter,
    required String positionId,
  }) async {
    calls.add('detach $workCenter $positionId');
    if (failDetach != null) throw failDetach!;
    seats = [
      for (final seat in seats)
        seat.positionId == positionId
            ? PositionSeat(
                workCenter: seat.workCenter,
                positionId: seat.positionId,
                machineId: '',
                workerId: seat.workerId,
                workerName: seat.workerName,
              )
            : seat,
    ];
    return const PositionCommandResult(status: 'SUCCESS');
  }

  @override
  Future<PositionCommandResult> transferWorker({
    required String workCenter,
    required String positionId,
    required String workerId,
  }) async {
    calls.add('transfer $positionId $workerId');
    if (failTransfer != null) throw failTransfer!;
    return const PositionCommandResult(status: 'SUCCESS');
  }

  Iterable<String> get commands =>
      calls.where((c) => c != 'board' && c != 'machines');
}

class _FakeScanner implements BarcodeScanner {
  final _controller = StreamController<BarcodeScanEvent>.broadcast(sync: true);
  var _tick = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<BarcodeScanEvent> get scans => _controller.stream;

  void emit(String raw) {
    _tick++;
    _controller.add(
      BarcodeScanEvent(
        rawValue: raw,
        source: BarcodeScanSource.hardware,
        timestamp: DateTime(2026, 10, 1).add(Duration(seconds: _tick)),
      ),
    );
  }

  Future<void> close() => _controller.close();
}

void main() {
  late _FakeApi api;
  late _FakeScanner scanner;

  setUp(() {
    ScanFeedback.setMuted(true);
    api = _FakeApi();
    scanner = _FakeScanner();
  });

  tearDown(() async {
    ScanFeedback.setMuted(false);
    await scanner.close();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: CaslaTheme.light,
          navigatorObservers: [appRouteObserver],
          home: S14WorkerPositionScreen(
            api: api,
            workCenter: _wc,
            workerNameLookup: (code) async =>
                code == '10000003' ? 'Lê Văn Cường' : null,
            scanner: scanner,
            scannerPreferences: InMemoryScannerPreferences(),
            accountAction: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a machine used at another position can still be chosen', (
    tester,
  ) async {
    await pumpScreen(tester);

    // M102 already sits at G02: not blocked, SAP moves it (2026-11-10).
    scanner.emit('G01@M102');
    await tester.pumpAndSettle();

    expect(find.textContaining('SAP sẽ từ chối'), findsNothing);
    expect(
      find.text(
        'Đang gắn ở vị trí G02. Cập nhật sẽ chuyển máy, vị trí G02 trống mã '
        'máy.',
      ),
      findsOneWidget,
    );
    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Cập nhật'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(button.onPressed, isNotNull);

    await tester.tap(find.text('Cập nhật'));
    await tester.pumpAndSettle();
    expect(find.text('Cảnh báo 1/2'), findsOneWidget);
    expect(find.text('Thay đổi máy tại vị trí'), findsOneWidget);
    await tester.tap(find.text('Có'));
    await tester.pumpAndSettle();

    expect(find.text('Cảnh báo 2/2'), findsOneWidget);
    expect(find.text('Máy đang gắn ở vị trí khác'), findsOneWidget);
    expect(
      find.text(
        'Máy M102 đang gắn ở vị trí G02. Có chuyển máy sang vị trí G01 không? '
        'Vị trí G02 sẽ trống mã máy.',
      ),
      findsOneWidget,
    );
    expect(api.commands, isEmpty);
    await tester.tap(find.text('Có'));
    await tester.pumpAndSettle();

    // One request: SAP clears G02 itself.
    expect(api.commands, ['machine G01 M102']);
  });

  testWidgets('new position plus worker: confirm, create, then seat', (
    tester,
  ) async {
    await pumpScreen(tester);

    scanner.emit('G05@M105');
    await tester.pumpAndSettle();
    // A worker card ticks "Gán công nhân" on its own.
    scanner.emit('10000003');
    await tester.pumpAndSettle();
    expect(find.text('Lê Văn Cường'), findsOneWidget);
    expect(find.textContaining('TH1'), findsNothing);

    await tester.tap(find.text('Cập nhật'));
    await tester.pumpAndSettle();
    expect(find.text('Vị trí chưa tồn tại'), findsOneWidget);
    expect(find.textContaining('Trường hợp'), findsNothing);
    // Listed in the preview behind the dialog and in the dialog itself.
    expect(
      find.text('Xếp Lê Văn Cường (10000003) vào vị trí G05'),
      findsWidgets,
    );

    await tester.tap(find.text('Có'));
    await tester.pumpAndSettle();

    expect(api.commands, ['create $_wc G05 M105', 'transfer G05 10000003']);
    expect(find.text('Đã cập nhật vị trí'), findsOneWidget);
  });

  testWidgets('declining a warning sends nothing', (tester) async {
    await pumpScreen(tester);

    scanner.emit('G01@M109');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cập nhật'));
    await tester.pumpAndSettle();
    expect(find.text('Thay đổi máy tại vị trí'), findsOneWidget);
    // Before/after block: the board's machine above the scanned one.
    expect(find.text('Máy hiện tại: M101', findRichText: true), findsOneWidget);
    expect(find.text('Máy mới: M109', findRichText: true), findsOneWidget);

    await tester.tap(find.text('Không'));
    await tester.pumpAndSettle();

    expect(api.commands, isEmpty);
    expect(
      find.text('Đã hủy. Chưa có thay đổi nào được gửi lên SAP.'),
      findsOneWidget,
    );
  });

  testWidgets('a failed seat keeps the finished step and explains why', (
    tester,
  ) async {
    api.failTransfer = const SapBusinessError('WORKER_NOT_IN_WORK_CENTER');
    await pumpScreen(tester);

    scanner.emit('G02@M102');
    await tester.pumpAndSettle();
    scanner.emit('10000003');
    await tester.pumpAndSettle();
    // Empty position, no warning: the update goes straight to SAP.
    await tester.tap(find.text('Cập nhật'));
    await tester.pumpAndSettle();

    expect(find.text('SAP chưa cập nhật xong'), findsOneWidget);
    expect(
      find.text(
        'Công nhân không thuộc xưởng này theo danh sách nhân công hôm nay.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a machine picked from the catalog creates the position', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Chọn máy từ danh mục'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('machines'));
    expect(find.text('M109 · Máy dự phòng'), findsOneWidget);
    expect(find.text('Đang gắn ở vị trí G01'), findsOneWidget);

    await tester.tap(find.text('M109 · Máy dự phòng'));
    await tester.pumpAndSettle();
    // No position in the form yet: the catalog pick asks for one.
    expect(find.text('Nhập mã vị trí'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'g05');
    await tester.pump();
    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();

    expect(find.text('G05'), findsOneWidget);
    expect(find.text('M109'), findsOneWidget);
    expect(find.textContaining('SAP sẽ từ chối'), findsNothing);

    await tester.tap(find.text('Cập nhật'));
    await tester.pumpAndSettle();
    expect(find.text('Vị trí chưa tồn tại'), findsOneWidget);
    await tester.tap(find.text('Có'));
    await tester.pumpAndSettle();

    expect(api.commands, ['create $_wc G05 M109']);
  });

  testWidgets('picking a machine in use elsewhere swaps it and warns', (
    tester,
  ) async {
    await pumpScreen(tester);

    scanner.emit('G02@M102');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chọn máy khác từ danh mục'));
    await tester.pumpAndSettle();
    expect(find.text('Chọn máy cho vị trí G02'), findsOneWidget);
    expect(find.text('Máy hiện tại của vị trí này'), findsOneWidget);

    await tester.tap(find.text('M101 · Máy M101'));
    await tester.pumpAndSettle();

    // The position is kept, only the machine changes; no position dialog.
    expect(find.text('Nhập mã vị trí'), findsNothing);
    expect(find.text('G02'), findsOneWidget);
    expect(find.text('M101'), findsOneWidget);
    expect(find.text('M102 → M101'), findsOneWidget);
    // Same Work Center: the machine card says it moves, no error banner.
    expect(
      find.text(
        'Đang gắn ở vị trí G01. Cập nhật sẽ chuyển máy, vị trí G01 trống mã '
        'máy.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('MACHINE_IN_USE'), findsNothing);
  });

  testWidgets('picking a machine of another Work Center names the scope rule', (
    tester,
  ) async {
    api.otherWorkCenterMachines = const [
      MachineOption(
        machineId: 'B7',
        machineName: 'Máy xưởng khác',
        workCenter: 'CL100078',
        positionId: 'B-01',
      ),
    ];
    await pumpScreen(tester);

    scanner.emit('G02@M102');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chọn máy khác từ danh mục'));
    await tester.pumpAndSettle();
    expect(
      find.text('Đang gắn ở vị trí B-01 · xưởng CL100078'),
      findsOneWidget,
    );
    await tester.tap(find.text('B7 · Máy xưởng khác'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Máy B7 đang gắn ở vị trí B-01 (xưởng CL100078). Cập nhật sẽ chuyển '
        'máy sang vị trí G02, vị trí B-01 trống mã máy. Nếu xưởng CL100078 '
        'ngoài phạm vi quyền của bạn thì SAP từ chối (MACHINE_IN_USE).',
      ),
      findsOneWidget,
    );
  });

  testWidgets('MACHINE_IN_USE from SAP explains the scope', (tester) async {
    api.failMachineChange = const SapBusinessError('MACHINE_IN_USE');
    await pumpScreen(tester);

    scanner.emit('G02@B7');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cập nhật'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Có'));
    await tester.pumpAndSettle();

    expect(find.text('SAP chưa cập nhật xong'), findsOneWidget);
    expect(
      find.text(
        'Máy đang gắn ở vị trí thuộc xưởng ngoài phạm vi quyền của bạn nên '
        'không chuyển sang được. Nhờ người quản lý xưởng đó gỡ máy trước.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a catalog that cannot be read explains why', (tester) async {
    api.failMachines = const SapBusinessError('MISSING_PERMISSION');
    await pumpScreen(tester);

    await tester.tap(find.text('Chọn máy từ danh mục'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('chưa được cấp quyền quản lý vị trí'),
      findsOneWidget,
    );
    expect(find.text('Thử lại'), findsOneWidget);
  });

  testWidgets('the board is read only', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('Bảng vị trí'));
    await tester.pumpAndSettle();
    expect(find.text('Tất cả · 2'), findsOneWidget);
    expect(find.text('Chưa có công nhân'), findsOneWidget);

    await tester.tap(find.text('G01 · M101'));
    await tester.pumpAndSettle();

    expect(find.text('Chi tiết vị trí'), findsOneWidget);
    expect(find.text('Nguyễn Văn An · 10000001'), findsOneWidget);
    // Only the search box; nothing on the board edits.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('a known position fills its machine in from SAP', (tester) async {
    await pumpScreen(tester);

    scanner.emit('G01');
    await tester.pumpAndSettle();

    expect(find.text('G01'), findsOneWidget);
    expect(find.text('M101'), findsWidgets);
    expect(find.textContaining('Điền sẵn từ SAP'), findsOneWidget);
    expect(find.text('Không có thay đổi để gửi'), findsOneWidget);
    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Cập nhật'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(button.onPressed, isNull);

    // The reader moved on to the machine: a bare code is the new machine.
    scanner.emit('M109');
    await tester.pumpAndSettle();
    expect(find.text('M109'), findsWidgets);
    expect(find.text('M101 → M109'), findsOneWidget);
    expect(find.text('Đổi máy của vị trí G01 sang M109'), findsOneWidget);
  });

  testWidgets('x on the machine SAP filled in takes it off the position', (
    tester,
  ) async {
    await pumpScreen(tester);

    scanner.emit('G01');
    await tester.pumpAndSettle();
    expect(find.textContaining('bấm ✕ để gỡ máy'), findsOneWidget);

    await tester.tap(find.byTooltip('Gỡ máy khỏi vị trí'));
    await tester.pumpAndSettle();
    // Nothing sent yet: the form shows the pending removal.
    expect(api.commands, isEmpty);
    expect(find.textContaining('Sẽ gỡ máy M101 khỏi vị trí'), findsOneWidget);
    expect(find.text('Gỡ máy M101 khỏi vị trí G01'), findsOneWidget);

    await tester.tap(find.text('Cập nhật'));
    await tester.pumpAndSettle();
    expect(find.text('Gỡ máy khỏi vị trí'), findsOneWidget);
    expect(
      find.text(
        'Vị trí G01 đang gắn máy M101. Có gỡ máy khỏi vị trí không? Vị trí '
        'vẫn đang dùng, máy M101 thành máy rảnh. CN Nguyễn Văn An vẫn ngồi '
        'vị trí này.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Có'));
    await tester.pumpAndSettle();

    expect(api.commands, ['detach $_wc G01']);
    expect(find.text('Đã cập nhật vị trí'), findsOneWidget);
  });

  testWidgets('a pending machine removal can be taken back', (tester) async {
    await pumpScreen(tester);

    scanner.emit('G01');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Gỡ máy khỏi vị trí'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Giữ máy'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Điền sẵn từ SAP'), findsOneWidget);
    expect(find.text('Không có thay đổi để gửi'), findsOneWidget);

    // A scan after x is a machine change, not a removal.
    await tester.tap(find.byTooltip('Gỡ máy khỏi vị trí'));
    await tester.pumpAndSettle();
    scanner.emit('M109');
    await tester.pumpAndSettle();
    expect(find.text('Đổi máy của vị trí G01 sang M109'), findsOneWidget);
    expect(find.textContaining('Sẽ gỡ máy'), findsNothing);
    expect(api.commands, isEmpty);
  });

  testWidgets('a backend without machine removal answers INPUT_INVALID', (
    tester,
  ) async {
    api.failDetach = const SapBusinessError('INPUT_INVALID');
    await pumpScreen(tester);

    scanner.emit('G02');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Gỡ máy khỏi vị trí'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cập nhật'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Có'));
    await tester.pumpAndSettle();

    expect(find.text('SAP chưa cập nhật xong'), findsOneWidget);
    expect(find.textContaining('Thiếu hoặc sai mã xưởng'), findsOneWidget);
  });

  testWidgets('a new position waits for its machine', (tester) async {
    await pumpScreen(tester);

    scanner.emit('A2-1');
    await tester.pumpAndSettle();
    expect(find.text('Vị trí mới, SAP chưa có'), findsOneWidget);
    expect(
      find.text('Vị trí mới A2-1: quét QR máy để tiếp tục'),
      findsOneWidget,
    );
    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Cập nhật'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(button.onPressed, isNull);

    scanner.emit('VLT16');
    await tester.pumpAndSettle();
    expect(find.text('Tạo vị trí A2-1 với máy VLT16'), findsOneWidget);
    expect(find.text('Gửi SAP: chỉ vị trí / máy'), findsOneWidget);
  });

  testWidgets('a bare code lands in the selected field', (tester) async {
    await pumpScreen(tester);

    scanner.emit('G02');
    await tester.pumpAndSettle();
    expect(find.text('M102'), findsWidgets);

    // Back to the position field: the next bare code is a position.
    await tester.tap(
      find
          .descendant(
            of: find.byType(ScanSlotField).first,
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();
    scanner.emit('G01');
    await tester.pumpAndSettle();
    expect(find.text('G01'), findsOneWidget);
    expect(find.text('M101'), findsWidgets);
    expect(find.text('M102'), findsNothing);

    // A worker card is digits only, so it never lands in a label field.
    scanner.emit('10000003');
    await tester.pumpAndSettle();
    expect(find.text('Lê Văn Cường'), findsOneWidget);
    expect(find.text('G01'), findsOneWidget);
  });

  testWidgets('system Back closes the camera instead of the app', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.byTooltip('Camera').first);
    await tester.pump();
    expect(find.byType(AdaptiveBarcodeScannerView), findsOneWidget);

    // Handled inside the app: the platform is not asked to leave it.
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pump();
    expect(find.byType(AdaptiveBarcodeScannerView), findsNothing);
    expect(find.byType(ScanSlotField), findsWidgets);
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('the board finds a seat by scan and by search', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Bảng vị trí'));
    await tester.pumpAndSettle();

    scanner.emit('M102');
    await tester.pumpAndSettle();
    expect(find.text('Chi tiết vị trí'), findsOneWidget);
    expect(find.text('G02 · M102'), findsNWidgets(2));
    await tester.tap(find.text('Đóng'));
    await tester.pumpAndSettle();
    // The search box now holds the found position, so only it is listed.
    expect(find.text('G01 · M101'), findsNothing);

    scanner.emit('Z9');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Mã Z9 không phải vị trí đang dùng'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField), 'an');
    await tester.pumpAndSettle();
    expect(find.text('G01 · M101'), findsOneWidget);
    expect(find.text('G02 · M102'), findsNothing);
  });

  testWidgets('a position created on SAP without a machine takes a worker', (
    tester,
  ) async {
    await pumpScreen(tester);
    // Created on Fiori after the board was loaded, machine left empty.
    api.seats.add(
      const PositionSeat(workCenter: _wc, positionId: 'HA002', machineId: ''),
    );

    scanner.emit('HA002');
    await tester.pumpAndSettle();

    // The board was asked again, so the position is known, not new.
    expect(find.text('Vị trí mới, SAP chưa có'), findsNothing);
    expect(find.text('Chưa gắn máy'), findsOneWidget);
    expect(find.text('Không có thay đổi để gửi'), findsOneWidget);

    scanner.emit('10000003');
    await tester.pumpAndSettle();
    expect(
      find.text('Xếp Lê Văn Cường (10000003) vào vị trí HA002'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cập nhật'));
    await tester.pumpAndSettle();

    expect(api.commands, ['transfer HA002 10000003']);
    expect(find.text('Đã cập nhật vị trí'), findsOneWidget);
  });

  testWidgets('the machine catalog is the third view', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Danh mục máy'));
    await tester.pumpAndSettle();

    expect(find.text('M109 · Máy dự phòng'), findsOneWidget);
    expect(find.text('Chưa gắn vị trí nào'), findsOneWidget);
    // Worker joined from the board, since the fake catalog sends none.
    expect(find.text('Nguyễn Văn An · 10000001'), findsOneWidget);

    scanner.emit('M109');
    await tester.pumpAndSettle();
    expect(find.text('Chi tiết máy'), findsOneWidget);
    expect(find.text('Chưa bố trí: chưa gán vị trí'), findsOneWidget);
  });
}
