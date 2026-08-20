import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/core/utils/worker_qr_parser.dart';

void main() {
  group('WorkerQrParser', () {
    test('parses JSON and delimited payloads', () {
      final json = WorkerQrParser.parse(
        '{"ma_nv":"NV42","ten":"Nguyễn Văn B"}',
      );
      final delimited = WorkerQrParser.parse('NV43 | Trần Thị C');

      expect(json.isValid, isTrue);
      expect(json.maNv, 'NV42');
      expect(delimited.isValid, isTrue);
      expect(delimited.maNv, 'NV43');
    });

    test('rejects unrelated QR payloads', () {
      expect(WorkerQrParser.parse('https://example.com').isValid, isFalse);
      expect(WorkerQrParser.parse('NV-FAKE').isValid, isFalse);
      expect(WorkerQrParser.parse('').isValid, isFalse);
    });
  });
}
