// Sync — queue drain engine
// Spec: Section 4.7 (Đồng bộ offline)
//
// Wiring (Phase 2, once a SapWriteGateway exists):
//
//   final engine = SyncEngine(
//     database: CaslaDatabase.instance,
//     gateway: SapODataWriteGateway(client),
//     connectivity: PlatformConnectivityMonitor(),
//   )..start();
//
// The engine never deletes a transaction it could not confirm. Every exit path
// either leaves the queue row in place or removes it in the same transaction
// that stamps the source row SYNCED.

// prefer_initializing_formals cannot be satisfied here: Dart has no private
// named parameter, so `this._database` in a named constructor is unreachable by
// callers. The fields stay private and are assigned in the initializer list.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../database/casla_database.dart';
import '../network/connectivity_monitor.dart';
import 'sap_write_gateway.dart';
import 'sync_failure.dart';

/// Outcome of one drain pass, for logging and tests.
@immutable
class SyncRunReport {
  final int pushed;
  final int transientFailures;
  final int permanentFailures;

  /// True when the pass did not run at all — offline, or another pass was
  /// already in flight.
  final bool skipped;

  const SyncRunReport({
    this.pushed = 0,
    this.transientFailures = 0,
    this.permanentFailures = 0,
    this.skipped = false,
  });

  static const SyncRunReport skippedRun = SyncRunReport(skipped: true);

  int get attempted => pushed + transientFailures + permanentFailures;

  @override
  String toString() =>
      'SyncRunReport(pushed: $pushed, transient: $transientFailures, '
      'permanent: $permanentFailures, skipped: $skipped)';
}

class SyncEngine {
  final CaslaDatabase _database;
  final SapWriteGateway _gateway;
  final ConnectivityMonitor _connectivity;
  final SyncBackoff _backoff;
  final Duration _pollInterval;
  final int _batchSize;

  Timer? _timer;
  StreamSubscription<bool>? _connectivitySubscription;
  bool _running = false;

  final _reports = StreamController<SyncRunReport>.broadcast();

  SyncEngine({
    required CaslaDatabase database,
    required SapWriteGateway gateway,
    required ConnectivityMonitor connectivity,
    SyncBackoff? backoff,
    Duration pollInterval = const Duration(seconds: 30),
    int batchSize = 50,
  }) : _database = database,
       _gateway = gateway,
       _connectivity = connectivity,
       _backoff = backoff ?? SyncBackoff(),
       _pollInterval = pollInterval,
       _batchSize = batchSize;

  /// Emits once per completed pass.
  Stream<SyncRunReport> get reports => _reports.stream;

  /// Begins draining: once now, on every reconnect, and on a timer.
  ///
  /// The timer is not redundant with the connectivity signal. A PDA that never
  /// loses its Wi-Fi association but sits behind an unreachable SAP host emits
  /// no connectivity event at all, and its queue would otherwise never drain.
  void start() {
    if (_timer != null) return;

    _connectivitySubscription = _connectivity.onStatusChange.listen((online) {
      if (online) unawaited(runOnce());
    });
    _timer = Timer.periodic(_pollInterval, (_) => unawaited(runOnce()));
    unawaited(runOnce());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
  }

  Future<void> dispose() async {
    await stop();
    await _reports.close();
  }

  /// Drains every queue item whose backoff has elapsed.
  ///
  /// Safe to call concurrently — overlapping passes would push the same item
  /// twice, so a second caller is turned away rather than queued.
  Future<SyncRunReport> runOnce() async {
    if (_running) return SyncRunReport.skippedRun;
    _running = true;
    try {
      if (!await _connectivity.isOnline()) {
        final report = SyncRunReport.skippedRun;
        _publish(report);
        return report;
      }

      final items = await _database.getDueSyncItems(limit: _batchSize);
      var pushed = 0;
      var transient = 0;
      var permanent = 0;
      var sessionRefreshed = false;

      for (final item in items) {
        final outcome = await _pushItem(
          item,
          allowSessionRefresh: !sessionRefreshed,
          onSessionRefreshed: () => sessionRefreshed = true,
        );

        switch (outcome) {
          case _Outcome.pushed:
            pushed++;
          case _Outcome.permanent:
            permanent++;
          case _Outcome.transient:
            transient++;
            // The connection is down or SAP is unwell. Every remaining item
            // would fail the same way, each burning a full request timeout and
            // an undeserved retry_count. Stop and let the backoff decide when to
            // come back.
            final report = SyncRunReport(
              pushed: pushed,
              transientFailures: transient,
              permanentFailures: permanent,
            );
            _publish(report);
            return report;
        }
      }

      final report = SyncRunReport(
        pushed: pushed,
        transientFailures: transient,
        permanentFailures: permanent,
      );
      _publish(report);
      return report;
    } finally {
      _running = false;
    }
  }

  Future<_Outcome> _pushItem(
    Map<String, dynamic> item, {
    required bool allowSessionRefresh,
    required VoidCallback onSessionRefreshed,
  }) async {
    final id = item['id'] as String;
    final entityType = item['entity_type'] as String;
    final entityId = item['entity_id'] as String;

    final source = await _database.getSyncSourceRow(entityType, entityId);
    if (source == null) {
      // Nothing left to push. Retrying cannot conjure the row back, and leaving
      // it PENDING would keep the badge count wrong forever.
      await _database.updateSyncQueueError(
        id,
        'ERR_SOURCE_MISSING',
        'Không tìm thấy bản ghi gốc ($entityType/$entityId).',
        failureKind: SyncFailureKind.permanent.name,
      );
      return _Outcome.permanent;
    }

    final request = SyncPushRequest(queueItem: item, source: source);

    try {
      final result = await _gateway.push(request);
      await _database.markSyncItemSynced(
        id,
        entityType: entityType,
        entityId: entityId,
        sapId: result.sapId,
      );
      return _Outcome.pushed;
    } catch (error) {
      var failure = classifySyncError(error);

      if (failure.kind == SyncFailureKind.auth && allowSessionRefresh) {
        onSessionRefreshed();
        if (await _refreshSessionQuietly()) {
          try {
            final result = await _gateway.push(request);
            await _database.markSyncItemSynced(
              id,
              entityType: entityType,
              entityId: entityId,
              sapId: result.sapId,
            );
            return _Outcome.pushed;
          } catch (retryError) {
            failure = classifySyncError(retryError);
          }
        }
      }

      return _recordFailure(id, item, failure);
    }
  }

  Future<bool> _refreshSessionQuietly() async {
    try {
      return await _gateway.refreshSession();
    } catch (_) {
      return false;
    }
  }

  Future<_Outcome> _recordFailure(
    String id,
    Map<String, dynamic> item,
    SyncFailure failure,
  ) async {
    if (failure.kind == SyncFailureKind.permanent) {
      await _database.updateSyncQueueError(
        id,
        failure.code,
        failure.message,
        failureKind: failure.kind.name,
      );
      return _Outcome.permanent;
    }

    // Transient and unresolved auth failures both stay PENDING: the record is
    // still valid, only the delivery failed.
    final retryCount = (item['retry_count'] as int?) ?? 0;
    await _database.updateSyncQueueError(
      id,
      failure.code,
      failure.message,
      status: 'PENDING',
      failureKind: failure.kind.name,
      nextRetryAtUtc: _backoff.nextRetryAtUtc(retryCount),
    );
    return _Outcome.transient;
  }

  void _publish(SyncRunReport report) {
    if (!_reports.isClosed) _reports.add(report);
  }
}

enum _Outcome { pushed, transient, permanent }
