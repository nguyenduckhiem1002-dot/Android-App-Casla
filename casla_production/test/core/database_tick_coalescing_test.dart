// One write usually notifies several tables back to back. A watcher that
// listens to more than one of them must re-run its query once for that write,
// not once per table: on a PDA every extra run is a UNION over the transaction
// tables on the single SQLite thread.

import 'dart:async';

import 'package:casla_production/core/database/casla_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;
  late Map<String, dynamic> template;

  setUp(() async {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
    template = {
      ...(await db.getAssignmentById('asg-001'))!,
      'to_id': 'XM2.002',
      'business_date': '2026-01-05',
      'shift_id': 'DAY',
      'sap_id': null,
    };
    await db.insertAssignment({
      ...template,
      'id': 'real',
      'idempotency_key': 'real',
    });
  });
  tearDown(() => db.close());

  Map<String, dynamic> record(String id, double qty) => {
    'id': id,
    'phan_cong_id': 'real',
    'quantity': qty,
    'business_date': '2026-01-05',
    'shift_id': 'DAY',
    'created_by': 'test',
    'occurred_at_utc': 1,
    'device_id': 'test',
    'sync_status': 'PENDING',
    'idempotency_key': id,
    'created_at_utc': 1,
  };

  Stream<List<Map<String, dynamic>>> watchLedger() => db.watchLocalLedgerRows(
    teamIds: const ['XM2.002'],
    fromBusinessDate: '2026-01-05',
    toBusinessDate: '2026-01-05',
    shiftId: 'DAY',
  );

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Long enough for any query still queued behind a tick to finish.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 250));

  test('a write that notifies two tables re-runs the ledger once', () async {
    final emissions = <int>[];
    final subscription = watchLedger().listen(
      (rows) => emissions.add(rows.length),
    );
    await until(() => emissions.isNotEmpty);
    expect(emissions, [1]);

    // insertProductionRecord notifies production and assignments.
    await db.insertProductionRecord(record('confirm-1', 3));
    await until(() => emissions.length >= 2);
    await settle();

    expect(emissions, [1, 2]);
    await subscription.cancel();
  });

  test('a queue write that notifies every table re-runs it once', () async {
    await db.insertProductionRecord(record('confirm-1', 3));
    await db.insertSyncQueueItem({
      'id': 'queue-1',
      'entity_type': 'PRODUCTION',
      'entity_id': 'confirm-1',
      'action': 'CREATE',
      'created_at_utc': 1,
      'status': 'PENDING',
    });
    final emissions = <int>[];
    final subscription = watchLedger().listen(
      (rows) => emissions.add(rows.length),
    );
    await until(() => emissions.isNotEmpty);
    await settle();
    expect(emissions, [2]);

    // A row turning SYNCED notifies the queue and all three ledger tables.
    await db.markSyncItemSynced(
      'queue-1',
      entityType: 'PRODUCTION',
      entityId: 'confirm-1',
      sapId: 'SAP-1',
    );
    await until(() => emissions.length >= 2);
    await settle();

    expect(emissions, [2, 2]);
    await subscription.cancel();
  });

  test('separate writes still each reach the watcher', () async {
    final emissions = <int>[];
    final subscription = watchLedger().listen(
      (rows) => emissions.add(rows.length),
    );
    await until(() => emissions.isNotEmpty);

    for (var index = 1; index <= 5; index++) {
      await db.insertProductionRecord(record('confirm-$index', 1));
      await until(() => emissions.last == index + 1);
    }
    await settle();

    // One snapshot per write, in order, and nothing after the last one.
    expect(emissions, [1, 2, 3, 4, 5, 6]);
    await subscription.cancel();
  });

  test('writes fired without awaiting still end on the latest rows', () async {
    final emissions = <int>[];
    final subscription = watchLedger().listen(
      (rows) => emissions.add(rows.length),
    );
    await until(() => emissions.isNotEmpty);

    await Future.wait([
      for (var index = 1; index <= 8; index++)
        db.insertProductionRecord(record('burst-$index', 1)),
    ]);
    await until(() => emissions.last == 9);
    await settle();

    expect(emissions.last, 9);
    // Never more re-runs than writes, and never a snapshot going backwards.
    expect(emissions.length, lessThanOrEqualTo(9));
    expect(emissions, orderedEquals([...emissions]..sort()));
    await subscription.cancel();
  });

  test('a watcher of one table still hears every write to it', () async {
    final seen = <int>[];
    final subscription = db
        .watchSyncFeedPage(
          actorId: 'test',
          teamIds: const ['XM2.002'],
          filter: SyncFeedFilter.all,
        )
        .listen((page) => seen.add(page.items.length));
    await until(() => seen.isNotEmpty);
    expect(seen, [0]);

    await db.insertProductionRecord(record('confirm-1', 3));
    await db.insertSyncQueueItem({
      'id': 'queue-1',
      'entity_type': 'PRODUCTION',
      'entity_id': 'confirm-1',
      'action': 'CREATE',
      'created_at_utc': 1,
      'status': 'PENDING',
    });
    await until(() => seen.last == 1);
    await settle();

    expect(seen, [0, 1]);
    await subscription.cancel();
  });

  test('a cancelled watcher does not hold up later writes', () async {
    final first = watchLedger().listen((_) {});
    await db.insertProductionRecord(record('confirm-1', 3));
    await first.cancel();

    final emissions = <int>[];
    final second = watchLedger().listen((rows) => emissions.add(rows.length));
    await until(() => emissions.isNotEmpty);
    expect(emissions.first, 2);
    await db.insertProductionRecord(record('confirm-2', 3));
    await until(() => emissions.last == 3);
    await second.cancel();
  });

  test('closing the database with a notification pending is quiet', () async {
    final subscription = watchLedger().listen((_) {});
    // No await between the write completing and close(): the coalesced tick
    // is still pending when the controllers shut.
    final write = db.insertProductionRecord(record('confirm-1', 3));
    await write;
    await subscription.cancel();
    await db.close();
    await settle();
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
  });
}
