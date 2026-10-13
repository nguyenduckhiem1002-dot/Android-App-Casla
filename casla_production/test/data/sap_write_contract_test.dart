// Contract tests for the write path: what SQLite keeps and what ZUI_PP_OPALLOC
// receives must be the same transaction.
//
// These drive the real repository and the real gateway with the HTTP transport
// intercepted, so the assertions are made against the actual POST body the
// gateway builds — not against a re-implementation of it.

import 'package:casla_production/core/config/app_config.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/sync/sap_write_gateway.dart';
import 'package:casla_production/core/utils/operation_qr_parser.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';
import 'package:casla_production/data/sap/sap_pp_opalloc_gateway.dart';
import 'package:casla_production/data/sap/sap_session_provider.dart';
import 'package:casla_production/domain/policies/production_math.dart';
import 'package:casla_production/domain/entities/work_history.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

class _Session implements SapSessionProvider {
  @override
  String get accessToken => 'contract-token';
  @override
  int get generation => 1;
  @override
  bool isGenerationCurrent(int generation) => generation == 1;
  @override
  Future<bool> refreshSession() async => false;
}

class _OfflineClient extends SapODataClient {
  _OfflineClient()
    : super(
        baseUrl: 'https://contract.invalid/',
        transportAuthMode: SapTransportAuthMode.gateway,
      );

