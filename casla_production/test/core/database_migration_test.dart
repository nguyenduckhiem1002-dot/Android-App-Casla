// Migration tests.
//
// A user's device is always mid-upgrade from whatever version it last opened,
// never from a fresh install. These open a database pinned at a historical
// version, seed it the way that version's app would have, then walk it forward
// with `migrate` and assert nothing already on disk was lost.

import 'package:casla_production/core/database/casla_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/database_test_harness.dart';

/// The `orders` table exactly as `createSchema` shipped it at schema version 1
/// (before the v2 migration added `production_order`/`operation`).
///
/// A frozen copy, not `createSchema` with columns stripped back out: the whole
/// point is to catch `createSchema` and `migrate` drifting apart, so the v1
/// shape here must not move when `createSchema` does.
const _ordersV1 = '''
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
''';

void main() {
  setUpAll(initSqfliteFfi);

  test('every version below current has a migration step', () {
    for (var v = 1; v < schemaVersion; v++) {
      expect(
        () => migrate(_NeverOpened(), v, v + 1),
        // A real Database would run the step; here we only need `migrate` to
        // find one instead of throwing StateError('Thiếu bước migration...').
        // _NeverOpened blows up the moment a step touches it, which is the
        // point — reaching that failure proves a step exists for `v`.
        throwsA(isNot(isA<StateError>())),
      );
    }
  });

  test(
    'v1 -> v2 adds production_order/operation without losing rows',
    () async {
      final db = await openDatabase(inMemoryDatabasePath, version: 1);
      await db.execute(_ordersV1);
      await db.insert('orders', {
        'id': 'ord-1',
        'ma_don_hang': 'DH-2026-00417',
        'ma_qr': 'QR-AKG-L',
        'ma_sp': 'SP-AKG',
        'ten_sp': 'Áo khoác gió — size L',
        'dac_tinh': 'Vải dù 2 lớp',
        'uom': 'cái',
        'so_luong_don': 1000.0,
        'trang_thai': 'OPEN',
      });

      await migrate(db, 1, 2);

      final rows = await db.query(
        'orders',
        where: 'id = ?',
        whereArgs: ['ord-1'],
      );
      expect(rows, hasLength(1));
      final row = rows.single;

      // Every v1 column survives with its original value.
      expect(row['ma_don_hang'], 'DH-2026-00417');
      expect(row['ten_sp'], 'Áo khoác gió — size L');
      expect(row['so_luong_don'], 1000.0);

      // The new columns exist and default to NULL for a pre-existing row.
      expect(row.containsKey('production_order'), isTrue);
      expect(row['production_order'], isNull);
      expect(row.containsKey('operation'), isTrue);
      expect(row['operation'], isNull);

      await db.close();
    },
  );

  test('v2 -> v3 creates the WorkHistory cache tables', () async {
    final db = await openDatabase(inMemoryDatabasePath, version: 2);

    await migrate(db, 2, 3);

    final tables = await db.query(
      'sqlite_master',
      columns: ['name'],
      where: "type = 'table' AND name LIKE 'work_history_cache_%'",
      orderBy: 'name',
    );
    expect(
      tables.map((row) => row['name']),
      containsAll(<String>[
        'work_history_cache_meta',
        'work_history_cache_entries',
        'work_history_cache_workers',
      ]),
    );

    await db.close();
  });

  test(
    'a fresh install has QR validity and operation payload columns',
    () async {
      final db = await openDatabase(
        inMemoryDatabasePath,
        version: schemaVersion,
        onCreate: (db, _) => createSchema(db),
      );

      await db.insert('orders', {
        'id': 'ord-1',
        'ma_don_hang': 'DH-2026-00417',
        'ten_sp': 'Áo khoác gió',
        'so_luong_don': 1000.0,
        'trang_thai': 'OPEN',
        'production_order': '000010001234',
        'operation': '0010',
      });

      final row = (await db.query('orders')).single;
      expect(row['production_order'], '000010001234');
      expect(row['operation'], '0010');
      expect(row.containsKey('operation_qr_payload'), isTrue);

      // The fresh-install schema is checked through an explicit table-info query
      // because this test database does not seed employees by default.
      final employeeColumns = await db.rawQuery('PRAGMA table_info(employees)');
      expect(
        employeeColumns.map((column) => column['name']),
        containsAll(<String>['valid_from', 'valid_to']),
      );

      await db.close();
    },
  );

  test('v4 -> v5 freezes the unit onto existing transactions', () async {
    // A v4 device mid-shift: an assignment already queued under KG, and the
    // order row it points at. The migration has to answer "what unit was this
    // entered in" for rows that never recorded one.
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: 4,
      onCreate: (db, _) => createSchema(db),
    );
    for (final statement in _transactionTablesV4) {
      await db.execute(statement);
    }
    await db.insert('orders', {
      'id': 'ord-1',
      'ma_don_hang': 'DH-2026-00417',
      'ten_sp': 'Sợi polyester',
      'so_luong_don': 1000.0,
      'trang_thai': 'OPEN',
      'uom': 'KG',
    });
    await db.insert('assignments', {
      'id': 'asg-1',
      'nhan_vien_id': 'emp-1',
      'don_hang_id': 'ord-1',
      'to_id': 'team-1',
      'assigned_quantity': 12.5,
      'business_date': '2026-09-07',
      'shift_id': 'SHIFT_1',
      'status': 'OPEN',
      'created_by': 'MNV00100',
      'occurred_at_utc': 1,
      'device_id': 'PDA-1',
      'sync_status': 'PENDING',
      'idempotency_key': 'idem-1',
      'created_at_utc': 1,
    });

    await migrate(db, 4, 5);

    final assignment = (await db.query('assignments')).single;
    expect(assignment['assigned_quantity'], 12.5);
    // Backfilled from the order it belongs to — exactly what the old code
    // would have sent for this row.
    expect(assignment['unit_of_measure'], 'KG');

    // And the freeze holds: rewriting the order no longer moves it.
    await db.update(
      'orders',
      {'uom': 'ST'},
      where: 'id = ?',
      whereArgs: ['ord-1'],
    );
    expect((await db.query('assignments')).single['unit_of_measure'], 'KG');

    await db.close();
  });
}

/// The three transaction tables exactly as `createSchema` shipped them at v4,
/// before the v5 migration added `unit_of_measure`. Frozen copies on purpose —
/// see [_ordersV1]. The test opens at the *current* schema (so the rest of the
/// database is real) and then rolls just these three back to their v4 shape.
const _transactionTablesV4 = [
  'DROP TABLE production_records',
  'DROP TABLE recall_records',
  'DROP TABLE assignments',
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
];

/// A [Database] stand-in that throws the moment anything calls it.
///
/// Used only to prove `_migrations` has an entry for a given `from` version —
/// if `migrate` reaches the step's body at all, this throws before it can do
/// anything meaningful, which is a more specific failure than the
/// `StateError('Thiếu bước migration...')` a missing entry would raise instead.
class _NeverOpened implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_NeverOpened reached: migration step ran');
}
