import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/utils/operation_qr_parser.dart';
import 'package:casla_production/data/repositories/confirmation_targets.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/history_work_context.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/database_test_harness.dart';
import '../support/fake_sap_gateway.dart';

void main() {
  useInMemoryDatabase();
  late CaslaDatabase db;
  late AssignmentRepositoryImpl repo;
  late Map<String, dynamic> template;
  setUp(() async {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
    repo = AssignmentRepositoryImpl(db, gateway: NoopSapGateway());
    template = (await db.getAssignmentById('asg-001'))!;
    final order = await db.upsertOrderFromOperationQr(
      const OperationQrResult(
        isValid: true,
        rawPayload: 'test',
        productionOrder: '010140000365',
        operation: '0020',
        productCode: '200009410',
        productName: 'Túi',
        workCenter: 'CL100077',
        plant: '6711',
        workCenterDescription: '',
        orderCode: '010140000365',
        operationQuantity: 10000,
        unitOfMeasure: 'CHC',
      ),
    );
    template = {
      ...template,
      'id': 'stale',
      'idempotency_key': 'stale',
      'don_hang_id': order!['id'],
      'to_id': 'XM2.002',
      'business_date': '2026-09-23',
      'shift_id': 'DAY',
      'assigned_quantity': 100.0,
      'sap_id': 'allocation',
      'sync_status': 'SYNCED',
      'note': historyImportedAssignmentNote,
      'status': 'OPEN',
    };
    await db.insertAssignment(template);
  });
  tearDown(() => db.close());

  WorkHistoryEntry entry(
    String id,
    String type,
    double qty, {
    String workId = 'XM2.002',
    String workCenter = 'CL100077',
    String operation = '0020',
    DateTime? date,
    String original = '',
  }) => WorkHistoryEntry(
    transactionUuid: id,
    executionDate: date ?? DateTime(2026, 9, 23),
    workerId: template['nhan_vien_id'] as String,
    workerName: 'Khiêm',
    productionOrder: '010140000365',
    operation: operation,
    plant: '6711',
    workCenter: workCenter,
    workId: workId,
    transactionType: type,
    quantity: qty,
    unitOfMeasure: 'CHC',
    transactionStatus: 'POSTED',
    originalTransactionUuid: original,
  );
  Future<List<Assignment>> resolve(
    List<WorkHistoryEntry> entries, {
    bool truncated = false,
  }) => resolveConfirmationTargets(
    db: db,
    assignments: repo,
    history: WorkHistoryResult(
      scopeCode: 'T',
      dateFrom: DateTime(2026, 9, 23),
      dateTo: DateTime(2026, 9, 23),
      isTruncated: truncated,
      entries: entries,
      workers: const [],
    ),
    workerId: template['nhan_vien_id'] as String,
    workerCode: 'NV',
    businessDate: '2026-09-23',
    shiftId: 'DAY',
    workId: 'XM2.002',
    workCenter: 'CL100077',
  );

  group('carried-over balance (REASSIGN)', () {
    test(
      'carried 60 + top-up 20 is one target of 80, sent via REASSIGN',
      () async {
        // Root A was yesterday's allocation, so it is not in today's report;
        // both the overnight snapshot R and today's top-up N point at it.
        final target = (await resolve([
          entry('R', 'REASSIGN', 60, original: 'root-A'),
          entry('N', 'INITIAL_ASSIGN', 20, original: 'root-A'),
        ])).single;
        expect(target.assignedQuantity, 80);
        expect(target.remaining, 80);
        // SAP resolves the whole group from the REASSIGN UUID.
        expect(target.sapId, 'R');
      },
    );

    test('consumption through any group member is deducted once', () async {
      final target = (await resolve([
        entry('R', 'REASSIGN', 60, original: 'root-A'),
        entry('N', 'INITIAL_ASSIGN', 20, original: 'root-A'),
        entry('C1', 'CONFIRM', 30, original: 'R'),
        entry('C2', 'CONFIRM', 5, original: 'root-A'),
        entry('X', 'RECALL', 10, original: 'N'),
        // A reversal points at the confirmation it undoes.
        entry('V', 'REVERSE', 5, original: 'C2'),
      ])).single;
      expect(target.assignedQuantity, 80);
      expect(target.remaining, 80 - 30 - 5 - 10 + 5);
    });

    test(
      'night-shift work posted after midnight counts for its work day',
      () async {
        final late = WorkHistoryEntry(
          transactionUuid: 'C-night',
          // Posted at 02:00 on the 24th, but for the shift of the 23rd.
          executionDate: DateTime(2026, 9, 24, 2),
          reportedWorkDate: DateTime(2026, 9, 23),
          workerId: template['nhan_vien_id'] as String,
          workerName: 'Khiêm',
          productionOrder: '010140000365',
          operation: '0020',
          plant: '6711',
          workCenter: 'CL100077',
          workId: 'XM2.002',
          transactionType: 'CONFIRM',
          quantity: 25,
          unitOfMeasure: 'CHC',
          transactionStatus: 'POSTED',
          originalTransactionUuid: 'R',
        );
        final target = (await resolve([
          entry('R', 'REASSIGN', 60, original: 'root-A'),
          late,
        ])).single;
        expect(target.remaining, 60 - 25);
      },
    );

    test('a re-run delta nets into the opening balance', () async {
      final target = (await resolve([
        entry('R', 'REASSIGN', 60, original: 'root-A'),
        entry('R2', 'REASSIGN', -10, original: 'root-A'),
      ])).single;
      expect(target.assignedQuantity, 50);
    });

    test(
      'an unrelated allocation of the same operation stays separate',
      () async {
        final targets = await resolve([
          entry('R', 'REASSIGN', 60, original: 'root-A'),
          entry('allocation', 'INITIAL_ASSIGN', 7),
        ]);
        expect(
          {for (final t in targets) t.sapId: t.assignedQuantity},
          {'R': 60, 'allocation': 7},
        );
      },
    );
  });

  test(
    'SAP 1433 replaces stale 100 and atomic submit accepts the same balance',
    () async {
      final target = (await resolve([
        entry('allocation', 'INITIAL_ASSIGN', 1433),
      ])).single;
      expect(target.id, 'stale');
      expect(target.assignedQuantity, 1433);
      expect(target.remaining, 1433);
      expect(
        (await db.getOrderById(target.orderId))!['operation_qr_payload'],
        'test',
      );
      await db.recordProductionAtomically(
        record: {
          'id': 'confirm',
          'phan_cong_id': target.id,
          'quantity': 1433.0,
          'business_date': '2026-09-23',
          'shift_id': 'DAY',
          'created_by': 'test',
          'occurred_at_utc': 1,
          'device_id': 'test',
          'sync_status': 'PENDING',
          'idempotency_key': 'confirm',
          'created_at_utc': 1,
        },
        queueItem: {
          'id': 'queue',
          'entity_type': 'PRODUCTION',
          'entity_id': 'confirm',
          'action': 'CREATE',
          'status': 'PENDING',
          'created_at_utc': 1,
          'updated_at_utc': 1,
        },
        auditLog: {
          'id': 'audit',
          'event_type': 'CONFIRM',
          'actor_id': 'test',
          'entity_type': 'Production',
          'entity_id': 'confirm',
          'occurred_at_utc': 1,
        },
        expectedRemaining: 1433,
      );
      expect((await repo.getAssignmentById(target.id))!.remaining, 0);
    },
  );
  test(
    'repeat refresh retains pending quantity and does not double count posted confirmation',
    () async {
      await resolve([entry('allocation', 'INITIAL_ASSIGN', 1433)]);
      await db.insertProductionRecord({
        'id': 'real',
        'phan_cong_id': 'stale',
        'quantity': 33.0,
        'business_date': '2026-09-23',
        'shift_id': 'DAY',
        'created_by': 'test',
        'occurred_at_utc': 1,
        'device_id': 'test',
        'sync_status': 'PENDING',
        'idempotency_key': 'real',
        'sap_id': 'posted',
        'created_at_utc': 1,
      });
      await db.insertSyncQueueItem({
        'id': 'pending-real',
        'entity_type': 'PRODUCTION',
        'entity_id': 'real',
        'action': 'CREATE',
        'status': 'NEEDS_VERIFICATION',
        'idempotency_key': 'real',
        'created_at_utc': 1,
        'updated_at_utc': 1,
      });
      final entries = [
        entry('allocation', 'INITIAL_ASSIGN', 1433),
        entry('external', 'CONFIRM', 100),
      ];
      for (var i = 0; i < 2; i++) {
        expect((await resolve(entries)).single.remaining, 1300);
      }
      expect(
        (await resolve([
          ...entries,
          entry('posted', 'CONFIRM', 33),
        ])).single.remaining,
        1300,
      );
      expect(await db.getCompletedQuantity('stale'), 133);
      final visible = await db.getProductionHistory(
        template['nhan_vien_id'] as String,
        fromBusinessDate: '2026-09-23',
        toBusinessDate: '2026-09-23',
        shiftId: 'DAY',
      );
      expect(visible.map((row) => row['id']), ['real']);
      expect(
        (await db.getSyncQueueItemById('pending-real'))!['idempotency_key'],
        'real',
      );
    },
  );
  test(
    'unrelated synced 100 never wins over current SAP allocation 1433',
    () async {
      final result = await resolve([
        entry('current-allocation', 'INITIAL_ASSIGN', 1433),
      ]);
      expect(result, hasLength(1));
      expect(result.single.sapId, 'current-allocation');
      expect(result.single.remaining, 1433);
      expect(result.single.id, isNot('stale'));
      // Preserve audit history rather than deleting an old source transaction.
      expect((await db.getAssignmentById('stale'))!['assigned_quantity'], 100);
    },
  );
  test(
    'deleting and undoing pending confirmation still restores its quantity after refresh',
    () async {
      final entries = [
        entry('allocation', 'INITIAL_ASSIGN', 1433),
        entry('external', 'CONFIRM', 100),
      ];
      await resolve(entries);
      await db.insertProductionRecord({
        'id': 'pending',
        'phan_cong_id': 'stale',
        'quantity': 33.0,
        'business_date': '2026-09-23',
        'shift_id': 'DAY',
        'created_by': 'test',
        'occurred_at_utc': 1,
        'device_id': 'test',
        'sync_status': 'NEEDS_VERIFICATION',
        'idempotency_key': 'pending',
        'created_at_utc': 1,
      });
      await db.insertSyncQueueItem({
        'id': 'pending-queue',
        'entity_type': 'PRODUCTION',
        'entity_id': 'pending',
        'action': 'CREATE',
        'status': 'NEEDS_VERIFICATION',
        'idempotency_key': 'pending',
        'created_at_utc': 1,
        'updated_at_utc': 1,
      });
      expect((await resolve(entries)).single.remaining, 1300);
      expect(await db.deleteSyncQueueItem('pending-queue'), isTrue);
      expect((await resolve(entries)).single.remaining, 1333);
      // Removed for good: nothing is left to count or to restore.
      expect(await db.getSyncSourceRow('PRODUCTION', 'pending'), isNull);
    },
  );
  test('no fallback to synced 100 when SAP says fully complete', () async {
    expect(
      await resolve([
        entry('allocation', 'INITIAL_ASSIGN', 1433),
        entry('done', 'CONFIRM', 1433),
      ]),
      isEmpty,
    );
  });
  test('no cross-date department or work-center totals', () async {
    final targets = await resolve([
      entry('allocation', 'INITIAL_ASSIGN', 1433),
      entry('other-work', 'INITIAL_ASSIGN', 900, workId: 'XM2.001'),
      entry('other-center', 'INITIAL_ASSIGN', 900, workCenter: 'OTHER'),
      entry('yesterday', 'INITIAL_ASSIGN', 900, date: DateTime(2026, 9, 22)),
    ]);
    expect(targets.single.remaining, 1433);
  });
  test(
    'operation totals stay separate and UUID duplicates do not multiply quantity',
    () async {
      final initial = entry('allocation', 'INITIAL_ASSIGN', 1433);
      final targets = await resolve([
        initial,
        initial,
        entry('second', 'INITIAL_ASSIGN', 200, operation: '0030'),
      ]);
      expect(targets.map((a) => a.remaining), unorderedEquals([1433.0, 200.0]));
    },
  );
  test('truncated history cannot overwrite durable balance', () async {
    await expectLater(
      resolve([entry('allocation', 'INITIAL_ASSIGN', 1433)], truncated: true),
      throwsFormatException,
    );
    expect((await repo.getAssignmentById('stale'))!.remaining, 100);
  });
  test('unknown allocation lineages cannot silently use newest 100', () async {
    await expectLater(
      resolve([
        entry('allocation', 'INITIAL_ASSIGN', 100),
        entry('second', 'INITIAL_ASSIGN', 1333),
        entry('unlinked-confirm', 'CONFIRM', 1),
      ]),
      throwsFormatException,
    );
    expect((await repo.getAssignmentById('stale'))!.remaining, 100);
  });
  test(
    'multiple untouched SAP allocations retain both 100 and 1333 lineages',
    () async {
      final targets = await resolve([
        entry('allocation', 'INITIAL_ASSIGN', 100),
        entry('second', 'INITIAL_ASSIGN', 1333),
      ]);
      expect(targets.map((a) => a.remaining), unorderedEquals([100.0, 1333.0]));
      expect(
        targets.map((a) => a.sapId),
        unorderedEquals(['allocation', 'second']),
      );
    },
  );
  Future<void> realLot(String id, double qty) => db.insertAssignment({
    ...template,
    'id': id,
    'idempotency_key': 'key-$id',
    'assigned_quantity': qty,
    'sap_id': id,
    'note': null,
    'sync_status': 'SYNCED',
  });
  Map<String, dynamic> confirmRow(
    String id,
    String lot,
    double qty, {
    String status = 'SYNCED',
    String? sapId,
  }) => {
    'id': id,
    'phan_cong_id': lot,
    'quantity': qty,
    'business_date': '2026-09-23',
    'shift_id': 'DAY',
    'created_by': 'test',
    'occurred_at_utc': 1,
    'device_id': 'test',
    'sync_status': status,
    'idempotency_key': 'key-$id',
    'sap_id': sapId,
    'created_at_utc': 1,
  };

  test(
    'lots entered on this device resolve per lot even with local work ahead',
    () async {
      // The field case: 1.000 + 333 + 100 assigned, 15 confirmed on the 100.
      await realLot('lot-1000', 1000);
      await realLot('lot-333', 333);
      await realLot('lot-100', 100);
      await db.insertProductionRecord(
        confirmRow('c15', 'lot-100', 15, sapId: 'confirm-15'),
      );
      // Confirmed here a moment ago; SAP's report does not show it yet.
      await db.insertProductionRecord(
        confirmRow('c5', 'lot-333', 5, status: 'PENDING'),
      );
      final targets = await resolve([
        entry('lot-1000', 'INITIAL_ASSIGN', 1000),
        entry('lot-333', 'INITIAL_ASSIGN', 333),
        entry('lot-100', 'INITIAL_ASSIGN', 100),
        entry('confirm-15', 'CONFIRM', 15),
      ]);
      final byId = {for (final a in targets) a.id: a.remaining};
      expect(byId, {'lot-1000': 1000.0, 'lot-333': 328.0, 'lot-100': 85.0});
    },
  );

  test(
    'a lot from another device is untouched when SAP work is all ours',
    () async {
      await realLot('lot-100', 100);
      await db.insertProductionRecord(
        confirmRow('c15', 'lot-100', 15, sapId: 'confirm-15'),
      );
      final targets = await resolve([
        entry('lot-100', 'INITIAL_ASSIGN', 100),
        entry('elsewhere', 'INITIAL_ASSIGN', 333),
        entry('confirm-15', 'CONFIRM', 15),
      ]);
      expect(
        targets.map((a) => '${a.sapId}:${a.remaining}'),
        unorderedEquals(['lot-100:85.0', 'elsewhere:333.0']),
      );
    },
  );

  test(
    'SAP lineage on history rows resolves lots without local records',
    () async {
      final targets = await resolve([
        entry('lot-a', 'INITIAL_ASSIGN', 100),
        entry('lot-b', 'INITIAL_ASSIGN', 333),
        entry('c1', 'CONFIRM', 15, original: 'lot-a'),
        entry('r1', 'RECALL', 3, original: 'lot-b'),
      ]);
      expect(
        targets.map((a) => '${a.sapId}:${a.remaining}'),
        unorderedEquals(['lot-a:85.0', 'lot-b:330.0']),
      );
    },
  );

  test('a root with SAP top-ups from another device is one balance', () async {
    final targets = await resolve([
      entry('root', 'INITIAL_ASSIGN', 100),
      entry('top-1', 'INITIAL_ASSIGN', 333, original: 'root'),
      entry('top-2', 'INITIAL_ASSIGN', 1000, original: 'root'),
      // SAP checks the root total, so one confirmation may exceed the root.
      entry('c1', 'CONFIRM', 150, original: 'root'),
      entry('c2', 'CONFIRM', 15, original: 'top-1'),
    ]);
    expect(targets, hasLength(1));
    expect(targets.single.sapId, 'root');
    expect(targets.single.assignedQuantity, 1433);
    expect(targets.single.remaining, 1268);
  });

  test('top-ups entered on this device keep their own allocations', () async {
    await realLot('root', 100);
    await realLot('top-1', 333);
    final targets = await resolve([
      entry('root', 'INITIAL_ASSIGN', 100),
      entry('top-1', 'INITIAL_ASSIGN', 333, original: 'root'),
    ]);
    expect(
      targets.map((a) => '${a.id}:${a.remaining}'),
      unorderedEquals(['root:100.0', 'top-1:333.0']),
    );
  });

  test('the same worker by local id or SAP code reuses one import', () async {
    final history = WorkHistoryResult(
      scopeCode: 'T',
      dateFrom: DateTime(2026, 9, 23),
      dateTo: DateTime(2026, 9, 23),
      isTruncated: false,
      entries: [entry('lot-967', 'INITIAL_ASSIGN', 967)],
      workers: const [],
    );
    Future<List<Assignment>> open(String workerId) =>
        resolveConfirmationTargets(
          db: db,
          assignments: repo,
          history: history,
          workerId: workerId,
          workerCode: 'MNV00123',
          businessDate: '2026-09-23',
          shiftId: 'DAY',
          workId: 'XM2.002',
          workCenter: 'CL100077',
        );
    // Tab Xác nhận knows the local employee id...
    final fromConfirmTab = await open(template['nhan_vien_id'] as String);
    // ...the employee detail screen may only know the SAP code.
    final fromDetail = await open('MNV00123');
    expect(fromDetail.single.id, fromConfirmTab.single.id);
    expect(fromDetail.single.remaining, 967);
  });

  test('an allocation not yet posted to SAP cannot be confirmed', () async {
    await db.insertAssignment({
      ...template,
      'id': 'held',
      'idempotency_key': 'held',
      'assigned_quantity': 1000.0,
      'sap_id': null,
      'note': null,
      'sync_status': 'NEEDS_VERIFICATION',
    });
    // Nothing posted: say why instead of "nothing to confirm".
    await expectLater(
      resolve(const []),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('chưa được gửi lên SAP'),
        ),
      ),
    );
  });

  test('settled allocations come along only when asked for', () async {
    await realLot('lot-a', 100);
    await realLot('lot-b', 20);
    await db.insertProductionRecord(
      confirmRow('c20', 'lot-b', 20, sapId: 'confirm-20'),
    );
    final entries = [
      entry('lot-a', 'INITIAL_ASSIGN', 100),
      entry('lot-b', 'INITIAL_ASSIGN', 20),
      entry('confirm-20', 'CONFIRM', 20, original: 'lot-b'),
    ];
    expect((await resolve(entries)).map((a) => a.id), ['lot-a']);
    final all = await resolveConfirmationTargets(
      db: db,
      assignments: repo,
      history: WorkHistoryResult(
        scopeCode: 'T',
        dateFrom: DateTime(2026, 9, 23),
        dateTo: DateTime(2026, 9, 23),
        isTruncated: false,
        entries: entries,
        workers: const [],
      ),
      workerId: template['nhan_vien_id'] as String,
      workerCode: 'NV',
      businessDate: '2026-09-23',
      shiftId: 'DAY',
      workId: 'XM2.002',
      workCenter: 'CL100077',
      includeSettled: true,
    );
    expect(all.map((a) => a.id), unorderedEquals(['lot-a', 'lot-b']));
  });
}
