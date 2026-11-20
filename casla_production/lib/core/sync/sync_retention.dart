// Retention of work that never reached SAP (decided 2026-10-28).
//
// A queued, failed or verification-pending transaction is kept only for the
// local calendar day it was entered. From the next day on it is dropped,
// together with its local record, whenever the app next runs: on open, on
// every sync pass and on the Đồng bộ tab's refresh tick. The supervisor is
// expected to have resolved it during the shift; a day-old entry re-sent
// later would land on the wrong business date and shift on SAP.

/// Whether a queue row entered at [createdAtUtcMs] has outlived its day as of
/// [now]. The day boundary is the device's local midnight, like the business
/// dates the forms write.
bool isExpiredSyncItem({required int createdAtUtcMs, required DateTime now}) {
  if (createdAtUtcMs <= 0) return false;
  final created = DateTime.fromMillisecondsSinceEpoch(
    createdAtUtcMs,
    isUtc: true,
  ).toLocal();
  final local = now.toLocal();
  final createdDay = DateTime(created.year, created.month, created.day);
  final today = DateTime(local.year, local.month, local.day);
  return createdDay.isBefore(today);
}
