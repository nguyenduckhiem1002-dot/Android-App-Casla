import 'package:casla_production/core/telemetry/field_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('aggregate telemetry counts events without accepting labels', () {
    final telemetry = FieldTelemetry();

    telemetry.increment(FieldMetric.hardwareScanAccepted);
    telemetry.increment(FieldMetric.hardwareScanAccepted);
    telemetry.increment(FieldMetric.hardwareScanDuplicate);

    final snapshot = telemetry.snapshot();
    expect(snapshot.count(FieldMetric.hardwareScanAccepted), 2);
    expect(snapshot.count(FieldMetric.hardwareScanDuplicate), 1);
    expect(snapshot.count(FieldMetric.workHistoryCacheHit), 0);
  });

  test('duration metrics expose total and average timing', () {
    final telemetry = FieldTelemetry();

    telemetry.recordDuration(
      FieldMetric.workHistoryRemoteSuccess,
      const Duration(milliseconds: 80),
    );
    telemetry.recordDuration(
      FieldMetric.workHistoryRemoteSuccess,
      const Duration(milliseconds: 120),
    );

    final snapshot = telemetry.snapshot();
    expect(snapshot.count(FieldMetric.workHistoryRemoteSuccess), 2);
    expect(
      snapshot.totalDuration(FieldMetric.workHistoryRemoteSuccess),
      const Duration(milliseconds: 200),
    );
    expect(
      snapshot.averageDuration(FieldMetric.workHistoryRemoteSuccess),
      const Duration(milliseconds: 100),
    );
  });

  test(
    'diagnostic map contains only enum metric names and numeric aggregates',
    () {
      final telemetry = FieldTelemetry();
      telemetry.recordDuration(
        FieldMetric.workHistoryRemoteFailure,
        const Duration(milliseconds: 17),
      );

      final diagnostics = telemetry.snapshot().toDiagnosticMap();

      expect(diagnostics.keys, [FieldMetric.workHistoryRemoteFailure.name]);
      expect(diagnostics.values.single, {
        'count': 1,
        'totalDurationMs': 17,
        'averageDurationMs': 17,
      });
    },
  );

  test('reset clears all aggregates', () {
    final telemetry = FieldTelemetry();
    telemetry.increment(FieldMetric.workHistoryCacheHit);

    telemetry.reset();

    expect(telemetry.snapshot().toDiagnosticMap(), isEmpty);
  });
}
