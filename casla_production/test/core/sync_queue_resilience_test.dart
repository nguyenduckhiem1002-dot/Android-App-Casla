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

  Future<Map<String, dynamic>> queueProduction({
    required String suffix,
    required String idempotencyKey,
    int? createdAt,
  }) async {
    final at = createdAt ?? DateTime.now().millisecondsSinceEpoch;
    final sourceId = 'prod-$suffix';
    final queueId = 'sync-$suffix';
    await db.insertProductionRecord({
      'id': sourceId,
      'phan_cong_id': 'asg-001',
      'quantity': 3.0,
      'business_date': '2026-09-05',
      'shift_id': 'SHIFT_1',
      'created_by': 'MNV00100',
      'occurred_at_utc': at,
      'device_id': 'PDA-TEST',
      'sync_status': 'PENDING',
      'idempotency_key': idempotencyKey,
      'created_at_utc': at,
    });
    final queueItem = <String, dynamic>{
      'id': queueId,
      'entity_type': 'PRODUCTION_RECORD',
      'entity_id': sourceId,
      'action': 'CREATE',
      'status': 'PENDING',
      'priority': 1,
      'retry_count': 0,
      'created_at_utc': at,
    };
    await db.insertSyncQueueItem(queueItem);
    return queueItem;
  }

  test('a duplicate SAP receipt is finalized exactly like a fresh success', () async {
    final queueItem = await queueProduction(
      suffix: 'duplicate',
      idempotencyKey: 'idem-duplicate',
    );
    final source = await db.getSyncSourceRow(
      queueItem['entity_type'] as String,
      queueItem['entity_id'] as String,
    );

    final failure = await pushAndRecord(
      database: db,
      gateway: _Gateway(
        onPush: (_) async => const SapWriteResult(
          sapId: 'SAP-EXISTING',
          wasDuplicate: true,
        ),
      ),
      backoff: SyncBackoff(),
      queueItem: queueItem,
      source: source!,
    );

    expect(failure, isNull);
    expect(await db.getSyncQueueItemById(queueItem['id'] as String), isNull);
    final stamped = await db.getSyncSourceRow(
      'PRODUCTION_RECORD',
      queueItem['entity_id'] as String,
    );
    expect(stamped!['sync_status'], 'SYNCED');
    expect(stamped['sap_id'], 'SAP-EXISTING');
  });

  test('an auth retry keeps the exact same idempotency key', () async {
    final queueItem = await queueProduction(
      suffix: 'auth-idem',
      idempotencyKey: 'idem-stable-across-retry',
    );
    final source = await db.getSyncSourceRow(
      queueItem['entity_type'] as String,
      queueItem['entity_id'] as String,
    );
    final seenKeys = <String?>[];
    var attempts = 0;
    final gateway = _Gateway(
      onPush: (request) async {
        seenKeys.add(request.idempotencyKey);
        if (attempts++ == 0) throw _authFailure();
        return const SapWriteResult(sapId: 'SAP-AUTH-RETRY');
      },
    );

    var failure = await pushAndRecord(
      database: db,
      gateway: gateway,
      backoff: SyncBackoff(),
      queueItem: queueItem,
      source: source!,
      workerPassword: 'fresh-password',
    );
    expect(failure?.kind, SyncFailureKind.auth);

    final retryItem = await db.getSyncQueueItemById(queueItem['id'] as String);
    final retrySource = await db.getSyncSourceRow(
      queueItem['entity_type'] as String,
      queueItem['entity_id'] as String,
    );
    failure = await pushAndRecord(
      database: db,
      gateway: gateway,
      backoff: SyncBackoff(),
      queueItem: retryItem!,
      source: retrySource!,
      workerPassword: 'fresh-password',
    );

    expect(failure, isNull);
    expect(seenKeys, ['idem-stable-across-retry', 'idem-stable-across-retry']);
  });

  test('backoff uses an explicit clock and cannot retry early', () async {
    final now = DateTime(2026, 9, 5, 10).millisecondsSinceEpoch;
    final queueItem = await queueProduction(
      suffix: 'clock',
      idempotencyKey: 'idem-clock',
      createdAt: now - const Duration(minutes: 5).inMilliseconds,
    );
    final retryAt = now + const Duration(minutes: 2).inMilliseconds;

    await db.updateSyncQueueError(
      queueItem['id'] as String,
      'ERR_NETWORK',
      'network down',
      status: 'PENDING',
      failureKind: SyncFailureKind.transient.name,
      nextRetryAtUtc: retryAt,
    );

    expect(await db.getDueSyncItems(nowUtc: now), isEmpty);
    expect(await db.getDueSyncItems(nowUtc: retryAt - 1), isEmpty);
    expect(
      (await db.getDueSyncItems(nowUtc: retryAt)).single['id'],
      queueItem['id'],
    );
  });

  test('long queues are bounded and ordered by priority then age', () async {
    final base = DateTime(2026, 9, 5, 10).millisecondsSinceEpoch;
    for (var index = 0; index < 60; index++) {
      await db.insertSyncQueueItem({
        'id': 'bulk-$index',
        'entity_type': 'PRODUCTION_RECORD',
        'entity_id': 'missing-$index',
        'action': 'CREATE',
        'status': 'PENDING',
        'priority': index < 5 ? 0 : 1,
        'retry_count': 0,
        'created_at_utc': base + index,
      });
    }

    final firstPage = await db.getDueSyncItems(nowUtc: base + 1000);
    expect(firstPage, hasLength(50));
    expect(firstPage.take(5).map((item) => item['id']), [
      'bulk-0',
      'bulk-1',
      'bulk-2',
      'bulk-3',
      'bulk-4',
    ]);
    expect(firstPage[5]['id'], 'bulk-5');
    expect(firstPage.last['id'], 'bulk-49');
  });
}

DioException _authFailure() {
  final options = RequestOptions(path: '/sync');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<void>(requestOptions: options, statusCode: 401),
  );
}

class _Gateway implements SapWriteGateway {
  final Future<SapWriteResult> Function(SyncPushRequest request) onPush;

  _Gateway({required this.onPush});

  @override
  Future<SapWriteResult> push(SyncPushRequest request) => onPush(request);

  @override
  Future<bool> refreshSession() async => true;
}
