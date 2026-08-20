// Core Database — SQLite schema & migrations
// Spec: Section 8 (Data model & database), Section 14 (DDL tham chiếu)
//
// Migrations are hand-written and forward-only. Every bump of [schemaVersion]
// must add a matching case to [migrate]; `test/core/database_migration_test.dart`
// opens a database at every historical version and walks it up to the current
// one, so a missing case fails the build rather than a user's device.

import 'package:sqflite/sqflite.dart';

/// Bump on every schema change and add the matching step to [migrate].
const int schemaVersion = 1;

/// Tables holding transactions that must survive a restart until SAP confirms
/// them. The retention policy in Spec 4.7 forbids clearing these.
const Set<String> durableTransactionTables = {
  'assignments',
  'production_records',
  'recall_records',
  'sync_queue',
  'audit_log',
};

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
    to_ids TEXT NOT NULL DEFAULT '[]'
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
    trang_thai TEXT NOT NULL
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
    business_date TEXT NOT NULL,
    shift_id TEXT NOT NULL,
    status TEXT NOT NULL,
    note TEXT,
    created_by TEXT NOT NULL,
    occurred_at_utc INTEGER NOT NULL,
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
    quantity REAL NOT NULL CHECK(quantity > 0),
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
    synced_at_utc INTEGER
  )
  ''',
  'CREATE INDEX idx_prod_assignment_date ON production_records(phan_cong_id, business_date, shift_id)',

  '''
  CREATE TABLE recall_records (
    id TEXT PRIMARY KEY,
    phan_cong_id TEXT NOT NULL REFERENCES assignments(id),
    quantity REAL NOT NULL CHECK(quantity > 0),
    reason_code TEXT NOT NULL,
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
    synced_at_utc INTEGER
  )
  ''',
  'CREATE INDEX idx_recall_assignment ON recall_records(phan_cong_id)',

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
];

Future<void> createSchema(Database db) async {
  final batch = db.batch();
  for (final statement in _createStatements) {
    batch.execute(statement);
  }
  await batch.commit(noResult: true);
}

/// Migration steps, keyed by the version they upgrade *from*.
///
/// Adding `2` here means "run this to go from version 1 to version 2".
const Map<int, Future<void> Function(Database)> _migrations = {
  // 1: _upgradeTo2,
};

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
