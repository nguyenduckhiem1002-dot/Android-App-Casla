import 'package:casla_production/core/scanner/scanner_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();

  group('ScannerMode storage', () {
    test('every mode survives a round trip', () {
      for (final mode in ScannerMode.values) {
        expect(ScannerMode.fromStorage(mode.storageValue), mode);
      }
    });

    test('an unknown or missing value falls back to automatic', () {
      // A handset that has never been configured, or one whose settings row
      // was written by an older build, must still scan.
      expect(ScannerMode.fromStorage(null), ScannerMode.auto);
      expect(ScannerMode.fromStorage(''), ScannerMode.auto);
      expect(ScannerMode.fromStorage('rs38-only'), ScannerMode.auto);
    });

    test('every mode is described to the technician who has to pick one', () {
      for (final mode in ScannerMode.values) {
        expect(mode.label, isNotEmpty);
        expect(mode.description, isNotEmpty);
      }
    });
  });

  group('DatabaseScannerPreferences', () {
    test('defaults to automatic with no reader seen', () async {
      final preferences = DatabaseScannerPreferences();

      expect(await preferences.readMode(), ScannerMode.auto);
      expect(await preferences.wasHardwareScanSeen(), isFalse);
    });

    test('a chosen mode persists', () async {
      final preferences = DatabaseScannerPreferences();
      await preferences.writeMode(ScannerMode.hardware);

      // A separate instance, because the technician's override has to outlive
      // the screen that set it.
      expect(
        await DatabaseScannerPreferences().readMode(),
        ScannerMode.hardware,
      );
    });

    test('a first scan is remembered', () async {
      final preferences = DatabaseScannerPreferences();
      await preferences.rememberHardwareScanSeen();

      // This is what stops a wedge-only handset — undetectable until it fires
      // — from dropping back to the camera on every later visit.
      expect(
        await DatabaseScannerPreferences().wasHardwareScanSeen(),
        isTrue,
      );
    });
  });

  group('InMemoryScannerPreferences', () {
    test('mirrors the persistent implementation', () async {
      final preferences = InMemoryScannerPreferences();

      expect(await preferences.readMode(), ScannerMode.auto);
      await preferences.writeMode(ScannerMode.camera);
      expect(await preferences.readMode(), ScannerMode.camera);

      expect(await preferences.wasHardwareScanSeen(), isFalse);
      await preferences.rememberHardwareScanSeen();
      expect(await preferences.wasHardwareScanSeen(), isTrue);
    });
  });
}
