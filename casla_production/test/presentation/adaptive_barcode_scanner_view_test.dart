import 'dart:async';

import 'package:casla_production/core/scanner/barcode_scan_event.dart';
import 'package:casla_production/core/scanner/barcode_scanner.dart';
import 'package:casla_production/core/telemetry/field_telemetry.dart';
import 'package:casla_production/presentation/widgets/adaptive_barcode_scanner_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('RS38 mode exposes hardware-ready state and accepts one scan', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: true);
    final telemetry = FieldTelemetry();
    addTearDown(scanner.close);
    final accepted = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptiveBarcodeScannerView(
            title: 'Xác nhận công nhân',
            subtitle: 'Quét mã công nhân',
            hardwareScanner: scanner,
            telemetry: telemetry,
            onScan: accepted.add,
            onManualInput: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Đầu đọc PDA đang hoạt động'), findsOneWidget);
    expect(find.text('SẴN SÀNG QUÉT'), findsOneWidget);
    expect(find.text('Nhập mã thủ công'), findsOneWidget);
    expect(find.text('Dùng camera thay thế'), findsOneWidget);

    scanner.emit('  MNV00123  ');
    await tester.pump();

    expect(accepted, ['MNV00123']);
    expect(telemetry.snapshot().count(FieldMetric.hardwareScanAccepted), 1);
    expect(find.text('ĐÃ NHẬN MÃ'), findsOneWidget);
    expect(find.text('Đã nhận mã • đang kiểm tra dữ liệu'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 650));
    expect(find.text('SẴN SÀNG QUÉT'), findsOneWidget);
    expect(find.text('Sẵn sàng cho lượt quét tiếp theo'), findsOneWidget);

    scanner.emit('MNV00123');
    await tester.pump();
    expect(accepted, ['MNV00123']);
    expect(telemetry.snapshot().count(FieldMetric.hardwareScanDuplicate), 1);
  });

  testWidgets('manual action stays available in hardware scanner mode', (
    tester,
  ) async {
    final scanner = _FakeScanner(available: true);
    addTearDown(scanner.close);
    var manualPressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptiveBarcodeScannerView(
            title: 'Xác nhận công nhân',
            subtitle: 'Quét mã công nhân',
            hardwareScanner: scanner,
            onScan: (_) {},
            onManualInput: () => manualPressed = true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

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

  void emit(String rawValue) {
    _controller.add(
      BarcodeScanEvent(
        rawValue: rawValue,
        source: BarcodeScanSource.hardware,
        timestamp: DateTime(2026, 9, 4),
      ),
    );
  }

  Future<void> close() => _controller.close();
}
