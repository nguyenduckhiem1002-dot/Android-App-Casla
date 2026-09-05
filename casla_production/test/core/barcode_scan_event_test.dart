import 'package:casla_production/core/scanner/barcode_scan_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BarcodeScanEvent.fromPlatform', () {
    test('accepts a bounded hardware event', () {
      final event = BarcodeScanEvent.fromPlatform({
        'rawValue': '  NV123  ',
        'symbology': ' QR ',
        'source': 'hardware',
        'timestampMs': 1700000000000,
      });

      expect(event.rawValue, 'NV123');
      expect(event.symbology, 'QR');
      expect(event.source, BarcodeScanSource.hardware);
      expect(event.timestamp.millisecondsSinceEpoch, 1700000000000);
    });

    test('rejects missing or unknown source', () {
      expect(
        () => BarcodeScanEvent.fromPlatform({'rawValue': 'NV123'}),
        throwsFormatException,
      );
      expect(
        () => BarcodeScanEvent.fromPlatform({
          'rawValue': 'NV123',
          'source': 'spoofed',
        }),
        throwsFormatException,
      );
    });

    test('rejects invalid barcode data', () {
      final oversized = List.filled(
        BarcodeScanEvent.maxRawValueCharacters + 1,
        'A',
      ).join();

      expect(
        () => BarcodeScanEvent.fromPlatform({
          'rawValue': 123,
          'source': 'hardware',
        }),
        throwsFormatException,
      );
      expect(
        () => BarcodeScanEvent.fromPlatform({
          'rawValue': oversized,
          'source': 'hardware',
        }),
        throwsFormatException,
      );
      expect(
        () => BarcodeScanEvent.fromPlatform({
          'rawValue': 'NV12\u00003',
          'source': 'hardware',
        }),
        throwsFormatException,
      );
    });

    test('rejects malformed metadata', () {
      expect(
        () => BarcodeScanEvent.fromPlatform({
          'rawValue': 'NV123',
          'source': 'hardware',
          'symbology': List.filled(2, 'QR'),
        }),
        throwsFormatException,
      );
      expect(
        () => BarcodeScanEvent.fromPlatform({
          'rawValue': 'NV123',
          'source': 'hardware',
          'timestampMs': '1700000000000',
        }),
        throwsFormatException,
      );
    });
  });
}
