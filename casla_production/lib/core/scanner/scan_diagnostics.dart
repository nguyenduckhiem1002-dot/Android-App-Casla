import 'dart:collection';

/// Bounded in-memory diagnostics, including release builds. Only fixed event
/// names and numeric lengths can enter the support log; never QR/password text.
enum ScanDiagnosticEvent {
  listenerStarted,
  listenerStopped,
  probeAvailable,
  probeUnavailable,
  channelError,
  invalidEnvelope,
  wedgeAttached,
  wedgeDetached,
  wedgeBurst,
  wedgeNoCharacter,
  wedgeFieldFocused,
  wedgeAccepted,
  wedgeRejected,
  eventReceived,
  ignoredInactive,
  ignoredDuplicate,
  callbackAccepted,
  callbackRejected,
  callbackError,
  classifiedOperation,
  classifiedWorker,
  classifiedUnknown,
}

class ScanDiagnostics {
  static final instance = ScanDiagnostics();
  static const capacity = 120;
  final Queue<String> _entries = Queue<String>();

  void record(ScanDiagnosticEvent event, {int? length}) {
    if (_entries.length >= capacity) _entries.removeFirst();
    _entries.add(
      '${DateTime.now().toUtc().toIso8601String()} '
      '${event.name}${length == null ? '' : ' length=$length'}',
    );
  }

  String export() => _entries.isEmpty
      ? 'Chưa có sự kiện quét trong phiên mở app này.'
      : _entries.join('\n');

  void clear() => _entries.clear();
}
