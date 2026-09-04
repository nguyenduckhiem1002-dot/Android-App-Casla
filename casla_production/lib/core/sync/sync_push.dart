// Sync — the one-attempt push+record building block
//
// Shared by two callers with different retry policies:
//   - `SyncEngine`'s background pass (no worker password, wraps this in an
//     auth-refresh-then-retry-once dance);
//   - a repository's immediate push right after a write (has a live worker
//     password, tries exactly once — see Section 4.7's "sync ngay lập tức").
//
// Both need the exact same classify-and-record behavior on failure; splitting
// it out means a change to how NEEDS_VERIFICATION or backoff is recorded only
// has to happen in one place.

import '../database/casla_database.dart';
import 'sap_write_gateway.dart';
import 'sync_failure.dart';

/// Attempts one push. On success, stamps the source row SYNCED and removes the
/// queue item, returning null. On failure, classifies the error and writes the
/// outcome to `sync_queue` exactly the way the background engine would,
/// returning the classification so the caller can decide whether to retry.
Future<SyncFailure?> pushAndRecord({
  required CaslaDatabase database,
  required SapWriteGateway gateway,
  required SyncBackoff backoff,
  required Map<String, dynamic> queueItem,
  required Map<String, dynamic> source,
  String? workerPassword,
}) async {
  final id = queueItem['id'] as String;
  final entityType = queueItem['entity_type'] as String;
  final entityId = queueItem['entity_id'] as String;

  final request = SyncPushRequest(
    queueItem: queueItem,
    source: source,
    workerPassword: workerPassword,
  );

  try {
    final result = await gateway.push(request);
    await database.markSyncItemSynced(
      id,
      entityType: entityType,
      entityId: entityId,
      sapId: result.sapId,
    );
    return null;
  } catch (error) {
    final failure = classifySyncError(error);
    await _writeFailure(database, backoff, id, queueItem, failure);
    return failure;
  }
}

Future<void> _writeFailure(
  CaslaDatabase database,
  SyncBackoff backoff,
  String id,
  Map<String, dynamic> queueItem,
  SyncFailure failure,
) async {
  if (failure.kind == SyncFailureKind.permanent) {
    await database.updateSyncQueueError(
      id,
      failure.code,
      failure.message,
      failureKind: failure.kind.name,
    );
    return;
  }

  if (failure.kind == SyncFailureKind.needsVerification) {
    // No `next_retry_at_utc`: `getDueSyncItems` only ever picks up `PENDING`,
    // so this status is how the item stays out of the automatic engine's
    // hands until a human resupplies the password and something calls
    // `retrySyncItem` (which puts it back to PENDING) on their behalf.
    await database.updateSyncQueueError(
      id,
      failure.code,
      failure.message,
      status: 'NEEDS_VERIFICATION',
      failureKind: failure.kind.name,
    );
    return;
  }

  // Transient and unresolved-auth failures both stay PENDING: the record is
  // still valid, only the delivery failed.
  final retryCount = (queueItem['retry_count'] as int?) ?? 0;
  await database.updateSyncQueueError(
    id,
    failure.code,
    failure.message,
    status: 'PENDING',
    failureKind: failure.kind.name,
    nextRetryAtUtc: backoff.nextRetryAtUtc(retryCount),
  );
}
