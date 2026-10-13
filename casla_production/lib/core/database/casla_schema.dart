// Core Database — SQLite schema & migrations
// Spec: Section 8 (Data model & database), Section 14 (DDL tham chiếu)
//
// Migrations are hand-written and forward-only. Every bump of [schemaVersion]
// must add a matching case to [migrate]; `test/core/database_migration_test.dart`
// opens a database at every historical version and walks it up to the current
// one, so a missing case fails the build rather than a user's device.

import 'package:sqflite/sqflite.dart';

/// Bump on every schema change and add the matching step to [migrate].
const int schemaVersion = 18;

/// Tables holding transactions that must survive a restart until SAP confirms
/// them. The retention policy in Spec 4.7 forbids clearing these.
const Set<String> durableTransactionTables = {
  'assignments',
  'production_records',
  'recall_records',
  'sync_queue',
  'audit_log',
};

const List<String> _workHistoryCacheStatements = [
  '''
  CREATE TABLE IF NOT EXISTS work_history_cache_meta (
    cache_key TEXT PRIMARY KEY,
    subject_id TEXT NOT NULL,
    range_code TEXT NOT NULL,
    request_date_from TEXT,
    request_date_to TEXT,
    scope_code TEXT NOT NULL,
    result_date_from TEXT NOT NULL,
    result_date_to TEXT NOT NULL,
    is_truncated INTEGER NOT NULL DEFAULT 0,
    fetched_at_utc INTEGER NOT NULL
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_work_history_meta_subject ON work_history_cache_meta(subject_id, fetched_at_utc)',
  '''
  CREATE TABLE IF NOT EXISTS work_history_cache_entries (
    cache_key TEXT NOT NULL REFERENCES work_history_cache_meta(cache_key) ON DELETE CASCADE,
    sequence_no INTEGER NOT NULL,
    transaction_uuid TEXT NOT NULL,
    execution_date TEXT NOT NULL,
    worker_id TEXT NOT NULL,
    worker_name TEXT NOT NULL,
    production_order TEXT NOT NULL,
    operation TEXT NOT NULL,
    operation_name TEXT,
    product_name TEXT,
    product_code TEXT,
    sales_order TEXT,
    sales_order_item TEXT,
    plant TEXT NOT NULL,
    work_center TEXT NOT NULL,
    work_id TEXT,
    work_date TEXT,
    original_transaction_uuid TEXT,
    position_id TEXT,
    origin_position_id TEXT,
    transaction_type TEXT NOT NULL,
    quantity REAL NOT NULL,
    defect_quantity REAL NOT NULL DEFAULT 0,
    unit_of_measure TEXT NOT NULL,
    transaction_status TEXT NOT NULL,
    PRIMARY KEY(cache_key, sequence_no)
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_work_history_entries_lookup ON work_history_cache_entries(cache_key, execution_date)',
  '''
  CREATE TABLE IF NOT EXISTS work_history_cache_workers (
    cache_key TEXT NOT NULL REFERENCES work_history_cache_meta(cache_key) ON DELETE CASCADE,
    sequence_no INTEGER NOT NULL,
    worker_id TEXT NOT NULL,
    worker_name TEXT NOT NULL,
    assigned_quantity REAL NOT NULL,
    completed_quantity REAL NOT NULL,
    defect_quantity REAL NOT NULL DEFAULT 0,
    remaining_quantity REAL NOT NULL,
    unit_of_measure TEXT NOT NULL,
    transaction_count INTEGER NOT NULL,
    work_id TEXT,
    work_name TEXT,
    bo_phan TEXT,
    location TEXT,
    PRIMARY KEY(cache_key, sequence_no)
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_work_history_workers_lookup ON work_history_cache_workers(cache_key, worker_id)',
];

const List<String> _createStatements = [
  // ─── Master data ────────────────────────────────────────────────────
  // Refreshed from SAP; safe to replace wholesale.
  '''
  CREATE TABLE employees (
    id TEXT PRIMARY KEY,
    ma_nv TEXT NOT NULL,
    ten TEXT NOT NULL,
    bo_phan TEXT,
    trang_thai TEXT NOT NULL,
    vai_tro TEXT NOT NULL,
    quyen_han TEXT NOT NULL DEFAULT '[]',
    to_ids TEXT NOT NULL DEFAULT '[]',
    valid_from TEXT,
    valid_to TEXT
  )
  ''',
  'CREATE UNIQUE INDEX idx_employees_ma_nv ON employees(ma_nv)',

  '''
  CREATE TABLE teams (
    id TEXT PRIMARY KEY,
    ma_to TEXT NOT NULL,
    ten_to TEXT NOT NULL,
    bo_phan TEXT,
    trang_thai TEXT NOT NULL
  )
  ''',

  '''
  CREATE TABLE orders (
    id TEXT PRIMARY KEY,
    ma_don_hang TEXT NOT NULL,
    ma_qr TEXT,
    ma_sp TEXT,
    ten_sp TEXT NOT NULL,
    dac_tinh TEXT,
    uom TEXT,
    so_luong_don REAL NOT NULL,
    trang_thai TEXT NOT NULL,
    -- SAP live keys (added v2). Every mobile mutation against ZUI_PP_OPALLOC
    -- resolves the SAP Manufacturing Order + Operation live from these two
    -- fields, not from `ma_don_hang` — that code is an app-internal label and
    -- is never guaranteed to match SAP's real order number format.
    production_order TEXT,
    operation TEXT,
    plant TEXT,
    work_center TEXT,
    operation_qr_payload TEXT,
    operation_name TEXT,
    sales_order TEXT,
    sales_order_item TEXT
  )
  ''',
  // getOrderByCode resolves a scan against any of these identifiers.
  'CREATE INDEX idx_orders_ma_qr ON orders(ma_qr)',
  'CREATE INDEX idx_orders_ma_don_hang ON orders(ma_don_hang)',
  'CREATE INDEX idx_orders_ma_sp ON orders(ma_sp)',

  // ─── Transactions ───────────────────────────────────────────────────
  '''
  CREATE TABLE assignments (
    id TEXT PRIMARY KEY,
    nhan_vien_id TEXT NOT NULL,
    don_hang_id TEXT NOT NULL,
    to_id TEXT NOT NULL,
    assigned_quantity REAL NOT NULL CHECK(assigned_quantity > 0),
    -- Unit of measure frozen at the moment the transaction was created (v5).
    -- `orders.uom` is refreshed by every operation QR scan, so reading it at
    -- push time would send a queued transaction under a unit it was never
    -- entered in — and SAP compares the unit when it matches an idempotency
    -- key, so the re-send is rejected rather than de-duplicated.
    unit_of_measure TEXT,
    business_date TEXT NOT NULL,
    shift_id TEXT NOT NULL,
    status TEXT NOT NULL,
    note TEXT,
    -- Position the worker operates from for this assignment (v15). Sent to
    -- SAP as PositionID; the machine is kept for display only, the ledger
    -- does not store it.
    position_id TEXT,
    machine_id TEXT,
    created_by TEXT NOT NULL,
    occurred_at_utc INTEGER NOT NULL,
    -- Moment of entry as SAP's EntryDate / EntryTime, in Vietnam time (v18).
    -- Frozen here because a retry must repeat them to the second. NULL on a
    -- row queued before v18: that one keeps sending ExecutedAt in UTC.
    entry_date TEXT,
    entry_time TEXT,
    device_id TEXT NOT NULL,
    sync_status TEXT NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE,
    sap_id TEXT,
    created_at_utc INTEGER NOT NULL,
    synced_at_utc INTEGER
  )
  ''',
  'CREATE INDEX idx_assignments_worker ON assignments(nhan_vien_id, created_at_utc)',
  'CREATE INDEX idx_assignments_team ON assignments(to_id, created_at_utc)',

  // Named `production_records` rather than the spec's `production_entries`:
  // every existing query and payload in the app uses the former.
  '''
  CREATE TABLE production_records (
    id TEXT PRIMARY KEY,
    phan_cong_id TEXT NOT NULL REFERENCES assignments(id),
    quantity REAL NOT NULL CHECK(quantity >= 0),
    defect_quantity REAL NOT NULL DEFAULT 0 CHECK(defect_quantity >= 0),
    -- Frozen per transaction — see `assignments.unit_of_measure`.
    unit_of_measure TEXT,
    note TEXT,
    business_date TEXT NOT NULL,
    shift_id TEXT NOT NULL,
    created_by TEXT NOT NULL,
    occurred_at_utc INTEGER NOT NULL,
    -- See `assignments.entry_date`.
    entry_date TEXT,
    entry_time TEXT,
    device_id TEXT NOT NULL,
    sync_status TEXT NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE,
    sap_id TEXT,
    created_at_utc INTEGER NOT NULL,
    synced_at_utc INTEGER,
    CHECK(quantity + defect_quantity > 0)
  )
  ''',
  'CREATE INDEX idx_prod_assignment_date ON production_records(phan_cong_id, business_date, shift_id)',

  '''
  CREATE TABLE recall_records (
    id TEXT PRIMARY KEY,
    phan_cong_id TEXT NOT NULL REFERENCES assignments(id),
    quantity REAL NOT NULL CHECK(quantity > 0),
    -- Frozen per transaction — see `assignments.unit_of_measure`.
    unit_of_measure TEXT,
    reason_code TEXT NOT NULL,
    note TEXT,
    business_date TEXT NOT NULL,
    shift_id TEXT NOT NULL,
    created_by TEXT NOT NULL,
    occurred_at_utc INTEGER NOT NULL,
    -- See `assignments.entry_date`.
    entry_date TEXT,
    entry_time TEXT,
    device_id TEXT NOT NULL,
    sync_status TEXT NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE,
    sap_id TEXT,
    created_at_utc INTEGER NOT NULL,
    synced_at_utc INTEGER
  )
  ''',
  'CREATE INDEX idx_recall_assignment ON recall_records(phan_cong_id)',

  // Read-only SAP report cache. It is intentionally not part of
  // durableTransactionTables: a cache can be rebuilt, queued writes cannot.
  ..._workHistoryCacheStatements,

  // ─── Sync queue ─────────────────────────────────────────────────────
  // `status` is stored rather than derived from `last_error_code`, because a
  // transient network failure must stay PENDING (the engine retries it) while a
  // business-rule rejection becomes FAILED (Spec 4.7). Both write an error code,
  // so the code alone cannot tell them apart.
  '''
  CREATE TABLE sync_queue (
    id TEXT PRIMARY KEY,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    action TEXT NOT NULL,
    payload_summary TEXT,
    idempotency_key TEXT,
    priority INTEGER NOT NULL DEFAULT 5,
    status TEXT NOT NULL DEFAULT 'PENDING',
    retry_count INTEGER NOT NULL DEFAULT 0,
    last_error_code TEXT,
    last_error_message TEXT,
    failure_kind TEXT,
    next_retry_at_utc INTEGER,
    device_id TEXT,
    created_at_utc INTEGER NOT NULL,
    updated_at_utc INTEGER
  )
  ''',
  'CREATE INDEX idx_sync_queue_feed ON sync_queue(created_at_utc)',
  // The engine's claim query filters on these two before ordering.
  'CREATE INDEX idx_sync_queue_due ON sync_queue(status, next_retry_at_utc)',

  '''
  CREATE TABLE audit_log (
    id TEXT PRIMARY KEY,
    event_type TEXT,
    action TEXT,
    actor_id TEXT,
    performed_by TEXT,
    target_employee_id TEXT,
    entity_type TEXT,
    entity_id TEXT,
    business_date TEXT,
    shift_id TEXT,
    occurred_at_utc INTEGER NOT NULL,
    device_id TEXT
  )
  ''',
  'CREATE INDEX idx_audit_occurred ON audit_log(occurred_at_utc)',
  '''
  CREATE TABLE local_settings (
    setting_key TEXT PRIMARY KEY,
    setting_value TEXT NOT NULL,
    updated_at_utc INTEGER NOT NULL
  )
  ''',
];

Future<void> createSchema(Database db) async {
  final batch = db.batch();
  for (final statement in _createStatements) {
    batch.execute(statement);
  }
  for (final statement in _workHistoryCacheStatements) {
    batch.execute(statement);
  }
  await batch.commit(noResult: true);
}

/// Migration steps, keyed by the version they upgrade *from*.
///
/// Adding `2` here means "run this to go from version 1 to version 2".
const Map<int, Future<void> Function(Database)> _migrations = {
  1: _upgradeV1ToV2,
  2: _upgradeV2ToV3,
  3: _upgradeV3ToV4,
  4: _upgradeV4ToV5,
  5: _upgradeV5ToV6,
  6: _upgradeV6ToV7,
  7: _upgradeV7ToV8,
  8: _upgradeV8ToV9,
  9: _upgradeV9ToV10,
  10: _upgradeV10ToV11,
  11: _upgradeV11ToV12,
  12: _upgradeV12ToV13,
  13: _upgradeV13ToV14,
  14: _upgradeV14ToV15,
  15: _upgradeV15ToV16,
  16: _upgradeV16ToV17,
  17: _upgradeV17ToV18,
};

/// v18 — the moment of entry as SAP's EntryDate / EntryTime (Vietnam time),
/// frozen on each transaction. Rows already queued keep both NULL and go on
/// sending ExecutedAt in UTC: SAP compares a retry with the first attempt to
/// the second, so their format must not change underneath them.
Future<void> _upgradeV17ToV18(Database db) async {
  for (final table in const [
    'assignments',
    'production_records',
    'recall_records',
  ]) {
    await _addColumns(db, table, const ['entry_date', 'entry_time']);
  }
}

/// v17 — keep the position SAP reports on each history transaction, so the
/// assignment form can tell where a worker's work for the shift was given
/// even from an offline cache hit.
Future<void> _upgradeV16ToV17(Database db) async {
  await _addColumns(db, 'work_history_cache_entries', const [
    'position_id',
    'origin_position_id',
  ]);
}

/// v16 — store defective output independently from good completion while
/// counting both against the assigned balance. Quantity may now be zero for
/// defect-only confirmations, but the combined transaction must be positive.
Future<void> _upgradeV15ToV16(Database db) async {
  for (final table in const [
    'work_history_cache_entries',
    'work_history_cache_workers',
  ]) {
    final columns = (await db.rawQuery(
      'PRAGMA table_info($table)',
    )).map((column) => column['name']).toSet();
    if (!columns.contains('defect_quantity')) {
      await db.execute(
        'ALTER TABLE $table ADD COLUMN defect_quantity REAL NOT NULL DEFAULT 0',
      );
    }
  }
  await db.execute('''
    CREATE TABLE production_records_v16 (
      id TEXT PRIMARY KEY,
      phan_cong_id TEXT NOT NULL REFERENCES assignments(id),
      quantity REAL NOT NULL CHECK(quantity >= 0),
      defect_quantity REAL NOT NULL DEFAULT 0 CHECK(defect_quantity >= 0),
      unit_of_measure TEXT,
      note TEXT,
      business_date TEXT NOT NULL,
      shift_id TEXT NOT NULL,
      created_by TEXT NOT NULL,
      occurred_at_utc INTEGER NOT NULL,
      device_id TEXT NOT NULL,
      sync_status TEXT NOT NULL,
      idempotency_key TEXT NOT NULL UNIQUE,
      sap_id TEXT,
      created_at_utc INTEGER NOT NULL,
      synced_at_utc INTEGER,
      CHECK(quantity + defect_quantity > 0)
    )
  ''');
  await db.execute('''
    INSERT INTO production_records_v16 (
      id, phan_cong_id, quantity, defect_quantity, unit_of_measure, note,
      business_date, shift_id, created_by, occurred_at_utc, device_id,
      sync_status, idempotency_key, sap_id, created_at_utc, synced_at_utc
    )
    SELECT id, phan_cong_id, quantity, 0, unit_of_measure, note,
      business_date, shift_id, created_by, occurred_at_utc, device_id,
      sync_status, idempotency_key, sap_id, created_at_utc, synced_at_utc
    FROM production_records
  ''');
  await db.execute('DROP TABLE production_records');
  await db.execute(
    'ALTER TABLE production_records_v16 RENAME TO production_records',
  );
  await db.execute(
    'CREATE INDEX idx_prod_assignment_date '
    'ON production_records(phan_cong_id, business_date, shift_id)',
  );
}

/// v15 — the position (and its machine) an assignment was made at. SAP's
/// submitInitialAssign takes it as PositionID; it may be a temporary seat,
/// so it is frozen on the transaction rather than read from the board later.
Future<void> _upgradeV14ToV15(Database db) async {
  await _addColumns(db, 'assignments', const ['position_id', 'machine_id']);
}

/// v14 — keep SAP's WorkDate (the shift's business date, which differs from
/// the posting time on night shifts) and each row's OriginalTransactionUUID
/// in the history cache. Without the lineage an offline cache hit cannot
/// group carried-over work (REASSIGN) with its top-ups for confirmation.
Future<void> _upgradeV13ToV14(Database db) async {
  await _addColumns(db, 'work_history_cache_entries', const [
    'work_date',
    'original_transaction_uuid',
  ]);
}

/// v9 — retain the operation name carried by production QR labels.
Future<void> _upgradeV8ToV9(Database db) async {
  await _addColumns(db, 'orders', const ['operation_name']);
}

/// v10 — retain descriptive product/operation fields in the history cache.
Future<void> _upgradeV9ToV10(Database db) async {
  await _addColumns(db, 'work_history_cache_entries', const [
    'operation_name',
    'product_name',
    'product_code',
  ]);
}

/// v11 — retain SalesOrder/SalesOrderItem carried by the history response.
Future<void> _upgradeV10ToV11(Database db) async {
  await _addColumns(db, 'work_history_cache_entries', const [
    'sales_order',
    'sales_order_item',
  ]);
}

/// v12 — retain SalesOrder/SalesOrderItem carried by operation QR labels.
Future<void> _upgradeV11ToV12(Database db) async {
  await _addColumns(db, 'orders', const ['sales_order', 'sales_order_item']);
}

/// v13 — retain the SAP work context returned with history transactions and
/// worker summaries. This keeps the location at posting time available after
/// an offline cache hit.
Future<void> _upgradeV12ToV13(Database db) async {
  await _addColumns(db, 'work_history_cache_entries', const ['work_id']);
  await _addColumns(db, 'work_history_cache_workers', const [
    'work_id',
    'work_name',
    'bo_phan',
    'location',
  ]);
}

/// v2 — SAP live keys on `orders`.
///
/// `ZUI_PP_OPALLOC` resolves the live SAP Manufacturing Order + Operation from
/// `ProductionOrder + Operation`, supplied per mutation. A v1 database has
/// nowhere to keep those, so every existing order gains them as nullable —
/// existing rows read back NULL until a supervisor fills them in; new orders
/// created after this migration should always set both.
Future<void> _upgradeV1ToV2(Database db) async {
  await db.execute('ALTER TABLE orders ADD COLUMN production_order TEXT');
  await db.execute('ALTER TABLE orders ADD COLUMN operation TEXT');
}

/// v5 — retain the Plant/Work Center carried by an operation QR when present.
/// These are hints for selecting the manager's existing Work Context; SAP
/// remains authoritative when the mutation is submitted.
Future<void> _upgradeV4ToV5(Database db) async {
  await _addColumns(db, 'orders', const ['plant', 'work_center']);
}

/// Adds any of [columns] that `table` does not already have.
///
/// `ALTER TABLE ... ADD COLUMN` throws on a duplicate, and two migrations were
/// briefly both numbered v5 on master (one adding orders.plant/work_center, one
/// adding unit_of_measure to the transaction tables). A device that opened the
/// app while that was true may hold either half. Checking first lets every
/// device converge on the same schema no matter which half it already ran.
Future<void> _addColumns(
  Database db,
  String table,
  List<String> columns,
) async {
  final existing = (await db.rawQuery(
    'PRAGMA table_info($table)',
  )).map((column) => column['name']).toSet();
  for (final column in columns) {
    if (!existing.contains(column)) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column TEXT');
    }
  }
}

/// v3 — account-isolated WorkHistory cache.
///
/// The cache is additive only. No durable transaction table is rebuilt or
/// copied, so upgrading a PDA cannot drop queued production writes.
Future<void> _upgradeV2ToV3(Database db) async {
  for (final statement in _workHistoryCacheStatements) {
    await db.execute(statement);
  }
}

/// v4 — preserve the validity window from worker QR cards and the original
/// operation QR payload used to resolve SAP's production order/operation.
Future<void> _upgradeV3ToV4(Database db) async {
  // Some earlier debug installs added QR columns without advancing user_version.
  // Inspect the actual schema so upgrading those devices preserves their data.
  final employeeColumns = (await db.rawQuery(
    'PRAGMA table_info(employees)',
  )).map((column) => column['name']).toSet();
  for (final column in ['valid_from', 'valid_to']) {
    if (!employeeColumns.contains(column)) {
      await db.execute('ALTER TABLE employees ADD COLUMN $column TEXT');
    }
  }
  final orderColumns = await db.rawQuery('PRAGMA table_info(orders)');
  if (!orderColumns.any((column) => column['name'] == 'operation_qr_payload')) {
    await db.execute('ALTER TABLE orders ADD COLUMN operation_qr_payload TEXT');
  }
}

/// v6 — freeze the unit of measure onto each transaction.
///
/// Until now the gateway read `orders.uom` when it built the payload. Scanning
/// the same production order + operation again with a different unit rewrites
/// that row in place, so a transaction sitting in the queue would be pushed
/// under a unit the supervisor never entered. `zbp_r_pp_opalloc` compares the
/// unit as part of matching an idempotency key, so such a re-send comes back
/// rejected instead of de-duplicated.
///
/// Existing rows are backfilled from the order they belong to. That is the
/// best available answer for history — it is exactly what the old code would
/// have sent — and it is applied once, now, rather than re-read on every push.
Future<void> _upgradeV5ToV6(Database db) async {
  await _repairTransactionUnits(db);
}

/// Re-run the idempotent repair for devices that already installed v6.
/// Existing nonempty units and idempotency keys must remain unchanged.
Future<void> _upgradeV6ToV7(Database db) async {
  await _repairTransactionUnits(db);
}

/// v8 — durable, account-scoped local UI settings such as the selected
/// supervisor work context and shift. This table contains no SAP credentials.
Future<void> _upgradeV7ToV8(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS local_settings (
      setting_key TEXT PRIMARY KEY,
      setting_value TEXT NOT NULL,
      updated_at_utc INTEGER NOT NULL
    )
  ''');
}

