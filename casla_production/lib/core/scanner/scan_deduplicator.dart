class ScanDeduplicator {
  final Duration window;

  String? _lastValue;
  DateTime? _lastAcceptedAt;

  ScanDeduplicator({this.window = const Duration(milliseconds: 750)});

  bool shouldAccept(String rawValue, {DateTime? now}) {
    final value = rawValue.trim();
    if (value.isEmpty) return false;

    final acceptedAt = now ?? DateTime.now();
    final isDuplicate =
        _lastValue == value &&
        _lastAcceptedAt != null &&
        acceptedAt.difference(_lastAcceptedAt!) < window;

    if (isDuplicate) return false;

    _lastValue = value;
    _lastAcceptedAt = acceptedAt;
    return true;
  }

  void reset() {
    _lastValue = null;
    _lastAcceptedAt = null;
  }
}
