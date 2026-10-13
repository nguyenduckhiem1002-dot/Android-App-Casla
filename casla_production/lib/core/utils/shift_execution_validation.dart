import '../../data/sap/sap_shift_controller.dart';

/// Mirrors SAP's [start, end) shift window, including overnight work dates,
/// and additionally allows late entry for the chosen work date until the end
/// of the calendar day the shift ends on ([shiftEntryDeadline]).
///
/// Supervisors often stay on after the shift to catch up on entries. NOTE:
/// `zcl_pp_shift_resolver` on SAP still enforces the strict [start, end)
/// window, so a late entry is rejected there (SHIFT_NOT_APPLICABLE /
/// OUTSIDE_SHIFT) until the same grace is added on the SAP side.
///
/// Unknown SAP timezone keys remain subject to server validation; never infer
/// a plant timezone from the phone's timezone.
String? validateShiftExecution({
  required SapShift shift,
  required DateTime businessDate,
  required DateTime executedAt,
}) {
  final zone = shift.timeZone.trim().toUpperCase();
  final offset = _zoneOffsetMinutes(zone);
  if (offset == null) return null;
  final start = _seconds(shift.startTime);
  final end = _seconds(shift.endTime);
  if (start == null ||
      end == null ||
      shift.endDayOffset < 0 ||
      shift.endDayOffset > 1 ||
      (shift.endDayOffset == 0 && end <= start) ||
      (shift.endDayOffset == 1 && end > start)) {
    return 'Cấu hình giờ ca không hợp lệ. Hãy tải lại danh sách ca hoặc liên hệ quản trị.';
  }
  final local = executedAt.toUtc().add(Duration(minutes: offset));
  // Inside the chosen work date's shift, or after it on the day it ends.
  final chosenDate = DateTime.utc(
    businessDate.year,
    businessDate.month,
    businessDate.day,
  );
  final chosenStart = chosenDate.add(Duration(seconds: start));
  final chosenDeadline = chosenDate.add(Duration(days: shift.endDayOffset + 1));
  if (!local.isBefore(chosenStart) && local.isBefore(chosenDeadline)) {
    if (!shift.isValidOn(chosenDate)) {
      return 'Ca ${shift.shiftName} không có hiệu lực ngày ${_date(chosenDate)}. '
          'Hãy tải lại danh sách ca.';
    }
    return null;
  }
  final time = local.hour * 3600 + local.minute * 60 + local.second;
  var workDate = DateTime.utc(local.year, local.month, local.day);
  if (shift.endDayOffset == 1 && time < end) {
    workDate = workDate.subtract(const Duration(days: 1));
  }
  final startAt = workDate.add(Duration(seconds: start));
  final endAt = workDate.add(Duration(days: shift.endDayOffset, seconds: end));
  if (local.isBefore(startAt) || !local.isBefore(endAt)) {
    return 'Thời điểm hiện tại ${_date(local)} ${_two(local.hour)}:${_two(local.minute)} '
        '($zone) nằm ngoài ${shift.shiftName} (${shift.timeLabel}) '
        'và đã quá hạn nhập bù (đến hết ngày kết thúc ca). '
        'Hãy chọn ca đang làm việc trước khi gửi.';
  }
  if (!shift.isValidOn(workDate)) {
    return 'Ca ${shift.shiftName} không có hiệu lực ngày ${_date(workDate)}. '
        'Hãy tải lại danh sách ca.';
  }
  if (_date(businessDate) != _date(workDate)) {
    return 'Ngày đang chọn ${_date(businessDate)} không khớp ngày làm việc '
        '${_date(workDate)} của ${shift.shiftName} tại thời điểm hiện tại ($zone). '
        'Hãy đổi ngày/ca trước khi tạo giao dịch.';
  }
  return null;
}

