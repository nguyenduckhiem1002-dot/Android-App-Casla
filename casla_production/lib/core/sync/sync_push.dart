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
import '../../data/sap/sap_session_provider.dart';
import 'sap_write_gateway.dart';
import 'sync_failure.dart';

/// Attempts one push. On success, stamps the source row SYNCED and removes the
/// queue item, returning null. On failure, classifies the error and writes the
/// honest next action to `sync_queue`. A foreground transient failure becomes
/// verification work because the one-use worker password is not retained;
/// background transient failures can still use normal backoff.
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
  } on SapSessionInvalidatedException {
    // Logout/account-switch won the race. Do not increment retries or stamp a
    // status from an I/O operation that no longer belongs to this session.
    rethrow;
  } catch (error) {
    final failure = classifySyncError(error);
    return _writeFailure(
      database,
      backoff,
      id,
      queueItem,
      failure,
      hadWorkerPassword: workerPassword?.isNotEmpty == true,
    );
  }
}

Future<SyncFailure> _writeFailure(
  CaslaDatabase database,
  SyncBackoff backoff,
  String id,
  Map<String, dynamic> queueItem,
  SyncFailure failure, {
  required bool hadWorkerPassword,
}) async {
  if (failure.kind == SyncFailureKind.permanent) {
    await database.updateSyncQueueError(
      id,
      failure.code,
      failure.message,
      failureKind: failure.kind.name,
    );
    return failure;
  }

  if (failure.kind == SyncFailureKind.needsVerification) {
    // No `next_retry_at_utc`: `getDueSyncItems` only ever picks up `PENDING`,
    // so this status is how the item stays out of the automatic engine's
    // hands until a human resupplies the password to
    // `VerifiedSyncCoordinator`, which calls this method directly.
    await database.updateSyncQueueError(
      id,
      failure.code,
      failure.message,
      status: 'NEEDS_VERIFICATION',
      failureKind: failure.kind.name,
    );
    return failure;
  }

  // The password was intentionally kept in memory for one foreground attempt
  // only. If that attempt reached a transient delivery error, a future
  // background retry cannot replay it honestly: the gateway will stop at
  // WorkerVerificationRequiredException before sending. Move the item straight
  // to the recoverable human state instead of briefly promising auto-retry.
  if (failure.kind == SyncFailureKind.transient && hadWorkerPassword) {
    final verificationFailure = SyncFailure(
      kind: SyncFailureKind.needsVerification,
      code: failure.code,
      message: _freshVerificationMessage(failure),
    );
    await database.updateSyncQueueError(
      id,
      verificationFailure.code,
      verificationFailure.message,
      status: 'NEEDS_VERIFICATION',
      failureKind: verificationFailure.kind.name,
    );
    return verificationFailure;
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
  return failure;
}

String _freshVerificationMessage(SyncFailure failure) {
  if (failure.code == 'ERR_NETWORK') {
    return 'Không có kết nối tới SAP. Khi có mạng, hãy xác minh lại công nhân để gửi tiếp.';
  }
  if (failure.code == 'ERR_TIMEOUT') {
    return 'SAP không phản hồi kịp. Hãy xác minh lại công nhân để kiểm tra và gửi tiếp.';
  }
  if (failure.code == 'SYNC_RECEIPT_NOT_FOUND' ||
      failure.code == 'SYNC_RECEIPT_DUPLICATE') {
    return 'SAP chưa xác nhận được giao dịch. Hãy xác minh lại công nhân để kiểm tra và gửi tiếp.';
  }
  return 'Chưa gửi được giao dịch lên SAP. Hãy xác minh lại công nhân để thử tiếp.';
}
