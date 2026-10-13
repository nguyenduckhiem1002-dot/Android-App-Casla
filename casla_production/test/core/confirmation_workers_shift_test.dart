import 'package:casla_production/core/database/casla_database.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();
  setUp(() => CaslaDatabase.resetForTesting());
  test(
    'confirmation workers require matching date shift and department',
    () async {
      final db = CaslaDatabase.instance;
      await db.ready;
      final assignments = await db.watchAllAssignments().first;
      final row = assignments.first;
      Future<Set<String>> query({
        String? date,
        String? shift,
        List<String>? teams,
      }) => db.getAssignedWorkerIdsForShift(
        teamIds: teams ?? [row['to_id'] as String],
        businessDate: date ?? row['business_date'] as String,
        shiftId: shift ?? row['shift_id'] as String,
      );
      expect(await query(), contains(row['nhan_vien_id']));
      expect(await query(date: '1900-01-01'), isEmpty);
      expect(await query(shift: 'OTHER_SHIFT'), isEmpty);
      expect(await query(teams: ['OTHER_TEAM']), isEmpty);
      expect(await query(teams: []), isEmpty);
      expect(await query(shift: ''), isEmpty);
    },
  );

  test(
    'confirmation workers exclude completed work even when worker has open work in another department',
    () async {
      final db = CaslaDatabase.instance;
      await db.ready;
      final assignments = await db.watchAllAssignments().first;
      final current = assignments.first;
      final workerId = current['nhan_vien_id'] as String;
      final currentTeam = current['to_id'] as String;
      final businessDate = current['business_date'] as String;
      final shiftId = current['shift_id'] as String;

      await db.recordProductionOffline(
        assignmentId: current['id'] as String,
        quantity: (current['assigned_quantity'] as num).toDouble(),
        businessDate: businessDate,
        shiftId: shiftId,
        createdBy: 'test-supervisor',
        deviceId: 'test-device',
      );
      await db.insertAssignment({
        ...current,
        'id': 'open-in-other-department',
        'to_id': 'OTHER_DEPARTMENT',
        'status': 'OPEN',
        'sync_status': 'SYNCED',
        'idempotency_key': 'idem-open-in-other-department',
        'created_at_utc': (current['created_at_utc'] as int) + 1,
      });

      expect(
        await db.getAssignedWorkerIdsForShift(
          teamIds: [currentTeam],
          businessDate: businessDate,
          shiftId: shiftId,
        ),
        isNot(contains(workerId)),
      );
      expect(
        await db.getAssignedWorkerIdsForShift(
          teamIds: ['OTHER_DEPARTMENT'],
          businessDate: businessDate,
          shiftId: shiftId,
        ),
        contains(workerId),
      );
    },
  );
}
