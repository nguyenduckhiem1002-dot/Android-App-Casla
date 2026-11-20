// SAP Integration — Worker position API
// SAP Service: ZUI_PP_POS (binding ZAPI_PP_POS, RAP OData V4)
//
// Five static facade actions, one command per request:
//   Positions/getPositionBoard, Positions/getMachines,
//   Positions/submitPositionCreate, Positions/submitMachineChange,
//   PositionAssignments/submitPositionTransfer.
// Every call carries AccessToken + DeviceID like ZUI_PP_OPALLOC. SAP treats a
// repeated command that already took effect as SUCCESS, so a retry after a
// timeout is safe.

import 'package:dio/dio.dart';

import '../../core/sync/sync_failure.dart';
import '../../core/utils/device_info.dart';
import '../../core/auth/session_refresh.dart';
import '../../domain/entities/worker_position.dart';
import 'odata_error.dart';
import 'sap_odata_client.dart';
import 'sap_session_provider.dart';

const String _kPositionSet = 'Positions';
const String _kAssignmentSet = 'PositionAssignments';
// Static actions are addressed through the service namespace alias, as in
// sap_pp_opalloc_gateway.dart.
const String _kStaticActionBinding = 'SAP__self';

/// Field lengths from the published EDMX (`ZA_PP_Pos*Cmd`).
abstract final class PositionFieldLimits {
  static const workCenter = 8;
  static const positionId = 10;
  static const machineId = 10;
  static const positionName = 60;
  static const workerId = 8;
}

/// What the position screen needs from SAP. A seam so widget tests can run
/// the screen without a network.
abstract interface class PositionApi {
  /// Active positions and who sits there. An empty [workCenter] returns every
  /// Work Center the account may manage. A [workerId] narrows the answer to
  /// the seat that worker holds (none: an empty board, not an error), so a
  /// screen that needs one worker's seat does not download the whole board
  /// (SAP since 2026-11-13). SAP treats every parameter of the action as
  /// mandatory, so WorkerID is always sent, empty for the whole board; an
  /// older backend rejects the parameter it does not know.
  Future<PositionBoard> getBoard({
    String workCenter = '',
    String workerId = '',
  });

  /// Every active machine of the catalog, with the position each one is
  /// attached to. Not filtered by Work Center: picking a machine attached
  /// elsewhere moves it, or is refused (MACHINE_IN_USE) when that Work Center
  /// is outside the account's scope, so the supervisor has to see it.
  Future<MachineCatalog> getMachines();

  Future<PositionCommandResult> createPosition({
    required String workCenter,
    required String positionId,
    required String machineId,
  });

  Future<PositionCommandResult> changeMachine({
    required String workCenter,
    required String positionId,
    required String machineId,
  });

  /// Takes the machine off an active position: the position stays active
  /// without a machine and whoever sits there keeps the seat. Sent as
  /// submitMachineChange with an empty MachineID (SAP since 2026-11-10; an
  /// older backend answers INPUT_INVALID).
  Future<PositionCommandResult> detachMachine({
    required String workCenter,
    required String positionId,
  });

  Future<PositionCommandResult> transferWorker({
    required String workCenter,
    required String positionId,
    required String workerId,
  });
}

class SapPositionGateway implements PositionApi {
  final SapODataClient client;
  final SapSessionProvider session;

  SapPositionGateway({required this.client, required this.session});

  /// Clears CSRF token and cookies when the signed-in identity changes.
  void resetTransportSession() {
    client.setAuthToken(null);
    client.resetCsrfSession();
  }

  @override
  Future<PositionBoard> getBoard({
    String workCenter = '',
    String workerId = '',
  }) async {
    final normalized = _code(workCenter);
    _checkLength(normalized, PositionFieldLimits.workCenter);
    final worker = _code(workerId);
    _checkLength(worker, PositionFieldLimits.workerId);
    final body = await _call(_kPositionSet, 'getPositionBoard', {
      'WorkCenter': normalized,
      // Always sent, empty for the whole board: SAP answers 400 "No value
      // for mandatory parameter" when a parameter of the action is missing.
      'WorkerID': worker,
    });
    return PositionBoard.fromJson(body);
  }

  @override
  Future<MachineCatalog> getMachines() async => MachineCatalog.fromJson(
    await _call(_kPositionSet, 'getMachines', const {}),
  );

  @override
  Future<PositionCommandResult> createPosition({
    required String workCenter,
    required String positionId,
    required String machineId,
  }) async {
    final normalizedPosition = _required(
      positionId,
      PositionFieldLimits.positionId,
    );
    final params = {
      'WorkCenter': _required(workCenter, PositionFieldLimits.workCenter),
      'PositionID': normalizedPosition,
      'MachineID': _required(machineId, PositionFieldLimits.machineId),
      'PositionName': normalizedPosition,
    };
    return PositionCommandResult.fromJson(
      await _call(_kPositionSet, 'submitPositionCreate', params),
    );
  }

