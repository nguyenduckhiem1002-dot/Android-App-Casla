import 'package:casla_production/core/scanner/wedge_scan_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feeds a burst at a fixed pace and returns the flushed value.
String? typeBurst(
  WedgeScanBuffer buffer,
  String text, {
  required Duration perKey,
  DateTime? start,
}) {
  var at = start ?? DateTime(2026, 9, 4, 8);
  for (final rune in text.runes) {
    buffer.append(String.fromCharCode(rune), now: at);
    at = at.add(perKey);
  }
  return buffer.flush();
}

void main() {
  group('reader input', () {
    test('a fast burst terminated by the caller is accepted', () {
      final buffer = WedgeScanBuffer();

      expect(
        typeBurst(buffer, 'NV000123', perKey: const Duration(milliseconds: 8)),
        'NV000123',
      );
    });

    test('a JSON worker payload survives intact', () {
      final buffer = WedgeScanBuffer();
      const payload = '{"WorkerID":"NC000002","WorkerName":"Le Thi Hoa"}';

      expect(
        typeBurst(buffer, payload, perKey: const Duration(milliseconds: 4)),
        payload,
      );
    });

    test('surrounding whitespace is trimmed', () {
      final buffer = WedgeScanBuffer();

      expect(
        typeBurst(buffer, '  NV1  ', perKey: const Duration(milliseconds: 5)),
        'NV1',
      );
    });
  });

  group('human input', () {
    test('a slow burst is rejected', () {
      final buffer = WedgeScanBuffer();

      // 200ms per key is ordinary typing. Nothing here should be mistaken for
      // a reader, whose characters arrive back to back.
      expect(
        typeBurst(buffer, 'abc', perKey: const Duration(milliseconds: 200)),
        isNull,
      );
    });

    test('a single keystroke is rejected', () {
      final buffer = WedgeScanBuffer();
      buffer.append('a');

      expect(buffer.flush(), isNull);
    });

    test('a payload below the minimum length is rejected', () {
      final buffer = WedgeScanBuffer();

      expect(
        typeBurst(buffer, 'ab', perKey: const Duration(milliseconds: 5)),
        isNull,
      );
    });
  });

  group('burst boundaries', () {
    test('a long gap starts a new burst rather than extending the old one', () {
      final buffer = WedgeScanBuffer();
      final start = DateTime(2026, 9, 4, 8);

      for (final rune in 'AAA'.runes) {
        buffer.append(String.fromCharCode(rune), now: start);
      }
      // Second scan arrives well after the first went quiet. Concatenating
      // them would produce a code that was never on any label.
      var at = start.add(const Duration(seconds: 5));
      for (final rune in 'BBB'.runes) {
        buffer.append(String.fromCharCode(rune), now: at);
        at = at.add(const Duration(milliseconds: 5));
      }

      expect(buffer.flush(), 'BBB');
    });

    test('settling is reported once the inter-key gap has elapsed', () {
      final buffer = WedgeScanBuffer();
      final at = DateTime(2026, 9, 4, 8);
      buffer.append('A', now: at);

      expect(buffer.hasSettled(at.add(const Duration(milliseconds: 50))), isFalse);
      expect(buffer.hasSettled(at.add(const Duration(milliseconds: 200))), isTrue);
    });

    test('an empty buffer has not settled', () {
      expect(WedgeScanBuffer().hasSettled(DateTime(2026, 9, 4)), isFalse);
    });

    test('flushing clears the buffer', () {
      final buffer = WedgeScanBuffer();
      typeBurst(buffer, 'NV1234', perKey: const Duration(milliseconds: 5));

      expect(buffer.isEmpty, isTrue);
      expect(buffer.flush(), isNull);
    });

    test('reset discards a burst in progress', () {
      final buffer = WedgeScanBuffer();
      buffer.append('A');
      buffer.append('B');
      buffer.reset();

      expect(buffer.isEmpty, isTrue);
      expect(buffer.length, 0);
    });
  });

  test('an oversized burst is dropped rather than grown without bound', () {
    final buffer = WedgeScanBuffer();
    final at = DateTime(2026, 9, 4, 8);
    for (var i = 0; i <= WedgeScanBuffer.maxLength; i++) {
      buffer.append('A', now: at);
    }

    // Past the cap the buffer restarts, so what remains is a short tail rather
    // than a multi-megabyte string built from a stuck key.
    expect(buffer.length, lessThan(WedgeScanBuffer.maxLength));
  });
}
