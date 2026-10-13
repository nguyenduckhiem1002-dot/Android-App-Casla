/// When an operation was entered, as SAP's `EntryDate` / `EntryTime`.
///
/// `ZAPI_PP_OPALLOC` takes the moment of entry as a Vietnam wall-clock date
/// and time. It is derived from the UTC instant with a fixed offset (Vietnam
/// has no daylight saving), so a device set to another time zone still sends
/// the factory's time.
class SapEntryTime {
  /// `yyyy-MM-dd`.
  final String date;

  /// `HH:mm:ss`.
  final String time;

  const SapEntryTime({required this.date, required this.time});

  static const Duration _vietnamOffset = Duration(hours: 7);

  factory SapEntryTime.fromInstant(DateTime instant) {
    final local = instant.toUtc().add(_vietnamOffset);
    String two(int value) => value.toString().padLeft(2, '0');
    return SapEntryTime(
      date:
          '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)}',
      time: '${two(local.hour)}:${two(local.minute)}:${two(local.second)}',
    );
  }

  factory SapEntryTime.fromEpochMillis(int millis) => SapEntryTime.fromInstant(
    DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
  );
}
