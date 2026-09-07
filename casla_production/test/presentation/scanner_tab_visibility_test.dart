import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/core/scanner/barcode_scanner.dart';
import 'package:casla_production/core/scanner/barcode_scan_event.dart';
import 'package:casla_production/presentation/widgets/adaptive_barcode_scanner_view.dart';

class FakeScanner implements BarcodeScanner {
  // Closed explicitly by the widget test after scanner disposal.
  // ignore: close_sinks
  final events = StreamController<BarcodeScanEvent>.broadcast();
  @override
  Future<bool> isAvailable() async => true;
  @override
  Stream<BarcodeScanEvent> get scans => events.stream;
}

void main() {
  testWidgets('hidden tab must not handle PDA scans', (tester) async {
    final scanner = FakeScanner();
    var handled = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: false,
          child: AdaptiveBarcodeScannerView(
            title: 'Scan',
            subtitle: 'Test',
            hardwareScanner: scanner,
            onScan: (_) {
              handled++;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    scanner.events.add(
      BarcodeScanEvent(
        rawValue: 'NV01',
        source: BarcodeScanSource.hardware,
        timestamp: DateTime.now(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(handled, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await scanner.events.close();
  });
}
