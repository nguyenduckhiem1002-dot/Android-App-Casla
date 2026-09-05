// Sync-engine tests.
//
// The engine is driven against fake gateways because Phase 2 has not built the
// real one yet; what is under test here is the queue bookkeeping, which is the
// part that decides whether a shift's production is ever delivered.

import 'dart:async';

import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/network/connectivity_monitor.dart';
import 'package:casla_production/core/sync/sap_write_gateway.dart';
import 'package:casla_production/core/sync/sync_engine.dart';
import 'package:casla_production/core/sync/sync_access_scope.dart';
import 'package:casla_production/core/sync/sync_failure.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;
  late _FakeConnectivity connectivity;

  setUp(() async {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
    await db.ready;
    connectivity = _FakeConnectivity();
    // The seeded queue would otherwise mix its two demo rows into every
    // assertion about what the engine attempted.
    await _clearQueue(db);
  });

  tearDown(() async {
    await connectivity.dispose();
    CaslaDatabase.resetForTesting();
  });

  SyncEngine engineWith(SapWriteGateway gateway) =>
      SyncEngine(database: db, gateway: gateway, connectivity: connectivity);

  test('a successful push clears the queue and stamps the source', () async {
    final id = await _queueProduction(db, quantity: 12.0);
    final gateway = _FakeGateway(
      onPush: (_) => const SapWriteResult(sapId: 'SAP-1'),
    );

    final report = await engineWith(gateway).runOnce();

    expect(report.pushed, 1);
    expect(await db.watchSyncQueue().first, isEmpty);

    final source = await db.getSyncSourceRow('PRODUCTION_RECORD', id);
    expect(source!['sync_status'], 'SYNCED');
    expect(source['sap_id'], 'SAP-1');
    expect(source['synced_at_utc'], isNotNull);
  });

  test('the push carries the idempotency key SAP de-duplicates on', () async {
    await _queueProduction(db, quantity: 5.0, idempotencyKey: 'idem-abc');
    SyncPushRequest? seen;
    final gateway = _FakeGateway(
      onPush: (r) {
        seen = r;
        return const SapWriteResult();
      },
    );

    await engineWith(gateway).runOnce();

    expect(seen?.idempotencyKey, 'idem-abc');
  });

  test('a rejected record becomes FAILED and is not retried', () async {
    await _queueProduction(db, quantity: 999.0);
    var attempts = 0;
    final gateway = _FakeGateway(
      onPush: (_) {
        attempts++;
        throw _badResponse(400, 'Số lượng vượt quá phần còn lại');
      },
    );
    final engine = engineWith(gateway);

    final first = await engine.runOnce();
    expect(first.permanentFailures, 1);

    final item = (await db.watchSyncFeed().first).single;
    expect(item['status'], 'FAILED');
    expect(item['failure_kind'], SyncFailureKind.permanent.name);
    expect(item['last_error_message'], 'Số lượng vượt quá phần còn lại');

    // A second pass must leave it alone. Spec 4.7: "không retry vô hạn".
    final second = await engine.runOnce();
    expect(second.attempted, 0);
    expect(attempts, 1);
  });

  test('a timeout keeps the record PENDING behind a backoff', () async {
    await _queueProduction(db, quantity: 20.0);
    final gateway = _FakeGateway(
      onPush: (_) => throw DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionTimeout,
      ),
    );
    final engine = engineWith(gateway);

    final report = await engine.runOnce();
    expect(report.transientFailures, 1);

    final item = (await db.watchSyncFeed().first).single;
    expect(item['status'], 'PENDING');
    expect(item['retry_count'], 1);
    expect(
      item['next_retry_at_utc'],
      greaterThan(DateTime.now().millisecondsSinceEpoch),
    );

    // Still queued, still owned by the user's record — nothing was dropped.
    expect(
      await db.getSyncSourceRow(
        'PRODUCTION_RECORD',
        item['entity_id'] as String,
      ),
      isNotNull,
    );

    // And the backoff actually holds the next pass off.
    expect(await db.getDueSyncItems(), isEmpty);
  });

  test('offline skips the pass without touching the queue', () async {
    await _queueProduction(db, quantity: 7.0);
    connectivity.online = false;
    var attempts = 0;
    final gateway = _FakeGateway(
      onPush: (_) {
        attempts++;
        return const SapWriteResult();
      },
    );

    final report = await engineWith(gateway).runOnce();

    expect(report.skipped, isTrue);
    expect(attempts, 0);
    expect((await db.watchSyncFeed().first).single['retry_count'], 0);
  });

  test('a 401 triggers one re-auth and then succeeds', () async {
    await _queueProduction(db, quantity: 9.0);
    var pushes = 0;
    var refreshes = 0;
    final gateway = _FakeGateway(
      onPush: (_) {
        pushes++;
        if (pushes == 1) throw _badResponse(401, 'expired');
        return const SapWriteResult(sapId: 'SAP-9');
      },
      onRefresh: () {
        refreshes++;
        return true;
      },
    );

    final report = await engineWith(gateway).runOnce();

    expect(refreshes, 1);
    expect(pushes, 2);
    expect(report.pushed, 1);
    expect(await db.watchSyncQueue().first, isEmpty);
  });

  test('an auth failure that survives re-auth stays PENDING', () async {
    await _queueProduction(db, quantity: 4.0);
    final gateway = _FakeGateway(
      onPush: (_) => throw _badResponse(401, 'still expired'),
      onRefresh: () => true,
    );

    final report = await engineWith(gateway).runOnce();

    expect(report.transientFailures, 1);
    final item = (await db.watchSyncFeed().first).single;
    // FAILED here would bury a whole shift behind manual supervisor action for
    // what is usually a transient SAP auth outage.
    expect(item['status'], 'PENDING');
    expect(item['failure_kind'], SyncFailureKind.auth.name);
  });

  test('a transient failure stops the batch instead of burning it', () async {
    for (var i = 0; i < 4; i++) {
      await _queueProduction(db, quantity: i + 1.0);
    }
    var attempts = 0;
    final gateway = _FakeGateway(
      onPush: (_) {
        attempts++;
        throw DioException(
          requestOptions: RequestOptions(path: '/x'),
          type: DioExceptionType.connectionError,
        );
      },
    );

    await engineWith(gateway).runOnce();

    // One attempt, not four: the other three keep retry_count 0 and stay due.
    expect(attempts, 1);
    final feed = await db.watchSyncFeed().first;
    expect(feed.where((i) => (i['retry_count'] as int) == 0).length, 3);
  });

  test('a permanent failure does not stop the rest of the batch', () async {
    await _queueProduction(db, quantity: 1.0);
    await _queueProduction(db, quantity: 2.0);
    var attempts = 0;
    final gateway = _FakeGateway(
      onPush: (_) {
        attempts++;
        if (attempts == 1) throw _badResponse(400, 'nope');
        return const SapWriteResult();
      },
    );

    final report = await engineWith(gateway).runOnce();

    expect(attempts, 2);
    expect(report.permanentFailures, 1);
    expect(report.pushed, 1);
  });

  test('a queue item whose source vanished is retired, not retried', () async {
    await db.insertSyncQueueItem({
      'id': 'sync-orphan',
      'entity_type': 'PRODUCTION_RECORD',
      'entity_id': 'prod-gone',
      'action': 'CREATE',
      'created_at_utc': DateTime.now().millisecondsSinceEpoch,
      'retry_count': 0,
    });
    var attempts = 0;
    final gateway = _FakeGateway(
      onPush: (_) {
        attempts++;
        return const SapWriteResult();
      },
    );

    final report = await engineWith(gateway).runOnce();

    expect(attempts, 0);
    expect(report.permanentFailures, 1);
    final item = (await db.watchSyncFeed().first).single;
    expect(item['status'], 'FAILED');
    expect(item['last_error_code'], 'ERR_SOURCE_MISSING');
  });

  test('overlapping passes do not push the same item twice', () async {
    await _queueProduction(db, quantity: 3.0);
    final release = Completer<void>();
    var pushes = 0;
    final gateway = _FakeGateway(
      onPushAsync: (_) async {
        pushes++;
        await release.future;
        return const SapWriteResult();
      },
    );
    final engine = engineWith(gateway);

    final first = engine.runOnce();
    final second = await engine.runOnce();

    expect(second.skipped, isTrue);
    release.complete();
    expect((await first).pushed, 1);
    expect(pushes, 1);
  });

  test('a reconnect drains the queue without waiting for the timer', () async {
    await _queueProduction(db, quantity: 6.0);
    connectivity.online = false;
    final gateway = _FakeGateway(onPush: (_) => const SapWriteResult());
    final engine = SyncEngine(
      database: db,
      gateway: gateway,
      connectivity: connectivity,
      pollInterval: const Duration(minutes: 10),
    );

    final drained = engine.reports.firstWhere((r) => r.pushed == 1);
    engine.start();

    connectivity.goOnline();
    await drained;

    expect(await db.watchSyncQueue().first, isEmpty);
    await engine.dispose();
  });

  test('items are pushed oldest first so SAP sees them in order', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final newer = await _queueProduction(db, quantity: 1.0, createdAt: now);
    final older = await _queueProduction(
      db,
      quantity: 2.0,
      createdAt: now - 60000,
    );

    final seen = <String>[];
    final gateway = _FakeGateway(
      onPush: (r) {
        seen.add(r.entityId);
        return const SapWriteResult();
      },
    );

    await engineWith(gateway).runOnce();

    expect(seen, [older, newer]);
  });

  test(
    'a new session during refresh stops retry without deleting the queue',
    () async {
      await _queueProduction(db, quantity: 1);
      var generation = 1;
      var attempts = 0;
      final engine = SyncEngine(
        database: db,
        connectivity: connectivity,
        scopeProvider: () => SyncAccessScope(
          actorId: 'MNV00100',
          teamIds: ['team-2'],
          sessionGeneration: generation,
        ),
        gateway: _FakeGateway(
          onPush: (_) {
            attempts++;
            throw _badResponse(401, 'expired');
          },
          onRefresh: () {
            generation++;
            return true;
          },
        ),
      );
      final report = await engine.runOnce();
      expect(report.skipped, isTrue);
      expect(attempts, 1);
      expect(await db.watchSyncQueue().first, hasLength(1));
      await engine.dispose();
    },
  );
}

