/// Accumulates keyboard-wedge keystrokes into one barcode.
///
/// Every PDA ships with its imager in "keyboard wedge" mode by default: the
/// reader types the decoded barcode as if it were a keyboard, then sends a
/// terminator (usually Enter). That behaviour is identical across CipherLab,
/// Zebra, Honeywell, Urovo, Chainway, Newland and the rest, which makes it the
/// only capture path that needs no vendor knowledge at all.
///
/// The logic lives here, free of Flutter, so the burst-detection rules can be
/// tested against a clock instead of a device.
class WedgeScanBuffer {
  /// A reader emits its characters back to back. Anything slower than this
  /// between two keys starts a new burst rather than extending the old one.
  static const Duration defaultInterKeyGap = Duration(milliseconds: 120);

  /// Sustained average gap a burst must stay under to count as machine input.
  /// 50ms/char over three or more characters is roughly 240 words per minute,
  /// which a person cannot hold — and no text field is focused when this runs,
  /// so nothing a human meant to type is at stake either way.
  static const Duration defaultMaxAverageKeyGap = Duration(milliseconds: 50);

  /// Shorter payloads are almost always a stray key press, not a barcode.
  static const int defaultMinLength = 3;

  /// Gap tolerated inside an unfinished JSON object. A 300-character label
  /// typed through the Android key pipeline can stall on a GC pause or a busy
  /// frame; resetting there would silently drop the start of the payload.
  static const Duration defaultJsonInterKeyGap = Duration(milliseconds: 800);

  /// Mirrors BarcodeScanEvent.maxRawValueCharacters. A burst longer than this
  /// is not a barcode; the buffer drops it instead of growing without bound.
  static const int maxLength = 4096;

  final Duration interKeyGap;
  final Duration jsonInterKeyGap;
  final Duration maxAverageKeyGap;
  final int minLength;

  final StringBuffer _buffer = StringBuffer();
  DateTime? _startedAt;
  DateTime? _lastKeyAt;
  int _count = 0;
  bool _discardCurrentBurst = false;

  // JSON structure of the current burst, tracked only when it starts with `{`.
  bool _isJson = false;
  int _jsonDepth = 0;
  bool _jsonInString = false;
  bool _jsonEscaped = false;

  WedgeScanBuffer({
    this.interKeyGap = defaultInterKeyGap,
    this.jsonInterKeyGap = defaultJsonInterKeyGap,
    this.maxAverageKeyGap = defaultMaxAverageKeyGap,
    this.minLength = defaultMinLength,
  });

  bool get isEmpty => _count == 0;

  /// True while the burst is a JSON object whose closing brace has not
  /// arrived. An Enter or Tab then belongs to the payload (a line break in a
  /// label field), not to the end of the scan.
  bool get hasOpenJsonObject => _isJson && _jsonDepth > 0;

  /// How long the burst may go quiet before it is considered finished.
  Duration get settleDelay => hasOpenJsonObject ? jsonInterKeyGap : interKeyGap;

  int get length => _count;

  /// True once the burst is long enough and fast enough to be a reader.
  bool get looksMachineTyped {
    if (_count < minLength) return false;
    final startedAt = _startedAt;
    final lastKeyAt = _lastKeyAt;
    if (startedAt == null || lastKeyAt == null) return false;

    final gaps = _count - 1;
    if (gaps <= 0) return false;
    final averageGap = lastKeyAt.difference(startedAt).inMicroseconds / gaps;
    return averageGap <= maxAverageKeyGap.inMicroseconds;
  }

  /// True when the burst has gone quiet long enough to be considered finished.
  ///
  /// Readers configured without a terminator rely on this; readers that do send
  /// Enter reach [flush] first and never get here.
  bool hasSettled(DateTime now) {
    final lastKeyAt = _lastKeyAt;
    if (lastKeyAt == null) return false;
    return now.difference(lastKeyAt) >= settleDelay;
  }

  /// Adds one printable character, starting a new burst if the previous one
  /// has already gone stale.
  void append(String character, {DateTime? now}) {
    if (character.isEmpty) return;
    final at = now ?? DateTime.now();

    final lastKeyAt = _lastKeyAt;
    if (lastKeyAt != null && at.difference(lastKeyAt) > settleDelay) {
      reset();
    }
    // Once a burst exceeds the protocol limit, discard the entire burst. Do
    // not reset and accept its tail as a new barcode: a long corrupt payload
    // must never turn into a different valid worker code.
    if (_discardCurrentBurst) {
      _lastKeyAt = at;
      return;
    }
    if (_count + character.length > maxLength) {
      _buffer.clear();
      _startedAt = null;
      _count = 0;
      _discardCurrentBurst = true;
      _lastKeyAt = at;
      return;
    }

    _startedAt ??= at;
    _lastKeyAt = at;
    if (_count == 0) _isJson = character.startsWith('{');
    _buffer.write(character);
    _count += character.length;
    if (_isJson) _trackJson(character);
  }

  /// Keeps a line break or tab that arrived as Enter/Tab inside an open JSON
  /// object. The parser escapes control characters inside strings.
  void appendJsonBreak(String character, {DateTime? now}) {
    if (!hasOpenJsonObject) return;
    append(character, now: now);
  }

  void _trackJson(String text) {
    for (final unit in text.codeUnits) {
      if (_jsonInString) {
        if (_jsonEscaped) {
          _jsonEscaped = false;
        } else if (unit == 0x5C) {
          _jsonEscaped = true;
        } else if (unit == 0x22) {
          _jsonInString = false;
        }
      } else if (unit == 0x22) {
        _jsonInString = true;
      } else if (unit == 0x7B) {
        _jsonDepth++;
      } else if (unit == 0x7D && _jsonDepth > 0) {
        _jsonDepth--;
      }
    }
  }

  /// Returns the completed barcode and clears the buffer.
  ///
  /// Returns null when the burst was too short or too slow to be a reader, so
  /// the caller can leave those keystrokes alone.
  String? flush() {
    final accepted = looksMachineTyped;
    final value = _buffer.toString().trim();
    reset();
    if (!accepted || value.length < minLength) return null;
    return value;
  }

  void reset() {
    _buffer.clear();
    _startedAt = null;
    _lastKeyAt = null;
    _count = 0;
    _discardCurrentBurst = false;
    _isJson = false;
    _jsonDepth = 0;
    _jsonInString = false;
    _jsonEscaped = false;
  }
}
