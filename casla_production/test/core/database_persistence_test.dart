import 'package:casla_production/core/utils/operation_qr_parser.dart';
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
import 'package:casla_production/domain/policies/history_work_context.dart';
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

    // A permanent SAP rejection remains auditable on disk, but must not count
    // toward the assignment's usable completion balance.
    expect(await reopened.getCompletedQuantity('asg-001'), 436.0);

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

  test(
    'operation reconciliation excludes SAP identities and failed rows',
    () async {
      final db = CaslaDatabase.instance;
      final order = await db.upsertOrderFromOperationQr(
        OperationQrParser.parse(
          '{"lenh_san_xuat":"ORDER-RECON","cong_doan":"0010","sl_cong_doan":"1000"}',
        ),
      );
      final original = (await db.getAssignmentById('asg-001'))!;
      for (final row in [
        ('pending', 'PENDING', null, 50.0),
        ('syncing', 'SYNCING', null, 20.0),
        ('verify', 'NEEDS_VERIFICATION', null, 10.0),
        ('known', 'SYNCED', 'sap-known', 100.0),
        ('lagging', 'SYNCED', 'sap-lagging', 30.0),
        ('failed', 'FAILED', null, 999.0),
      ]) {
        await db.insertAssignment({
          ...original,
          'id': row.$1,
          'don_hang_id': order!['id'],
          'assigned_quantity': row.$4,
          'sync_status': row.$2,
          'sap_id': row.$3,
          'idempotency_key': 'recon-${row.$1}',
        });
      }
      final pending = await db.getPendingOperationQuantitySummary(
        productionOrder: 'ORDER-RECON',
        operation: '0010',
      );
      expect(pending['assignedDelta'], 80.0);
      final merged = await db.getPendingOperationQuantitySummary(
        productionOrder: 'ORDER-RECON',
        operation: '0010',
        representedTransactionIds: {'sap-known'},
        includeSyncedMissingFromHistory: true,
      );
      expect(merged['assignedDelta'], 110.0);
      final caughtUp = await db.getPendingOperationQuantitySummary(
        productionOrder: 'ORDER-RECON',
        operation: '0010',
        representedTransactionIds: {'sap-known', 'sap-lagging'},
        includeSyncedMissingFromHistory: true,
      );
      expect(caughtUp['assignedDelta'], 80.0);
      expect(
        await db.getPendingOperationQuantitySummary(
          productionOrder: 'ORDER-RECON',
          operation: '0020',
        ),
        containsPair('assignedDelta', 0.0),
      );
    },
  );

  test(
    'pending operation summary skips SAP history imports and other days',
    () async {
      final db = CaslaDatabase.instance;
      final order = await db.upsertOrderFromOperationQr(
        OperationQrParser.parse(
          '{"lenh_san_xuat":"ORDER-SCOPE","cong_doan":"0010","sl_cong_doan":"1000"}',
        ),
      );
      final original = (await db.getAssignmentById('asg-001'))!;
      Future<void> assign(
        String id,
        double quantity, {
        String status = 'SYNCED',
        String? sapId,
        String date = '2026-09-22',
        String shift = 'DAY',
        String? note,
        String? key,
      }) => db.insertAssignment({
        ...original,
        'id': id,
        'don_hang_id': order!['id'],
        'assigned_quantity': quantity,
        'sync_status': status,
        'sap_id': sapId,
        'business_date': date,
        'shift_id': shift,
        'note': note,
        'idempotency_key': key ?? 'scope-$id',
      });
      // Posted today; SAP reports it with a dashed, lower-case UUID.
      await assign('today', 100, sapId: 'AABBCCDD11223344AABBCCDD11223344');
      // A copy of SAP's own row made while opening a confirmation.
      await assign(
        'imported',
        500,
        sapId: 'IMPORTED-UUID',
        note: historyImportedAssignmentNote,
        key: 'history-import:x',
      );
      // Posted yesterday: outside a report of today.
      await assign(
        'yesterday',
        70,
        sapId: 'YESTERDAY-UUID',
        date: '2026-09-21',
      );
      await assign('queued', 5, status: 'PENDING');

      final summary = await db.getPendingOperationQuantitySummary(
        productionOrder: 'ORDER-SCOPE',
        operation: '0010',
        businessDate: '2026-09-22',
        shiftId: 'DAY',
        representedTransactionIds: {'aabbccdd-1122-3344-aabb-ccdd11223344'},
        includeSyncedMissingFromHistory: true,
      );
      expect(summary['assignedDelta'], 5.0);

      // With SAP's live balance only the queued write may be added.
      final live = await db.getPendingOperationQuantitySummary(
        productionOrder: 'ORDER-SCOPE',
        operation: '0010',
      );
      expect(live['assignedDelta'], 5.0);
    },
  );

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

  test(
    'operation quantity summary includes assignments from earlier dates',
    () async {
      final db = CaslaDatabase.instance;
      final original = (await db.getAssignmentById('asg-001'))!;
      await db.createAssignmentAtomically(
        assignment: {
          ...original,
          'id': 'asg-earlier',
          'business_date': '2020-01-01',
          'assigned_quantity': 200.0,
          'idempotency_key': 'earlier-assignment',
        },
        queueItem: {
          'id': 'sync-earlier',
          'entity_type': 'ASSIGNMENT',
          'entity_id': 'asg-earlier',
          'action': 'CREATE',
          'idempotency_key': 'earlier-assignment',
          'priority': 1,
          'retry_count': 0,
          'created_at_utc': 1,
        },
        auditLog: {'id': 'audit-earlier', 'occurred_at_utc': 1},
      );
      final summary = await db.getOperationQuantitySummary(orderId: 'ord-1');

      // 650 from the current day + 200 from an earlier day. Failed
      // assignments and other operations are excluded from the total.
      expect(summary['operationQuantity'], 1000.0);
      expect(summary['confirmedQuantity'], 436.0);
      expect(summary['assignedQuantity'], 850.0);
      expect(summary['remaining'], 150.0);
    },
  );

  test(
    'production history keeps operation keys for grouped confirmations',
    () async {
      final db = CaslaDatabase.instance;
      final today = DateTime.now().toIso8601String().substring(0, 10);

      final rows = await db.getProductionHistory(
        'emp-1',
        fromBusinessDate: today,
        toBusinessDate: today,
      );
      final row = rows.singleWhere((value) => value['id'] == 'prod-001');
      expect(row['production_order'], '000010001234');
      expect(row['operation'], '0010');
    },
  );

  test('database watchers can be cancelled and attached again', () async {
    final db = CaslaDatabase.instance;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final stream = db.watchProductionHistory(
      'emp-1',
      fromBusinessDate: today,
      toBusinessDate: today,
    );

    expect(await stream.first, isNotEmpty);
    expect(await stream.first, isNotEmpty);
  });
}