Future<void> _repairTransactionUnits(Database db) async {
  // A short-lived v5 branch added transaction units before the work-context
  // columns were merged. Repair both halves here so those devices converge on
  // the current schema when they jump straight to v6.
  await _addColumns(db, 'orders', const ['plant', 'work_center']);
  for (final table in const [
    'assignments',
    'production_records',
    'recall_records',
  ]) {
    await _addColumns(db, table, const ['unit_of_measure']);
  }

  // Never overwrite a unit that was already frozen on a transaction. That
  // value is part of the original SAP request; the order row may have been
  // rescanned later with another UOM.
  await db.execute(
    'UPDATE assignments SET unit_of_measure = '
    '(SELECT o.uom FROM orders o WHERE o.id = assignments.don_hang_id) '
    "WHERE unit_of_measure IS NULL OR TRIM(unit_of_measure) = ''",
  );
  for (final table in ['production_records', 'recall_records']) {
    await db.execute(
      'UPDATE $table SET unit_of_measure = ('
      "  SELECT COALESCE(NULLIF(TRIM(a.unit_of_measure), ''), o.uom) "
      '  FROM assignments a'
      '  LEFT JOIN orders o ON o.id = a.don_hang_id'
      '  WHERE a.id = $table.phan_cong_id'
      ') '
      "WHERE unit_of_measure IS NULL OR TRIM(unit_of_measure) = ''",
    );
  }
}

/// Walks a database from [from] up to [to], one version at a time.
Future<void> migrate(Database db, int from, int to) async {
  for (var version = from; version < to; version++) {
    final step = _migrations[version];
    if (step == null) {
      throw StateError(
        'Thiếu bước migration cho schema version $version → ${version + 1}.',
      );
    }
    await step(db);
  }
}
