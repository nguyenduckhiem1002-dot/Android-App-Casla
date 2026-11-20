// Contract tests for ZUI_PP_POS: the action paths and payloads the gateway
// sends must match the published EDMX (ZUI_PP_POS v0001), and SAP's business
// codes must come back as SapBusinessError.

import 'package:casla_production/core/config/app_config.dart';
import 'package:casla_production/core/auth/session_refresh.dart';
import 'package:casla_production/core/sync/sync_failure.dart';
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
  var refreshOutcomeWhenFailing = SessionRefreshOutcome.rejected;
  String? lastStaleToken;

  @override
  String get accessToken => token;
  @override
  int get generation => 1;
  @override
  bool isGenerationCurrent(int generation) => generation == 1;
  @override
  Future<SessionRefreshOutcome> refreshSession({
    String? staleAccessToken,
  }) async {
    refreshes++;
    lastStaleToken = staleAccessToken;
    if (refreshSucceeds) {
      token = 'pos-token-2';
      return SessionRefreshOutcome.refreshed;
    }
    return refreshOutcomeWhenFailing;
  }
}

class _OfflineClient extends SapODataClient {
  _OfflineClient()
    : super(
        baseUrl: 'https://contract.invalid/',
        transportAuthMode: SapTransportAuthMode.gateway,
      );

  var csrfFetches = 0;
  var holdsCsrfToken = false;

  @override
  bool get hasCsrfToken => holdsCsrfToken;

  @override
  Future<String?> fetchCsrfToken() async {
    csrfFetches++;
    holdsCsrfToken = true;
    return 'contract-csrf';
  }
}

