import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/database_test_harness.dart';

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

void main() {
  useInMemoryDatabase();

  testWidgets('the working date follows the clock after 05:00 the next day', (
    tester,
  ) async {
    await tester.runAsync(() => CaslaDatabase.instance.ready);
    final state = AppState();
    addTearDown(state.dispose);
    var notified = 0;
    state.addListener(() => notified++);

    final startedOn = _dateOnly(state.activeBusinessDate);
    final nextDay = startedOn.add(const Duration(days: 1));

    // 04:00 the next morning: a night crew may still be on yesterday's date.
    expect(
      state.rollBusinessDateIfNewDay(
        now: nextDay.add(const Duration(hours: 4)),
      ),
      isFalse,
    );
    expect(_dateOnly(state.activeBusinessDate), startedOn);
    expect(notified, 0);

    // 06:00: the app left open overnight now shows today.
    final resumedAt = nextDay.add(const Duration(hours: 6));
    expect(state.rollBusinessDateIfNewDay(now: resumedAt), isTrue);
    expect(state.activeBusinessDate, nextDay);
    expect(state.activeShift, isNull);
    expect(notified, 1);

    // Nothing left to do the second time round.
    expect(state.rollBusinessDateIfNewDay(now: resumedAt), isFalse);
    expect(notified, 1);
  });

  testWidgets('a write in progress is never interrupted by the date change', (
    tester,
  ) async {
    await tester.runAsync(() => CaslaDatabase.instance.ready);
    final state = AppState();
    addTearDown(state.dispose);

    final startedOn = _dateOnly(state.activeBusinessDate);
    final nextMorning = startedOn.add(const Duration(days: 1, hours: 6));

    await state.runCriticalOperation(() async {
      expect(state.rollBusinessDateIfNewDay(now: nextMorning), isFalse);
      expect(_dateOnly(state.activeBusinessDate), startedOn);
    });

    expect(state.rollBusinessDateIfNewDay(now: nextMorning), isTrue);
  });
}
