import 'package:casla_production/core/scanner/scan_diagnostics.dart';
import 'package:casla_production/core/scanner/scan_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diagnostic buffer is bounded and can start a fresh scan session', () {
    final log = ScanDiagnostics();
    for (var i = 0; i < 200; i++) {
      log.record(ScanDiagnosticEvent.eventReceived, length: i);
    }
    final lines = log.export().split('\n');
    expect(lines, hasLength(ScanDiagnostics.capacity));
    expect(lines.first, contains('length=80'));
    expect(lines.last, contains('length=199'));
    log.clear();
    expect(log.export(), isNot(contains('eventReceived')));
  });

  test('classifier trace does not retain QR data or parser error text', () {
    ScanDiagnostics.instance.clear();
    const secret = '{"password":"SENSITIVE_SCANNER_TEST_PAYLOAD"}';
    ScanClassifier.classify(secret);
    final trace = ScanDiagnostics.instance.export();
    expect(trace, contains('classified'));
    expect(trace, contains('length=${secret.length}'));
    expect(trace, isNot(contains('SENSITIVE_SCANNER_TEST_PAYLOAD')));
    expect(trace, isNot(contains('password')));
    ScanDiagnostics.instance.clear();
  });
}
