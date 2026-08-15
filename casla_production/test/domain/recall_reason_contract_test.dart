// Contract test — recall reason codes must match between UI and domain.
//
// The S09 screen used to carry its own Vietnamese code map ('KHONG_LAM_HET',
// 'KHAC') while ProductionMath.validateRecallEntry checks for RecallReason's
// English codes. That mismatch is a silent failure mode: the mandatory-note rule
// for "Khác" simply stops firing, with no crash and no error message.
//
// These tests pin the contract so the two sides cannot drift apart again.

import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/domain/policies/production_math.dart';

void main() {
  group('RecallReason ↔ ProductionMath contract', () {
    test('every reason code is accepted by validateRecallEntry', () {
      for (final reason in RecallReason.values) {
        // A non-"other" reason needs no note; "other" is covered separately.
        final note = reason == RecallReason.other ? 'lý do cụ thể' : null;

        final error = ProductionMath.validateRecallEntry(
          10.0,
          100.0,
          reason.code,
          note,
        );

        expect(
          error,
          isNull,
          reason: 'Reason ${reason.name} (code "${reason.code}") was rejected',
        );
      }
    });

    test('the "other" reason requires a note', () {
      final error = ProductionMath.validateRecallEntry(
        10.0,
        100.0,
        RecallReason.other.code,
        null,
      );

      expect(error, isNotNull);
      expect(error, contains('ghi chú'));
    });

    test('a blank note does not satisfy the "other" reason', () {
      final error = ProductionMath.validateRecallEntry(
        10.0,
        100.0,
        RecallReason.other.code,
        '   ',
      );

      expect(error, isNotNull);
    });

    test('reasons other than "other" do not require a note', () {
      for (final reason in RecallReason.values) {
        if (reason == RecallReason.other) continue;

        expect(
          ProductionMath.validateRecallEntry(10.0, 100.0, reason.code, null),
          isNull,
          reason: '${reason.name} should not require a note',
        );
      }
    });

    test('the legacy Vietnamese codes are gone', () {
      // If someone reintroduces 'KHAC', the mandatory-note rule silently dies:
      // validateRecallEntry compares against 'OTHER' and never matches.
      const legacyCodes = {
        'KHONG_LAM_HET',
        'DIEU_CHUYEN',
        'DOI_KE_HOACH',
        'KET_THUC_DON',
        'KHAC',
      };

      final actualCodes = RecallReason.values.map((r) => r.code).toSet();

      expect(actualCodes.intersection(legacyCodes), isEmpty);

      // And specifically: the code that carries the note requirement must be
      // the one the domain layer checks for.
      expect(RecallReason.other.code, equals('OTHER'));
    });
  });
}
