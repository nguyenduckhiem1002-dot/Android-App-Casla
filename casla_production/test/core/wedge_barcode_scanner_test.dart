import 'dart:async';

import 'package:casla_production/core/scanner/barcode_scan_event.dart';
import 'package:casla_production/core/scanner/wedge_barcode_scanner.dart';
import 'package:casla_production/core/scanner/wedge_scan_buffer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WedgeBarcodeScanner scanner;
  late List<BarcodeScanEvent> received;
  late StreamSubscription<BarcodeScanEvent> subscription;
  late bool textFieldHasFocus;
  late DateTime clock;

  void start({WedgeScanBuffer? buffer}) {
    textFieldHasFocus = false;
    clock = DateTime(2026, 9, 4, 8);
    received = <BarcodeScanEvent>[];
    scanner = WedgeBarcodeScanner(
      buffer: buffer,
      textInputHasFocus: () => textFieldHasFocus,
      clock: () => clock,
    );
    subscription = scanner.scans.listen(received.add);
  }

  tearDown(() async {
    await subscription.cancel();
    await scanner.dispose();
  });

  /// One key down event carrying [character].
  KeyEvent keyFor(String character, {LogicalKeyboardKey? logicalKey}) {
    return KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: logicalKey ?? LogicalKeyboardKey.keyA,
      character: logicalKey == null ? character : null,
      timeStamp: Duration.zero,
    );
  }

  /// Types [text] fast enough to read as a reader, then presses Enter.
  ///
  /// The scan stream is a broadcast controller, so it hands events to
  /// listeners on a microtask. Draining the queue here keeps every
  /// assertion below written against the delivered result rather than the
  /// emission.
  Future<void> scan(
    String text, {
    Duration perKey = const Duration(milliseconds: 8),
  }) async {
    for (final rune in text.runes) {
      scanner.handleKeyEvent(keyFor(String.fromCharCode(rune)));
      clock = clock.add(perKey);
    }
    scanner.handleKeyEvent(
      keyFor('\n', logicalKey: LogicalKeyboardKey.enter),
    );
    await pumpEventQueue();
  }

  test('a wedge burst terminated by Enter is published as one scan', () async {
    start();

    await scan('NV000123');

    expect(received, hasLength(1));
    expect(received.single.rawValue, 'NV000123');
    expect(received.single.source, BarcodeScanSource.hardware);
    // Tagged so the listener can tell wedge scans apart from broadcast ones
    // in telemetry without inspecting the payload.
    expect(received.single.symbology, 'wedge');
  });

  test('printable keys are consumed, so nothing else reacts to them', () {
    start();

    expect(scanner.handleKeyEvent(keyFor('N')), isTrue);
  });

  test('a bare Enter is left alone for the screen to handle', () {
    start();

    // No burst in progress, so this Enter belongs to whatever button or form
    // the operator is actually using.
    expect(
      scanner.handleKeyEvent(keyFor('\n', logicalKey: LogicalKeyboardKey.enter)),
      isFalse,
    );
    expect(received, isEmpty);
  });

  test('key-up events are ignored', () {
    start();

    final event = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      timeStamp: Duration.zero,
    );
    expect(scanner.handleKeyEvent(event), isFalse);
  });

  test('a focused text field keeps the keystrokes', () async {
    start();
    textFieldHasFocus = true;

    // Standard wedge behaviour: when the operator is in a field, the reader's
    // output belongs to that field, not to the screen's scan handler.
    expect(scanner.handleKeyEvent(keyFor('N')), isFalse);
    await scan('NV000123');
    expect(received, isEmpty);
  });

  test('control characters never enter the payload', () {
    start();

    // Escape and Delete would otherwise be appended verbatim and corrupt
    // the barcode. Built from code points so the literals cannot be
    // mangled in transit.
    expect(scanner.handleKeyEvent(keyFor(String.fromCharCode(0x1b))), isFalse);
    expect(scanner.handleKeyEvent(keyFor(String.fromCharCode(0x7f))), isFalse);
  });

  test('two consecutive scans arrive as two events', () async {
    start();

    await scan('NV000123');
    await scan('NV000456');

    expect(received.map((event) => event.rawValue), [
      'NV000123',
      'NV000456',
    ]);
  });

  test('typing at human speed is not published as a scan', () async {
    start();

    // 180ms per key is ordinary typing on a handset keypad. A reader
    // delivers its characters back to back, which is the only thing that
    // separates the two.
    await scan('abcdef', perKey: const Duration(milliseconds: 180));

    expect(received, isEmpty);
  });

  test('nothing is published once the listener has gone', () async {
    start();
    await subscription.cancel();

    await scan('NV000123');

    expect(received, isEmpty);
  });

  test('the reader reports itself usable off-web', () async {
    start();

    expect(await scanner.isAvailable(), isTrue);
  });
}
