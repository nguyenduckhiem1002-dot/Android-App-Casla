// Sync — the seam between the queue and SAP
// Spec: Section 9 (SAP OData/RAP)
//
// Implemented by SapPpOpAllocGateway (lib/data/sap/sap_pp_opalloc_gateway.dart)
// against the real ZUI_PP_OPALLOC service.

/// One queued transaction, paired with the row it was built from.
class SyncPushRequest {
  /// The `sync_queue` row.
  final Map<String, dynamic> queueItem;

  /// The source row from `assignments` / `production_records` / `recall_records`.
  final Map<String, dynamic> source;

  /// The worker's own password, required by every ZUI_PP_OPALLOC mutation.
  ///
  /// This is deliberately not a column anywhere — SQLite is a durability
  /// guarantee for the *record*, not a place to hold a worker's credential
  /// while it waits to be retried. It is supplied fresh, in memory, only for
  /// the immediate push a repository makes right after the write; the
  /// automatic background engine has no way to obtain one and always leaves
  /// this null, so [SapWriteGateway.push] must throw
  /// [WorkerVerificationRequiredException] rather than send an empty string
  /// when this is missing.
  final String? workerPassword;

  const SyncPushRequest({
    required this.queueItem,
    required this.source,
    this.workerPassword,
  });

  String get id => queueItem['id'] as String;
  String get entityType => queueItem['entity_type'] as String;
  String get entityId => queueItem['entity_id'] as String;
  String get action => queueItem['action'] as String;
  int get retryCount => (queueItem['retry_count'] as int?) ?? 0;

  /// The de-duplication key SAP must key on.
  ///
  /// It lives on the source row; the queue row carries a copy only on the paths
  /// that write one. Without this reaching SAP, a retry after a timeout creates
  /// a second production record for the same work.
  String? get idempotencyKey =>
      (source['idempotency_key'] ?? queueItem['idempotency_key']) as String?;
}

class SapWriteResult {
  /// Identifier SAP assigned to the record, stored back on the source row.
  final String? sapId;

  /// True when SAP recognised the idempotency key and returned the record it
  /// already held. Treated exactly like a fresh success — the work is in SAP,
  /// which is all the queue cares about.
  final bool wasDuplicate;

  const SapWriteResult({this.sapId, this.wasDuplicate = false});
}

abstract class SapWriteGateway {
  /// Pushes one transaction. Throws on failure; [classifySyncError] decides
  /// whether the throw is worth retrying.
  Future<SapWriteResult> push(SyncPushRequest request);

  /// Re-fetches the CSRF token and session cookies after a 401/403.
  ///
  /// Returns false when re-authentication itself failed, which tells the engine
  /// not to burn the rest of the batch on the same rejection.
  Future<bool> refreshSession();
}
