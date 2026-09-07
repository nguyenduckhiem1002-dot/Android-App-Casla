// Review probes: use the real Flutter repository/gateway with intercepted HTTP.
// No SAP connection or .env is used. Kept outside the normal test suite.
import 'package:casla_production/core/config/app_config.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/sync/sap_write_gateway.dart';
import 'package:casla_production/core/utils/operation_qr_parser.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';
import 'package:casla_production/data/sap/sap_pp_opalloc_gateway.dart';
import 'package:casla_production/data/sap/sap_session_provider.dart';
import 'package:casla_production/domain/policies/production_math.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../test/support/database_test_harness.dart';

class _Session implements SapSessionProvider {
  @override
  String get accessToken => 'review-only-token';
  @override
  int get generation => 1;
  @override
  bool isGenerationCurrent(int generation) => generation == 1;
  @override
  Future<bool> refreshSession() async => false;
}

class _ReviewClient extends SapODataClient {
  _ReviewClient() : super(
    baseUrl: 'https://review.invalid/',
    transportAuthMode: SapTransportAuthMode.gateway,
  );
  // Production CSRF fetching constructs its own Dio. Stub that separate
  // transport too, so every part of this probe is offline.
  @override
  Future<String?> fetchCsrfToken() async => 'review-csrf';
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
    final client = _ReviewClient();
    client.dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.method == 'POST') {
        payloads.add(Map<String, dynamic>.from(request.data as Map));
      }
      handler.resolve(Response(
        requestOptions: request,
        statusCode: 200,
        headers: Headers.fromMap({'x-csrf-token': ['review-csrf']}),
        data: {'Status': 'SUCCESS', 'TransactionUUID': '00000000-0000-0000-0000-000000000001'},
      ));
    }));
    gateway = SapPpOpAllocGateway(db: db, client: client, session: _Session());
    repo = AssignmentRepositoryImpl(db, gateway: gateway);
  });

  Future<String> scan(String uom) async {
    final order = await db.upsertOrderFromOperationQr(OperationQrParser.parse(
      '{"ProductionOrder":"000001000020","Operation":"0010","UnitOfMeasure":"$uom"}',
    ));
    return order!['id'] as String;
  }

  test('persisted quantity must equal the actual SAP payload quantity', () async {
    final orderId = await scan('KG');
    final receipt = await repo.createAssignment(
      workerId: 'emp-1', orderId: orderId, teamId: 'team-2',
      assignedQuantity: 1.2345, businessDate: '2026-09-07',
      shiftId: 'SHIFT_1', createdBy: 'review-manager', workerPassword: 'review-password',
    );
    final row = await db.getAssignmentById(receipt.id);
    expect(row!['assigned_quantity'], double.parse(payloads.single['Quantity'] as String));
  });

  test('replaying a command after rescanning must keep its original unit', () async {
    final orderId = await scan('KG');
    final receipt = await repo.createAssignment(
      workerId: 'emp-1', orderId: orderId, teamId: 'team-2',
      assignedQuantity: 1.25, businessDate: '2026-09-07',
      shiftId: 'SHIFT_1', createdBy: 'review-manager', workerPassword: 'review-password',
    );
    final row = await db.getAssignmentById(receipt.id);
    await scan('ST');
    await gateway.push(SyncPushRequest(
      queueItem: {'id': 'review-replay', 'entity_type': 'ASSIGNMENT', 'entity_id': receipt.id, 'action': 'CREATE'},
      source: row!, workerPassword: 'review-password',
    ));
    expect(payloads.last['SyncItemUUID'], payloads.first['SyncItemUUID']);
    expect(payloads.last['UnitOfMeasure'], payloads.first['UnitOfMeasure']);
  });

  test('remaining quantity should not block an exact decimal completion', () {
    final remaining = ProductionMath.calculateRemaining(0.3, 0.1);
    // Both S08 and S09 use this direct comparison before calling repositories.
    expect(0.2 > remaining, isFalse);
  });
}
