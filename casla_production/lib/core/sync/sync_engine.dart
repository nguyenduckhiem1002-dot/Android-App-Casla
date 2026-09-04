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
import 'sync_push.dart';

/// Outcome of one drain pass, for logging and tests.
@immutable
class SyncRunReport {
  final int pushed;
  final int transientFailures;
  final int permanentFailures;

  /// Items that need a human to re-enter a worker password before the next
  /// attempt — see [SyncPushRequest.workerPassword]. Distinct from
  /// [permanentFailures]: nothing is wrong with the record itself.
  final int needsVerification;

  /// True when the pass did not run at all — offline, or another pass was
  /// already in flight.
  final bool skipped;

  const SyncRunReport({
    this.pushed = 0,
    this.transientFailures = 0,
    this.permanentFailures = 0,
    this.needsVerification = 0,
    this.skipped = false,
  });

  static const SyncRunReport skippedRun = SyncRunReport(skipped: true);

  int get attempted =>
      pushed + transientFailures + permanentFailures + needsVerification;

  @override
  String toString() =>
      'SyncRunReport(pushed: $pushed, transient: $transientFailures, '
      'permanent: $permanentFailures, needsVerification: $needsVerification, '
      'skipped: $skipped)';
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
      var needsVerification = 0;
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
          case _Outcome.needsVerification:
            // Per-record, not global: this item needs a human, but the rest
            // of the batch may still be pushable right now.
            needsVerification++;
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
              needsVerification: needsVerification,
            );
            _publish(report);
            return report;
        }
      }

      final report = SyncRunReport(
        pushed: pushed,
        transientFailures: transient,
        permanentFailures: permanent,
        needsVerification: needsVerification,
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
    final entityType = item['entity_type'] as String;
    final entityId = item['entity_id'] as String;

    final source = await _database.getSyncSourceRow(entityType, entityId);
    if (source == null) {
      // Nothing left to push. Retrying cannot conjure the row back, and leaving
      // it PENDING would keep the badge count wrong forever.
      await _database.updateSyncQueueError(
        item['id'] as String,
        'ERR_SOURCE_MISSING',
        'Không tìm thấy bản ghi gốc ($entityType/$entityId).',
        failureKind: SyncFailureKind.permanent.name,
      );
      return _Outcome.permanent;
    }

    // The background engine never has a worker password to send — every
    // mutation on this backend requires one, so the first attempt below
    // always lands on `needsVerification` for a freshly-queued item. That is
    // expected, not a bug: see `SyncPushRequest.workerPassword`.
    var failure = await pushAndRecord(
      database: _database,
      gateway: _gateway,
      backoff: _backoff,
      queueItem: item,
      source: source,
    );
    if (failure == null) return _Outcome.pushed;

    if (failure.kind == SyncFailureKind.auth && allowSessionRefresh) {
      onSessionRefreshed();
      if (await _refreshSessionQuietly()) {
        // `pushAndRecord` already wrote the first failure; retrying either
        // deletes that row (success) or simply overwrites it with whatever
        // this attempt finds — nothing extra to undo either way.
        failure = await pushAndRecord(
          database: _database,
          gateway: _gateway,
          backoff: _backoff,
          queueItem: item,
          source: source,
        );
        if (failure == null) return _Outcome.pushed;
      }
    }

    return switch (failure.kind) {
      SyncFailureKind.permanent => _Outcome.permanent,
      SyncFailureKind.needsVerification => _Outcome.needsVerification,
      SyncFailureKind.transient || SyncFailureKind.auth => _Outcome.transient,
    };
  }

  Future<bool> _refreshSessionQuietly() async {
    try {
      return await _gateway.refreshSession();
    } catch (_) {
      return false;
    }
  }

  void _publish(SyncRunReport report) {
    if (!_reports.isClosed) _reports.add(report);
  }
}

enum _Outcome { pushed, transient, permanent, needsVerification }