  // CSRF fetching builds its own Dio, so stubbing the interceptor below is not
  // enough to keep this test off the network.
  @override
  Future<String?> fetchCsrfToken() async => 'contract-csrf';
}

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;
  late SapPpOpAllocGateway gateway;
  late AssignmentRepositoryImpl repo;
  late List<Map<String, dynamic>> payloads;
  late List<String> requestPaths;
  late List<Duration?> requestReceiveTimeouts;
  Map<String, dynamic>? historyResponse;

  setUp(() {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
    payloads = [];
    historyResponse = null;
    requestPaths = [];
    requestReceiveTimeouts = [];
    final client = _OfflineClient();
    client.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (request.method == 'POST') {
            // A decimal encoded as a JSON string requires explicit OData
            // IEEE754 negotiation, including on the actual outgoing request.
            expect(request.contentType, contains('IEEE754Compatible=true'));
            payloads.add(Map<String, dynamic>.from(request.data as Map));
            requestPaths.add(request.path);
            requestReceiveTimeouts.add(request.receiveTimeout);
          }
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              headers: Headers.fromMap({
                'x-csrf-token': ['contract-csrf'],
              }),
              data:
                  historyResponse ??
                  {
                    'Status': 'SUCCESS',
                    'TransactionUUID': '00000000-0000-0000-0000-000000000001',
                  },
            ),
          );
        },
      ),
    );
    gateway = SapPpOpAllocGateway(db: db, client: client, session: _Session());
    repo = AssignmentRepositoryImpl(db, gateway: gateway);
  });

  Future<String> scan(String uom) async {
    final order = await db.upsertOrderFromOperationQr(
      OperationQrParser.parse(
        '{"ProductionOrder":"000001000020","Operation":"0010",'
        '"UnitOfMeasure":"$uom"}',
      ),
    );
    return order!['id'] as String;
  }

  Future<String> assign({
    required String orderId,
    required double quantity,
  }) async {
    final receipt = await repo.createAssignment(
      workerId: 'emp-1',
      orderId: orderId,
      teamId: 'team-2',
      assignedQuantity: quantity,
      businessDate: '2026-09-07',
      shiftId: 'SHIFT_1',
      createdBy: 'contract-manager',
      workerPassword: 'contract-password',
    );
    return receipt.id;
  }

  test('the stored quantity is exactly the quantity SAP receives', () async {
    // ztb_pp_alloc_txn-quantity is quan(15,3). A 4th decimal used to survive
    // into SQLite and be dropped only on the wire, so the row on the device
    // and the row in SAP disagreed with nothing to reconcile them.
    final id = await assign(orderId: await scan('KG'), quantity: 1.2345);

    final row = await db.getAssignmentById(id);
    expect(
      row!['assigned_quantity'],
      double.parse(payloads.single['Quantity'] as String),
    );
    expect(row['assigned_quantity'], ProductionMath.toSapScale(1.2345));
    expect(payloads.single['ShiftID'], 'SHIFT_1');
    expect(payloads.single['WorkID'], 'team-2');
    // The moment of entry travels as Vietnam wall-clock date and time, frozen
    // on the row so that a retry repeats it to the second.
    expect(row['entry_date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    expect(row['entry_time'], matches(RegExp(r'^\d{2}:\d{2}:\d{2}$')));
    expect(payloads.single['EntryDate'], row['entry_date']);
    expect(payloads.single['EntryTime'], row['entry_time']);
    expect(payloads.single['PostingDate'], '2026-09-07');
    expect(payloads.single.containsKey('ExecutedAt'), isFalse);
    expect(payloads.single.containsKey('ExecutionDate'), isFalse);
  });

  Future<Map<String, dynamic>> pushRecord(
    String entityType,
    String assignmentId, {
    required String key,
    String? entryDate,
    String? entryTime,
  }) async {
    payloads.clear();
    await gateway.push(
      SyncPushRequest(
        queueItem: {
          'id': 'contract-$key',
          'entity_type': entityType,
          'entity_id': 'rec-$key',
          'action': 'CREATE',
        },
        source: {
          'id': 'rec-$key',
          'phan_cong_id': assignmentId,
          'quantity': 1.0,
          'unit_of_measure': 'KG',
          // Night shift 22:00-06:00 of the 7th, worked at 02:00 on the 8th
          // in Vietnam, which is 19:00 UTC on the 7th.
          'business_date': '2026-09-07',
          'shift_id': 'NIGHT',
          'occurred_at_utc': DateTime.utc(
            2026,
            9,
            7,
            19,
          ).millisecondsSinceEpoch,
          'entry_date': ?entryDate,
          'entry_time': ?entryTime,
          'reason_code': 'OTHER',
          'idempotency_key': '00000000-0000-4000-8000-0000000000$key',
        },
        workerPassword: 'contract-password',
      ),
    );
    return payloads.single;
  }

  test('a night-shift entry sends its own date and the shift date', () async {
    final assignmentId = await assign(orderId: await scan('KG'), quantity: 5);

    for (final (entityType, key) in [('PRODUCTION', 'e1'), ('RECALL', 'e2')]) {
      final payload = await pushRecord(
        entityType,
        assignmentId,
        key: key,
        entryDate: '2026-09-08',
        entryTime: '02:00:00',
      );

      expect(payload['ShiftID'], 'NIGHT', reason: entityType);
      expect(payload['EntryDate'], '2026-09-08', reason: entityType);
      expect(payload['EntryTime'], '02:00:00', reason: entityType);
      // The day the shift began, not the calendar day of the entry.
      expect(payload['PostingDate'], '2026-09-07', reason: entityType);
      expect(payload.containsKey('ExecutedAt'), isFalse, reason: entityType);
      expect(payload.containsKey('ExecutionDate'), isFalse, reason: entityType);
    }
  });

  test('a row queued by an older build keeps its UTC format', () async {
    // SAP compares a retry with the first attempt to the second; switching
    // such a row to EntryDate/EntryTime would earn IDEMPOTENCY_KEY_REUSED.
    final assignmentId = await assign(orderId: await scan('KG'), quantity: 5);

    for (final (entityType, key) in [('PRODUCTION', 'f1'), ('RECALL', 'f2')]) {
      final payload = await pushRecord(entityType, assignmentId, key: key);

      expect(payload['ShiftID'], 'NIGHT', reason: entityType);
      expect(payload['ExecutedAt'], '2026-09-07T19:00:00.000Z');
      expect(payload['ExecutionDate'], '2026-09-07', reason: entityType);
      for (final field in ['EntryDate', 'EntryTime', 'PostingDate']) {
        expect(
          payload.containsKey(field),
          isFalse,
          reason: '$entityType $field',
        );
      }
    }
  });

  test('an assignment queued by an older build keeps its UTC format', () async {
    final id = await assign(orderId: await scan('KG'), quantity: 5);
    final row = Map<String, dynamic>.from((await db.getAssignmentById(id))!)
      ..['entry_date'] = null
      ..['entry_time'] = null;
    payloads.clear();

    await gateway.push(
      SyncPushRequest(
        queueItem: {
          'id': 'contract-legacy-assign',
          'entity_type': 'ASSIGNMENT',
          'entity_id': id,
          'action': 'CREATE',
        },
        source: row,
        workerPassword: 'contract-password',
      ),
    );

    final payload = payloads.single;
    expect(payload['ExecutionDate'], '2026-09-07');
    expect(DateTime.parse(payload['ExecutedAt'] as String).isUtc, isTrue);
    expect(payload.containsKey('EntryDate'), isFalse);
    expect(payload.containsKey('PostingDate'), isFalse);
  });

  test('the chosen position is stored and sent as PositionID', () async {
    final orderId = await scan('KG');
    final receipt = await repo.createAssignment(
      workerId: 'emp-1',
      orderId: orderId,
      teamId: 'team-2',
      assignedQuantity: 5,
      businessDate: '2026-09-07',
      shiftId: 'SHIFT_1',
      createdBy: 'contract-manager',
      workerPassword: 'contract-password',
      positionId: 'g07',
      machineId: 'm107',
    );

    final row = await db.getAssignmentById(receipt.id);
    expect(row!['position_id'], 'G07');
    expect(row['machine_id'], 'M107');
    expect(payloads.single['PositionID'], 'G07');
    // The ledger has no machine column; it stays on the device.
    expect(payloads.single.containsKey('MachineID'), isFalse);
  });

  test('an assignment without a position still sends PositionID', () async {
    // The gateway answers "No value for mandatory parameter 'PositionID'"
    // when a declared action parameter is left out, so it travels empty.
    await assign(orderId: await scan('KG'), quantity: 5);

    expect(payloads.single['PositionID'], '');
  });

  test('confirm and recall send no PositionID', () async {
    // Only submitInitialAssign declares it; an undeclared action parameter
    // would be refused by the gateway.
    final assignmentId = await assign(orderId: await scan('KG'), quantity: 5);
    payloads.clear();
    requestPaths.clear();

    for (final entityType in ['PRODUCTION', 'RECALL']) {
      await gateway.push(
        SyncPushRequest(
          queueItem: {
            'id': 'contract-$entityType',
            'entity_type': entityType,
            'entity_id': 'rec-$entityType',
            'action': 'CREATE',
          },
          source: {
            'id': 'rec-$entityType',
            'phan_cong_id': assignmentId,
            'quantity': 1.0,
            'unit_of_measure': 'KG',
            'business_date': '2026-09-07',
            'shift_id': 'SHIFT_1',
            'occurred_at_utc': DateTime.utc(
              2026,
              9,
              7,
              3,
            ).millisecondsSinceEpoch,
            'reason_code': 'OTHER',
            'idempotency_key': entityType == 'PRODUCTION'
                ? '00000000-0000-4000-8000-0000000000c1'
                : '00000000-0000-4000-8000-0000000000c2',
          },
          workerPassword: 'contract-password',
        ),
      );
    }

    expect(requestPaths.map((path) => path.split('.').last), [
      'submitConfirm',
      'submitRecall',
    ]);
    for (final payload in payloads) {
      expect(payload.containsKey('PositionID'), isFalse);
    }
  });

  test('a confirmation sends good and defective quantities apart', () async {
    final assignmentId = await assign(orderId: await scan('KG'), quantity: 20);
    payloads.clear();

    await gateway.push(
      SyncPushRequest(
        queueItem: {
          'id': 'contract-defect',
          'entity_type': 'PRODUCTION',
          'entity_id': 'rec-defect',
          'action': 'CREATE',
        },
        source: {
          'id': 'rec-defect',
          'phan_cong_id': assignmentId,
          // 7 finished, 3 defective: Quantity must stay 7, not become 10.
          'quantity': 7.0,
          'defect_quantity': 3.0,
          'unit_of_measure': 'KG',
          'business_date': '2026-09-07',
          'shift_id': 'SHIFT_1',
          'occurred_at_utc': DateTime.utc(2026, 9, 7, 3).millisecondsSinceEpoch,
          'idempotency_key': '00000000-0000-4000-8000-0000000000d1',
        },
        workerPassword: 'contract-password',
      ),
    );

    final payload = payloads.single;
    expect(double.parse(payload['Quantity'] as String), 7);
    expect(double.parse(payload['DefectQuantity'] as String), 3);
  });

  test('rescanning the operation cannot restate an existing '
      'transaction\'s unit', () async {
    final id = await assign(orderId: await scan('KG'), quantity: 1.25);
    final row = await db.getAssignmentById(id);

    // The same production order + operation, scanned again under a different
    // unit. This rewrites orders.uom in place.
    await scan('ST');

    // Re-push the transaction exactly as the sync queue would.
    await gateway.push(
      SyncPushRequest(
        queueItem: {
          'id': 'contract-replay',
          'entity_type': 'ASSIGNMENT',
          'entity_id': id,
          'action': 'CREATE',
        },
        source: row!,
        workerPassword: 'contract-password',
      ),
    );

    expect(payloads.last['SyncItemUUID'], payloads.first['SyncItemUUID']);
    // zbp_r_pp_opalloc compares the unit when matching an idempotency key, so
    // a changed unit here comes back rejected instead of de-duplicated.
    expect(payloads.last['UnitOfMeasure'], 'KG');
    expect(payloads.last['UnitOfMeasure'], payloads.first['UnitOfMeasure']);
  });

  test(
    'a pre-v5 row with no frozen unit still falls back to the order',
    () async {
      final orderId = await scan('KG');
      final id = await assign(orderId: orderId, quantity: 2.0);
      final row = Map<String, dynamic>.from((await db.getAssignmentById(id))!)
        ..['unit_of_measure'] = null;

      await gateway.push(
        SyncPushRequest(
          queueItem: {
            'id': 'contract-legacy',
            'entity_type': 'ASSIGNMENT',
            'entity_id': id,
            'action': 'CREATE',
          },
          source: row,
          workerPassword: 'contract-password',
        ),
      );

      expect(payloads.last['UnitOfMeasure'], 'KG');
    },
  );

  test('work history sends the selected shift and exact date window', () async {
    await gateway.getWorkHistory(
      range: HistoryRange.week,
      dateFrom: DateTime(2026, 9, 7),
      dateTo: DateTime(2026, 9, 13),
      shiftId: 'SHIFT_1',
      workId: 'team-2',
      productionOrder: '000001000020',
      operation: '0010',
    );

    expect(payloads.single['RangeCode'], 'C');
    expect(payloads.single['DateFrom'], '2026-09-07');
    expect(payloads.single['DateTo'], '2026-09-13');
    expect(payloads.single['WorkerID'], '');
    expect(payloads.single['WorkID'], 'team-2');
    expect(payloads.single['ShiftID'], 'SHIFT_1');
    expect(payloads.single['SummaryOnly'], isFalse);
    expect(payloads.single['ProductionOrder'], '000001000020');
    expect(payloads.single['Operation'], '0010');
    expect(
      requestPaths.single,
      endsWith('OperationAllocations/SAP__self.getWorkHistory'),
    );
    expect(requestReceiveTimeouts.single, const Duration(seconds: 60));
  });

  test('work history uses WorkDate as the business day', () async {
    Map<String, dynamic> row(String id, {Object? workDate}) => {
      'TransactionUUID': id,
      'WorkerID': 'NV01',
      'ProductionOrder': '010140000365',
      'Operation': '0020',
      'TransactionType': 'CONFIRM',
      'Quantity': '5',
      'UnitOfMeasure': 'CHC',
      'TransactionStatus': 'POSTED',
      'ExecutedAt': '2026-09-24T19:15:00Z', // 02:15 on the 25th in Vietnam
      'ExecutionDate': '2026-09-24',
      'WorkDate': ?workDate,
    };
    historyResponse = {
      'ScopeCode': 'T',
      'DateFrom': '2026-09-24',
      'DateTo': '2026-09-24',
      '_Entries': [
        row('with-work-date', workDate: '2026-09-24'),
        // An initial ABAP date must not become a nonsense day.
        row('initial-work-date', workDate: '0000-00-00'),
        row('older-service'),
      ],
      '_Workers': const [],
    };

    final entries = (await gateway.getWorkHistory(
      range: HistoryRange.day,
      dateFrom: DateTime(2026, 9, 24),
      dateTo: DateTime(2026, 9, 24),
    )).entries;

    for (final entry in entries) {
      expect(
        entry.workDate,
        DateTime(2026, 9, 24),
        reason: entry.transactionUuid,
      );
    }
  });

  test('work history prefers PostingDate as the business day', () async {
    historyResponse = {
      'ScopeCode': 'T',
      'DateFrom': '2026-09-07',
      'DateTo': '2026-09-08',
      '_Entries': [
        {
          'TransactionUUID': 'night-entry',
          'WorkerID': 'NV01',
          'ProductionOrder': '010140000365',
          'Operation': '0020',
          'TransactionType': 'CONFIRM',
          'Quantity': '5',
          'UnitOfMeasure': 'CHC',
          'TransactionStatus': 'POSTED',
          'ExecutedAt': '2026-09-07T19:00:00Z',
          'PostingDate': '2026-09-07',
          'EntryDate': '2026-09-08',
          'EntryTime': '02:00:00',
        },
      ],
      '_Workers': const [],
    };

    final entry = (await gateway.getWorkHistory(
      range: HistoryRange.day,
      dateFrom: DateTime(2026, 9, 7),
      dateTo: DateTime(2026, 9, 8),
    )).entries.single;

    expect(entry.workDate, DateTime(2026, 9, 7));
  });

  test('work history reads each worker recalled quantity', () async {
    Map<String, dynamic> worker(String id, {Object? recalled}) => {
      'WorkerID': id,
      'AssignedQuantity': '3000',
      'CompletedQuantity': '2600',
      'RemainingQuantity': '100',
      'UnitOfMeasure': 'CHC',
      'RecalledQuantity': ?recalled,
    };
    historyResponse = {
      'ScopeCode': 'T',
      'DateFrom': '2026-09-24',
      'DateTo': '2026-09-24',
      '_Entries': const [],
      '_Workers': [
        worker('NV01', recalled: '300'),
        // An older service binding without the field: SAP's identity
        // remaining = assigned − recalled − completed recovers it.
        worker('NV02'),
      ],
    };

    final result = await gateway.getWorkHistory(
      range: HistoryRange.day,
      dateFrom: DateTime(2026, 9, 24),
      dateTo: DateTime(2026, 9, 24),
    );

    expect(result.workers[0].recalledQuantity, 300);
    expect(result.workers[1].recalledQuantity, 300);
  });

  test(
    'operation access check sends the live scope and parses quantities',
    () async {
      historyResponse = {
        'IsAllowed': true,
        'ProductionOrder': '000001000020',
        'Operation': '0010',
        'WorkID': 'team-2',
        'ShiftID': 'SHIFT_1',
        'OperationQuantity': 1200,
        'InitialAssignedQuantity': 700,
        'CurrentAssignedQuantity': 650,
        'CompletedQuantity': 500,
        'RecalledQuantity': 50,
        'RemainingQuantity': 50,
        'UnitOfMeasure': 'ST',
      };

      final result = await gateway.checkOperationAccess(
        productionOrder: '000001000020',
        operation: '0010',
        workId: 'team-2',
        shiftId: 'SHIFT_1',
        executedAt: DateTime.utc(2026, 9, 14, 8),
      );

      expect(result.isAllowed, isTrue);
      expect(result.currentAssignedQuantity, 650);
      expect(result.completedQuantity, 500);
      expect(result.remainingQuantity, 50);
      expect(payloads.single['ProductionOrder'], '000001000020');
      expect(payloads.single['Operation'], '0010');
      expect(payloads.single['WorkID'], 'team-2');
      expect(payloads.single['ShiftID'], 'SHIFT_1');
      // 08:00 UTC is 15:00 in Vietnam, whatever zone the device is set to.
      expect(payloads.single['EntryDate'], '2026-09-14');
      expect(payloads.single['EntryTime'], '15:00:00');
      expect(payloads.single.containsKey('ExecutedAt'), isFalse);
      expect(
        requestPaths.single,
        endsWith('OperationAllocations/SAP__self.checkOperationAccess'),
      );
      expect(requestReceiveTimeouts.single, const Duration(seconds: 20));
    },
  );

  test(
    'general history sends empty filters from the action contract',
    () async {
      await gateway.getWorkHistory(
        range: HistoryRange.day,
        dateFrom: DateTime(2026, 9, 7),
        dateTo: DateTime(2026, 9, 7),
      );

      expect(payloads.single['ProductionOrder'], '');
      expect(payloads.single['WorkID'], '');
      expect(payloads.single['Operation'], '');
    },
  );

  test('server-relative history sends valid date parameters', () async {
    await gateway.getWorkHistory(range: HistoryRange.week);

    expect(payloads.single['RangeCode'], 'W');
    expect(payloads.single['DateFrom'], matches(r'^\d{4}-\d{2}-\d{2}$'));
    expect(payloads.single['DateTo'], matches(r'^\d{4}-\d{2}-\d{2}$'));
    final from = DateTime.parse(payloads.single['DateFrom'] as String);
    final to = DateTime.parse(payloads.single['DateTo'] as String);
    expect(to.difference(from).inDays, 6);
  });

  test('invalid filters never issue a history POST', () async {
    for (final request in [
      () => gateway.getWorkHistory(range: HistoryRange.custom),
      () => gateway.getWorkHistory(
        range: HistoryRange.day,
        dateFrom: DateTime(2026, 9, 1),
      ),
      () => gateway.getWorkHistory(
        range: HistoryRange.custom,
        dateFrom: DateTime(2026, 9, 2),
        dateTo: DateTime(2026, 9, 1),
      ),
      () => gateway.getWorkHistory(
        range: HistoryRange.day,
        productionOrder: '010140000032',
      ),
      () => gateway.getWorkHistory(
        range: HistoryRange.day,
        shiftId: '12345678901',
      ),
    ]) {
      await expectLater(request(), throwsArgumentError);
    }
    expect(payloads, isEmpty);
  });

  test('work history keeps ExecutionAt including SAP epoch dates', () async {
    historyResponse = {
      'DateFrom': '2026-09-07',
      'DateTo': '2026-09-07',
      '_Entries': [
        {
          'WorkerID': 'emp-1',
          'ProductionOrder': '000001000020',
          'Operation': '0010',
          'ProductName': 'TM-EU24122750-G-44.5x18.5x36.5',
          'Product': '000000000200009050',
          'SalesOrder': '5000012345',
          'SalesOrderItem': '000010',
          'TransactionType': 'CONFIRM',
          'Quantity': '2.000',
          'UnitOfMeasure': 'ST',
          'ExecutionAt': '/Date(1788777000000)/',
          'ExecutionDate': '2026-09-07',
        },
      ],
      '_Workers': const [],
    };

    final result = await gateway.getWorkHistory(
      range: HistoryRange.day,
      dateFrom: DateTime(2026, 9, 7),
      dateTo: DateTime(2026, 9, 7),
    );

    expect(result.entries, hasLength(1));
    expect(result.entries.single.executionDate.year, 2026);
    expect(result.entries.single.executionDate.hour, isNot(0));
    expect(result.entries.single.productName, 'TM-EU24122750-G-44.5x18.5x36.5');
    expect(result.entries.single.productCode, '000000000200009050');
    expect(result.entries.single.salesOrder, '5000012345');
    expect(result.entries.single.salesOrderItem, '000010');
  });

  for (final fields in [
    '"sl_cong_doan":"10.000","unit":"ST"',
    '"sl_cong_doan":"10.000,000","unit":"ST"',
    '"sl_cong_doan":"10.000,000 ST"',
    '"sl_cong_doan":"10.000,000 KG","unit":"ST"',
  ]) {
    test('QR unit reaches stored assignment and SAP POST: $fields', () async {
      final parsed = OperationQrParser.parse(
        '{"ProductionOrder":"000001000020","Operation":"0010",$fields}',
      );
      expect(parsed.unitOfMeasure, 'ST');
      expect(parsed.operationQuantity, 10000);
      final order = await db.upsertOrderFromOperationQr(parsed);
      final id = await assign(orderId: order!['id'] as String, quantity: 10);
      expect((await db.getAssignmentById(id))!['unit_of_measure'], 'ST');
      expect(payloads.single['UnitOfMeasure'], 'ST');
      expect(payloads.single['Quantity'], '10.000');
    });
  }
}
