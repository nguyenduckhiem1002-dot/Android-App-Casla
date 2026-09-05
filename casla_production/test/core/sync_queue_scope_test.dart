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

  Future<void> addAssignment({
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

  test('a scoped supervisor cannot view or drain another account queue',
      () async {
    await addAssignment(
      assignmentId: 'assignment-owned',
      queueId: 'queue-owned',
      actor: 'SUPERVISOR-A',
      teamId: 'team-a',
    );
    await addAssignment(
      assignmentId: 'assignment-other',
      queueId: 'queue-other',
      actor: 'SUPERVISOR-B',
      teamId: 'team-b',
    );

    final visible = await db
        .watchSyncFeed(actorId: 'SUPERVISOR-A', teamIds: ['team-a'])
        .first;
    final due = await db.getDueSyncItems(
      actorId: 'SUPERVISOR-A',
      teamIds: ['team-a'],
    );

    expect(visible.map((item) => item['id']), contains('queue-owned'));
    expect(visible.map((item) => item['id']), isNot(contains('queue-other')));
    expect(due.map((item) => item['id']), contains('queue-owned'));
    expect(due.map((item) => item['id']), isNot(contains('queue-other')));
    expect(
      await db.isSyncQueueItemInScope(
        'queue-other',
        actorId: 'SUPERVISOR-A',
        teamIds: ['team-a'],
      ),
      isFalse,
    );
  });
}
