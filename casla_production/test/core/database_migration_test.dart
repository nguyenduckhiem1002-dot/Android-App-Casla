// Migration tests.
//
// A user's device is always mid-upgrade from whatever version it last opened,
// never from a fresh install. These open a database pinned at a historical
// version, seed it the way that version's app would have, then walk it forward
// with `migrate` and assert nothing already on disk was lost.

import 'dart:io';

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
      expect(row.containsKey('plant'), isTrue);
      expect(row.containsKey('work_center'), isTrue);

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

  test('v5 -> v6 freezes the unit onto existing transactions', () async {
    // A v5 device mid-shift: an assignment already queued under KG, and the
    // order row it points at. The migration has to answer "what unit was this
    // entered in" for rows that never recorded one.
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: 5,
      onCreate: (db, _) => createSchema(db),
    );
    for (final statement in _transactionTablesV5) {
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

    await migrate(db, 5, 6);

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

  test(
    'v5 -> v6 preserves an already frozen unit and repairs work context',
    () async {
      final db = await openDatabase(
        inMemoryDatabasePath,
        version: 5,
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE orders (id TEXT, uom TEXT)');
          await db.execute(
            'CREATE TABLE assignments '
            '(id TEXT, don_hang_id TEXT, unit_of_measure TEXT)',
          );
          for (final table in ['production_records', 'recall_records']) {
            await db.execute(
              'CREATE TABLE $table '
              '(id TEXT, phan_cong_id TEXT, unit_of_measure TEXT)',
            );
          }
        },
      );
      addTearDown(db.close);
      await db.insert('orders', {'id': 'order-1', 'uom': 'ST'});
      await db.insert('assignments', {
        'id': 'assignment-1',
        'don_hang_id': 'order-1',
        'unit_of_measure': 'KG',
      });

      await migrate(db, 5, 6);

      expect((await db.query('assignments')).single['unit_of_measure'], 'KG');
      final orderColumns = (await db.rawQuery(
        'PRAGMA table_info(orders)',
      )).map((column) => column['name']);
      expect(orderColumns, containsAll(['plant', 'work_center']));
    },
  );

  for (final oldVersion in [5, 6]) {
    test(
      'v$oldVersion upgrades on reopen and preserves parent and child units',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'casla-migration-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}/upgrade.db';
        final old = await openDatabase(
          path,
          version: oldVersion,
          onCreate: (db, _) async {
            await createSchema(db);
            await db.execute('ALTER TABLE orders DROP COLUMN plant');
            await db.execute('ALTER TABLE orders DROP COLUMN work_center');
          },
        );
        await old.insert('orders', {
          'id': 'order',
          'ma_don_hang': 'order',
          'ten_sp': 'Product',
          'so_luong_don': 10.0,
          'trang_thai': 'OPEN',
          'uom': 'ST',
        });
        await old.insert('assignments', {
          'id': 'parent',
          'don_hang_id': 'order',
          'nhan_vien_id': 'worker',
          'to_id': 'team',
          'assigned_quantity': 10.0,
          'unit_of_measure': 'KG',
          'business_date': '2026-09-07',
          'shift_id': 'SHIFT_1',
          'status': 'OPEN',
          'created_by': 'manager',
          'occurred_at_utc': 1,
          'device_id': 'test',
          'sync_status': 'PENDING',
          'idempotency_key': 'parent',
          'created_at_utc': 1,
        });
        for (final table in ['production_records', 'recall_records']) {
          for (final unit in <String?>[null, '', 'KG', 'ST']) {
            final id = '$table-$unit';
            await old.insert(table, {
              'id': id,
              'phan_cong_id': 'parent',
              'quantity': 0.1,
              'unit_of_measure': unit,
              'business_date': '2026-09-07',
              'shift_id': 'SHIFT_1',
              if (table == 'recall_records') 'reason_code': 'PLAN_CHANGE',
              'created_by': 'manager',
              'occurred_at_utc': 1,
              'device_id': 'test',
              'sync_status': 'PENDING',
              'idempotency_key': id,
              'created_at_utc': 1,
            });
          }
        }
        await old.close();
        final upgraded = await openDatabase(
          path,
          version: schemaVersion,
          onUpgrade: migrate,
        );
        addTearDown(upgraded.close);
        expect(await upgraded.getVersion(), greaterThan(oldVersion));
        expect(
          (await upgraded.rawQuery(
            'PRAGMA table_info(orders)',
          )).map((c) => c['name']),
          containsAll(['plant', 'work_center']),
        );
        expect(
          (await upgraded.query('assignments')).single['unit_of_measure'],
          'KG',
        );
        for (final table in ['production_records', 'recall_records']) {
          final rows = await upgraded.query(table, orderBy: 'id');
          expect(rows, hasLength(4));
          for (final row in rows) {
            expect(
              row['unit_of_measure'],
              row['id'] == '$table-ST' ? 'ST' : 'KG',
            );
            expect(row['idempotency_key'], row['id']);
            expect(row['quantity'], 0.1);
          }
        }
      },
    );
  }

  for (final preexisting in [false, true]) {
    test(
      'v3 -> v4 preserves QR data with preexisting columns: $preexisting',
      () async {
        final db = await openDatabase(inMemoryDatabasePath, version: 3);
        addTearDown(db.close);
        await db.execute(
          'CREATE TABLE employees (id TEXT PRIMARY KEY'
          '${preexisting ? ', valid_from TEXT' : ''})',
        );
        await db.execute(
          'CREATE TABLE orders (id TEXT PRIMARY KEY'
          '${preexisting ? ', operation_qr_payload TEXT' : ''})',
        );
        await db.insert('employees', {
          'id': 'worker-1',
          if (preexisting) 'valid_from': '2026-09-01',
        });
        await db.insert('orders', {
          'id': 'order-1',
          if (preexisting) 'operation_qr_payload': 'original-qr',
        });

        await migrate(db, 3, 4);
        // A device may already have every new column while user_version is 3.
        await migrate(db, 3, 4);

        final employee = (await db.query('employees')).single;
        expect(employee['id'], 'worker-1');
        expect(employee['valid_from'], preexisting ? '2026-09-01' : null);
        expect(employee.containsKey('valid_to'), isTrue);
        final order = (await db.query('orders')).single;
        expect(order['id'], 'order-1');
        expect(
          order['operation_qr_payload'],
          preexisting ? 'original-qr' : null,
        );
      },
    );
  }

  test(
    'v4 -> v5 adds operation context without losing the QR payload',
    () async {
      final db = await openDatabase(inMemoryDatabasePath, version: 4);
      await db.execute(
        'CREATE TABLE orders (id TEXT PRIMARY KEY, operation_qr_payload TEXT)',
      );
      await db.insert('orders', {
        'id': 'order-1',
        'operation_qr_payload': 'original-qr',
      });

      await migrate(db, 4, 5);

      final row = (await db.query('orders')).single;
      expect(row['operation_qr_payload'], 'original-qr');
      expect(row.containsKey('plant'), isTrue);
      expect(row.containsKey('work_center'), isTrue);
      await db.close();
    },
  );

  test('v7 -> v8 creates account-scoped local settings', () async {
    final db = await openDatabase(inMemoryDatabasePath, version: 7);
    addTearDown(db.close);

    await migrate(db, 7, 8);
    await db.insert('local_settings', {
      'setting_key': 'supervisor_setup:user-a',
      'setting_value': '{"ShiftID":"NIGHT"}',
      'updated_at_utc': 1,
    });

    final row = (await db.query('local_settings')).single;
    expect(row['setting_key'], 'supervisor_setup:user-a');
    expect(row['setting_value'], '{"ShiftID":"NIGHT"}');
  });
}

/// The three transaction tables exactly as `createSchema` shipped them at v5,
/// before the v6 migration added `unit_of_measure`. Frozen copies on purpose —
/// see [_ordersV1]. The test opens at the *current* schema (so the rest of the
/// database is real) and then rolls just these three back to their v4 shape.
const _transactionTablesV5 = [
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
