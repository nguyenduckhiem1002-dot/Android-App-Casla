/// Privacy-safe, aggregate-only telemetry for field diagnostics.
///
/// Metrics are deliberately represented by a closed enum and accept no labels,
/// free-form strings, barcodes, worker identifiers, SAP payloads, tokens or
/// credentials. The default store is in-memory only; callers may surface a
/// snapshot to support tooling without creating a new data-export channel.
enum FieldMetric {
  hardwareScanAccepted,
  hardwareScanDuplicate,
  workHistoryCacheHit,
  workHistoryStaleHit,
  workHistoryCacheMiss,
  workHistoryRemoteSuccess,
  workHistoryRemoteFailure,
}

class FieldTelemetry {
  FieldTelemetry();

  static final FieldTelemetry instance = FieldTelemetry();

  final Map<FieldMetric, int> _counts = <FieldMetric, int>{};
  final Map<FieldMetric, int> _totalDurationMs = <FieldMetric, int>{};

  void increment(FieldMetric metric) {
    _counts.update(metric, (value) => value + 1, ifAbsent: () => 1);
  }

  void recordDuration(FieldMetric metric, Duration duration) {
    increment(metric);
    _totalDurationMs.update(
      metric,
      (value) => value + duration.inMilliseconds,
      ifAbsent: () => duration.inMilliseconds,
    );
  }

  FieldTelemetrySnapshot snapshot() => FieldTelemetrySnapshot._(
    _counts: Map<FieldMetric, int>.unmodifiable(_counts),
    _totalDurationMs: Map<FieldMetric, int>.unmodifiable(_totalDurationMs),
  );

  void reset() {
    _counts.clear();
    _totalDurationMs.clear();
  }
}

class FieldTelemetrySnapshot {
  final Map<FieldMetric, int> _counts;
  final Map<FieldMetric, int> _totalDurationMs;

  const FieldTelemetrySnapshot._({
    required this._counts,
    required this._totalDurationMs,
  });

  int count(FieldMetric metric) => _counts[metric] ?? 0;

  Duration totalDuration(FieldMetric metric) =>
      Duration(milliseconds: _totalDurationMs[metric] ?? 0);

  Duration averageDuration(FieldMetric metric) {
    final countValue = count(metric);
    if (countValue == 0) return Duration.zero;
    return Duration(
      milliseconds: (_totalDurationMs[metric] ?? 0) ~/ countValue,
    );
  }

  /// A copy/paste friendly support payload containing metric names and numbers
  /// only. No caller-provided values can enter this structure.
  Map<String, Map<String, int>> toDiagnosticMap() {
    final result = <String, Map<String, int>>{};
    for (final metric in FieldMetric.values) {
      final countValue = count(metric);
      final totalMs = _totalDurationMs[metric] ?? 0;
      if (countValue == 0 && totalMs == 0) continue;
      result[metric.name] = <String, int>{
        'count': countValue,
        if (totalMs > 0) 'totalDurationMs': totalMs,
        if (totalMs > 0)
          'averageDurationMs': averageDuration(metric).inMilliseconds,
      };
    }
    return result;
  }
}
