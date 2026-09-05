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

    test('accepts the real mixed worker codes and reads validity dates', () {
      final result = WorkerQrParser.parse(
        '{"MaNV":"NC000002","ValidFrom":"2020-01-01","ValidTo":"2099-12-31"}',
      );

      expect(result.isValid, isTrue);
      expect(result.maNv, 'NC000002');
      expect(result.isEffectiveOn(DateTime(2026, 9, 5)), isTrue);
      expect(WorkerQrParser.parse('A1').isValid, isTrue);
      expect(WorkerQrParser.parse('bachdv').isValid, isTrue);
      expect(WorkerQrParser.parse('2').isValid, isTrue);
    });

    test('marks a worker QR outside its validity window', () {
      final beforeStart = WorkerQrParser.parse(
        '{"ma_nv":"A1","ValidFrom":"2099-01-01"}',
      );
      final afterEnd = WorkerQrParser.parse(
        '{"ma_nv":"A1","ValidTo":"2020-01-01"}',
      );

      expect(beforeStart.isEffectiveOn(DateTime(2026, 9, 5)), isFalse);
      expect(afterEnd.isEffectiveOn(DateTime(2026, 9, 5)), isFalse);
    });

    test('rejects unrelated QR payloads', () {
      expect(WorkerQrParser.parse('https://example.com').isValid, isFalse);
      expect(WorkerQrParser.parse('NV-FAKE').isValid, isFalse);
      expect(WorkerQrParser.parse('').isValid, isFalse);
    });

    test('rejects oversized and NUL-containing untrusted payloads', () {
      final oversized = List.filled(
        WorkerQrParser.maxInputCharacters + 1,
        '1',
      ).join();

      expect(WorkerQrParser.parse(oversized).isValid, isFalse);
      expect(WorkerQrParser.parse('NV12\u00003').isValid, isFalse);
    });
  });
}
