import 'package:casla_production/core/utils/shift_execution_validation.dart';
import 'package:casla_production/core/sync/sync_failure.dart';
import 'package:casla_production/data/sap/odata_error.dart';
import 'package:casla_production/data/sap/sap_shift_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SapShift shift({bool night = false, String zone = 'UTC+7'}) =>
      SapShift.fromJson({
        'WorkCenter': '67110021',
        'ShiftID': 'DAY',
        'ShiftName': 'Ca ngày',
        'ValidFrom': '2026-01-01',
        'ValidTo': '2026-12-31',
        'IsActive': 'A',
        'StartTime': night ? '22:00:00' : '08:00:00',
        'EndTime': night ? '06:00:00' : '17:00:00',
        'EndDayOffset': night ? 1 : 0,
        'SAPTimeZone': zone,
      });
  String? validate(
    DateTime time, {
    int day = 19,
    bool night = false,
    String zone = 'UTC+7',
  }) => validateShiftExecution(
    shift: shift(night: night, zone: zone),
    businessDate: DateTime(2026, 9, day),
    executedAt: time,
  );
  test('matches SAP business date using plant timezone', () {
    expect(validate(DateTime.utc(2026, 9, 19, 4)), isNull);
    expect(validate(DateTime.utc(2026, 9, 22, 4)), contains('19/09/2026'));
    expect(validate(DateTime.utc(2026, 9, 22, 4)), contains('22/09/2026'));
  });
  test('start inclusive; late entry allowed until the shift day ends', () {
    expect(validate(DateTime.utc(2026, 9, 19, 1)), isNull); // 08:00
    expect(validate(DateTime.utc(2026, 9, 19, 0, 59)), contains('nằm ngoài'));
    expect(validate(DateTime.utc(2026, 9, 19, 10)), isNull); // 17:00, ended
    expect(validate(DateTime.utc(2026, 9, 19, 16, 59)), isNull); // 23:59
    expect(
      validate(DateTime.utc(2026, 9, 19, 17)),
      contains('quá hạn nhập bù'),
    );
  });
  test('overnight shift accepts late entry through the day it ends', () {
    // Ends 06:00 on 20/09; entry stays open until 24:00 on 20/09 (UTC+7).
    expect(validate(DateTime.utc(2026, 9, 20, 3), night: true), isNull);
    expect(validate(DateTime.utc(2026, 9, 20, 16, 59), night: true), isNull);
    expect(validate(DateTime.utc(2026, 9, 20, 17), night: true), isNotNull);
  });
  test('overnight early morning belongs to previous business day', () {
    expect(validate(DateTime.utc(2026, 9, 19, 19), night: true), isNull);
    expect(
      validate(DateTime.utc(2026, 9, 19, 19), night: true, day: 20),
      contains('19/09/2026'),
    );
  });
  test('unknown SAP zone is not guessed from device zone', () {
    expect(validate(DateTime.utc(2026, 9, 22, 4), zone: 'CUSTOM'), isNull);
  });
  test('shift end honours SAP timezone and overnight offset', () {
    expect(
      shiftEndInstant(shift: shift(), businessDate: DateTime(2026, 9, 19)),
      DateTime.utc(2026, 9, 19, 10), // 17:00 UTC+7
    );
    expect(
      shiftEndInstant(
        shift: shift(night: true),
        businessDate: DateTime(2026, 9, 19),
      ),
      DateTime.utc(2026, 9, 19, 23), // 06:00 on 20/09, UTC+7
    );
    expect(
      shiftEndInstant(
        shift: shift(zone: 'CUSTOM'),
        businessDate: DateTime(2026, 9, 19),
      ),
      isNull,
    );
  });
  test('setup lasts until late entry for the chosen shift closes', () {
    final now = DateTime.utc(2026, 9, 19, 3).toLocal();
    // Day shift ends 17:00 on 19/09 → open until 24:00 19/09 (UTC+7).
    expect(
      supervisorSetupExpiry(
        shift: shift(),
        businessDate: DateTime(2026, 9, 19),
        now: now,
      ),
      DateTime.utc(2026, 9, 19, 17).toLocal(),
    );
    // Night shift ends 06:00 on 20/09 → open until 24:00 20/09 (UTC+7).
    expect(
      supervisorSetupExpiry(
        shift: shift(night: true),
        businessDate: DateTime(2026, 9, 19),
        now: now,
      ),
      DateTime.utc(2026, 9, 20, 17).toLocal(),
    );
  });
  test('a finished or unreadable shift falls back to the next 08:00', () {
    final now = DateTime(2026, 9, 22, 12);
    final nextEight = DateTime(2026, 9, 23, 8);
    // Past date opened for review: its shift ended days ago.
    expect(
      supervisorSetupExpiry(
        shift: shift(),
        businessDate: DateTime(2026, 9, 19),
        now: now,
      ),
      nextEight,
    );
    expect(
      supervisorSetupExpiry(
        shift: shift(zone: 'CUSTOM'),
        businessDate: DateTime(2026, 9, 22),
        now: now,
      ),
      nextEight,
    );
  });
  test(
    'immutable execution errors require correction, not password retries',
    () {
      for (final code in [
        'SHIFT_WORK_DATE_MISMATCH',
        'SHIFT_NOT_APPLICABLE',
        'OUTSIDE_SHIFT',
      ]) {
        expect(
          classifySyncError(SapBusinessError(code)).kind,
          SyncFailureKind.permanent,
        );
      }
    },
  );
  test('a device clock running ahead of SAP is retried, not rejected', () {
    // ExecutedAt is fixed at entry; SAP's clock catches up.
    expect(
      classifySyncError(const SapBusinessError('EXECUTED_AT_IN_FUTURE')).kind,
      SyncFailureKind.transient,
    );
  });
}
