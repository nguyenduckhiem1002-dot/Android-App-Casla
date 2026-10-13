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

  @override
  Future<PositionBoard> getBoard({String workCenter = ''}) async {
    calls.add('board');
    return PositionBoard(workCenterCount: 1, seats: List.of(seats));
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

  Iterable<String> get commands => calls.where((c) => c != 'board');
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

    // M102 already sits at G02; the app no longer checks machine codes.
    scanner.emit('G01@M102');
    await tester.pumpAndSettle();

    expect(find.textContaining('đang dùng ở vị trí'), findsNothing);
    final button = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Cập nhật'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(button.onPressed, isNotNull);
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
    expect(
      find.text('Xếp Lê Văn Cường (10000003) vào vị trí G05'),
      findsOneWidget,
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
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });
}
