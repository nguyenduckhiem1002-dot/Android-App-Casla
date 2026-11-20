import 'package:casla_production/domain/policies/business_day_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Working date 9 Nov, picked that morning; the PDA is then left on.
  final businessDate = DateTime(2026, 11, 9);
  final pickedYesterday = DateTime(2026, 11, 9, 7, 15);

  bool roll(DateTime now, {DateTime? selectedAt, DateTime? shiftEndsAt}) =>
      shouldRollBusinessDate(
        businessDate: businessDate,
        selectedAt: selectedAt ?? pickedYesterday,
        now: now,
        shiftEndsAt: shiftEndsAt,
      );

  group('shouldRollBusinessDate', () {
    test('a date left from yesterday moves on from 05:00', () {
      expect(roll(DateTime(2026, 11, 10, 5)), isTrue);
      expect(roll(DateTime(2026, 11, 10, 7, 30)), isTrue);
    });

    test('before 05:00 the previous working date stays', () {
      expect(roll(DateTime(2026, 11, 10, 0, 30)), isFalse);
      expect(roll(DateTime(2026, 11, 10, 4, 59, 59)), isFalse);
    });

    test('the same day never rolls', () {
      expect(roll(DateTime(2026, 11, 9, 5)), isFalse);
      expect(roll(DateTime(2026, 11, 9, 23, 59)), isFalse);
    });

    test('a date several days old moves on too', () {
      expect(roll(DateTime(2026, 11, 13, 6)), isTrue);
    });

    test('a past date opened on purpose today is left alone', () {
      expect(
        roll(
          DateTime(2026, 11, 10, 9),
          selectedAt: DateTime(2026, 11, 10, 8, 45),
        ),
        isFalse,
      );
      // Picked exactly at the start hour counts as today's choice.
      expect(
        roll(DateTime(2026, 11, 10, 9), selectedAt: DateTime(2026, 11, 10, 5)),
        isFalse,
      );
    });

    test('a date picked in the small hours still moves on at 05:00', () {
      final pickedAtNight = DateTime(2026, 11, 10, 1, 20);
      expect(
        roll(DateTime(2026, 11, 10, 4), selectedAt: pickedAtNight),
        isFalse,
      );
      expect(
        roll(DateTime(2026, 11, 10, 5, 5), selectedAt: pickedAtNight),
        isTrue,
      );
    });

    test('a night shift still running keeps its work date', () {
      final shiftEndsAt = DateTime(2026, 11, 10, 6);
      expect(
        roll(DateTime(2026, 11, 10, 5, 30), shiftEndsAt: shiftEndsAt),
        isFalse,
      );
      expect(roll(DateTime(2026, 11, 10, 6), shiftEndsAt: shiftEndsAt), isTrue);
      expect(
        roll(DateTime(2026, 11, 10, 6, 10), shiftEndsAt: shiftEndsAt),
        isTrue,
      );
    });

    test('a working date that is today or later is never touched', () {
      expect(
        shouldRollBusinessDate(
          businessDate: DateTime(2026, 11, 10),
          selectedAt: pickedYesterday,
          now: DateTime(2026, 11, 10, 8),
        ),
        isFalse,
      );
      expect(
        shouldRollBusinessDate(
          businessDate: DateTime(2026, 11, 11),
          selectedAt: pickedYesterday,
          now: DateTime(2026, 11, 10, 8),
        ),
        isFalse,
      );
    });

    test('the time of day on the working date does not matter', () {
      expect(
        shouldRollBusinessDate(
          businessDate: DateTime(2026, 11, 9, 23, 30),
          selectedAt: pickedYesterday,
          now: DateTime(2026, 11, 10, 5),
        ),
        isTrue,
      );
    });
  });
}
