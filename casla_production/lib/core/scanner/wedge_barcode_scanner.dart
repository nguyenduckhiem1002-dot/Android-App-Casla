import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'barcode_scan_event.dart';
import 'barcode_scanner.dart';
import 'wedge_scan_buffer.dart';

/// Reads a PDA imager that is left in its factory "keyboard wedge" mode.
///
/// This is the universal capture path. It needs no vendor SDK, no broadcast
/// configuration and no allow-listed manufacturer: if the reader can type, this
/// class can read it. [PlatformHardwareBarcodeScanner] stays as the faster,
/// better-attributed path on the handsets whose vendor we do recognise.
///
/// Keystrokes are claimed only while no text field holds focus. When the
/// operator is typing into a field, the wedge output belongs to that field —
/// that is the behaviour people already expect — so the handler steps aside.
class WedgeBarcodeScanner implements BarcodeScanner {
  final WedgeScanBuffer _buffer;
  final HardwareKeyboard _keyboard;
  final bool Function() _textInputHasFocus;
  final DateTime Function() _clock;

  Timer? _settleTimer;
  bool _handlerAttached = false;

  /// Closed by [dispose], which the owning listener calls from its own
  /// `dispose`. Arming and disarming the key handler follows subscription, so
  /// no keystroke is claimed while nothing is listening.
  // ignore: close_sinks
  late final StreamController<BarcodeScanEvent> _controller =
      StreamController<BarcodeScanEvent>.broadcast(
        onListen: _attach,
        onCancel: _detach,
      );

  WedgeBarcodeScanner({
    WedgeScanBuffer? buffer,
    HardwareKeyboard? keyboard,
    bool Function()? textInputHasFocus,
    DateTime Function()? clock,
  }) : _buffer = buffer ?? WedgeScanBuffer(),
       _keyboard = keyboard ?? HardwareKeyboard.instance,
       _textInputHasFocus = textInputHasFocus ?? defaultTextInputHasFocus,
       // Key cadence is the whole basis for telling a reader from a
       // person, so tests need to drive it rather than race the clock.
       _clock = clock ?? DateTime.now;

  /// A wedge reader can be attached to anything with a keyboard input path, so
  /// this reports capability rather than detection. Whether a reader is really
  /// present only becomes known when the first burst arrives.
  @override
  Future<bool> isAvailable() async => !kIsWeb;

  @override
  Stream<BarcodeScanEvent> get scans => _controller.stream;

  /// Detects whether the operator is typing into a field rather than scanning.
  ///
  /// Deliberately fails open: an unrecognised focus owner leaves the wedge
  /// armed, because losing a scan is worse than claiming a keystroke on a
  /// screen that had nowhere to put it.
  static bool defaultTextInputHasFocus() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _attach() {
    if (_handlerAttached) return;
    _keyboard.addHandler(handleKeyEvent);
    _handlerAttached = true;
  }

  void _detach() {
    if (!_handlerAttached) return;
    _keyboard.removeHandler(handleKeyEvent);
    _handlerAttached = false;
    _settleTimer?.cancel();
    _settleTimer = null;
    _buffer.reset();
  }

  /// Releases the key handler and closes the stream. Safe to call twice.
  Future<void> dispose() async {
    _detach();
    if (!_controller.isClosed) await _controller.close();
  }

  /// Visible for tests. Returns true when the keystroke was consumed as part
  /// of a scan burst.
  @visibleForTesting
  bool handleKeyEvent(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    if (_controller.isClosed || !_controller.hasListener) return false;

    if (_textInputHasFocus()) {
      _cancelSettleTimer();
      _buffer.reset();
      return false;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab) {
      _cancelSettleTimer();
      // An empty buffer means this Enter was not a scan terminator, so it has
      // to keep travelling to whatever the screen does with Enter.
      if (_buffer.isEmpty) return false;
      return _emit(_buffer.flush());
    }

    final character = event.character;
    if (character == null || character.isEmpty) return false;
    // Control characters carry no barcode content and would corrupt the value.
    if (character.codeUnitAt(0) < 0x20 || character.codeUnitAt(0) == 0x7f) {
      return false;
    }

    _buffer.append(character, now: _clock());
    _restartSettleTimer();
    return true;
  }

  /// Readers configured without a terminator finish here: once the burst has
  /// been quiet for one inter-key gap, whatever arrived is the barcode.
  void _restartSettleTimer() {
    _settleTimer?.cancel();
    _settleTimer = Timer(_buffer.interKeyGap, () {
      _settleTimer = null;
      _emit(_buffer.flush());
    });
  }

  void _cancelSettleTimer() {
    _settleTimer?.cancel();
    _settleTimer = null;
  }

  bool _emit(String? code) {
    if (code == null || code.isEmpty) return false;
    if (_controller.isClosed) return false;

    _controller.add(
      BarcodeScanEvent(
        rawValue: code,
        source: BarcodeScanSource.hardware,
        symbology: 'wedge',
        timestamp: _clock(),
      ),
    );
    return true;
  }
}