Future<void> _clearQueue(CaslaDatabase db) async {
  for (final item in await db.watchSyncQueue().first) {
    await db.deleteSyncQueueItem(item['id'] as String);
  }
}

/// Writes a production record plus its queue entry, the way
/// `ProductionRepositoryImpl` does, but with ids the test can assert on.
var _seq = 0;
Future<String> _queueProduction(
  CaslaDatabase db, {
  required double quantity,
  String? idempotencyKey,
  int? createdAt,
}) async {
  final n = _seq++;
  final id = 'prod-test-$n';
  final at = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  await db.insertProductionRecord({
    'id': id,
    'phan_cong_id': 'asg-001',
    'quantity': quantity,
    'business_date': '2026-08-20',
    'shift_id': 'SHIFT_1',
    'created_by': 'MNV00100',
    'occurred_at_utc': at,
    'device_id': 'PDA-TEST',
    'sync_status': 'PENDING',
    'idempotency_key': idempotencyKey ?? 'idem-test-$n',
    'created_at_utc': at,
  });
  await db.insertSyncQueueItem({
    'id': 'sync-test-$n',
    'entity_type': 'PRODUCTION_RECORD',
    'entity_id': id,
    'action': 'CREATE',
    'priority': 1,
    'retry_count': 0,
    'created_at_utc': at,
  });
  return id;
}

DioException _badResponse(int status, String message) {
  final options = RequestOptions(path: 'ZUI_PROD_RECORD');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response<Object?>(
      requestOptions: options,
      statusCode: status,
      data: {
        'error': {
          'message': {'value': message},
        },
      },
    ),
  );
}

class _FakeGateway implements SapWriteGateway {
  final SapWriteResult Function(SyncPushRequest)? onPush;
  final Future<SapWriteResult> Function(SyncPushRequest)? onPushAsync;
  final bool Function()? onRefresh;

  _FakeGateway({this.onPush, this.onPushAsync, this.onRefresh});

  @override
  Future<SapWriteResult> push(SyncPushRequest request) {
    if (onPushAsync != null) return onPushAsync!(request);
    return Future.value(onPush!(request));
  }

  @override
  Future<bool> refreshSession() async => onRefresh?.call() ?? false;
}

class _FakeConnectivity implements ConnectivityMonitor {
  bool online = true;
  final _controller = StreamController<bool>.broadcast();

  void goOnline() {
    online = true;
    _controller.add(true);
  }

  @override
  Future<bool> isOnline() async => online;

  @override
  Stream<bool> get onStatusChange => _controller.stream;

  @override
  Future<void> dispose() => _controller.close();
}