  @override
  Future<PositionCommandResult> changeMachine({
    required String workCenter,
    required String positionId,
    required String machineId,
  }) async {
    final params = {
      'WorkCenter': _required(workCenter, PositionFieldLimits.workCenter),
      'PositionID': _required(positionId, PositionFieldLimits.positionId),
      'MachineID': _required(machineId, PositionFieldLimits.machineId),
    };
    return PositionCommandResult.fromJson(
      await _call(_kPositionSet, 'submitMachineChange', params),
    );
  }

  @override
  Future<PositionCommandResult> detachMachine({
    required String workCenter,
    required String positionId,
  }) async {
    final params = {
      'WorkCenter': _required(workCenter, PositionFieldLimits.workCenter),
      'PositionID': _required(positionId, PositionFieldLimits.positionId),
      'MachineID': '',
    };
    return PositionCommandResult.fromJson(
      await _call(_kPositionSet, 'submitMachineChange', params),
    );
  }

  @override
  Future<PositionCommandResult> transferWorker({
    required String workCenter,
    required String positionId,
    required String workerId,
  }) async {
    final params = {
      'WorkCenter': _required(workCenter, PositionFieldLimits.workCenter),
      'PositionID': _required(positionId, PositionFieldLimits.positionId),
      'WorkerID': _required(workerId, PositionFieldLimits.workerId),
    };
    return PositionCommandResult.fromJson(
      await _call(_kAssignmentSet, 'submitPositionTransfer', params),
    );
  }

  /// The access token lives 30 minutes and nothing queues these calls, so an
  /// expired token is refreshed once here, as getWorkHistory does.
  Future<Map<String, dynamic>> _call(
    String entitySet,
    String action,
    Map<String, String> params,
  ) async {
    final usedToken = session.accessToken;
    try {
      return await _callOnce(entitySet, action, params);
    } on SapSessionInvalidatedException {
      rethrow;
    } catch (error) {
      if (classifySyncError(error).kind != SyncFailureKind.auth) rethrow;
      final outcome = await session.refreshSession(staleAccessToken: usedToken);
      switch (outcome) {
        case SessionRefreshOutcome.refreshed:
          return _callOnce(entitySet, action, params);
        case SessionRefreshOutcome.unavailable:
          // Not an expired session: SAP was not reachable for the refresh.
          throw const SessionRefreshUnavailableException(
            'Chưa làm mới được phiên SAP. Sẽ tự động thử lại.',
          );
        case SessionRefreshOutcome.rejected:
        case SessionRefreshOutcome.skipped:
          rethrow;
      }
    }
  }

  Future<Map<String, dynamic>> _callOnce(
    String entitySet,
    String action,
    Map<String, String> params,
  ) async {
    final sessionGeneration = session.generation;
    final accessToken = session.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      if (!session.isGenerationCurrent(sessionGeneration)) {
        throw const SapSessionInvalidatedException();
      }
      throw const SapBusinessError('TOKEN_INVALID_OR_EXPIRED');
    }
    _ensureSessionCurrent(sessionGeneration, accessToken);

    try {
      // CSRF token reuse and the one resend on 403 live in postWithCsrf.
      final response = await client.postWithCsrf(
        '$entitySet/$_kStaticActionBinding.$action',
        guard: () => _ensureSessionCurrent(sessionGeneration, accessToken),
        data: {
          'AccessToken': accessToken,
          'DeviceID': DeviceInfoHelper.deviceId,
          ...params,
        },
      );
      _ensureSessionCurrent(sessionGeneration, accessToken);
      return odataActionResult(response);
    } on DioException catch (error) {
      rethrowAsBusinessError(error);
    }
  }

  void _ensureSessionCurrent(int expectedGeneration, String expectedToken) {
    if (!session.isGenerationCurrent(expectedGeneration) ||
        session.accessToken != expectedToken) {
      throw const SapSessionInvalidatedException();
    }
  }

  static String _code(String value) => value.trim().toUpperCase();

  static String _required(String value, int maxLength) {
    final code = _code(value);
    if (code.isEmpty) throw const SapBusinessError('INPUT_INVALID');
    _checkLength(code, maxLength);
    return code;
  }

  static void _checkLength(String value, int maxLength) {
    // SAP would truncate or reject an over-long key; fail before the round
    // trip with the same code the backend uses for bad input.
    if (value.length > maxLength) {
      throw const SapBusinessError('INPUT_INVALID');
    }
  }
}
