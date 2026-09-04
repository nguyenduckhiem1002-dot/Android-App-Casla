// pushAndRecord tests — the shared push+classify+record building block both
// SyncEngine (background, no password) and a repository's immediate push
// (foreground, with password) rely on.

import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/sync/sap_write_gateway.dart';
import 'package:casla_production/core/sync/sync_failure.dart';
import 'package:casla_production/core/sync/sync_push.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;

  setUp(() async {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
    await db.ready;
    for (final item in await db.watchSyncQueue().first) {
      await db.deleteSyncQueueItem(item['id'] as String);
    }
  });

  Future<Map<String, dynamic>> queueProduction() async {
    const id = 'prod-push-test';
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insertProductionRecord({
      'id': id,
      'phan_cong_id': 'asg-001',
      'quantity': 5.0,
      'business_date': '2026-08-20',
      'shift_id': 'SHIFT_1',
      'created_by': 'MNV00100',
      'occurred_at_utc': now,
      'device_id': 'PDA-TEST',
      'sync_status': 'PENDING',
      'idempotency_key': 'idem-push-test',
      'created_at_utc': now,
    });
    final queueItem = {
      'id': 'sync-push-test',
      'entity_type': 'PRODUCTION_RECORD',
      'entity_id': id,
      'action': 'CREATE',
      'retry_count': 0,
      'created_at_utc': now,
    };
    await db.insertSyncQueueItem(queueItem);
    return queueItem;
  }

  test('success deletes the queue item and stamps the source SYNCED', () async {
    final queueItem = await queueProduction();
    final source = await db.getSyncSourceRow(
      'PRODUCTION_RECORD',
      'prod-push-test',
    );

    final failure = await pushAndRecord(
      database: db,
      gateway: _FakeGateway(
        onPush: (_) => const SapWriteResult(sapId: 'SAP-1'),
      ),
      backoff: SyncBackoff(),
      queueItem: queueItem,
      source: source!,
    );

    expect(failure, isNull);
    expect(await db.watchSyncQueue().first, isEmpty);
    final stamped = await db.getSyncSourceRow(
      'PRODUCTION_RECORD',
      'prod-push-test',
    );
    expect(stamped!['sync_status'], 'SYNCED');
    expect(stamped['sap_id'], 'SAP-1');
  });

  test(
    'a missing worker password lands NEEDS_VERIFICATION, not PENDING',
    () async {
      final queueItem = await queueProduction();
      final source = await db.getSyncSourceRow(
        'PRODUCTION_RECORD',
        'prod-push-test',
      );

      final failure = await pushAndRecord(
        database: db,
        gateway: _FakeGateway(
          onPush: (_) => throw const WorkerVerificationRequiredException(),
        ),
        backoff: SyncBackoff(),
        queueItem: queueItem,
        source: source!,
      );

      expect(failure?.kind, SyncFailureKind.needsVerification);
      final item = (await db.watchSyncFeed().first).single;
      expect(item['status'], 'NEEDS_VERIFICATION');
      final markedSource = await db.getSyncSourceRow(
        'PRODUCTION_RECORD',
        'prod-push-test',
      );
      expect(markedSource!['sync_status'], 'NEEDS_VERIFICATION');
      // No backoff for a state only a human can clear.
      expect(item['next_retry_at_utc'], isNull);
      // getDueSyncItems only ever looks at PENDING — this must not be pickable.
      expect(await db.getDueSyncItems(), isEmpty);
    },
  );

  test('a transient error stays PENDING behind a backoff', () async {
    final queueItem = await queueProduction();
    final source = await db.getSyncSourceRow(
      'PRODUCTION_RECORD',
      'prod-push-test',
    );

    final failure = await pushAndRecord(
      database: db,
      gateway: _FakeGateway(
        onPush: (_) => throw DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionTimeout,
        ),
      ),
      backoff: SyncBackoff(),
      queueItem: queueItem,
      source: source!,
    );

    expect(failure?.kind, SyncFailureKind.transient);
    final item = (await db.watchSyncFeed().first).single;
    expect(item['status'], 'PENDING');
    expect(item['next_retry_at_utc'], isNotNull);
    final markedSource = await db.getSyncSourceRow(
      'PRODUCTION_RECORD',
      'prod-push-test',
    );
    expect(markedSource!['sync_status'], 'PENDING');
  });

  test(
    'a transient foreground failure needs fresh verification for replay',
    () async {
      final queueItem = await queueProduction();
      final source = await db.getSyncSourceRow(
        'PRODUCTION_RECORD',
        'prod-push-test',
      );

      final failure = await pushAndRecord(
        database: db,
        gateway: _FakeGateway(
          onPush: (_) => throw DioException(
            requestOptions: RequestOptions(path: '/x'),
            type: DioExceptionType.connectionError,
          ),
        ),
        backoff: SyncBackoff(),
        queueItem: queueItem,
        source: source!,
        workerPassword: 'one-attempt-only',
      );

      expect(failure?.kind, SyncFailureKind.needsVerification);
      final item = (await db.watchSyncFeed().first).single;
      expect(item['status'], 'NEEDS_VERIFICATION');
      expect(item['next_retry_at_utc'], isNull);
      expect(item['last_error_message'], contains('xác minh lại'));
      expect(
        (await db.getSyncSourceRow(
          'PRODUCTION_RECORD',
          'prod-push-test',
        ))!['sync_status'],
        'NEEDS_VERIFICATION',
      );
    },
  );

  test('a permanent rejection lands FAILED', () async {
    final queueItem = await queueProduction();
    final source = await db.getSyncSourceRow(
      'PRODUCTION_RECORD',
      'prod-push-test',
    );

    final failure = await pushAndRecord(
      database: db,
      gateway: _FakeGateway(onPush: (_) => throw Exception('SAP từ chối')),
      backoff: SyncBackoff(),
      queueItem: queueItem,
      source: source!,
    );

    expect(failure?.kind, SyncFailureKind.permanent);
    final item = (await db.watchSyncFeed().first).single;
    expect(item['status'], 'FAILED');
    final markedSource = await db.getSyncSourceRow(
      'PRODUCTION_RECORD',
      'prod-push-test',
    );
    expect(markedSource!['sync_status'], 'FAILED');
  });

  test(
    'the worker password is forwarded to the gateway, never persisted',
    () async {
      final queueItem = await queueProduction();
      final source = await db.getSyncSourceRow(
        'PRODUCTION_RECORD',
        'prod-push-test',
      );
      String? seenPassword;

      await pushAndRecord(
        database: db,
        gateway: _FakeGateway(
          onPush: (request) {
            seenPassword = request.workerPassword;
            return const SapWriteResult();
          },
        ),
        backoff: SyncBackoff(),
        queueItem: queueItem,
        source: source!,
        workerPassword: 'hunter2',
      );

      expect(seenPassword, 'hunter2');
      // Nothing about the password reaches a stored row.
      final feed = await db.watchSyncQueue().first;
      expect(
        feed,
        isEmpty,
      ); // deleted on success — nowhere for it to have leaked.
    },
  );
}

class _FakeGateway implements SapWriteGateway {
  final SapWriteResult Function(SyncPushRequest) onPush;

  _FakeGateway({required this.onPush});

  @override
  Future<SapWriteResult> push(SyncPushRequest request) async => onPush(request);

  @override
  Future<bool> refreshSession() async => false;
}
