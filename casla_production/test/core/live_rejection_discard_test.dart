import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/sync/sap_write_gateway.dart';
import 'package:casla_production/core/sync/verified_sync_coordinator.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/odata_error.dart';
import 'package:casla_production/domain/entities/mutation_receipt.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

class _Gateway implements SapWriteGateway {
  String? rejectWith;
  Object? throwError;

  @override
  Future<bool> refreshSession() async => false;

  @override
  Future<SapWriteResult> push(SyncPushRequest request) async {
    final error = throwError;
    if (error != null) throw error;
    final code = rejectWith;
    if (code != null) throw SapBusinessError(code);
    return SapWriteResult(sapId: 'sap-${request.entityId}');
  }
}

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;
  late _Gateway gateway;
  late AssignmentRepositoryImpl assignments;
  late ProductionRepositoryImpl production;
  late RecallRepositoryImpl recall;

  setUp(() {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
    gateway = _Gateway();
    final coordinator = VerifiedSyncCoordinator(database: db, gateway: gateway);
    assignments = AssignmentRepositoryImpl(db, gateway: gateway);
    production = ProductionRepositoryImpl(
      db,
      gateway: gateway,
      verifiedSync: coordinator,
    );
    recall = RecallRepositoryImpl(
      db,
      gateway: gateway,
      verifiedSync: coordinator,
    );
  });
  tearDown(() => db.close());

  Future<bool> queued(String entityId) async =>
      (await db.watchSyncQueue().first).any((q) => q['entity_id'] == entityId);

  for (final code in [
    'USER_INACTIVE',
    'WORKER_AUTH_FAILED',
    'MISSING_PERMISSION',
    'WORKER_OPERATION_NOT_ALLOWED',
    'WORK_NOT_FOUND',
    'OPERATION_QUANTITY_EXCEEDED',
    'BUSINESS_VALIDATION_FAILED',
    'SHIFT_NOT_APPLICABLE',
  ]) {
    test('$code on a live assignment is rolled back, not queued', () async {
      gateway.rejectWith = code;
      final receipt = await assignments.createAssignment(
        workerId: 'emp-001',
        orderId: 'order-001',
        teamId: 'team-001',
        assignedQuantity: 5,
        businessDate: '2026-09-07',
        shiftId: 'SHIFT_1',
        createdBy: 'MNV00100',
        workerPassword: 'test-only-password',
      );

      expect(receipt.state, MutationDeliveryState.discarded);
      expect(receipt.code, code);
      expect(receipt.isWrongWorkerPassword, code == 'WORKER_AUTH_FAILED');
      expect(await queued(receipt.id), isFalse);
      expect(await db.getAssignmentById(receipt.id), isNull);
    });
  }

  test('wrong worker password on a confirmation keeps the balance', () async {
    final before = (await assignments.getAssignmentById('asg-001'))!;
    gateway.rejectWith = 'WORKER_AUTH_FAILED';

    final receipt = await production.recordProduction(
      assignmentId: before.id,
      quantity: before.remaining,
      businessDate: '2026-09-07',
      shiftId: 'SHIFT_1',
      createdBy: 'MNV00100',
      workerPassword: 'wrong',
    );

    expect(receipt.isWrongWorkerPassword, isTrue);
    expect(await queued(receipt.id), isFalse);
    expect(
      (await assignments.getAssignmentById(before.id))!.remaining,
      before.remaining,
    );

    gateway.rejectWith = null;
    final retry = await production.recordProduction(
      assignmentId: before.id,
      quantity: before.remaining,
      businessDate: '2026-09-07',
      shiftId: 'SHIFT_1',
      createdBy: 'MNV00100',
      workerPassword: 'right',
    );
    expect(retry.state, MutationDeliveryState.synced);
  });

  test('missing permission on a recall is rolled back, not queued', () async {
    final before = (await assignments.getAssignmentById('asg-001'))!;
    gateway.rejectWith = 'MANAGER_OPERATION_NOT_ALLOWED';

    final receipt = await recall.recallAssignment(
      assignmentId: before.id,
      quantity: before.remaining,
      reasonCode: 'PLAN_CHANGE',
      businessDate: '2026-09-07',
      shiftId: 'SHIFT_1',
      createdBy: 'MNV00100',
      workerPassword: 'test-only-password',
    );

    expect(receipt.state, MutationDeliveryState.discarded);
    expect(await queued(receipt.id), isFalse);
    expect(
      (await assignments.getAssignmentById(before.id))!.remaining,
      before.remaining,
    );
  });

  DioException dio(DioExceptionType type, {int? status}) {
    final options = RequestOptions(path: 'x');
    return DioException(
      requestOptions: options,
      type: type,
      response: status == null
          ? null
          : Response<Object?>(requestOptions: options, statusCode: status),
    );
  }

  for (final (label, error) in [
    ('timeout', dio(DioExceptionType.receiveTimeout)),
    ('504', dio(DioExceptionType.badResponse, status: 504)),
    ('no connection', dio(DioExceptionType.connectionError)),
  ]) {
    test('$label keeps the transaction and holds its quantity', () async {
      final before = (await assignments.getAssignmentById('asg-001'))!;
      gateway.throwError = error;

      final receipt = await production.recordProduction(
        assignmentId: before.id,
        quantity: 1,
        businessDate: '2026-09-07',
        shiftId: 'SHIFT_1',
        createdBy: 'MNV00100',
        workerPassword: 'test-only-password',
      );

      expect(receipt.state, isNot(MutationDeliveryState.discarded));
      expect(await queued(receipt.id), isTrue);
      expect(
        (await assignments.getAssignmentById(before.id))!.remaining,
        before.remaining - 1,
      );
    });
  }

  test('an HTTP 500 answer from SAP is rolled back, not queued', () async {
    gateway.throwError = dio(DioExceptionType.badResponse, status: 500);
    final before = (await assignments.getAssignmentById('asg-001'))!;
    final receipt = await production.recordProduction(
      assignmentId: before.id,
      quantity: 1,
      businessDate: '2026-09-07',
      shiftId: 'SHIFT_1',
      createdBy: 'MNV00100',
      workerPassword: 'test-only-password',
    );
    expect(receipt.state, MutationDeliveryState.discarded);
    expect(await queued(receipt.id), isFalse);
  });
}