void main() {
  late _Session session;
  late SapPositionGateway gateway;
  late _OfflineClient client;
  late List<String> paths;
  late List<Map<String, dynamic>> payloads;
  late List<Object> responses;

  setUp(() {
    session = _Session();
    paths = [];
    payloads = [];
    responses = [];
    client = _OfflineClient();
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
      // Mandatory in the action signature, so sent even when empty.
      'WorkerID': '',
    });
    expect(board.workCenterCount, 1);
    expect(board.seats.map((s) => s.isOccupied), [true, false]);
    expect(board.seats.first.workerLabel, 'Nguyễn Văn An');
  });

  test('the CSRF token is fetched once and reused by later calls', () async {
    await gateway.getBoard();
    await gateway.getBoard();

    expect(client.csrfFetches, 1);
    expect(paths, hasLength(2));
  });

  test(
    'a 403 on a reused CSRF token fetches a fresh one and sends again',
    () async {
      await gateway.getBoard();
      responses.add(403);

      final board = await gateway.getBoard();

      expect(client.csrfFetches, 2);
      expect(paths, hasLength(3));
      expect(board.seats, isEmpty);
    },
  );

  test('a 403 on a freshly fetched CSRF token is not sent again', () async {
    responses.add(403);

    await expectLater(gateway.getBoard(), throwsA(isA<SapBusinessError>()));

    expect(client.csrfFetches, 1);
    expect(paths, hasLength(1));
  });

  test('getPositionBoard narrows to one worker when asked', () async {
    responses.add({
      'WorkCenterCount': 1,
      'PositionCount': 0,
      '_Positions': <Map<String, dynamic>>[],
    });

    final board = await gateway.getBoard(
      workCenter: 'cl100077',
      workerId: ' 10000001 ',
    );

    expect(payloads.single, {
      'AccessToken': 'pos-token',
      'DeviceID': isA<String>(),
      'WorkCenter': 'CL100077',
      'WorkerID': '10000001',
    });
    // A worker without a seat is an empty board, not an error.
    expect(board.seats, isEmpty);
  });

  test(
    'getMachines sends only the credentials and parses the catalog',
    () async {
      responses.add({
        'MachineCount': 2,
        '_Machines': [
          {
            'MachineID': 'M1',
            'MachineName': 'Máy cắt 1',
            'IsInUse': true,
            'WorkCenter': 'CL100077',
            'PositionID': 'G01',
            'WorkerID': '10000001',
            'WorkerName': 'Nguyễn Văn An',
          },
          {
            'MachineID': 'm2',
            'MachineName': '',
            'IsInUse': false,
            'WorkCenter': '',
            'PositionID': '',
            // A worker without a position is meaningless; dropped.
            'WorkerID': '10000009',
            'WorkerName': 'Lạc',
          },
        ],
      });

      final catalog = await gateway.getMachines();

      expect(paths.single, 'Positions/SAP__self.getMachines');
      expect(
        payloads.single.keys,
        unorderedEquals(['AccessToken', 'DeviceID']),
      );
      expect(catalog.machines.map((m) => m.machineId), ['M1', 'M2']);
      expect(catalog.machines.map((m) => m.isInUse), [true, false]);
      expect(catalog.machines.first.positionId, 'G01');
      expect(catalog.machines.first.label, 'Máy cắt 1');
      expect(catalog.machines.last.label, 'M2');
      expect(catalog.byId('m1')?.workCenter, 'CL100077');
      expect(catalog.machines.first.workerId, '10000001');
      expect(catalog.machines.first.workerLabel, 'Nguyễn Văn An');
      expect(catalog.machines.first.isOccupied, isTrue);
      expect(catalog.machines.last.isOccupied, isFalse);
      expect(catalog.machines.last.workerId, '');
    },
  );

  test('getMachines without the worker fields (older backend)', () async {
    responses.add({
      'MachineCount': 1,
      '_Machines': [
        {
          'MachineID': 'M1',
          'MachineName': 'Máy cắt 1',
          'IsInUse': true,
          'WorkCenter': 'CL100077',
          'PositionID': 'G01',
        },
      ],
    });

    final catalog = await gateway.getMachines();

    expect(catalog.machines.single.isInUse, isTrue);
    expect(catalog.machines.single.isOccupied, isFalse);
    expect(catalog.machines.single.workerLabel, '');
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

  test('taking the machine off is a machine change with no machine', () async {
    await gateway.detachMachine(workCenter: 'cl100077', positionId: 'g05');

    expect(paths, ['Positions/SAP__self.submitMachineChange']);
    expect(payloads.single, containsPair('WorkCenter', 'CL100077'));
    expect(payloads.single, containsPair('PositionID', 'G05'));
    expect(payloads.single, containsPair('MachineID', ''));

    // A position is still required, as for every other command.
    await expectLater(
      gateway.detachMachine(workCenter: 'CL100077', positionId: ' '),
      throwsA(
        isA<SapBusinessError>().having((e) => e.code, 'code', 'INPUT_INVALID'),
      ),
    );
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

  test('the refresh is told which token failed', () async {
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

    expect(session.lastStaleToken, 'pos-token');
  });

  test(
    'an unreachable SAP during refresh is transient, not an expired session',
    () async {
      session.refreshOutcomeWhenFailing = SessionRefreshOutcome.unavailable;
      responses.add(401);

      Object? thrown;
      try {
        await gateway.transferWorker(
          workCenter: 'CL100077',
          positionId: 'G01',
          workerId: '10000001',
        );
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<SessionRefreshUnavailableException>());
      final failure = classifySyncError(thrown!);
      expect(failure.kind, SyncFailureKind.transient);
      expect(failure.code, 'AUTH_REFRESH_UNAVAILABLE');
      expect(session.refreshes, 1);
    },
  );

  test('a refused refresh surfaces the original auth error', () async {
    session.refreshOutcomeWhenFailing = SessionRefreshOutcome.rejected;
    responses.add(401);

    await expectLater(
      gateway.transferWorker(
        workCenter: 'CL100077',
        positionId: 'G01',
        workerId: '10000001',
      ),
      throwsA(
        isA<SapBusinessError>().having(
          (e) => e.code,
          'code',
          'TOKEN_INVALID_OR_EXPIRED',
        ),
      ),
    );
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
