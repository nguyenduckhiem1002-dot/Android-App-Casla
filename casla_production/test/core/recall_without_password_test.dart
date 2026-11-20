// Recall without the worker's password (SAP function PP_RECALL_NOPASS).
//
// The supervisor ticks "Thu hồi không cần mật khẩu" on the Xác nhận sheet when
// the worker is away and what is left goes to someone else. The recall then
// has no password at all, so unlike every other write it must be sendable by
// the background engine: the flag is frozen on the stored row, not carried in
// memory like a password.

import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/sync/sap_write_gateway.dart';
import 'package:casla_production/core/sync/sync_failure.dart';
import 'package:casla_production/core/sync/sync_push.dart';
import 'package:casla_production/core/sync/verified_sync_coordinator.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/odata_error.dart';
import 'package:casla_production/domain/entities/mutation_receipt.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

class _Gateway implements SapWriteGateway {
  final requests = <SyncPushRequest>[];
  Object? throwError;

  @override
  Future<bool> refreshSession() async => false;

  @override
  Future<SapWriteResult> push(SyncPushRequest request) async {
    requests.add(request);
    final error = throwError;
    if (error != null) throw error;
    return SapWriteResult(sapId: 'sap-${request.entityId}');
  }
}

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;
  late _Gateway gateway;
  late AssignmentRepositoryImpl assignments;
  late RecallRepositoryImpl recall;

  setUp(() {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
    gateway = _Gateway();
    assignments = AssignmentRepositoryImpl(db, gateway: gateway);
    recall = RecallRepositoryImpl(
      db,
      gateway: gateway,
      verifiedSync: VerifiedSyncCoordinator(database: db, gateway: gateway),
    );
  });
  tearDown(() => db.close());

  Future<Map<String, dynamic>?> queueRow(String entityId) async {
    final rows = await db.watchSyncQueue().first;
    for (final row in rows) {
      if (row['entity_id'] == entityId) return row;
    }
    return null;
  }

  Future<MutationReceipt> recallAll({bool withoutWorkerPassword = true}) async {
    final before = (await assignments.getAssignmentById('asg-001'))!;
    return recall.recallAssignment(
      assignmentId: before.id,
      quantity: before.remaining,
      reasonCode: 'NOT_FINISHED',
      businessDate: '2026-09-07',
      shiftId: 'SHIFT_1',
      createdBy: 'MNV00100',
      workerPassword: withoutWorkerPassword ? null : 'test-only-password',
      withoutWorkerPassword: withoutWorkerPassword,
    );
  }

  test('is sent at once with no password and marked on its row', () async {
    final receipt = await recallAll();

    expect(receipt.state, MutationDeliveryState.synced);
    final request = gateway.requests.single;
    expect(request.entityType, 'RECALL');
    expect(request.workerPassword, isNull);
    expect(request.source['without_worker_password'], 1);
    expect(await queueRow(receipt.id), isNull);
  });

  test('a recall with the worker password is not marked', () async {
    final receipt = await recallAll(withoutWorkerPassword: false);

    expect(receipt.state, MutationDeliveryState.synced);
    final request = gateway.requests.single;
    expect(request.workerPassword, 'test-only-password');
    expect(request.source['without_worker_password'], 0);
  });

  test('offline it stays PENDING for the engine, not parked for a '
      'password', () async {
    gateway.throwError = DioException(
      requestOptions: RequestOptions(path: 'submitRecall'),
      type: DioExceptionType.connectionError,
    );

    final receipt = await recallAll();

    expect(receipt.state, MutationDeliveryState.queued);
    final queued = (await queueRow(receipt.id))!;
    expect(queued['status'], 'PENDING');

    // What the background engine does on its next pass: the stored row still
    // says "no password", so the retry goes out without one.
    gateway.throwError = null;
    gateway.requests.clear();
    final source = (await db.getSyncSourceRow('RECALL', receipt.id))!;
    expect(source['without_worker_password'], 1);
    final failure = await pushAndRecord(
      database: db,
      gateway: gateway,
      backoff: SyncBackoff(),
      queueItem: queued,
      source: source,
    );

    expect(failure, isNull);
    expect(gateway.requests.single.workerPassword, isNull);
    expect(await queueRow(receipt.id), isNull);
  });

  test('an account without PP_RECALL_NOPASS is refused and rolled '
      'back', () async {
    final before = (await assignments.getAssignmentById('asg-001'))!;
    gateway.throwError = const SapBusinessError('RECALL_NOPASS_NOT_ALLOWED');

    final receipt = await recallAll();

    expect(receipt.state, MutationDeliveryState.discarded);
    expect(receipt.code, 'RECALL_NOPASS_NOT_ALLOWED');
    expect(receipt.isWrongWorkerPassword, isFalse);
    expect(await queueRow(receipt.id), isNull);
    expect(
      (await assignments.getAssignmentById(before.id))!.remaining,
      before.remaining,
    );
  });
}
