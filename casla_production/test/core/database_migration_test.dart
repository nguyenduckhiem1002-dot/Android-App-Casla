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

  test('a fresh install already has the v2 columns', () async {
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

    await db.close();
  });
}

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
