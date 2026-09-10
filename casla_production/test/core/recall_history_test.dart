import 'package:casla_production/core/database/casla_database.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();
  test('recall history filters worker, business date and shift', () async {
    CaslaDatabase.resetForTesting();
    final db = CaslaDatabase.instance;
    addTearDown(db.close);
    final assignment = (await db.getAssignmentById('asg-001'))!;
    final workerId = assignment['nhan_vien_id'] as String;
    for (final row in [
      ('one', '2026-09-09', 'DAY'),
      ('two', '2026-09-09', 'NIGHT'),
      ('old', '2026-09-08', 'DAY'),
    ]) {
      await db.insertRecallRecord({
        'id': row.$1,
        'phan_cong_id': assignment['id'],
        'quantity': 1,
        'unit_of_measure': 'ST',
        'reason_code': 'PLAN_CHANGE',
        'business_date': row.$2,
        'shift_id': row.$3,
        'created_by': 'tester',
        'occurred_at_utc': 1,
        'device_id': 'test',
        'sync_status': 'PENDING',
        'idempotency_key': row.$1,
        'created_at_utc': 1,
      });
    }
    Future<List<Map<String, dynamic>>> history(String worker, String? shift) =>
        db
            .watchRecallHistory(
              worker,
              fromBusinessDate: '2026-09-09',
              toBusinessDate: '2026-09-09',
              shiftId: shift,
            )
            .first;
    expect((await history(workerId, 'DAY')).map((e) => e['id']), ['one']);
    expect(await history(workerId, null), hasLength(2));
    expect(await history('another-worker', null), isEmpty);
  });
}
