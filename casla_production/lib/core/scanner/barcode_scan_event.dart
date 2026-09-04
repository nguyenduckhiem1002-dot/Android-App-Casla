enum BarcodeScanSource { hardware, camera, manual }

class BarcodeScanEvent {
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

    final rawValue = payload['rawValue']?.toString().trim() ?? '';
    if (rawValue.isEmpty) {
      throw const FormatException('Scanner event is missing barcode data.');
    }

    final sourceName = payload['source']?.toString().toLowerCase();
    final source = switch (sourceName) {
      'camera' => BarcodeScanSource.camera,
      'manual' => BarcodeScanSource.manual,
      _ => BarcodeScanSource.hardware,
    };

    final timestampMs = int.tryParse(payload['timestampMs']?.toString() ?? '');

    return BarcodeScanEvent(
      rawValue: rawValue,
      symbology: payload['symbology']?.toString(),
      source: source,
      timestamp: timestampMs == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(timestampMs),
    );
  }
}
