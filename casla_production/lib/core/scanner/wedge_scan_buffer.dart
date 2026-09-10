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

  /// Mirrors BarcodeScanEvent.maxRawValueCharacters. A burst longer than this
  /// is not a barcode; the buffer drops it instead of growing without bound.
  static const int maxLength = 4096;

  final Duration interKeyGap;
  final Duration maxAverageKeyGap;
  final int minLength;

  final StringBuffer _buffer = StringBuffer();
  DateTime? _startedAt;
  DateTime? _lastKeyAt;
  int _count = 0;

  WedgeScanBuffer({
    this.interKeyGap = defaultInterKeyGap,
    this.maxAverageKeyGap = defaultMaxAverageKeyGap,
    this.minLength = defaultMinLength,
  });

  bool get isEmpty => _count == 0;

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
    return now.difference(lastKeyAt) >= interKeyGap;
  }

  /// Adds one printable character, starting a new burst if the previous one
  /// has already gone stale.
  void append(String character, {DateTime? now}) {
    if (character.isEmpty) return;
    final at = now ?? DateTime.now();

    final lastKeyAt = _lastKeyAt;
    if (lastKeyAt != null && at.difference(lastKeyAt) > interKeyGap) {
      reset();
    }
    if (_count + character.length > maxLength) {
      reset();
      return;
    }

    _startedAt ??= at;
    _lastKeyAt = at;
    _buffer.write(character);
    _count += character.length;
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
  }
}
