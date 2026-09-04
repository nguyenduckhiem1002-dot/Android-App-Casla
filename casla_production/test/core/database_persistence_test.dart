// Durability tests — the whole point of moving off the in-memory store.
//
// Every other test in the suite runs against `:memory:`, which cannot tell you
// whether a queued transaction actually reaches the disk. These open a real
// file, close it, and open it again — the same thing the OS does when a PDA
// runs out of battery mid-shift.

import 'dart:io';

import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/sync/verified_sync_coordinator.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/database_test_harness.dart';
import '../support/fake_sap_gateway.dart';

void main() {
  late Directory tempDir;

  setUpAll(initSqfliteFfi);

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('casla_db_test');
    CaslaDatabase.databasePathOverride = p.join(tempDir.path, 'casla.db');
  });

  tearDown(() async {
    await CaslaDatabase.instance.close();
    CaslaDatabase.databasePathOverride = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('a queued production record survives closing and reopening', () async {
    final first = CaslaDatabase.instance;
    final gateway = NoopSapGateway();
    final repo = ProductionRepositoryImpl(
      first,
      gateway: gateway,
      verifiedSync: VerifiedSyncCoordinator(database: first, gateway: gateway),
    );

    // asg-001 is seeded with 650 assigned and 436 already recorded.
    final receipt = await repo.recordProduction(
      assignmentId: 'asg-001',
      quantity: 30.0,
      businessDate: '2026-08-20',
      shiftId: 'SHIFT_1',
      createdBy: 'MNV00100',
    );

    // recordProduction's immediate push attempt hits NoopSapGateway, which
    // always throws — this item lands FAILED, not PENDING, same as any other
    // unrecognized gateway error would. It must still be on disk afterward,
    // whatever its status.
    final queueBefore = await first.watchSyncQueue().first;
    final itemBefore = queueBefore.firstWhere(
      (i) => i['entity_id'] == receipt.id,
    );
    expect(itemBefore['status'], 'FAILED');

    await first.close();

    final reopened = CaslaDatabase.instance;
    expect(identical(reopened, first), isFalse);

    expect(await reopened.getCompletedQuantity('asg-001'), 466.0);

    final queueAfter = await reopened.watchSyncQueue().first;
    final itemAfter = queueAfter.firstWhere(
      (i) => i['entity_id'] == receipt.id,
    );
    expect(itemAfter['status'], 'FAILED');
  });

  test('reopening does not re-run the demo seed', () async {
    final first = CaslaDatabase.instance;
    final seededEmployees = (await first.getAllEmployees()).length;
    final seededAssignments = (await first.watchAllAssignments().first).length;
    expect(seededEmployees, greaterThan(0));

    await first.close();

    final reopened = CaslaDatabase.instance;
    expect((await reopened.getAllEmployees()).length, seededEmployees);
    expect(
      (await reopened.watchAllAssignments().first).length,
      seededAssignments,
    );
  });

  test('a FAILED queue item keeps its diagnosis across a restart', () async {
    final first = CaslaDatabase.instance;
    await first.updateSyncQueueError(
      'sync-002',
      'HTTP_400',
      'Số lượng vượt quá phần còn lại.',
      failureKind: 'permanent',
    );
    await first.close();

    final reopened = CaslaDatabase.instance;
    final item = (await reopened.watchSyncFeed().first).firstWhere(
      (i) => i['id'] == 'sync-002',
    );

    expect(item['status'], 'FAILED');
    expect(item['last_error_code'], 'HTTP_400');
    expect(item['last_error_message'], 'Số lượng vượt quá phần còn lại.');
    expect(item['retry_count'], 1);
  });

  test('the schema rejects production against a missing assignment', () async {
    final db = CaslaDatabase.instance;

    // The foreign key is enforced, not decorative: an orphaned record would
    // silently drop out of every remaining-quantity calculation.
    await expectLater(
      db.insertProductionRecord({
        'id': 'prod-orphan',
        'phan_cong_id': 'asg-does-not-exist',
        'quantity': 10.0,
        'business_date': '2026-08-20',
        'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100',
        'occurred_at_utc': 1,
        'device_id': 'PDA-TEST',
        'sync_status': 'PENDING',
        'idempotency_key': 'idem-orphan',
        'created_at_utc': 1,
      }),
      throwsA(anything),
    );
  });
}
