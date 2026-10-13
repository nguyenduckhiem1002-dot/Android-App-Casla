import 'package:casla_production/core/utils/sap_entry_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an instant is written as Vietnam wall-clock date and time', () {
    // 19:00 UTC on the 7th is 02:00 on the 8th in Vietnam.
    final entry = SapEntryTime.fromInstant(DateTime.utc(2026, 9, 7, 19));

    expect(entry.date, '2026-09-08');
    expect(entry.time, '02:00:00');
  });

  test('the device time zone does not change the result', () {
    final utc = DateTime.utc(2026, 12, 31, 17, 5, 9, 750);
    final sameInstantLocal = utc.toLocal();

    for (final instant in [utc, sameInstantLocal]) {
      final entry = SapEntryTime.fromInstant(instant);
      expect(entry.date, '2027-01-01');
      // Seconds are kept, fractions dropped: SAP's EntryTime has none.
      expect(entry.time, '00:05:09');
    }
    expect(
      SapEntryTime.fromEpochMillis(utc.millisecondsSinceEpoch).time,
      '00:05:09',
    );
  });
}
