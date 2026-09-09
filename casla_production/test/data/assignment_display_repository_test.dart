import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/core/utils/operation_qr_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';
import '../support/fake_sap_gateway.dart';

void main() {
  useInMemoryDatabase();
  late CaslaDatabase db;
  setUp(() {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
  });
  tearDown(() async {
    await db.close();
  });

  test(
    'selected assignment retains display fields and independent totals',
    () async {
      await db.upsertOrderFromOperationQr(
        const OperationQrResult(
          isValid: true,
          rawPayload: '{"ProductionOrder":"000010001234"}',
          productionOrder: '000010001234',
          operation: '0010',
          productCode: 'SP-AKG',
          productName: 'Áo khoác gió — size L',
          workCenter: '67110021',
          plant: '6711',
          workCenterDescription: 'Demo',
          orderCode: 'DH-2026-00417',
          operationQuantity: 1000,
          unitOfMeasure: 'cái',
        ),
      );
      for (var i = 0; i < 2; i++) {
        await db.insertRecallRecord({
          'id': 'recall-display-$i',
          'phan_cong_id': 'asg-001',
          'quantity': 2.5,
          'reason_code': 'NOT_FINISHED',
          'business_date': '2026-09-05',
          'shift_id': 'SHIFT_1',
          'created_by': 'MNV00100',
          'occurred_at_utc': i,
          'device_id': 'TEST',
          'sync_status': 'PENDING',
          'idempotency_key': 'recall-display-$i',
          'created_at_utc': i,
        });
      }
      final repo = AssignmentRepositoryImpl(db, gateway: NoopSapGateway());
      final assignment = (await repo.getAssignmentById('asg-001'))!;
      expect(assignment.workerMaNv, 'MNV00123');
      expect(assignment.orderCode, 'DH-2026-00417');
      expect(assignment.plant, '6711');
      expect(assignment.workCenter, '67110021');
      expect(
        assignment.completedQuantity,
        await db.getCompletedQuantity('asg-001'),
      );
      expect(assignment.recalledQuantity, 5);
      expect(assignment.remaining, 209);
      final team = await repo.watchAssignmentsByTeams(['team-1']).first;
      expect(team, isNotEmpty);
      expect(team.every((item) => item.teamId == 'team-1'), isTrue);
    },
  );

  test('chunked display reads preserve order and omit absent IDs', () async {
    final template = (await db.getAssignmentById('asg-001'))!;
    final ids = <String>[];
    for (var i = 0; i < 405; i++) {
      final id = 'display-$i';
      ids.add(id);
      await db.insertAssignment({...template, 'id': id, 'idempotency_key': id});
    }
    final requested = ids.reversed.toList();
    final rows = await db.getAssignmentDisplayRows([...requested, 'missing']);
    expect(rows.map((row) => row['id']), requested);
    expect(rows.every((row) => row['completed_quantity'] == 0), isTrue);
    expect(await db.getAssignmentDisplayRows([]), isEmpty);
  });

  test(
    'report counts child transactions in their own shift, retaining lifetime balance',
    () async {
      await db.recordProductionOffline(
        assignmentId: 'asg-001',
        quantity: 7,
        businessDate: '2026-09-09',
        shiftId: 'NIGHT',
        createdBy: 'test',
        deviceId: 'test',
      );
      await db.recordProductionOffline(
        assignmentId: 'asg-001',
        quantity: 3,
        businessDate: '2026-09-09',
        shiftId: 'DAY',
        createdBy: 'test',
        deviceId: 'test',
      );
      final rows = await db.getAssignmentDisplayRows(
        ['asg-001'],
        fromBusinessDate: '2026-09-09',
        toBusinessDate: '2026-09-09',
        shiftId: 'NIGHT',
      );
      expect(rows, hasLength(1));
      expect(rows.single['assigned_quantity'], 0);
      expect(rows.single['completed_quantity'], 7);
      expect(rows.single['recalled_quantity'], 0);
      final lifetime = await db.getAssignmentDisplayRows(['asg-001']);
      expect(lifetime.single['assigned_quantity'], greaterThan(0));
      expect(lifetime.single['completed_quantity'], greaterThanOrEqualTo(10));
    },
  );
}
