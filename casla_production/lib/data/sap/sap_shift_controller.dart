// SAP Integration — ZAPI_PP_SHIFT / ZUI_PP_SHIFT_API (OData V4)

import '../../core/config/app_config.dart';
import 'odata_error.dart';
import 'sap_odata_client.dart';

const String _shiftEntitySet = 'Shifts';

class SapShift {
  final String plant;
  final String shiftId;
  final DateTime validFrom;
  final String shiftName;
  final String startTime;
  final String endTime;
  final int endDayOffset;
  final String timeZone;
  final DateTime? validTo;
  final String isActive;

  const SapShift({
    required this.plant,
    required this.shiftId,
    required this.validFrom,
    required this.shiftName,
    required this.startTime,
    required this.endTime,
    required this.endDayOffset,
    required this.timeZone,
    required this.validTo,
    required this.isActive,
  });

  factory SapShift.fromJson(Map<String, dynamic> json) => SapShift(
    plant: '${json['Plant'] ?? ''}',
    shiftId: '${json['ShiftID'] ?? ''}',
    validFrom:
        DateTime.tryParse('${json['ValidFrom'] ?? ''}') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    shiftName: '${json['ShiftName'] ?? ''}',
    startTime: '${json['StartTime'] ?? ''}',
    endTime: '${json['EndTime'] ?? ''}',
    endDayOffset: int.tryParse('${json['EndDayOffset'] ?? 0}') ?? 0,
    timeZone: '${json['SAPTimeZone'] ?? ''}',
    validTo: DateTime.tryParse('${json['ValidTo'] ?? ''}'),
    isActive: '${json['IsActive'] ?? ''}',
  );

  bool isValidOn(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    final from = DateTime(validFrom.year, validFrom.month, validFrom.day);
    final to = validTo == null
        ? null
        : DateTime(validTo!.year, validTo!.month, validTo!.day);
    return isActive == 'A' &&
        !day.isBefore(from) &&
        (to == null || !day.isAfter(to));
  }

  String get timeLabel =>
      '${_hhmm(startTime)} – ${_hhmm(endTime)}'
      '${endDayOffset > 0 ? ' (+$endDayOffset ngày)' : ''}';

  static String _hhmm(String value) {
    final raw = value.trim();
    // OData V4 Edm.TimeOfDay is commonly serialized as PT22H00M00S.
    final duration = RegExp(r'^PT(\d{1,2})H(\d{2})M').firstMatch(raw);
    if (duration != null) {
      return '${duration.group(1)!.padLeft(2, '0')}:${duration.group(2)}';
    }
    final colon = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(raw);
    if (colon != null) {
      return '${colon.group(1)!.padLeft(2, '0')}:${colon.group(2)}';
    }
    final compact = RegExp(r'^(\d{2})(\d{2})').firstMatch(raw);
    return compact == null ? raw : '${compact.group(1)}:${compact.group(2)}';
  }
}

class SapShiftController {
  final SapODataClient client;
  SapShiftController(this.client);

  Future<List<SapShift>> getShifts({
    required String plant,
    DateTime? onDate,
  }) async {
    if (AppConfig.sapShiftApiServiceUrl.isEmpty) {
      throw const SapConfigurationException(
        'Chưa cấu hình SAP_BASE_URL để tải danh mục ca làm việc.',
      );
    }
    final response = await client.dio.get(
      _shiftEntitySet,
      queryParameters: {
        r'$filter': "Plant eq '${_escape(plant)}' and IsActive eq 'A'",
        r'$orderby': 'ValidFrom desc,StartTime asc',
      },
    );
    final rows = odataActionResult(response)['value'];
    if (rows is! List) return const [];
    final date = onDate ?? DateTime.now();
    return rows
        .whereType<Map>()
        .map((row) => SapShift.fromJson(Map<String, dynamic>.from(row)))
        .where((shift) => shift.isValidOn(date))
        .toList(growable: false);
  }

  static String _escape(String value) => value.replaceAll("'", "''");
}
