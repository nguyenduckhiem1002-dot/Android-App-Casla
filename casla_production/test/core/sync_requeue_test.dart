import 'package:casla_production/core/database/casla_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;

  setUp(() {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
  });

  Future<void> addQueuedAssignment({
    required String assignmentId,
    required String queueId,
    required String actor,
    required String teamId,
  }) {
    return db.createAssignmentAtomically(
      assignment: {
        'id': assignmentId,
        'nhan_vien_id': 'emp-1',
        'don_hang_id': 'ord-1',
        'to_id': teamId,
        'assigned_quantity': 10.0,
        'business_date': '2026-09-05',
        'shift_id': 'SHIFT_1',
        'status': 'OPEN',
        'created_by': actor,
        'occurred_at_utc': 1,
        'device_id': 'TEST',
        'sync_status': 'PENDING',
        'idempotency_key': 'idem-$assignmentId',
        'created_at_utc': 1,
      },
      queueItem: {
        'id': queueId,
        'entity_type': 'ASSIGNMENT',
        'entity_id': assignmentId,
        'action': 'CREATE',
        'idempotency_key': 'idem-$assignmentId',
        'priority': 1,
        'retry_count': 0,
        'created_at_utc': 1,
      },
      auditLog: {'id': 'audit-$assignmentId', 'occurred_at_utc': 1},
    );
  }

  /// Leaves an item exactly as a failed push attempt would: parked behind a
  /// backoff the engine will not revisit for minutes.
  Future<void> parkOnBackoff(
    String queueId, {
    required String status,
    Duration wait = const Duration(minutes: 12),
  }) {
    return db.updateSyncQueueError(
      queueId,
      'ERR_TEST',
      'SAP tạm thời không phản hồi',
      status: status,
      nextRetryAtUtc: DateTime.now().add(wait).millisecondsSinceEpoch,
    );
  }

  Future<Map<String, dynamic>> queueItem(String queueId) async {
    final row = await db.getSyncQueueItemById(queueId);
    expect(row, isNotNull, reason: 'queue item $queueId should exist');
    return row!;
  }

  /// What the engine would actually pick up on its next pass.
  Future<List<String>> dueNow(String actor, String team) async {
    final items = await db.getDueSyncItems(
      actorId: actor,
      teamIds: [team],
    );
    return items.map((item) => item['id'] as String).toList();
  }

  test('a failed item is requeued and becomes claimable', () async {
    await addQueuedAssignment(
      assignmentId: 'a-1',
      queueId: 'q-1',
      actor: 'SUP-A',
      teamId: 'team-a',
    );
    await parkOnBackoff('q-1', status: 'FAILED');
    expect(await dueNow('SUP-A', 'team-a'), isEmpty);

    final requeued = await db.requeueForImmediateRetry(
      actorId: 'SUP-A',
      teamIds: const ['team-a'],
    );

    expect(requeued, 1);
    // Clearing the backoff alone would not have been enough: the engine only
    // ever claims PENDING work, so a FAILED row had to go back to PENDING for
    // the button to mean anything.
    expect((await queueItem('q-1'))['status'], 'PENDING');
    expect((await queueItem('q-1'))['next_retry_at_utc'], isNull);
    expect(await dueNow('SUP-A', 'team-a'), ['q-1']);
  });

  test('a pending item waiting out a backoff is released', () async {
    await addQueuedAssignment(
      assignmentId: 'a-2',
      queueId: 'q-2',
      actor: 'SUP-A',
      teamId: 'team-a',
    );
    await parkOnBackoff('q-2', status: 'PENDING');
    expect(await dueNow('SUP-A', 'team-a'), isEmpty);

    expect(
      await db.requeueForImmediateRetry(
        actorId: 'SUP-A',
        teamIds: const ['team-a'],
      ),
      1,
    );
    expect(await dueNow('SUP-A', 'team-a'), ['q-2']);
  });

  test('an item awaiting a worker password is left alone', () async {
    await addQueuedAssignment(
      assignmentId: 'a-3',
      queueId: 'q-3',
      actor: 'SUP-A',
      teamId: 'team-a',
    );
    await parkOnBackoff('q-3', status: 'NEEDS_VERIFICATION');

    // Nothing can move without the worker re-entering their password, so
    // requeueing this would only burn an attempt against SAP.
    expect(
      await db.requeueForImmediateRetry(
        actorId: 'SUP-A',
        teamIds: const ['team-a'],
      ),
      0,
    );
    expect((await queueItem('q-3'))['status'], 'NEEDS_VERIFICATION');
    expect((await queueItem('q-3'))['next_retry_at_utc'], isNotNull);
  });

  test('another account queue is never touched', () async {
    await addQueuedAssignment(
      assignmentId: 'a-mine',
      queueId: 'q-mine',
      actor: 'SUP-A',
      teamId: 'team-a',
    );
    await addQueuedAssignment(
      assignmentId: 'a-theirs',
      queueId: 'q-theirs',
      actor: 'SUP-B',
      teamId: 'team-b',
    );
    await parkOnBackoff('q-mine', status: 'FAILED');
    await parkOnBackoff('q-theirs', status: 'FAILED');

    expect(
      await db.requeueForImmediateRetry(
        actorId: 'SUP-A',
        teamIds: const ['team-a'],
      ),
      1,
    );
    expect(await dueNow('SUP-A', 'team-a'), ['q-mine']);
    expect(await dueNow('SUP-B', 'team-b'), isEmpty);
  });

  test('an account with no usable scope requeues nothing', () async {
    await addQueuedAssignment(
      assignmentId: 'a-4',
      queueId: 'q-4',
      actor: 'SUP-A',
      teamId: 'team-a',
    );
    await parkOnBackoff('q-4', status: 'FAILED');

    expect(
      await db.requeueForImmediateRetry(actorId: '', teamIds: const []),
      0,
    );
    expect((await queueItem('q-4'))['status'], 'FAILED');
  });

  test('an empty queue reports nothing requeued', () async {
    expect(
      await db.requeueForImmediateRetry(
        actorId: 'SUP-A',
        teamIds: const ['team-a'],
      ),
      0,
    );
  });
}
