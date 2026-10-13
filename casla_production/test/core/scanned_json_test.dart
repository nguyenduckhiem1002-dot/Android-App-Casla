import 'package:casla_production/core/scanner/scan_intent.dart';
import 'package:casla_production/core/utils/operation_qr_parser.dart';
import 'package:casla_production/core/utils/scanned_json.dart';
import 'package:casla_production/core/utils/worker_qr_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _label =
    '{"lenh_san_xuat":"010010000022","cong_doan":"0010",'
    '"ten_cong_doan":"Kéo sợi Quai","work_center":"67110006",'
    '"sl_cong_doan":"10","unit":"KG"}';

void main() {
  OperationQrResult parse(String raw) => OperationQrParser.parse(raw);

  test('a symbology prefix or trailing suffix around the JSON is ignored', () {
    for (final raw in [
      ']Q1$_label',
      '$_label\u001d',
      '﻿$_label\r\n',
      'QR: $_label END',
    ]) {
      final result = parse(raw);
      expect(result.isValid, isTrue, reason: raw);
      expect(result.productionOrder, '010010000022');
      expect(result.operation, '0010');
      expect(result.operationQuantity, 10);
    }
  });

  test('two labels glued by a double trigger yield the first one', () {
    final second = _label.replaceAll('0010', '0020');
    final result = parse('$_label$second');
    expect(result.isValid, isTrue);
    expect(result.operation, '0010');
  });

  test('UTF-8 read as Latin-1 or Windows-1252 is repaired', () {
    const garbledLatin1 = 'KÃ©o sá»£i Quai';
    expect(ScannedJson.normalizeText(garbledLatin1), 'Kéo sợi Quai');
    final result = parse(_label.replaceAll('Kéo sợi Quai', garbledLatin1));
    expect(result.operationName, 'Kéo sợi Quai');
    // Correct Vietnamese is never touched.
    expect(ScannedJson.normalizeText('Kéo sợi Quai'), 'Kéo sợi Quai');
    expect(ScannedJson.normalizeText('Café'), 'Café');
  });

  test('generator quirks are repaired without inventing values', () {
    // Raw line break in a value, trailing comma, zero-padded bare numbers.
    const raw =
        '{"lenh_san_xuat":010010000022,"cong_doan":0010,'
        '"ten_cong_doan":"Kéo sợi\nQuai","sl_cong_doan":10,}';
    final result = parse(raw);
    expect(result.isValid, isTrue);
    expect(result.productionOrder, '010010000022');
    expect(result.operation, '0010');
    expect(result.operationName, 'Kéo sợi\nQuai');
    expect(result.operationQuantity, 10);
  });

  test('keys printed as JSON numbers get their SAP width back', () {
    final result = parse('{"lenh_san_xuat":10010000022,"cong_doan":10}');
    expect(result.productionOrder, '010010000022');
    expect(result.operation, '0010');
  });

  test('smart quotes and one nested wrapper are accepted', () {
    final smart = parse('{“lenh_san_xuat”:“010010000022”,“cong_doan”:“0010”}');
    expect(smart.isValid, isTrue);
    final nested = parse('{"data":$_label}');
    expect(nested.isValid, isTrue);
    expect(nested.workCenter, '67110006');
  });

  test('a truncated label asks for a rescan and is never salvaged', () {
    final truncated = _label.substring(0, 60);
    final result = parse(truncated);
    expect(result.isValid, isFalse);
    expect(result.error, contains('Hãy quét lại'));
    final classified = ScanClassifier.classify(truncated);
    expect(classified.kind, ScannedCodeKind.unknown);
    expect(classified.error, contains('Hãy quét lại'));
    // A fragment must not pass as an employee code either.
    expect(WorkerQrParser.parse(truncated).isValid, isFalse);
  });

  test('worker JSON cards get the same tolerance', () {
    final worker = WorkerQrParser.parse(']Q1{"ma_nv":"NV0001","ten":"A",}');
    expect(worker.isValid, isTrue);
    expect(worker.maNv, 'NV0001');
  });
}
