import 'dart:async';

import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/history_work_context.dart';
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
  });
  tearDown(() => db.close());

  Map<String, dynamic> record(String id, String assignmentId, double qty) => {
    'id': id,
    'phan_cong_id': assignmentId,
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

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<List<Map<String, dynamic>>> ledger({String? shiftId = 'DAY'}) =>
      db.getLocalLedgerRows(
        teamIds: const ['XM2.002'],
        fromBusinessDate: '2026-01-05',
        toBusinessDate: '2026-01-05',
        shiftId: shiftId,
      );

  test(
    'ledger lists local writes in scope and skips history imports',
    () async {
      await db.insertAssignment({
        ...template,
        'id': 'real',
        'idempotency_key': 'real',
        'assigned_quantity': 50.0,
        'sync_status': 'PENDING',
      });
      await db.insertAssignment({
        ...template,
        'id': 'imported',
        'idempotency_key': 'history-import:x',
        'note': historyImportedAssignmentNote,
        'sync_status': 'SYNCED',
      });
      await db.insertAssignment({
        ...template,
        'id': 'other-shift',
        'idempotency_key': 'other-shift',
        'shift_id': 'NIGHT',
      });
      await db.insertProductionRecord(record('confirm', 'imported', 12));
      await db.insertProductionRecord({
        ...record('balance', 'imported', 99),
        'idempotency_key': 'history-balance:x',
      });

      final rows = await ledger();
      expect(
        rows.map((r) => '${r['kind']}:${r['quantity']}:${r['worker_code']}'),
        unorderedEquals(['ASSIGN:50.0:MNV00123', 'CONFIRM:12.0:MNV00123']),
      );
      expect(await ledger(shiftId: null), hasLength(3));
    },
  );

  test('ledger watcher re-emits when a confirmation is written', () async {
    await db.insertAssignment({
      ...template,
      'id': 'real',
      'idempotency_key': 'real',
    });
    final emissions = <int>[];
    final subscription = db
        .watchLocalLedgerRows(
          teamIds: const ['XM2.002'],
          fromBusinessDate: '2026-01-05',
          toBusinessDate: '2026-01-05',
          shiftId: 'DAY',
        )
        .listen((rows) => emissions.add(rows.length));
    await until(() => emissions.isNotEmpty);
    expect(emissions.first, 1);
    await db.insertProductionRecord(record('confirm', 'real', 3));
    await until(() => emissions.last == 2);
    await subscription.cancel();
  });

  test('invalidation makes an open watcher re-read SAP', () async {
    var calls = 0;
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => 'user-a:team',
      loadRemote:
          ({
            required range,
            dateFrom,
            dateTo,
            shiftId,
            productionOrder,
            operation,
          }) async {
            calls++;
            return WorkHistoryResult(
              scopeCode: 'T',
              dateFrom: DateTime(2026, 1, 5),
              dateTo: DateTime(2026, 1, 5),
              isTruncated: false,
              entries: const [],
              workers: [
                WorkHistorySummary(
                  workerId: 'MNV00123',
                  workerName: 'A',
                  assignedQuantity: 10,
                  completedQuantity: calls.toDouble(),
                  remainingQuantity: 10 - calls.toDouble(),
                  unitOfMeasure: 'PC',
                  transactionCount: calls,
                ),
              ],
            );
          },
    );
    addTearDown(repo.dispose);

    final seen = <double>[];
    final subscription = repo
        .watchWorkHistory(range: HistoryRange.day)
        .listen((r) => seen.add(r.workers.single.completedQuantity));
    await until(() => seen.isNotEmpty);
    expect(seen, [1]);

    await repo.invalidateCurrentSubject();
    await until(() => seen.length == 2);
    await subscription.cancel();
    expect(calls, 2);
    expect(seen, [1, 2]);
  });

  test('re-login of the same account reuses its offline snapshot', () async {
    var subject = '1@v4:acct-a:team';
    var online = true;
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => subject,
      isCacheSubjectCurrent: (candidate) => candidate == subject,
      loadRemote:
          ({
            required range,
            dateFrom,
            dateTo,
            shiftId,
            productionOrder,
            operation,
          }) async {
            if (!online) throw Exception('offline');
            return WorkHistoryResult(
              scopeCode: 'T',
              dateFrom: DateTime(2026, 1, 5),
              dateTo: DateTime(2026, 1, 5),
              isTruncated: false,
              entries: const [],
              workers: const [
                WorkHistorySummary(
                  workerId: 'MNV00123',
                  workerName: 'A',
                  assignedQuantity: 10,
                  completedQuantity: 4,
                  remainingQuantity: 6,
                  unitOfMeasure: 'PC',
                  transactionCount: 1,
                ),
              ],
            );
          },
    );
    addTearDown(repo.dispose);
    await repo.getWorkHistory(range: HistoryRange.day);

    // Logout + login bumps the lifetime; the device is offline now.
    subject = '3@v4:acct-a:team';
    online = false;
    final cached = await repo.getWorkHistory(range: HistoryRange.day);
    expect(cached.workers.single.completedQuantity, 4);

    // Another account never sees it.
    subject = '5@v4:acct-b:team';
    await expectLater(
      repo.getWorkHistory(range: HistoryRange.day),
      throwsA(anything),
    );
  });

  test(
    'a fresh report keeps the original allocation UUID of each row',
    () async {
      final repo = WorkHistoryRepositoryImpl(
        db,
        cacheSubject: () => 'user-a:team',
        loadRemote:
            ({
              required range,
              dateFrom,
              dateTo,
              shiftId,
              productionOrder,
              operation,
            }) async => WorkHistoryResult(
              scopeCode: 'T',
              dateFrom: DateTime(2026, 1, 5),
              dateTo: DateTime(2026, 1, 5),
              isTruncated: false,
              entries: [
                WorkHistoryEntry(
                  transactionUuid: 'confirm-15',
                  originalTransactionUuid: 'lot-100',
                  executionDate: DateTime(2026, 1, 5),
                  workerId: 'MNV00123',
                  workerName: 'A',
                  productionOrder: '010140000365',
                  operation: '0020',
                  plant: '6711',
                  workCenter: 'WC',
                  transactionType: 'CONFIRM',
                  quantity: 15,
                  unitOfMeasure: 'CHC',
                  transactionStatus: 'POSTED',
                ),
              ],
              workers: const [],
            ),
      );
      addTearDown(repo.dispose);
      final result = await repo.getWorkHistory(
        range: HistoryRange.day,
        forceRefresh: true,
      );
      expect(result.entries.single.originalTransactionUuid, 'lot-100');
    },
  );

  test('a held assignment deleted from Sync is removed for good', () async {
    await db.insertAssignment({
      ...template,
      'id': 'held',
      'idempotency_key': 'held',
      'assigned_quantity': 967.0,
      'sync_status': 'NEEDS_VERIFICATION',
    });
    await db.insertSyncQueueItem({
      'id': 'queue-held',
      'entity_type': 'ASSIGNMENT',
      'entity_id': 'held',
      'action': 'CREATE',
      'status': 'NEEDS_VERIFICATION',
      'created_at_utc': 1,
    });
    // A confirmation entered against it can never post without it.
    await db.insertProductionRecord(record('child', 'held', 5));
    await db.insertSyncQueueItem({
      'id': 'queue-child',
      'entity_type': 'PRODUCTION',
      'entity_id': 'child',
      'action': 'CREATE',
      'status': 'PENDING',
      'created_at_utc': 2,
    });
    Future<List<String>> byTeam() async => (await db.watchAssignmentsByTeams(
      const ['XM2.002'],
    ).first).map((row) => row['id'] as String).toList();
    Future<List<String>> byWorker() async =>
        (await db
                .watchAssignmentsByWorker(template['nhan_vien_id'] as String)
                .first)
            .map((row) => row['id'] as String)
            .toList();
    expect(await byTeam(), contains('held'));

    expect(await db.deleteSyncQueueItem('queue-held'), isTrue);
    expect(await db.getAssignmentById('held'), isNull);
    expect(await db.getSyncSourceRow('PRODUCTION', 'child'), isNull);
    final queueIds = (await db.watchSyncQueue().first).map((row) => row['id']);
    expect(queueIds, isNot(contains('queue-held')));
    expect(queueIds, isNot(contains('queue-child')));
    expect(await byTeam(), isNot(contains('held')));
    expect(await byWorker(), isNot(contains('held')));
    expect(
      await db.getLocalLedgerRows(
        teamIds: const ['XM2.002'],
        fromBusinessDate: '2026-01-05',
        toBusinessDate: '2026-01-05',
      ),
      isEmpty,
    );
  });

  test('storage namespace drops only the lifetime prefix', () {
    expect(WorkHistoryRepositoryImpl.storageNamespace('7@v4:x'), 'v4:x');
    expect(
      WorkHistoryRepositoryImpl.storageNamespace('user-a:self'),
      'user-a:self',
    );
  });

  test('SAP acknowledging a queued write ticks remotePostings', () async {
    final ticks = Completer<void>();
    final subscription = db.remotePostings.listen((_) => ticks.complete());
    await db.markSyncItemSynced(
      'missing-queue-item',
      entityType: 'PRODUCTION',
      entityId: 'missing',
      sapId: 'sap',
    );
    await ticks.future.timeout(const Duration(seconds: 1));
    await subscription.cancel();
  });
}
