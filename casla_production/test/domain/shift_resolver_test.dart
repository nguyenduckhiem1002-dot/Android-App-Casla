import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/domain/policies/shift_resolver.dart';

void main() {
  group('ShiftResolver', () {
    test('resolves morning and afternoon shifts', () {
      expect(
        ShiftResolver.getCurrentShiftInfo(
          now: DateTime(2026, 8, 14, 8),
        ).shiftId,
        'SHIFT_1',
      );
      expect(
        ShiftResolver.getCurrentShiftInfo(
          now: DateTime(2026, 8, 14, 16),
        ).shiftId,
        'SHIFT_2',
      );
    });

    test('attributes after-midnight night shift to previous business date', () {
      final shift = ShiftResolver.getCurrentShiftInfo(
        now: DateTime(2026, 8, 14, 2),
      );
      expect(shift.shiftId, 'SHIFT_NIGHT');
      expect(shift.businessDate, '2026-08-13');
    });
  });
}
