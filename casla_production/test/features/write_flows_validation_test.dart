// Write-flow tests — the three supervisor operations that mutate production data.
//
// Before Phase 2 the screens called CaslaDatabase directly, so none of the
// business rules below ran: ProductionMath's validation existed, had passing
// unit tests, and was unreachable from the app. These tests exercise the same
// repository entry points the screens now use, so a regression that reintroduces
// a direct db.* write turns them red.

import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/domain/entities/enums.dart';
import '../support/database_test_harness.dart';
import '../support/fake_sap_gateway.dart';

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;
  late AssignmentRepositoryImpl assignmentRepo;
  late ProductionRepositoryImpl productionRepo;
  late RecallRepositoryImpl recallRepo;

  setUp(() {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
    final gateway = NoopSapGateway();
    assignmentRepo = AssignmentRepositoryImpl(db, gateway: gateway);
    productionRepo = ProductionRepositoryImpl(db, gateway: gateway);
    recallRepo = RecallRepositoryImpl(db, gateway: gateway);
  });

  // Seed assignment asg-001: 650 assigned, 436 already completed (prod-001 +
  // prod-003), 0 recalled — so 214 remain.
  const seededAssignmentId = 'asg-001';
  const seededRemaining = 214.0;

  group('Create assignment', () {
    test('accepts a positive quantity', () async {
      final id = await assignmentRepo.createAssignment(
        workerId: 'emp-1',
        orderId: 'ord-1',
        teamId: 'team-2',
        assignedQuantity: 120.0,
        businessDate: '2026-08-14',
        shiftId: 'SHIFT_1',
        createdBy: 'MNV00100',
      );

      expect(id, isNotEmpty);
      expect(await db.getAssignmentById(id), isNotNull);
    });

    test('rejects a zero quantity', () async {
      await expectLater(
        assignmentRepo.createAssignment(
          workerId: 'emp-1',
          orderId: 'ord-1',
          teamId: 'team-2',
          assignedQuantity: 0.0,
          businessDate: '2026-08-14',
          shiftId: 'SHIFT_1',
          createdBy: 'MNV00100',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('rejects a negative quantity', () async {
      await expectLater(
        assignmentRepo.createAssignment(
          workerId: 'emp-1',
          orderId: 'ord-1',
          teamId: 'team-2',
          assignedQuantity: -5.0,
          businessDate: '2026-08-14',
          shiftId: 'SHIFT_1',
          createdBy: 'MNV00100',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('Record production', () {
    test('accepts a quantity within the remaining ceiling', () async {
      final before = await db.getCompletedQuantity(seededAssignmentId);

      await productionRepo.recordProduction(
        assignmentId: seededAssignmentId,
        quantity: 50.0,
        businessDate: '2026-08-14',
        shiftId: 'SHIFT_1',
        createdBy: 'MNV00100',
      );

      expect(
        await db.getCompletedQuantity(seededAssignmentId),
        closeTo(before + 50.0, 0.001),
      );
    });

    test('rejects a quantity above the remaining ceiling', () async {
      final before = await db.getCompletedQuantity(seededAssignmentId);

      await expectLater(
        productionRepo.recordProduction(
          assignmentId: seededAssignmentId,
          quantity: seededRemaining + 1,
          businessDate: '2026-08-14',
          shiftId: 'SHIFT_1',
          createdBy: 'MNV00100',
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('vượt quá'),
          ),
        ),
      );

      // The rejected write must not have landed.
      expect(
        await db.getCompletedQuantity(seededAssignmentId),
        closeTo(before, 0.001),
      );
    });

    test('rejects a write against a closed assignment', () async {
      await db.updateAssignmentStatus(seededAssignmentId, 'CLOSED', 'PENDING');

      await expectLater(
        productionRepo.recordProduction(
          assignmentId: seededAssignmentId,
          quantity: 10.0,
          businessDate: '2026-08-14',
          shiftId: 'SHIFT_1',
          createdBy: 'MNV00100',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('rejects an unknown assignment', () async {
      await expectLater(
        productionRepo.recordProduction(
          assignmentId: 'asg-does-not-exist',
          quantity: 10.0,
          businessDate: '2026-08-14',
          shiftId: 'SHIFT_1',
          createdBy: 'MNV00100',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('Recall assignment', () {
    test('accepts a recall within the max-recall ceiling', () async {
      await recallRepo.recallAssignment(
        assignmentId: seededAssignmentId,
        quantity: 100.0,
        reasonCode: RecallReason.planChange.code,
        businessDate: '2026-08-14',
        shiftId: 'SHIFT_1',
        createdBy: 'MNV00100',
      );

      expect(
        await db.getRecalledQuantity(seededAssignmentId),
        closeTo(100.0, 0.001),
      );
    });

    test('rejects a recall above the max-recall ceiling', () async {
      // 650 assigned − 436 completed − 0 recalled = 214 recallable.
      await expectLater(
        recallRepo.recallAssignment(
          assignmentId: seededAssignmentId,
          quantity: seededRemaining + 1,
          reasonCode: RecallReason.planChange.code,
          businessDate: '2026-08-14',
          shiftId: 'SHIFT_1',
          createdBy: 'MNV00100',
        ),
        throwsA(isA<Exception>()),
      );

      expect(await db.getRecalledQuantity(seededAssignmentId), 0.0);
    });

    // Pins the fix from P2-01. The screen used to send 'KHAC' while the domain
    // layer checks for 'OTHER', so this rule silently never fired.
    test('rejects the "other" reason when the note is blank', () async {
      await expectLater(
        recallRepo.recallAssignment(
          assignmentId: seededAssignmentId,
          quantity: 10.0,
          reasonCode: RecallReason.other.code,
          note: '   ',
          businessDate: '2026-08-14',
          shiftId: 'SHIFT_1',
          createdBy: 'MNV00100',
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('ghi chú'),
          ),
        ),
      );

      expect(await db.getRecalledQuantity(seededAssignmentId), 0.0);
    });

    test('accepts the "other" reason when a note is supplied', () async {
      await recallRepo.recallAssignment(
        assignmentId: seededAssignmentId,
        quantity: 10.0,
        reasonCode: RecallReason.other.code,
        note: 'Máy hỏng, chuyển tổ khác',
        businessDate: '2026-08-14',
        shiftId: 'SHIFT_1',
        createdBy: 'MNV00100',
      );

      expect(
        await db.getRecalledQuantity(seededAssignmentId),
        closeTo(10.0, 0.001),
      );
    });
  });

  group('Assignment projection', () {
    test('carries real completed and recalled totals', () async {
      final assignment = await assignmentRepo.getAssignmentById(
        seededAssignmentId,
      );

      expect(assignment, isNotNull);
      expect(assignment!.assignedQuantity, 650.0);
      // 236 + 200 from the seeded production records.
      expect(assignment.completedQuantity, closeTo(436.0, 0.001));
      expect(assignment.recalledQuantity, 0.0);
      expect(assignment.remaining, closeTo(seededRemaining, 0.001));
      // Resolved through the order lookup, not a fallback to the raw id.
      expect(assignment.orderCode, 'DH-2026-00417');
      expect(assignment.workerName, isNotEmpty);
    });
  });
}
