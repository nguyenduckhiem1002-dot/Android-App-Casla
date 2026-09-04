import '../database/casla_database.dart';
import 'sap_write_gateway.dart';
import 'sync_failure.dart';
import 'sync_push.dart';

enum VerifiedSyncOutcome { synced, queued, rejected, blocked, notFound }

class VerifiedSyncReport {
  final VerifiedSyncOutcome outcome;
  final int syncedCount;
  final int totalCount;
  final String message;

  const VerifiedSyncReport({
    required this.outcome,
    required this.syncedCount,
    required this.totalCount,
    required this.message,
  });
}

/// Sends a worker's queued mutation chain with one fresh, in-memory password.
///
/// Passwords are never persisted. Assignments are pushed before their
/// descendants and processing stops on the first failure, preserving SAP
/// lineage and avoiding a burst of repeated password failures.
class VerifiedSyncCoordinator {
  final CaslaDatabase database;
  final SapWriteGateway gateway;
  final Set<String> _workersInFlight = <String>{};

  VerifiedSyncCoordinator({required this.database, required this.gateway});

  Future<VerifiedSyncReport> syncVerifiedWorkerChain({
    required String anchorQueueItemId,
    required String workerPassword,
  }) async {
    if (workerPassword.trim().isEmpty) {
      return const VerifiedSyncReport(
        outcome: VerifiedSyncOutcome.blocked,
        syncedCount: 0,
        totalCount: 0,
        message: 'Vui lòng nhập mật khẩu xác nhận của công nhân.',
      );
    }

    final anchor = await database.getSyncQueueItemById(anchorQueueItemId);
    if (anchor == null) {
      return const VerifiedSyncReport(
        outcome: VerifiedSyncOutcome.notFound,
        syncedCount: 0,
        totalCount: 0,
        message: 'Giao dịch này đã được xử lý hoặc không còn trong hàng đợi.',
      );
    }

    final workerId = await _resolveWorkerId(anchor);
    if (workerId == null) {
      return const VerifiedSyncReport(
        outcome: VerifiedSyncOutcome.blocked,
        syncedCount: 0,
        totalCount: 1,
        message: 'Không xác định được công nhân của giao dịch này.',
      );
    }

    if (!_workersInFlight.add(workerId)) {
      return const VerifiedSyncReport(
        outcome: VerifiedSyncOutcome.blocked,
        syncedCount: 0,
        totalCount: 0,
        message: 'Các giao dịch của công nhân này đang được đồng bộ.',
      );
    }

    try {
      final items = await database.getVerifiableSyncItemsForWorker(workerId);
      if (items.isEmpty) {
        return const VerifiedSyncReport(
          outcome: VerifiedSyncOutcome.notFound,
          syncedCount: 0,
          totalCount: 0,
          message: 'Không còn giao dịch nào cần xác minh.',
        );
      }

      var synced = 0;
      for (final item in items) {
        final source = await database.getSyncSourceRow(
          item['entity_type'] as String,
          item['entity_id'] as String,
        );
        if (source == null) {
          return VerifiedSyncReport(
            outcome: VerifiedSyncOutcome.blocked,
            syncedCount: synced,
            totalCount: items.length,
            message: 'Thiếu dữ liệu gốc của một giao dịch. Không thể gửi SAP.',
          );
        }

        if (item['entity_type'] != 'ASSIGNMENT' &&
            !await _hasSyncedParent(source)) {
          return VerifiedSyncReport(
            outcome: VerifiedSyncOutcome.blocked,
            syncedCount: synced,
            totalCount: items.length,
            message:
                'Phân công gốc chưa được SAP xác nhận. Hãy xử lý phân công trước.',
          );
        }

        var failure = await pushAndRecord(
          database: database,
          gateway: gateway,
          backoff: SyncBackoff(),
          queueItem: item,
          source: source,
          workerPassword: workerPassword,
        );

        if (failure?.kind == SyncFailureKind.auth &&
            await gateway.refreshSession()) {
          failure = await pushAndRecord(
            database: database,
            gateway: gateway,
            backoff: SyncBackoff(),
            queueItem: item,
            source: source,
            workerPassword: workerPassword,
          );
        }

        if (failure == null) {
          synced++;
          continue;
        }

        return VerifiedSyncReport(
          outcome: failure.kind == SyncFailureKind.permanent
              ? VerifiedSyncOutcome.rejected
              : failure.kind == SyncFailureKind.needsVerification
              ? VerifiedSyncOutcome.blocked
              : VerifiedSyncOutcome.queued,
          syncedCount: synced,
          totalCount: items.length,
          message: failure.message,
        );
      }

      return VerifiedSyncReport(
        outcome: VerifiedSyncOutcome.synced,
        syncedCount: synced,
        totalCount: items.length,
        message: synced == 1
            ? 'Đã đồng bộ giao dịch lên SAP.'
            : 'Đã đồng bộ $synced giao dịch theo đúng thứ tự lên SAP.',
      );
    } finally {
      _workersInFlight.remove(workerId);
    }
  }

  Future<String?> _resolveWorkerId(Map<String, dynamic> queueItem) async {
    final source = await database.getSyncSourceRow(
      queueItem['entity_type'] as String,
      queueItem['entity_id'] as String,
    );
    if (source == null) return null;
    if (queueItem['entity_type'] == 'ASSIGNMENT') {
      return source['nhan_vien_id'] as String?;
    }
    final assignmentId = source['phan_cong_id'] as String?;
    if (assignmentId == null) return null;
    final assignment = await database.getAssignmentById(assignmentId);
    return assignment?['nhan_vien_id'] as String?;
  }

  Future<bool> _hasSyncedParent(Map<String, dynamic> source) async {
    final assignmentId = source['phan_cong_id'] as String?;
    if (assignmentId == null) return false;
    final assignment = await database.getAssignmentById(assignmentId);
    final sapId = assignment?['sap_id']?.toString().trim();
    return sapId != null && sapId.isNotEmpty;
  }
}
