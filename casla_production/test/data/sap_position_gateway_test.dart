// Contract tests for ZUI_PP_POS: the action paths and payloads the gateway
// sends must match the published EDMX (ZUI_PP_POS v0001), and SAP's business
// codes must come back as SapBusinessError.

import 'package:casla_production/core/config/app_config.dart';
import 'package:casla_production/data/sap/odata_error.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';
import 'package:casla_production/data/sap/sap_position_gateway.dart';
import 'package:casla_production/data/sap/sap_session_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session implements SapSessionProvider {
  var token = 'pos-token';
  var refreshes = 0;
  var refreshSucceeds = false;

  @override
  String get accessToken => token;
  @override
  int get generation => 1;
  @override
  bool isGenerationCurrent(int generation) => generation == 1;
  @override
  Future<bool> refreshSession() async {
    refreshes++;
    if (refreshSucceeds) token = 'pos-token-2';
    return refreshSucceeds;
  }
}

class _OfflineClient extends SapODataClient {
  _OfflineClient()
    : super(
        baseUrl: 'https://contract.invalid/',
        transportAuthMode: SapTransportAuthMode.gateway,
      );

  @override
  Future<String?> fetchCsrfToken() async => 'contract-csrf';
}

void main() {
  late _Session session;
  late SapPositionGateway gateway;
  late List<String> paths;
  late List<Map<String, dynamic>> payloads;
  late List<Object> responses;

  setUp(() {
    session = _Session();
    paths = [];
    payloads = [];
    responses = [];
    final client = _OfflineClient();
    client.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          paths.add(request.path);
          payloads.add(Map<String, dynamic>.from(request.data as Map));
          final next = responses.isEmpty
              ? <String, dynamic>{'Status': 'SUCCESS'}
              : responses.removeAt(0);
          if (next is int) {
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response(
                  requestOptions: request,
                  statusCode: next,
                  data: {
                    'error': {
                      'code': 'SABP_BEHV/100',
                      'message': next == 401
                          ? 'TOKEN_INVALID_OR_EXPIRED'
                          : 'MACHINE_IN_USE',
                    },
                  },
                ),
              ),
            );
            return;
          }
          handler.resolve(
            Response(requestOptions: request, statusCode: 200, data: next),
          );
        },
      ),
    );
    gateway = SapPositionGateway(client: client, session: session);
  });

  test('service root follows the ZAPI_PP_POS binding', () {
    expect(
      AppConfig.joinServiceUrl(
        'https://tenant/sap/opu/odata4/sap/',
        AppConfig.positionServiceSuffix,
      ),
      'https://tenant/sap/opu/odata4/sap/zapi_pp_pos/srvd_a2x/sap/zui_pp_pos/0001/',
    );
  });

  test('getPositionBoard sends credentials and parses seats', () async {
    responses.add({
      'WorkCenterCount': 1,
      'PositionCount': 2,
      '_Positions': [
        {
          'WorkCenter': 'CL100077',
          'PositionID': 'G01',
          'MachineID': 'M1',
          'PositionName': 'Ghế 1',
          'WorkerID': '10000001',
          'WorkerName': 'Nguyễn Văn An',
          'IsOccupied': true,
        },
        {
          'WorkCenter': 'CL100077',
          'PositionID': 'G02',
          'MachineID': 'M2',
          'PositionName': '',
          'WorkerID': '',
          'WorkerName': '',
          'IsOccupied': false,
        },
      ],
    });

    final board = await gateway.getBoard();

    expect(paths.single, 'Positions/SAP__self.getPositionBoard');
    expect(payloads.single, {
      'AccessToken': 'pos-token',
      'DeviceID': isA<String>(),
      'WorkCenter': '',
    });
    expect(board.workCenterCount, 1);
    expect(board.seats.map((s) => s.isOccupied), [true, false]);
    expect(board.seats.first.workerLabel, 'Nguyễn Văn An');
  });

  test('commands use their own action and entity set', () async {
    await gateway.createPosition(
      workCenter: 'cl100077',
      positionId: 'g05',
      machineId: 'm1',
    );
    await gateway.changeMachine(
      workCenter: 'CL100077',
      positionId: 'G05',
      machineId: 'M2',
    );
    await gateway.transferWorker(
      workCenter: 'CL100077',
      positionId: 'G05',
      workerId: '10000001',
    );

    expect(paths, [
      'Positions/SAP__self.submitPositionCreate',
      'Positions/SAP__self.submitMachineChange',
      'PositionAssignments/SAP__self.submitPositionTransfer',
    ]);
    expect(payloads[0], containsPair('PositionID', 'G05'));
    expect(payloads[0], containsPair('PositionName', 'G05'));
    expect(
      payloads[1].keys,
      containsAll(['WorkCenter', 'PositionID', 'MachineID']),
    );
    expect(payloads[1].containsKey('PositionName'), isFalse);
    expect(payloads[2], containsPair('WorkerID', '10000001'));
  });

  test('a business rejection surfaces its code', () async {
    responses.add(400);

    await expectLater(
      gateway.changeMachine(
        workCenter: 'CL100077',
        positionId: 'G01',
        machineId: 'M2',
      ),
      throwsA(
        isA<SapBusinessError>().having((e) => e.code, 'code', 'MACHINE_IN_USE'),
      ),
    );
  });

  test('an expired token is refreshed once and the call retried', () async {
    session.refreshSucceeds = true;
    responses.addAll([
      401,
      {'Status': 'SUCCESS'},
    ]);

    await gateway.transferWorker(
      workCenter: 'CL100077',
      positionId: 'G01',
      workerId: '10000001',
    );

    expect(session.refreshes, 1);
    expect(payloads.map((p) => p['AccessToken']), ['pos-token', 'pos-token-2']);
  });

  test('over-long codes never reach SAP', () async {
    await expectLater(
      gateway.transferWorker(
        workCenter: 'CL100077',
        positionId: 'G01',
        workerId: '123456789',
      ),
      throwsA(
        isA<SapBusinessError>().having((e) => e.code, 'code', 'INPUT_INVALID'),
      ),
    );
    expect(paths, isEmpty);
  });
}
