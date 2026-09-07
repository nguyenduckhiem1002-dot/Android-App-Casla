import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/utils/worker_qr_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();

  test(
    'unknown QR worker is accepted locally without assigning permissions',
    () async {
      final qr = WorkerQrParser.parse(
        '{"WorkerID":"QR_NEW_01","WorkerName":"Test QR","ValidFrom":"2026-09-01","ValidTo":"2026-09-07"}',
      );
      expect(qr.isValid, isTrue);
      expect(qr.name, 'Test QR');
      expect(qr.isEffectiveOn(DateTime(2026, 8, 31)), isFalse);
      expect(qr.isEffectiveOn(DateTime(2026, 9, 1)), isTrue);
      expect(qr.isEffectiveOn(DateTime(2026, 9, 7)), isTrue);
      expect(qr.isEffectiveOn(DateTime(2026, 9, 8)), isFalse);
      final db = CaslaDatabase.instance;
      final worker = await db.acceptWorkerQr(
        code: qr.maNv,
        name: qr.name,
        validFrom: qr.validFrom,
        validTo: qr.validTo,
      );
      expect(worker['ma_nv'], qr.maNv);
      expect(worker['ten'], 'Test QR');
      expect(worker['to_ids'], isEmpty);
      expect(worker['quyen_han'], isEmpty);
      final again = await db.acceptWorkerQr(code: qr.maNv, name: 'Updated QR');
      expect(again['id'], worker['id']);
      expect(again['ten'], 'Updated QR');
      expect(again['valid_to'], isNull);
    },
  );
}
