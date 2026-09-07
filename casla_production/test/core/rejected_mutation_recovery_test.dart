import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/sync/sap_write_gateway.dart';
import 'package:casla_production/core/sync/verified_sync_coordinator.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/odata_error.dart';
import 'package:casla_production/domain/entities/mutation_receipt.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

class _Gateway implements SapWriteGateway {
  bool reject = true;
  final List<SyncPushRequest> requests = [];

  @override
  Future<bool> refreshSession() async => false;

  @override
  Future<SapWriteResult> push(SyncPushRequest request) async {
    requests.add(request);
    if (reject) throw const SapBusinessError('BUSINESS_VALIDATION_FAILED');
    return SapWriteResult(sapId: 'sap-${request.entityId}');
  }
}

void main() {
  useInMemoryDatabase();

  for (final recalled in [false, true]) {
    test(
      'can complete again after SAP rejects a full ${recalled ? 'recall' : 'completion'}',
      () async {
        CaslaDatabase.resetForTesting();
        final db = CaslaDatabase.instance;
        addTearDown(db.close);
        final gateway = _Gateway();
        final coordinator = VerifiedSyncCoordinator(
          database: db,
          gateway: gateway,
        );
        final production = ProductionRepositoryImpl(
          db,
          gateway: gateway,
          verifiedSync: coordinator,
        );
        final recall = RecallRepositoryImpl(
          db,
          gateway: gateway,
          verifiedSync: coordinator,
        );
        final assignments = AssignmentRepositoryImpl(db, gateway: gateway);
        final before = (await assignments.getAssignmentById('asg-001'))!;

        Future<MutationReceipt> complete(double quantity) =>
            production.recordProduction(
              assignmentId: before.id,
              quantity: quantity,
              businessDate: '2026-09-07',
              shiftId: 'SHIFT_1',
              createdBy: 'MNV00100',
              workerPassword: 'test-only-password',
            );

        final rejected = recalled
            ? await recall.recallAssignment(
                assignmentId: before.id,
                quantity: before.remaining,
                reasonCode: 'PLAN_CHANGE',
                businessDate: '2026-09-07',
                shiftId: 'SHIFT_1',
                createdBy: 'MNV00100',
                workerPassword: 'test-only-password',
              )
            : await complete(before.remaining);
        expect(rejected.state, MutationDeliveryState.rejected);
        final reopened = (await assignments.getAssignmentById(before.id))!;
        expect(reopened.canRecord, isTrue);
        expect(reopened.remaining, before.remaining);

        gateway.reject = false;
        final replacement = await complete(before.remaining);
        expect(replacement.state, MutationDeliveryState.synced);
        expect((await assignments.getAssignmentById(before.id))!.remaining, 0);
        expect(gateway.requests, hasLength(2));
        expect(
          gateway.requests.last.idempotencyKey,
          isNot(gateway.requests.first.idempotencyKey),
        );
        final rejectedSource = await db.getSyncSourceRow(
          recalled ? 'RECALL' : 'PRODUCTION',
          rejected.id,
        );
        expect(rejectedSource!['sync_status'], 'FAILED');
        expect(
          (await db.watchSyncQueue().first).any(
            (q) => q['entity_id'] == rejected.id,
          ),
          isTrue,
        );
        await expectLater(complete(0.001), throwsA(isA<Exception>()));
      },
    );
  }
}
