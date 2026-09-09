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

  setUp(() {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
    payloads = [];
    final client = _OfflineClient();
    client.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (request.method == 'POST') {
            // A decimal encoded as a JSON string requires explicit OData
            // IEEE754 negotiation, including on the actual outgoing request.
            expect(request.contentType, contains('IEEE754Compatible=true'));
            payloads.add(Map<String, dynamic>.from(request.data as Map));
          }
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              headers: Headers.fromMap({
                'x-csrf-token': ['contract-csrf'],
              }),
              data: {
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
    expect(payloads.single['ExecutedAt'], isA<String>());
    expect(
      DateTime.tryParse(payloads.single['ExecutedAt'] as String)?.isUtc,
      isTrue,
    );
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
    );

    expect(payloads.single['RangeCode'], 'C');
    expect(payloads.single['DateFrom'], '2026-09-07');
    expect(payloads.single['DateTo'], '2026-09-13');
    expect(payloads.single['WorkerID'], '');
    expect(payloads.single['ShiftID'], 'SHIFT_1');
    expect(payloads.single['SummaryOnly'], isFalse);
  });

  for (final fields in [
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
