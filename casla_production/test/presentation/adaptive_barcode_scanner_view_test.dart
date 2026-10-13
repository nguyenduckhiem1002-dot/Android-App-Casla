import 'dart:async';
import 'package:casla_production/app/router/app_route_observer.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:casla_production/core/scanner/barcode_scan_event.dart';
import 'package:casla_production/core/scanner/barcode_scanner.dart';
import 'package:casla_production/core/scanner/composite_barcode_scanner.dart';
import 'package:casla_production/core/scanner/wedge_barcode_scanner.dart';
import 'package:casla_production/core/scanner/scan_feedback.dart';
import 'package:casla_production/core/scanner/scanner_preferences.dart';
import 'package:casla_production/core/telemetry/field_telemetry.dart';
import 'package:casla_production/presentation/widgets/adaptive_barcode_scanner_view.dart';
import 'package:casla_production/presentation/widgets/qr_scanner_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => ScanFeedback.setMuted(true));
  tearDown(() => ScanFeedback.setMuted(false));

  Future<void> pumpScanner(
    WidgetTester tester, {
    required BarcodeScanner scanner,
    required FutureOr<bool> Function(String) onScan,
    FieldTelemetry? telemetry,
    ScannerPreferences? preferences,
    VoidCallback? onManualInput,
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [appRouteObserver],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: AdaptiveBarcodeScannerView(
            title: 'Xác nhận công nhân',
            subtitle:
                'Quét thẻ hoặc mã QR công nhân để xem chi tiết và xác nhận.',
            hardwareScanner: scanner,
            telemetry: telemetry,
            preferences: preferences ?? InMemoryScannerPreferences(),
            onScan: onScan,
            onManualInput: onManualInput ?? () {},
          ),
        ),
      ),
    );
    // One frame to mount, one for the availability probe to settle.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('confirmation scanner fits a compact PDA before and after scan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scanner = _FakeScanner(available: true);
    addTearDown(scanner.close);
    await pumpScanner(tester, scanner: scanner, onScan: (_) => true);
    expect(tester.takeException(), isNull);
    scanner.emit('MNV00123');
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Nhập mã thủ công'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scanner actions remain reachable on small screens with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final scanner = _FakeScanner(available: true);
      addTearDown(scanner.close);
      var manualOpened = false;
      await pumpScanner(
        tester,
        scanner: scanner,
        onScan: (_) => true,
        textScale: 1.5,
        onManualInput: () => manualOpened = true,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Nhập mã thủ công'));
      await tester.pump();
      await tester.tap(find.text('Nhập mã thủ công'));
      expect(manualOpened, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dismissing manual input does not invent a hardware reader', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: false);
    addTearDown(scanner.close);
    await pumpScanner(tester, scanner: scanner, onScan: (_) => true);
    final cameraState = tester.state(find.byType(QrScannerView));
    final context = tester.element(find.byType(QrScannerView));
    final closed = showModalBottomSheet<void>(
      context: context,
      builder: (context) => TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Đóng nhập tay'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Đóng nhập tay'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await closed;
    expect(find.text('Dùng camera thay thế'), findsNothing);
    expect(tester.state(find.byType(QrScannerView)), same(cameraState));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'camera error replaces the viewfinder and has one manual action',
    (tester) async {
      final scanner = _FakeScanner(available: false);
      addTearDown(scanner.close);
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpScanner(tester, scanner: scanner, onScan: (_) => true);
      final camera = tester.widget<MobileScanner>(find.byType(MobileScanner));
      camera.controller!.value = camera.controller!.value.copyWith(
        error: const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied,
        ),
      );
      await tester.pump();
      expect(find.text('Không thể mở camera'), findsOneWidget);
      expect(find.text('Nhập mã thủ công'), findsOneWidget);
      expect(find.text('Xác nhận công nhân'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('hardware mode reports ready and accepts one scan', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: true);
    final telemetry = FieldTelemetry();
    addTearDown(scanner.close);
    final accepted = <String>[];

    await pumpScanner(
      tester,
      scanner: scanner,
      telemetry: telemetry,
      onScan: (code) {
        accepted.add(code);
        return true;
      },
    );

    expect(find.text('Đầu đọc đang hoạt động'), findsOneWidget);
    expect(find.text('Sẵn sàng quét'), findsOneWidget);
    expect(find.text('Sẵn sàng nhận mã từ đầu đọc'), findsNothing);
    expect(find.text('Bóp cò trên máy để quét.'), findsNothing);
    expect(find.text('Nhập mã thủ công'), findsOneWidget);
    expect(find.text('Dùng camera thay thế'), findsOneWidget);

    scanner.emit('  MNV00123  ');
    await tester.pump();
    await tester.pump();

    expect(accepted, ['MNV00123']);
    expect(telemetry.snapshot().count(FieldMetric.hardwareScanAccepted), 1);
    expect(find.text('Đã nhận. Mời quét tiếp.'), findsOneWidget);
    // The counter is what tells an operator the reader is really firing.
    expect(find.text('Đã quét 1 mã'), findsOneWidget);

    // Within the double-fire window the same payload is suppressed, so a
    // reader that both broadcasts and types does not book the code twice.
    scanner.emit('MNV00123');
    await tester.pump();
    expect(accepted, ['MNV00123']);
    expect(telemetry.snapshot().count(FieldMetric.hardwareScanDuplicate), 1);
  });

  testWidgets('the same code can be scanned again once the guard elapses', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: true);
    addTearDown(scanner.close);
    final accepted = <String>[];

    await pumpScanner(
      tester,
      scanner: scanner,
      onScan: (code) {
        accepted.add(code);
        return true;
      },
    );

    scanner.emit('MNV00123');
    await tester.pump();
    await tester.pump();

    // Deliberately re-scanning the same worker card is a real workflow, so the
    // guard must expire rather than lock the code out for good.
    scanner.emit('MNV00123', at: const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump();

    expect(accepted, ['MNV00123', 'MNV00123']);
  });

  testWidgets('a rejected scan is counted and leaves the reader armed', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: true);
    final telemetry = FieldTelemetry();
    addTearDown(scanner.close);

    await pumpScanner(
      tester,
      scanner: scanner,
      telemetry: telemetry,
      onScan: (_) => false,
    );

    scanner.emit('NOT-A-WORKER');
    await tester.pump();
    await tester.pump();

    expect(telemetry.snapshot().count(FieldMetric.hardwareScanRejected), 1);
    expect(find.text('Sẵn sàng quét'), findsOneWidget);
    expect(find.text('Sẵn sàng nhận mã từ đầu đọc'), findsNothing);
  });

  testWidgets('a failed callback leaves the next scan usable', (tester) async {
    final scanner = _FakeScanner(available: true);
    final telemetry = FieldTelemetry();
    addTearDown(scanner.close);
    var attempts = 0;

    await pumpScanner(
      tester,
      scanner: scanner,
      telemetry: telemetry,
      onScan: (_) async {
        if (++attempts == 1) throw const FormatException('Invalid scan');
        return true;
      },
    );

    scanner.emit('INVALID');
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(telemetry.snapshot().count(FieldMetric.hardwareScanRejected), 1);
    expect(find.text('Sẵn sàng quét'), findsOneWidget);

    scanner.emit('MNV00123');
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('Đã nhận. Mời quét tiếp.'), findsOneWidget);
  });

  testWidgets('camera and laser share one in-flight callback', (tester) async {
    final scanner = _FakeScanner(available: true);
    addTearDown(scanner.close);
    final gate = Completer<bool>();
    var calls = 0;
    await pumpScanner(
      tester,
      scanner: scanner,
      preferences: InMemoryScannerPreferences(mode: ScannerMode.camera),
      onScan: (_) {
        calls++;
        return gate.future;
      },
    );
    final camera = tester.widget<QrScannerView>(find.byType(QrScannerView));
    final pendingCamera = Future<bool>.sync(() => camera.onScan('WORKER_1'));
    scanner.emit('WORKER_1');
    await tester.pump();
    final observedCalls = calls;
    gate.complete(true);
    await pendingCamera;
    await tester.pump();
    expect(observedCalls, 1);
  });

  testWidgets('a slow handler shows the busy state while it runs', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: true);
    final gate = Completer<bool>();
    addTearDown(scanner.close);

    await pumpScanner(tester, scanner: scanner, onScan: (_) => gate.future);

    scanner.emit('MNV00123');
    await tester.pump();
    await tester.pump();

    expect(find.text('Đang xử lý mã'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete(true);
    await tester.pump();
    await tester.pump();
    expect(find.text('Sẵn sàng quét'), findsOneWidget);
  });

  testWidgets('keyboard capability alone does not hide the camera', (
    tester,
  ) async {
    final native = _FakeScanner(available: false);
    final wedge = WedgeBarcodeScanner();
    final scanner = CompositeBarcodeScanner([native, wedge]);
    addTearDown(native.close);
    addTearDown(wedge.dispose);
    addTearDown(scanner.dispose);

    await pumpScanner(tester, scanner: scanner, onScan: (_) => true);

    expect(find.text('Đầu đọc đang hoạt động'), findsNothing);
    final cameraCenter = tester.getCenter(find.byType(QrScannerView));
    expect(
      tester.getCenter(find.text('Xác nhận công nhân')).dx,
      closeTo(cameraCenter.dx, 0.5),
    );
    expect(
      tester.getCenter(find.text('Nhập mã thủ công')).dx,
      closeTo(cameraCenter.dx + 13, 2),
    );
    expect(find.text('Sẵn sàng quét'), findsNothing);
  });

  testWidgets('a device with no reader falls straight through to the camera', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: false);
    addTearDown(scanner.close);

    await pumpScanner(tester, scanner: scanner, onScan: (_) => true);

    // The hardware panel's own copy must be gone; the camera view owns the
    // screen from here.
    expect(find.text('Sẵn sàng quét'), findsNothing);
    expect(find.text('Đầu đọc đang hoạt động'), findsNothing);
  });

  testWidgets('a device that has scanned before opens in hardware mode', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: false);
    addTearDown(scanner.close);

    // A keyboard-wedge reader is undetectable until it first fires, so the
    // remembered flag is the only thing that keeps the camera from taking over
    // on every subsequent visit.
    await pumpScanner(
      tester,
      scanner: scanner,
      onScan: (_) => true,
      preferences: InMemoryScannerPreferences(hardwareSeen: true),
    );

    expect(find.text('Sẵn sàng quét'), findsOneWidget);
  });

  testWidgets('the camera mode preference wins over a present reader', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: true);
    addTearDown(scanner.close);

    await pumpScanner(
      tester,
      scanner: scanner,
      onScan: (_) => true,
      preferences: InMemoryScannerPreferences(mode: ScannerMode.camera),
    );

    expect(find.text('Sẵn sàng quét'), findsNothing);
  });

  testWidgets('the hardware mode preference hides the camera escape hatch', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: false);
    addTearDown(scanner.close);

    await pumpScanner(
      tester,
      scanner: scanner,
      onScan: (_) => true,
      preferences: InMemoryScannerPreferences(mode: ScannerMode.hardware),
    );

    // Forced hardware means a technician has said this handset has a reader,
    // even though detection disagrees. Offering "use the camera" here would
    // undo the override they just set.
    expect(find.text('Chưa kết nối'), findsOneWidget);
    expect(find.text('Dùng camera thay thế'), findsNothing);
  });

  testWidgets('manual action stays available in hardware scanner mode', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: true);
    addTearDown(scanner.close);
    var manualPressed = false;

    await pumpScanner(
      tester,
      scanner: scanner,
      onScan: (_) => true,
      onManualInput: () => manualPressed = true,
    );

    await tester.tap(find.text('Nhập mã thủ công'));
    await tester.pump();

    expect(manualPressed, isTrue);
  });
}

class _FakeScanner implements BarcodeScanner {
  final bool available;
  final StreamController<BarcodeScanEvent> _controller =
      StreamController<BarcodeScanEvent>.broadcast(sync: true);

  _FakeScanner({required this.available});

  @override
  Future<bool> isAvailable() async => available;

  @override
  Stream<BarcodeScanEvent> get scans => _controller.stream;

  static final DateTime _epoch = DateTime(2026, 9, 4);

  void emit(String rawValue, {Duration at = Duration.zero}) {
    _controller.add(
      BarcodeScanEvent(
        rawValue: rawValue,
        source: BarcodeScanSource.hardware,
        timestamp: _epoch.add(at),
      ),
    );
  }

  Future<void> close() => _controller.close();
}
