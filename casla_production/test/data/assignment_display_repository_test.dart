import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
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
}
