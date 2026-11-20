// Domain policy — when the working date moves on to a new day.
//
// A PDA is often left on overnight with the app open. The working date picked
// yesterday must not greet the next shift: once a new day has started, the
// date follows the clock again.

/// Hour of the day (device time) from which a new working day starts. Before
/// it, the previous day's selection stays so a night crew is not interrupted.
const int businessDayStartHour = 5;

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// Whether a working date left over from an earlier day should become today.
///
/// True only when all of these hold at [now]:
/// - it is [businessDayStartHour] or later,
/// - [businessDate] is before today,
/// - the date was put in place ([selectedAt]) before today's start hour — a
///   past date opened on purpose today is left alone,
/// - the selected shift, if any, is over ([shiftEndsAt] is not in the future),
///   so a night shift running past the start hour keeps its work date.
bool shouldRollBusinessDate({
  required DateTime businessDate,
  required DateTime selectedAt,
  required DateTime now,
  DateTime? shiftEndsAt,
}) {
  final today = _dateOnly(now);
  final dayStart = DateTime(now.year, now.month, now.day, businessDayStartHour);
  if (now.isBefore(dayStart)) return false;
  if (!_dateOnly(businessDate).isBefore(today)) return false;
  if (!selectedAt.isBefore(dayStart)) return false;
  if (shiftEndsAt != null && now.isBefore(shiftEndsAt)) return false;
  return true;
}
