import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/scanner/scan_intent.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

const String _workerQr = '{"WorkerID":"QR_FORM","WorkerName":"Worker Form"}';
const String _kgOperationQr =
    '{"ProductionOrder":"000001000020","Operation":"0010",'
    '"ProductName":"KG Product","UnitOfMeasure":"KG"}';

void main() {
  useInMemoryDatabase();

  group('classification', () {
    test('an operation payload is recognised as an operation', () {
      final scanned = ScanClassifier.classify(_kgOperationQr);

      expect(scanned.kind, ScannedCodeKind.operation);
      expect(scanned.operation?.productionOrder, '000001000020');
      expect(scanned.operation?.operation, '0010');
      expect(scanned.operation?.unitOfMeasure, 'KG');
    });

    test('a worker payload is recognised as a worker', () {
      final scanned = ScanClassifier.classify(_workerQr);

      expect(scanned.kind, ScannedCodeKind.worker);
      expect(scanned.worker?.maNv, 'QR_FORM');
      expect(scanned.worker?.name, 'Worker Form');
    });

    test('an operation is never mistaken for a worker', () {
      // The worker parser ends in a permissive bare-token fallback, so asking
      // it first would let it swallow operation payloads. Order matters.
      final delimited = ScanClassifier.classify('000001000020|0010');

      expect(delimited.kind, ScannedCodeKind.operation);
    });

    test('a bare employee code still resolves to a worker', () {
      expect(ScanClassifier.classify('NC000002').kind, ScannedCodeKind.worker);
      expect(ScanClassifier.classify('bachdv').kind, ScannedCodeKind.worker);
      expect(ScanClassifier.classify('2').kind, ScannedCodeKind.worker);
    });

    test('junk is reported rather than guessed at', () {
      final scanned = ScanClassifier.classify('https://example.invalid/x');

      expect(scanned.kind, ScannedCodeKind.unknown);
      expect(scanned.error, isNotEmpty);
    });

    test('an empty payload is unknown', () {
      expect(ScanClassifier.classify('   ').kind, ScannedCodeKind.unknown);
    });
  });

  group('retail barcode shape', () {
    test('flags the digit runs a laser picks up off a carton', () {
      expect(ScanClassifier.looksLikeRetailBarcode('8934673001234'), isTrue);
      expect(ScanClassifier.looksLikeRetailBarcode('012345678905'), isTrue);
      expect(ScanClassifier.looksLikeRetailBarcode('96385074'), isTrue);
    });

    test('leaves real employee codes alone', () {
      expect(ScanClassifier.looksLikeRetailBarcode('NC000002'), isFalse);
      expect(ScanClassifier.looksLikeRetailBarcode('bachdv'), isFalse);
      expect(ScanClassifier.looksLikeRetailBarcode('2'), isFalse);
      expect(ScanClassifier.looksLikeRetailBarcode('12345'), isFalse);
    });
  });

  test('an operation scan is persisted and returns the stored row', () async {
    final scanned = ScanClassifier.classify(_kgOperationQr);
    final order = await CaslaDatabase.instance.upsertOrderFromOperationQr(
      scanned.operation!,
    );

    expect(order, isNotNull);
    expect(order!['ten_sp'], 'KG Product');
    expect(order['uom'], 'KG');
    expect(order['production_order'], '000001000020');
  });
}
