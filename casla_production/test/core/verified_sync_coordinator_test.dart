import 'dart:async';

import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/sync/sap_write_gateway.dart';
import 'package:casla_production/core/sync/sync_access_scope.dart';
import 'package:casla_production/core/sync/verified_sync_coordinator.dart';
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

  Future<({String assignmentQueueId, String productionQueueId})>
  seedWorkerChain({String suffix = 'chain'}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final assignmentId = 'asg-$suffix';
    final productionId = 'prod-$suffix';
    final assignmentQueueId = 'sync-asg-$suffix';
    final productionQueueId = 'sync-prod-$suffix';

    await db.insertAssignment({
      'id': assignmentId,
      'nhan_vien_id': 'emp-1',
      'don_hang_id': 'ord-1',
      'to_id': 'team-2',
      'assigned_quantity': 25.0,
      'business_date': '2026-09-05',
      'shift_id': 'SHIFT_1',
      'status': 'OPEN',
      'created_by': 'MNV00100',
      'occurred_at_utc': now,
      'device_id': 'PDA-TEST',
      'sync_status': 'PENDING',
      'idempotency_key': 'idem-asg-$suffix',
      'created_at_utc': now,
    });
    await db.insertSyncQueueItem({
      'id': assignmentQueueId,
      'entity_type': 'ASSIGNMENT',
      'entity_id': assignmentId,
      'action': 'CREATE',
      'status': 'PENDING',
      'retry_count': 0,
      'created_at_utc': now,
    });

    await db.insertProductionRecord({
      'id': productionId,
      'phan_cong_id': assignmentId,
      'quantity': 5.0,
      'business_date': '2026-09-05',
      'shift_id': 'SHIFT_1',
      'created_by': 'MNV00100',
      'occurred_at_utc': now + 1,
      'device_id': 'PDA-TEST',
      'sync_status': 'PENDING',
      'idempotency_key': 'idem-prod-$suffix',
      'created_at_utc': now + 1,
    });
    await db.insertSyncQueueItem({
      'id': productionQueueId,
      'entity_type': 'PRODUCTION_RECORD',
      'entity_id': productionId,
      'action': 'CREATE',
      'status': 'PENDING',
      'retry_count': 0,
      'created_at_utc': now + 1,
    });

    return (
      assignmentQueueId: assignmentQueueId,
      productionQueueId: productionQueueId,
    );
  }

  DioException authFailure() => DioException(
    requestOptions: RequestOptions(path: '/sync'),
    type: DioExceptionType.badResponse,
    response: Response<void>(
      requestOptions: RequestOptions(path: '/sync'),
      statusCode: 401,
    ),
  );

  test(
    'pushes assignment before descendants with the same fresh password',
    () async {
      final chain = await seedWorkerChain();
      final calls = <SyncPushRequest>[];
      final gateway = _RecordingGateway(
        onPush: (request) async {
          calls.add(request);
          return SapWriteResult(sapId: 'SAP-${request.entityId}');
        },
      );

      final report =
          await VerifiedSyncCoordinator(
            database: db,
            gateway: gateway,
          ).syncVerifiedWorkerChain(
            anchorQueueItemId: chain.productionQueueId,
            workerPassword: 'fresh-password',
          );

      expect(report.outcome, VerifiedSyncOutcome.synced);
      expect(report.syncedCount, 2);
      expect(calls.map((request) => request.entityType), [
        'ASSIGNMENT',
        'PRODUCTION_RECORD',
      ]);
      expect(
        calls.every((request) => request.workerPassword == 'fresh-password'),
        isTrue,
      );
      expect(await db.watchSyncQueue().first, isEmpty);
    },
  );

  test('refreshes once after auth failure then resumes the chain', () async {
    final chain = await seedWorkerChain(suffix: 'refresh');
    var assignmentAttempts = 0;
    final calls = <String>[];
    final gateway = _RecordingGateway(
      refreshResult: true,
      onPush: (request) async {
        calls.add(request.entityType);
        if (request.entityType == 'ASSIGNMENT' && assignmentAttempts++ == 0) {
          throw authFailure();
        }
        return SapWriteResult(sapId: 'SAP-${request.entityId}');
      },
    );

    final report = await VerifiedSyncCoordinator(database: db, gateway: gateway)
        .syncVerifiedWorkerChain(
          anchorQueueItemId: chain.assignmentQueueId,
          workerPassword: 'fresh-password',
        );

    expect(report.outcome, VerifiedSyncOutcome.synced);
    expect(gateway.refreshCalls, 1);
    expect(calls, ['ASSIGNMENT', 'ASSIGNMENT', 'PRODUCTION_RECORD']);
    expect(await db.watchSyncQueue().first, isEmpty);
  });

  test('stops descendants when auth still fails after one refresh', () async {
    final chain = await seedWorkerChain(suffix: 'auth-stop');
    final calls = <String>[];
    final gateway = _RecordingGateway(
      refreshResult: true,
      onPush: (request) async {
        calls.add(request.entityType);
        throw authFailure();
      },
    );

    final report = await VerifiedSyncCoordinator(database: db, gateway: gateway)
        .syncVerifiedWorkerChain(
          anchorQueueItemId: chain.productionQueueId,
          workerPassword: 'fresh-password',
        );

    expect(report.outcome, VerifiedSyncOutcome.queued);
    expect(report.syncedCount, 0);
    expect(gateway.refreshCalls, 1);
    expect(calls, ['ASSIGNMENT', 'ASSIGNMENT']);
    expect(await db.getSyncQueueItemById(chain.productionQueueId), isNotNull);
  });

  test('permanent parent rejection prevents descendant push', () async {
    final chain = await seedWorkerChain(suffix: 'reject-stop');
    final calls = <String>[];
    final gateway = _RecordingGateway(
      onPush: (request) async {
        calls.add(request.entityType);
        if (request.entityType == 'ASSIGNMENT') {
          throw Exception('SAP rejected assignment');
        }
        return const SapWriteResult();
      },
    );

    final report = await VerifiedSyncCoordinator(database: db, gateway: gateway)
        .syncVerifiedWorkerChain(
          anchorQueueItemId: chain.assignmentQueueId,
          workerPassword: 'fresh-password',
        );

    expect(report.outcome, VerifiedSyncOutcome.rejected);
    expect(calls, ['ASSIGNMENT']);
    expect(await db.getSyncQueueItemById(chain.productionQueueId), isNotNull);
  });

  test('blocks a second concurrent chain for the same worker', () async {
    final chain = await seedWorkerChain(suffix: 'concurrent');
    final enteredPush = Completer<void>();
    final releasePush = Completer<void>();
    final gateway = _RecordingGateway(
      onPush: (request) async {
        if (!enteredPush.isCompleted) enteredPush.complete();
        await releasePush.future;
        return SapWriteResult(sapId: 'SAP-${request.entityId}');
      },
    );
    final coordinator = VerifiedSyncCoordinator(database: db, gateway: gateway);

    final first = coordinator.syncVerifiedWorkerChain(
      anchorQueueItemId: chain.assignmentQueueId,
      workerPassword: 'fresh-password',
    );
    await enteredPush.future;

    final second = await coordinator.syncVerifiedWorkerChain(
      anchorQueueItemId: chain.productionQueueId,
      workerPassword: 'fresh-password',
    );

    expect(second.outcome, VerifiedSyncOutcome.blocked);
    expect(second.message, contains('đang được đồng bộ'));

    releasePush.complete();
    expect((await first).outcome, VerifiedSyncOutcome.synced);
  });

  test(
    'same-account relogin stops descendants of an old verification',
    () async {
      final chain = await seedWorkerChain(suffix: 'relogin');
      var generation = 1;
      final calls = <String>[];
      final coordinator = VerifiedSyncCoordinator(
        database: db,
        scopeProvider: () => SyncAccessScope(
          actorId: 'MNV00100',
          teamIds: ['team-2'],
          sessionGeneration: generation,
        ),
        gateway: _RecordingGateway(
          onPush: (request) async {
            calls.add(request.entityType);
            generation++;
            return SapWriteResult(sapId: 'SAP-${request.entityId}');
          },
        ),
      );
      final report = await coordinator.syncVerifiedWorkerChain(
        anchorQueueItemId: chain.assignmentQueueId,
        workerPassword: 'fresh-password',
      );
      expect(report.outcome, VerifiedSyncOutcome.blocked);
      expect(calls, ['ASSIGNMENT']);
      expect(await db.getSyncQueueItemById(chain.productionQueueId), isNotNull);
    },
  );

  test(
    'scope revoked during refresh never retries with the entered password',
    () async {
      final chain = await seedWorkerChain(suffix: 'refresh-revoke');
      var teams = ['team-2'];
      var attempts = 0;
      final coordinator = VerifiedSyncCoordinator(
        database: db,
        scopeProvider: () =>
            SyncAccessScope(actorId: 'MNV00100', teamIds: teams),
        gateway: _RecordingGateway(
          onRefresh: () async {
            teams = ['team-3'];
            return true;
          },
          onPush: (_) async {
            attempts++;
            throw authFailure();
          },
        ),
      );
      final report = await coordinator.syncVerifiedWorkerChain(
        anchorQueueItemId: chain.assignmentQueueId,
        workerPassword: 'fresh-password',
      );
      expect(report.outcome, VerifiedSyncOutcome.blocked);
      expect(attempts, 1);
      expect(await db.getSyncQueueItemById(chain.assignmentQueueId), isNotNull);
      expect(await db.getSyncQueueItemById(chain.productionQueueId), isNotNull);
    },
  );
}

class _RecordingGateway implements SapWriteGateway {
  final Future<SapWriteResult> Function(SyncPushRequest request) onPush;
  final bool refreshResult;
  final Future<bool> Function()? onRefresh;
  int refreshCalls = 0;

  _RecordingGateway({
    required this.onPush,
    this.refreshResult = false,
    this.onRefresh,
  });

  @override
  Future<SapWriteResult> push(SyncPushRequest request) => onPush(request);

  @override
  Future<bool> refreshSession() async {
    refreshCalls++;
    if (onRefresh != null) return onRefresh!();
    return refreshResult;
  }
}
