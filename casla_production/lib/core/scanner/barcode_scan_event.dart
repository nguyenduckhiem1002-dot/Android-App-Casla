enum BarcodeScanSource { hardware, camera, manual }

class BarcodeScanEvent {
  static const int maxRawValueCharacters = 4096;
  static const int maxSymbologyCharacters = 64;

  final String rawValue;
  final String? symbology;
  final BarcodeScanSource source;
  final DateTime timestamp;

  const BarcodeScanEvent({
    required this.rawValue,
    required this.source,
    required this.timestamp,
    this.symbology,
  });

  factory BarcodeScanEvent.fromPlatform(Object? payload) {
    if (payload is! Map) {
      throw const FormatException('Invalid scanner event payload.');
    }

    final rawPayload = payload['rawValue'];
    if (rawPayload is! String) {
      throw const FormatException('Missing scanner barcode data.');
    }
    final rawValue = rawPayload.trim();
    if (rawValue.isEmpty ||
        rawValue.length > maxRawValueCharacters ||
        rawValue.contains('\u0000')) {
      throw const FormatException('Invalid scanner barcode data.');
    }

    final sourcePayload = payload['source'];
    if (sourcePayload is! String) {
      throw const FormatException('Missing scanner source metadata.');
    }
    final source = switch (sourcePayload.trim().toLowerCase()) {
      'hardware' => BarcodeScanSource.hardware,
      'camera' => BarcodeScanSource.camera,
      'manual' => BarcodeScanSource.manual,
      _ => throw const FormatException('Unknown scanner source.'),
    };

    final symbologyPayload = payload['symbology'];
    String? symbology;
    if (symbologyPayload != null) {
      if (symbologyPayload is! String) {
        throw const FormatException('Invalid scanner symbology.');
      }
      final normalized = symbologyPayload.trim();
      if (normalized.length > maxSymbologyCharacters) {
        throw const FormatException('Scanner symbology is too long.');
      }
      symbology = normalized.isEmpty ? null : normalized;
    }

    final timestampPayload = payload['timestampMs'];
    if (timestampPayload != null && timestampPayload is! int) {
      throw const FormatException('Invalid scanner timestamp.');
    }

    return BarcodeScanEvent(
      rawValue: rawValue,
      symbology: symbology,
      source: source,
      timestamp: timestampPayload == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(timestampPayload),
    );
  }
}
