import 'package:casla_production/core/database/casla_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

/// `getGroupAssignmentPosition` binds a top-up to the position the group was
/// made at only while the group still has work on it. Once it is fully
/// recalled, or confirmed and recalled down to zero, the same operation may
/// be given again at another position.
void main() {
  useInMemoryDatabase();

  const worker = 'emp-2';
  const order = 'ord-1';
  const date = '2026-10-20';
  const shift = 'SHIFT_1';

  late CaslaDatabase db;
  var sequence = 0;

  setUp(() {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
    addTearDown(db.close);
  });

  Future<String> assign(
    double quantity, {
    String? position,
    String syncStatus = 'PENDING',
  }) async {
    final id = 'grp-asg-${++sequence}';
    await db.insertAssignment({
      'id': id,
      'nhan_vien_id': worker,
      'don_hang_id': order,
      'to_id': 'team-1',
      'assigned_quantity': quantity,
      'unit_of_measure': 'CHC',
      'business_date': date,
      'shift_id': shift,
      'status': 'OPEN',
      'position_id': position,
      'created_by': 'tester',
      'occurred_at_utc': sequence,
      'device_id': 'test',
      'sync_status': syncStatus,
      'idempotency_key': id,
      'created_at_utc': sequence,
    });
    return id;
  }

  Future<void> confirm(
    String assignment,
    double quantity, {
    double defect = 0,
    String syncStatus = 'PENDING',
  }) => db.insertProductionRecord({
    'id': 'grp-prod-${++sequence}',
    'phan_cong_id': assignment,
    'quantity': quantity,
    'defect_quantity': defect,
    'unit_of_measure': 'CHC',
    'business_date': date,
    'shift_id': shift,
    'created_by': 'tester',
    'occurred_at_utc': sequence,
    'device_id': 'test',
    'sync_status': syncStatus,
    'idempotency_key': 'grp-prod-$sequence',
    'created_at_utc': sequence,
  });

  Future<void> recall(String assignment, double quantity) =>
      db.insertRecallRecord({
        'id': 'grp-rec-${++sequence}',
        'phan_cong_id': assignment,
        'quantity': quantity,
        'unit_of_measure': 'CHC',
        'reason_code': 'PLAN_CHANGE',
        'business_date': date,
        'shift_id': shift,
        'created_by': 'tester',
        'occurred_at_utc': sequence,
        'device_id': 'test',
        'sync_status': 'PENDING',
        'idempotency_key': 'grp-rec-$sequence',
        'created_at_utc': sequence,
      });

  Future<String?> groupPosition() => db.getGroupAssignmentPosition(
    workerId: worker,
    orderId: order,
    businessDate: date,
    shiftId: shift,
  );

  test('an open group binds the next assignment to its position', () async {
    final id = await assign(10, position: 'D2-5');
    await confirm(id, 4);

    expect(await groupPosition(), 'D2-5');
  });

  test('a fully recalled group leaves the position free', () async {
    final id = await assign(10, position: 'D2-5');
    await recall(id, 10);

    expect(await groupPosition(), isNull);
  });

  test('confirmed, defective and recalled down to zero frees it', () async {
    final id = await assign(10, position: 'D2-5');
    await confirm(id, 5, defect: 2);
    await recall(id, 3);

    expect(await groupPosition(), isNull);
  });

  test('the balance is taken over the whole group', () async {
    final first = await assign(10, position: 'D2-5');
    await recall(first, 10);
    // A later top-up without a position keeps the group open.
    await assign(5);

    expect(await groupPosition(), 'D2-5');
  });

  test('a confirmation SAP rejected does not settle the group', () async {
    final id = await assign(10, position: 'D2-5');
    await confirm(id, 10, syncStatus: 'FAILED');

    expect(await groupPosition(), 'D2-5');
  });

  test('the ledger tells what SAP has not seen yet', () async {
    final posted = await assign(10, position: 'D2-5', syncStatus: 'SYNCED');
    await confirm(posted, 4, syncStatus: 'SYNCED');
    await confirm(posted, 2);
    await recall(posted, 1);
    await assign(5);

    final ledger = await db.getGroupAssignmentLedger(
      workerId: worker,
      orderId: order,
      businessDate: date,
      shiftId: shift,
    );
    expect(ledger.hasRows, isTrue);
    expect(ledger.position, 'D2-5');
    expect(ledger.remaining, 8);
    // The queued confirmation, recall and top-up: -2 - 1 + 5.
    expect(ledger.unsentDelta, 2);
  });

  test('the ledger is scoped to the department when one is given', () async {
    await assign(10, position: 'D2-5');

    final other = await db.getGroupAssignmentLedger(
      workerId: worker,
      orderId: order,
      businessDate: date,
      shiftId: shift,
      workId: 'team-2',
    );
    expect(other.hasRows, isFalse);
    expect(other.openPosition, isNull);

    final same = await db.getGroupAssignmentLedger(
      workerId: worker,
      orderId: order,
      businessDate: date,
      shiftId: shift,
      workId: 'team-1',
    );
    expect(same.openPosition, 'D2-5');
  });
}
