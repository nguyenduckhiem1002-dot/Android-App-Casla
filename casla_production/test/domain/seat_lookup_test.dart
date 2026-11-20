import 'package:casla_production/domain/entities/worker_position.dart';
import 'package:casla_production/domain/policies/worker_position_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const _wc = 'CL100076';

const _seats = [
  PositionSeat(
    workCenter: _wc,
    positionId: 'A-01',
    machineId: 'A1',
    workerId: 'CL400033',
    workerName: 'Nguyễn Thị Năm',
  ),
  PositionSeat(workCenter: _wc, positionId: 'A1-5', machineId: 'A3'),
  PositionSeat(
    workCenter: 'CL100078',
    positionId: 'B-01',
    machineId: 'B7',
    workerId: 'CL400099',
    workerName: 'Khác xưởng',
  ),
];

void main() {
  group('lookupSeatForScan', () {
    test('a position label opens whoever sits there', () {
      final found = lookupSeatForScan(
        seats: _seats,
        raw: 'VT=a-01',
        workCenter: _wc,
      );
      expect(found, isA<SeatLookupWorker>());
      expect((found! as SeatLookupWorker).seat.workerId, 'CL400033');
    });

    test('a bare code is a position only when the board has it', () {
      expect(
        lookupSeatForScan(seats: _seats, raw: 'A-01', workCenter: _wc),
        isA<SeatLookupWorker>(),
      );
      // A worker card's code: not on the board, so not a position.
      expect(
        lookupSeatForScan(seats: _seats, raw: 'CL400033', workCenter: _wc),
        isNull,
      );
    });

    test('an empty position and an unknown label are told apart', () {
      expect(
        lookupSeatForScan(seats: _seats, raw: 'A1-5', workCenter: _wc),
        isA<SeatLookupEmpty>(),
      );
      final unknown = lookupSeatForScan(
        seats: _seats,
        raw: '{"PositionID":"Z-99"}',
        workCenter: _wc,
      );
      expect(unknown, isA<SeatLookupUnknown>());
      expect((unknown! as SeatLookupUnknown).positionId, 'Z-99');
      // The same code as a bare scan is simply not a position.
      expect(
        lookupSeatForScan(seats: _seats, raw: 'Z-99', workCenter: _wc),
        isNull,
      );
    });

    test('the active Work Center narrows the board', () {
      expect(
        lookupSeatForScan(seats: _seats, raw: 'B-01', workCenter: _wc),
        isNull,
      );
      expect(
        lookupSeatForScan(seats: _seats, raw: 'B-01'),
        isA<SeatLookupWorker>(),
      );
      // A label naming its Work Center wins over the active one.
      expect(
        lookupSeatForScan(
          seats: _seats,
          raw: 'WC=CL100078;VT=B-01',
          workCenter: _wc,
        ),
        isA<SeatLookupWorker>(),
      );
    });

    test('worker cards and junk are not positions', () {
      expect(
        lookupSeatForScan(seats: _seats, raw: '{"MaNV":"CL400033"}'),
        isNull,
      );
      expect(lookupSeatForScan(seats: _seats, raw: ''), isNull);
      expect(
        lookupSeatForScan(seats: _seats, raw: 'Xâu tem qua 2 quai'),
        isNull,
      );
    });
  });
}
