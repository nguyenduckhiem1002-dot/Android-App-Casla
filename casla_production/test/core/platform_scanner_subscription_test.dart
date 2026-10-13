import 'package:casla_production/core/scanner/barcode_scan_event.dart';
import 'package:casla_production/core/scanner/platform_hardware_barcode_scanner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'closing a scan route keeps another route subscribed to native',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('casla/scanner/events');
      var listens = 0;
      var cancels = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'listen') listens++;
        if (call.method == 'cancel') cancels++;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const first = PlatformHardwareBarcodeScanner();
      const second = PlatformHardwareBarcodeScanner();
      final received = <BarcodeScanEvent>[];
      final a = first.scans.listen((_) {});
      final b = second.scans.listen(received.add);
      addTearDown(a.cancel);
      addTearDown(b.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(listens, 1);

      await a.cancel();
      expect(cancels, 0);
      ServicesBinding.instance.channelBuffers.push(
        'casla/scanner/events',
        const StandardMethodCodec().encodeSuccessEnvelope({
          'rawValue': 'TEST_WORKER',
          'source': 'hardware',
          'timestampMs': DateTime.now().millisecondsSinceEpoch,
        }),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(received.single.rawValue, 'TEST_WORKER');

      await b.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(cancels, 1);
    },
  );
}