/// The instant [shift] ends when worked on [businessDate]: `EndTime` in the
/// shift's SAP timezone, `EndDayOffset` days after the work date.
///
/// Returns null when the timezone or the time fields cannot be interpreted;
/// callers must then fall back to a rule that does not depend on them.
DateTime? shiftEndInstant({
  required SapShift shift,
  required DateTime businessDate,
}) {
  final offset = _zoneOffsetMinutes(shift.timeZone.trim().toUpperCase());
  final start = _seconds(shift.startTime);
  final end = _seconds(shift.endTime);
  if (offset == null ||
      start == null ||
      end == null ||
      shift.endDayOffset < 0 ||
      shift.endDayOffset > 1 ||
      (shift.endDayOffset == 0 && end <= start) ||
      (shift.endDayOffset == 1 && end > start)) {
    return null;
  }
  return DateTime.utc(
    businessDate.year,
    businessDate.month,
    businessDate.day,
  ).add(Duration(days: shift.endDayOffset, seconds: end, minutes: -offset));
}

/// End of late entry for [shift] on [businessDate]: midnight after the day the
/// shift ends, in the shift's SAP timezone. Null when the shift's timezone or
/// times cannot be interpreted.
DateTime? shiftEntryDeadline({
  required SapShift shift,
  required DateTime businessDate,
}) {
  final end = shiftEndInstant(shift: shift, businessDate: businessDate);
  final offset = _zoneOffsetMinutes(shift.timeZone.trim().toUpperCase());
  if (end == null || offset == null) return null;
  final endLocal = end.add(Duration(minutes: offset));
  return DateTime.utc(
    endLocal.year,
    endLocal.month,
    endLocal.day + 1,
  ).subtract(Duration(minutes: offset));
}

/// When a supervisor's shift/work-date selection stops being active.
///
/// It lasts as long as entries for that shift are accepted: until the end of
/// the day the SAP shift ends on ([shiftEntryDeadline]). Two cases keep the
/// old daily boundary — 08:00 the next morning, device time — instead:
/// - SAP sent a timezone/time this app cannot interpret, and
/// - the chosen shift has already ended (a past date opened for review);
///   expiring it at once would loop straight back to the setup screen.
/// Writes are still checked against the real shift window when submitted.
DateTime supervisorSetupExpiry({
  required SapShift shift,
  required DateTime businessDate,
  required DateTime now,
}) {
  final deadline = shiftEntryDeadline(
    shift: shift,
    businessDate: businessDate,
  )?.toLocal();
  if (deadline != null && deadline.isAfter(now)) return deadline;
  final todayAtEight = DateTime(now.year, now.month, now.day, 8);
  return now.isBefore(todayAtEight)
      ? todayAtEight
      : todayAtEight.add(const Duration(days: 1));
}

int? _zoneOffsetMinutes(String zone) => switch (zone) {
  'UTC' || 'GMT' => 0,
  'ICT' || 'ASIA/BANGKOK' || 'ASIA/HO_CHI_MINH' || 'ASIA/SAIGON' => 420,
  _ => _fixedOffset(zone),
};

String _two(int value) => value.toString().padLeft(2, '0');
String _date(DateTime value) =>
    '${_two(value.day)}/${_two(value.month)}/${value.year}';

int? _fixedOffset(String value) {
  final match = RegExp(
    r'^(?:UTC|GMT)([+-])(\d{1,2})(?::?(\d{2}))?$',
  ).firstMatch(value);
  if (match == null) return null;
  final hours = int.parse(match[2]!);
  final minutes = int.parse(match[3] ?? '0');
  if (hours > 14 || minutes > 59) return null;
  return (hours * 60 + minutes) * (match[1] == '-' ? -1 : 1);
}

int? _seconds(String value) {
  final raw = value.trim();
  final duration = RegExp(
    r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$',
  ).firstMatch(raw);
  if (duration != null && raw != 'PT') {
    final h = int.parse(duration[1] ?? '0');
    final m = int.parse(duration[2] ?? '0');
    final s = int.parse(duration[3] ?? '0');
    return h < 24 && m < 60 && s < 60 ? h * 3600 + m * 60 + s : null;
  }
  final match = RegExp(r'^(\d{2}):?(\d{2})(?::?(\d{2}))?$').firstMatch(raw);
  if (match == null) return null;
  final h = int.parse(match[1]!);
  final m = int.parse(match[2]!);
  final s = int.parse(match[3] ?? '0');
  return h < 24 && m < 60 && s < 60 ? h * 3600 + m * 60 + s : null;
}
