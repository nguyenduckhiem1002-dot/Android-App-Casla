import 'package:casla_production/data/sap/odata_error.dart';
import 'package:casla_production/data/sap/sap_position_gateway.dart';
import 'package:casla_production/domain/entities/worker_position.dart';
import 'package:casla_production/domain/policies/worker_position_policy.dart';
import 'package:casla_production/features/shared/seat_scan_lookup.dart';
import 'package:flutter_test/flutter_test.dart';

const _wc = 'CL100076';

class _FakeApi implements PositionApi {
  int boardCalls = 0;
  Object? fail;

  @override
  Future<PositionBoard> getBoard({
    String workCenter = '',
    String workerId = '',
  }) async {
    boardCalls++;
    if (fail != null) throw fail!;
    return const PositionBoard(
      workCenterCount: 1,
      seats: [
        PositionSeat(
          workCenter: _wc,
          positionId: 'A-01',
          machineId: 'A1',
          workerId: 'CL400033',
          workerName: 'Nguyễn Thị Năm',
        ),
        PositionSeat(workCenter: _wc, positionId: 'A1-5', machineId: 'A3'),
      ],
    );
  }

  @override
  Future<MachineCatalog> getMachines() => throw UnimplementedError();

  @override
  Future<PositionCommandResult> createPosition({
    required String workCenter,
    required String positionId,
    required String machineId,
  }) => throw UnimplementedError();

  @override
  Future<PositionCommandResult> changeMachine({
    required String workCenter,
    required String positionId,
    required String machineId,
  }) => throw UnimplementedError();

  @override
  Future<PositionCommandResult> detachMachine({
    required String workCenter,
    required String positionId,
  }) => throw UnimplementedError();

  @override
  Future<PositionCommandResult> transferWorker({
    required String workCenter,
    required String positionId,
    required String workerId,
  }) => throw UnimplementedError();
}

void main() {
  late _FakeApi api;
  late DateTime clock;
  late SeatScanLookup lookup;

  setUp(() {
    api = _FakeApi();
    clock = DateTime(2026, 11, 9, 8);
    lookup = SeatScanLookup(api: () => api, now: () => clock);
  });

  test(
    'a position scan opens the seated worker, the board is cached',
    () async {
      final first = await lookup.resolve(
        'VT=A-01',
        workCenter: _wc,
        explicit: true,
      );
      expect((first! as SeatLookupWorker).seat.workerName, 'Nguyễn Thị Năm');

      clock = clock.add(const Duration(seconds: 30));
      final second = await lookup.resolve(
        'A1-5',
        workCenter: _wc,
        explicit: false,
      );
      expect(second, isA<SeatLookupEmpty>());
      expect(api.boardCalls, 1);

      clock = clock.add(const Duration(minutes: 2));
      await lookup.resolve('A-01', workCenter: _wc, explicit: false);
      expect(api.boardCalls, 2);

      // Another Work Center is a different board.
      await lookup.resolve('A-01', workCenter: 'CL100078', explicit: false);
      expect(api.boardCalls, 3);
    },
  );

  test(
    'a bare code is a worker code when the board has no such position',
    () async {
      expect(
        await lookup.resolve('CL400033', workCenter: _wc, explicit: false),
        isNull,
      );
    },
  );

  test(
    'without the board a bare code falls back silently, a label reports',
    () async {
      api.fail = const SapBusinessError('MISSING_PERMISSION');
      final messages = <String>[];

      expect(
        await lookup.resolve(
          'A-01',
          workCenter: _wc,
          explicit: false,
          onError: messages.add,
        ),
        isNull,
      );
      expect(messages, isEmpty);

      expect(
        await lookup.resolve(
          'VT=A-01',
          workCenter: _wc,
          explicit: true,
          onError: messages.add,
        ),
        isNull,
      );
      expect(messages.single, contains('PP_POS_MANAGE'));
      // A failed read is not cached.
      api.fail = null;
      expect(
        await lookup.resolve('VT=A-01', workCenter: _wc, explicit: true),
        isA<SeatLookupWorker>(),
      );
    },
  );
}
