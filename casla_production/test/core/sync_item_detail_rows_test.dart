// getSyncItemDetailRows replaced a per-item walk in the sync screen (source
// row, then assignment, then order, then employee). These tests hold the one
// query to exactly what that walk resolved, case by case.

import 'package:casla_production/core/database/casla_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

const _detailColumns = [
  'quantity',
  'unit_of_measure',
  'business_date',
  'shift_id',
  'occurred_at_utc',
  'worker_id',
  'work_id',
  'worker_code',
  'worker_name',
  'production_order',
  'operation',
  'product_name',
  'product_code',
];

/// Who created every transaction here; the feed is scoped to its creator.
const _actor = 'MNV00100';

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;
  late Map<String, dynamic> template;
  var sequence = 0;

  setUp(() async {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
    sequence = 0;
    template = {
      ...(await db.getAssignmentById('asg-001'))!,
      'sap_id': null,
      'sync_status': 'PENDING',
      'created_by': _actor,
    };
  });
  tearDown(() => db.close());

  /// The lookups the sync screen used to make for one queue item.
  Future<Map<String, Object?>?> walk(Map<String, dynamic> item) async {
    final entityType = item['entity_type']?.toString() ?? '';
    final entityId = item['entity_id']?.toString() ?? '';
    if (entityType.isEmpty || entityId.isEmpty) return null;
    final source = await db.getSyncSourceRow(entityType, entityId);
    if (source == null) return null;

    Map<String, dynamic>? assignment;
    if (entityType == 'ASSIGNMENT') {
      assignment = source;
    } else {
      final assignmentId = source['phan_cong_id']?.toString();
      if (assignmentId != null && assignmentId.isNotEmpty) {
        assignment = await db.getAssignmentById(assignmentId);
      }
    }
    Map<String, dynamic>? order;
    final orderId = assignment?['don_hang_id']?.toString();
    if (orderId != null && orderId.isNotEmpty) {
      order = await db.getOrderById(orderId);
    }
    final workerId = assignment?['nhan_vien_id']?.toString().trim() ?? '';
    final employee = workerId.isEmpty
        ? null
        : await db.getEmployeeById(workerId);

    return {
      'quantity':
          source[entityType == 'ASSIGNMENT' ? 'assigned_quantity' : 'quantity'],
      'unit_of_measure': source['unit_of_measure'] ?? order?['uom'],
      'business_date': source['business_date'] ?? assignment?['business_date'],
      'shift_id': source['shift_id'] ?? assignment?['shift_id'],
      'occurred_at_utc': source['occurred_at_utc'],
      'worker_id': assignment?['nhan_vien_id'],
      'work_id': assignment?['to_id'],
      'worker_code': employee?['ma_nv'],
      'worker_name': employee?['ten'],
      'production_order': order?['production_order'] ?? order?['ma_don_hang'],
      'operation': order?['operation'],
      'product_name': order?['ten_sp'],
      'product_code': order?['ma_sp'],
    };
  }

  Future<String> assignment({
    String worker = 'emp-1',
    String order = 'ord-1',
    String? unit = 'CHC',
    String date = '2026-03-04',
    String shift = 'SHIFT_2',
    double quantity = 40,
  }) async {
    final id = 'asg-t${++sequence}';
    await db.insertAssignment({
      ...template,
      'id': id,
      'idempotency_key': id,
      'nhan_vien_id': worker,
      'don_hang_id': order,
      'to_id': 'XM2.00$sequence',
      'unit_of_measure': unit,
      'business_date': date,
      'shift_id': shift,
      'assigned_quantity': quantity,
      'occurred_at_utc': 1000 + sequence,
    });
    return id;
  }

  Future<String> production(
    String assignmentId, {
    String? unit = 'CHC',
    double quantity = 7,
  }) async {
    final id = 'prod-t${++sequence}';
    await db.insertProductionRecord({
      'id': id,
      'phan_cong_id': assignmentId,
      'quantity': quantity,
      'unit_of_measure': unit,
      'business_date': '2026-03-05',
      'shift_id': 'SHIFT_1',
      'created_by': _actor,
      'occurred_at_utc': 2000 + sequence,
      'device_id': 'test',
      'sync_status': 'PENDING',
      'idempotency_key': id,
      'created_at_utc': 1,
    });
    return id;
  }

  Future<String> recall(String assignmentId, {String? unit = 'CHC'}) async {
    final id = 'rec-t${++sequence}';
    await db.insertRecallRecord({
      'id': id,
      'phan_cong_id': assignmentId,
      'quantity': 3,
      'unit_of_measure': unit,
      'reason_code': 'PLAN_CHANGE',
      'business_date': '2026-03-06',
      'shift_id': 'SHIFT_2',
      'created_by': _actor,
      'occurred_at_utc': 3000 + sequence,
      'device_id': 'test',
      'sync_status': 'PENDING',
      'idempotency_key': id,
      'created_at_utc': 1,
    });
    return id;
  }

  Future<String> queue(String entityType, String entityId) async {
    final id = 'q-t${++sequence}';
    await db.insertSyncQueueItem({
      'id': id,
      'entity_type': entityType,
      'entity_id': entityId,
      'action': 'CREATE',
      'created_at_utc': sequence,
      'status': 'PENDING',
    });
    return id;
  }

  /// Every queue id resolves to what the walk resolves, or to nothing where
  /// the walk finds no source row.
  Future<void> expectSameAsWalk(Iterable<String> queueIds) async {
    final ids = queueIds.toList();
    final rows = await db.getSyncItemDetailRows(ids);
    for (final id in ids) {
      final item = (await db.getSyncQueueItemById(id))!;
      final expected = await walk(item);
      final actual = rows[id];
      if (expected == null) {
        expect(actual, isNull, reason: '$id has no source row');
        continue;
      }
      expect(actual, isNotNull, reason: '$id should resolve');
      expect(actual!['queue_id'], id);
      expect(actual['entity_type'], item['entity_type']);
      expect(
        {for (final column in _detailColumns) column: actual[column]},
        expected,
        reason: id,
      );
    }
    expect(rows.keys.toSet().difference(ids.toSet()), isEmpty);
  }

  test('an assignment resolves its own row, order and worker', () async {
    final id = await queue('ASSIGNMENT', await assignment());
    final row = (await db.getSyncItemDetailRows([id]))[id]!;

    expect(row['quantity'], 40.0);
    expect(row['unit_of_measure'], 'CHC');
    expect(row['business_date'], '2026-03-04');
    expect(row['shift_id'], 'SHIFT_2');
    expect(row['worker_id'], 'emp-1');
    expect(row['worker_code'], 'MNV00123');
    expect(row['worker_name'], 'Nguyễn Văn A');
    expect(row['production_order'], '000010001234');
    expect(row['product_code'], 'SP-AKG');
    await expectSameAsWalk([id]);
  });

  test(
    'a confirmation and a recall resolve through their assignment',
    () async {
      final parent = await assignment();
      final ids = [
        await queue('PRODUCTION', await production(parent)),
        await queue('PRODUCTION_RECORD', await production(parent)),
        await queue('RECALL', await recall(parent)),
        await queue('RECALL_RECORD', await recall(parent)),
      ];
      final rows = await db.getSyncItemDetailRows(ids);

      // The record's own quantity, date and shift, not the assignment's.
      expect(rows[ids[0]]!['quantity'], 7.0);
      expect(rows[ids[0]]!['business_date'], '2026-03-05');
      expect(rows[ids[0]]!['shift_id'], 'SHIFT_1');
      expect(rows[ids[2]]!['quantity'], 3.0);
      expect(rows[ids[2]]!['business_date'], '2026-03-06');
      for (final id in ids) {
        expect(rows[id]!['worker_code'], 'MNV00123');
        expect(rows[id]!['work_id'], startsWith('XM2.00'));
      }
      await expectSameAsWalk(ids);
    },
  );

  test('a record with no frozen unit takes the order unit', () async {
    final parent = await assignment(unit: 'CHC');
    final ids = [
      await queue('PRODUCTION', await production(parent, unit: null)),
      await queue('RECALL', await recall(parent, unit: null)),
      await queue('ASSIGNMENT', await assignment(unit: null)),
    ];
    final rows = await db.getSyncItemDetailRows(ids);

    for (final id in ids) {
      expect(rows[id]!['unit_of_measure'], 'cái', reason: id);
    }
    await expectSameAsWalk(ids);
  });

  test('a worker or an order missing on the device leaves blanks', () async {
    final strangerWorker = await assignment(worker: 'CL-NOT-HERE');
    final strangerOrder = await assignment(order: 'ord-not-here', unit: null);
    final ids = [
      await queue('ASSIGNMENT', strangerWorker),
      await queue('PRODUCTION', await production(strangerWorker)),
      await queue('ASSIGNMENT', strangerOrder),
    ];
    final rows = await db.getSyncItemDetailRows(ids);

    expect(rows[ids[0]]!['worker_id'], 'CL-NOT-HERE');
    expect(rows[ids[0]]!['worker_code'], isNull);
    expect(rows[ids[0]]!['worker_name'], isNull);
    expect(rows[ids[1]]!['worker_id'], 'CL-NOT-HERE');
    expect(rows[ids[2]]!['production_order'], isNull);
    expect(rows[ids[2]]!['unit_of_measure'], isNull);
    expect(rows[ids[2]]!['worker_code'], 'MNV00123');
    await expectSameAsWalk(ids);
  });

  test('an item with no source row or an unknown type has no entry', () async {
    final parent = await assignment();
    final ids = [
      await queue('ASSIGNMENT', 'asg-deleted'),
      await queue('PRODUCTION', 'prod-deleted'),
      await queue('RECALL', 'rec-deleted'),
      await queue('SOMETHING_ELSE', parent),
      // The id exists, but in another table than the type names.
      await queue('PRODUCTION', parent),
      await queue('ASSIGNMENT', parent),
    ];
    final rows = await db.getSyncItemDetailRows([...ids, 'q-not-in-queue']);

    expect(rows.keys, [ids.last]);
    await expectSameAsWalk(ids);
  });

  test('empty and duplicate ids are harmless', () async {
    final id = await queue('ASSIGNMENT', await assignment());

    expect(await db.getSyncItemDetailRows(const []), isEmpty);
    expect(await db.getSyncItemDetailRows(const ['']), isEmpty);
    expect((await db.getSyncItemDetailRows([id, id, ''])).keys, [id]);
  });

  test('the seeded queue resolves as the walk does', () async {
    await expectSameAsWalk(['sync-001', 'sync-002']);
  });

  test('a page larger than one SQL chunk resolves every item', () async {
    final parent = await assignment();
    final confirmation = await production(parent);
    final recalled = await recall(parent);
    final ids = <String>[];
    for (var index = 0; index < 900; index++) {
      ids.add(
        await queue(switch (index % 3) {
          0 => 'ASSIGNMENT',
          1 => 'PRODUCTION',
          _ => 'RECALL',
        }, [parent, confirmation, recalled][index % 3]),
      );
    }
    final rows = await db.getSyncItemDetailRows(ids);

    expect(rows, hasLength(900));
    expect(rows[ids[0]]!['quantity'], 40.0);
    expect(rows[ids[1]]!['quantity'], 7.0);
    expect(rows[ids[899]]!['quantity'], 3.0);
    // Spot-check both sides of the chunk boundary against the walk.
    await expectSameAsWalk([ids[0], ids[399], ids[400], ids[401], ids[899]]);
  });

  test('the sync feed page resolves in full', () async {
    final parent = await assignment();
    final ids = [
      await queue('ASSIGNMENT', parent),
      await queue('PRODUCTION', await production(parent)),
      await queue('RECALL', await recall(parent)),
    ];
    final page = await db.getSyncFeedPage(
      actorId: _actor,
      teamIds: const ['XM2.001'],
      filter: SyncFeedFilter.all,
    );
    final pageIds = [for (final item in page.items) item['id'] as String];

    expect(pageIds, containsAll(ids));
    await expectSameAsWalk(pageIds);
  });
}
