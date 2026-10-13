// Domain — overlays local transactions SAP has not reported yet.
//
// SAP's work-history report is the source of truth, but it lags local writes:
// a transaction can still be queued (offline, waiting for the worker's
// password) or already posted while the cached report predates it. Screens
// that show per-worker totals add only the local rows the report does not
// contain yet, so a confirmation shows up immediately and never twice.

import '../entities/work_history.dart';

enum LocalLedgerKind { assign, confirm, recall }

/// One local assignment, confirmation or recall row, flattened for overlaying.
class LocalLedgerRow {
  final LocalLedgerKind kind;
  final String workerId;
  final String workerCode;
  final double quantity;
  final double defectQuantity;

  /// Unit the row was entered in; empty on rows saved without one.
  final String unit;
  final String syncStatus;
  final String sapId;
  final String idempotencyKey;

  const LocalLedgerRow({
    required this.kind,
    required this.workerId,
    this.workerCode = '',
    required this.quantity,
    this.defectQuantity = 0,
    this.unit = '',
    required this.syncStatus,
    this.sapId = '',
    this.idempotencyKey = '',
  });

  factory LocalLedgerRow.fromMap(Map<String, dynamic> row) {
    return LocalLedgerRow(
      kind: switch (row['kind']?.toString()) {
        'ASSIGN' => LocalLedgerKind.assign,
        'RECALL' => LocalLedgerKind.recall,
        _ => LocalLedgerKind.confirm,
      },
      workerId: row['worker_id']?.toString() ?? '',
      workerCode: row['worker_code']?.toString() ?? '',
      quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
      defectQuantity: (row['defect_quantity'] as num?)?.toDouble() ?? 0,
      unit: row['unit_of_measure']?.toString() ?? '',
      syncStatus: row['sync_status']?.toString() ?? '',
      sapId: row['sap_id']?.toString() ?? '',
      idempotencyKey: row['idempotency_key']?.toString() ?? '',
    );
  }
}

/// Quantities one worker has on this device that SAP has not reported yet.
class LocalPendingTotals {
  double assigned = 0;
  double completed = 0;
  double defect = 0;
  double recalled = 0;

  LocalPendingTotals();

  static final LocalPendingTotals zero = LocalPendingTotals();

  bool get isEmpty =>
      assigned == 0 && completed == 0 && defect == 0 && recalled == 0;

  /// Signed change to the worker's remaining balance.
  double get remainingDelta => assigned - recalled - completed - defect;
}

/// Per-worker pending totals, looked up by local id or employee code.
class LocalPendingLedger {
  final Map<String, LocalPendingTotals> _byKey;
  final Map<String, Map<String, LocalPendingTotals>> _byKeyUnit;

  const LocalPendingLedger._(this._byKey, [this._byKeyUnit = const {}]);

  static const empty = LocalPendingLedger._({});

  static String _key(String? value) => (value ?? '').trim().toUpperCase();

  /// Totals for the first key that has any; both a worker's local id and its
  /// employee code resolve to the same object, so callers may pass both.
  /// With [unit], only the rows entered in that unit.
  LocalPendingTotals forWorker(Iterable<String?> keys, {String? unit}) {
    for (final key in keys) {
      if (unit == null) {
        final totals = _byKey[_key(key)];
        if (totals != null) return totals;
      } else {
        final units = _byKeyUnit[_key(key)];
        if (units != null) return units[_key(unit)] ?? LocalPendingTotals.zero;
      }
    }
    return LocalPendingTotals.zero;
  }

  /// Units of the worker's pending rows, as entered (upper-cased).
  Set<String> unitsForWorker(Iterable<String?> keys) {
    for (final key in keys) {
      final units = _byKeyUnit[_key(key)];
      if (units != null) return units.keys.toSet();
    }
    return const {};
  }
}

String _normalizeTransactionId(String value) =>
    value.replaceAll('-', '').trim().toUpperCase();

/// Builds the pending ledger from [rows] that [sap] does not already contain.
///
/// A row counts when it is not FAILED and neither its `sap_id` nor its
/// idempotency key appears among the report's transaction UUIDs. A row that
/// is already SYNCED only counts when it carries a SAP id and the report is
/// complete: without an id it can never be matched, and a truncated report may
/// simply have cut its entry off — adding it then would count it twice.
LocalPendingLedger buildLocalPendingLedger({
  required WorkHistoryResult? sap,
  required Iterable<LocalLedgerRow> rows,
}) {
  final represented = <String>{
    for (final entry in sap?.entries ?? const <WorkHistoryEntry>[])
      _normalizeTransactionId(entry.transactionUuid),
  }..remove('');
  final truncated = sap?.isTruncated ?? false;
  final byKey = <String, LocalPendingTotals>{};
  final byKeyUnit = <String, Map<String, LocalPendingTotals>>{};

  for (final row in rows) {
    final status = row.syncStatus.trim().toUpperCase();
    if (status == 'FAILED' ||
        !row.quantity.isFinite ||
        !row.defectQuantity.isFinite ||
        (row.quantity <= 0 && row.defectQuantity <= 0)) {
      continue;
    }
    final sapId = _normalizeTransactionId(row.sapId);
    final idempotency = _normalizeTransactionId(row.idempotencyKey);
    if (represented.contains(sapId) || represented.contains(idempotency)) {
      continue;
    }
    if (status == 'SYNCED' && (sapId.isEmpty || truncated)) continue;

    final keys = {
      LocalPendingLedger._key(row.workerId),
      LocalPendingLedger._key(row.workerCode),
    }..remove('');
    if (keys.isEmpty) continue;
    final totals =
        keys
            .map((key) => byKey[key])
            .whereType<LocalPendingTotals>()
            .firstOrNull ??
        LocalPendingTotals();
    final units =
        keys
            .map((key) => byKeyUnit[key])
            .whereType<Map<String, LocalPendingTotals>>()
            .firstOrNull ??
        <String, LocalPendingTotals>{};
    for (final key in keys) {
      byKey[key] = totals;
      byKeyUnit[key] = units;
    }
    final unitTotals = units[LocalPendingLedger._key(row.unit)] ??=
        LocalPendingTotals();
    for (final target in [totals, unitTotals]) {
      switch (row.kind) {
        case LocalLedgerKind.assign:
          target.assigned += row.quantity;
        case LocalLedgerKind.confirm:
          target.completed += row.quantity;
          target.defect += row.defectQuantity;
        case LocalLedgerKind.recall:
          target.recalled += row.quantity;
      }
    }
  }
  return LocalPendingLedger._(byKey, byKeyUnit);
}

/// SAP totals for one worker with the pending local rows applied.
///
/// SAP reports `AssignedQuantity` gross of recalls and derives
/// `RemainingQuantity` as assigned − recalled − completed (see
/// `zcl_pp_work_history`), so a local recall lowers only the remaining value.
({
  double assigned,
  double completed,
  double defect,
  double recalled,
  double remaining,
})
overlayWorkerSummary(WorkHistorySummary summary, LocalPendingTotals pending) {
  return (
    assigned: summary.assignedQuantity + pending.assigned,
    completed: summary.completedQuantity + pending.completed,
    defect: summary.defectQuantity + pending.defect,
    recalled: summary.recalledQuantity + pending.recalled,
    remaining: summary.remainingQuantity + pending.remainingDelta,
  );
}
