// Domain Policies — Shift Resolver
// Spec: Section 3.3 (Business Date & Night Shift)
// Timezone: Asia/Ho_Chi_Minh

import '../entities/entities.dart';

class ShiftResolver {
  ShiftResolver._();

  /// Determine businessDate and shift based on current time.
  /// Night shift (22:00 to 06:00):
  /// Timestamp 02:00 on Aug 6 → businessDate = Aug 5 (date shift started).
  /// Spec 3.3: Ca qua 0 giờ thuộc ngày bắt đầu ca.
  static ShiftInfo getCurrentShiftInfo({DateTime? now}) {
    // Use UTC+7 (Asia/Ho_Chi_Minh = UTC+7)
    final dateTime = now ?? DateTime.now().toUtc().add(const Duration(hours: 7));
    final hour = dateTime.hour;

    if (hour >= 6 && hour < 14) {
      return ShiftInfo(
        shiftId: 'SHIFT_1',
        shiftName: 'Ca sáng (06:00–14:00)',
        businessDate: _formatDate(dateTime),
      );
    } else if (hour >= 14 && hour < 22) {
      return ShiftInfo(
        shiftId: 'SHIFT_2',
        shiftName: 'Ca chiều (14:00–22:00)',
        businessDate: _formatDate(dateTime),
      );
    } else {
      // Ca đêm (22:00–06:00)
      // 00:00–05:59 thuộc ngày hôm trước
      final adjustedDate = hour < 6
          ? dateTime.subtract(const Duration(days: 1))
          : dateTime;
      return ShiftInfo(
        shiftId: 'SHIFT_NIGHT',
        shiftName: 'Ca đêm (22:00–06:00)',
        businessDate: _formatDate(adjustedDate),
      );
    }
  }

  static String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  /// Format date from yyyy-MM-dd to dd/MM/yyyy for display
  static String formatDateDisplay(String dateStr) {
    try {
      final parts = dateStr.split('-');
      if (parts.length == 3) {
        return '${parts[2]}/${parts[1]}/${parts[0]}';
      }
      return dateStr;
    } catch (_) {
      return dateStr;
    }
  }

  /// Get today's business date string
  static String getTodayBusinessDate() {
    return getCurrentShiftInfo().businessDate;
  }
}
