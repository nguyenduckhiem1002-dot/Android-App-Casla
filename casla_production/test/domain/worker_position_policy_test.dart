import 'package:casla_production/domain/entities/worker_position.dart';
import 'package:casla_production/domain/policies/worker_position_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const _wc = 'CL100077';

const _board = [
  PositionSeat(
    workCenter: _wc,
    positionId: 'G01',
    machineId: 'M101',
    workerId: '10000001',
    workerName: 'Nguyễn Văn An',
  ),
  PositionSeat(
    workCenter: _wc,
    positionId: 'G02',
    machineId: 'M102',
    workerId: '10000002',
    workerName: 'Trần Thị Bình',
  ),
  PositionSeat(workCenter: _wc, positionId: 'G06', machineId: 'M106'),
];

const _cuong = PositionWorker(code: '10000003', name: 'Lê Văn Cường');
const _an = PositionWorker(code: '10000001', name: 'Nguyễn Văn An');

PositionUpdatePlan _plan(
  String position,
  String machine, {
  PositionWorker? worker,
}) => planPositionUpdate(
  board: _board,
  slot: PositionSlot(workCenter: _wc, positionId: position, machineId: machine),
  worker: worker,
);

List<PositionCommandKind> _kinds(PositionUpdatePlan plan) =>
    plan.commands.map((c) => c.kind).toList();

void main() {
  group('position only', () {
    test('case 1: an unknown position is created after confirmation', () {
      final plan = _plan('G05', 'M105');

      expect(plan.warnings.single.kind, PositionCase.newPosition);
      expect(_kinds(plan), [PositionCommandKind.createPosition]);
    });

    test('case 2: a new machine at a known position is a machine change', () {
      final plan = _plan('G01', 'M109');

      expect(plan.warnings.single.kind, PositionCase.changeMachine);
      expect(plan.warnings.single.message, contains('M101'));
      // SAP keeps the seated worker on a machine change; say so.
      expect(plan.warnings.single.message, contains('Nguyễn Văn An'));
      expect(_kinds(plan), [PositionCommandKind.changeMachine]);
    });

    test('a machine used at another position is not checked', () {
      // M102 already sits at G02: the same code may serve several positions.
      final plan = _plan('G01', 'M102');

      expect(plan.warnings.single.kind, PositionCase.changeMachine);
      expect(_kinds(plan), [PositionCommandKind.changeMachine]);
    });

    test('the same position and machine needs no update', () {
      expect(_plan('g01', 'm101').isNoop, isTrue);
    });
  });

  group('with a worker', () {
    test('an empty position takes the worker without a warning', () {
      final plan = _plan('G06', 'M106', worker: _cuong);

      expect(plan.warnings, isEmpty);
      expect(_kinds(plan), [PositionCommandKind.transferWorker]);
    });

    test('case 4: a seated worker is moved and the occupant warned', () {
      final plan = _plan('G02', 'M102', worker: _an);

      expect(plan.warnings.map((w) => w.kind), [
        PositionCase.transferWorker,
        PositionCase.replaceWorker,
      ]);
      expect(plan.warnings.last.message, contains('Trần Thị Bình'));
      expect(_kinds(plan), [PositionCommandKind.transferWorker]);
    });

    test('a new position is created before the worker is seated', () {
      final plan = _plan('G05', 'M105', worker: _an);

      expect(plan.warnings.map((w) => w.kind), [
        PositionCase.newPosition,
        PositionCase.transferWorker,
      ]);
      expect(_kinds(plan), [
        PositionCommandKind.createPosition,
        PositionCommandKind.transferWorker,
      ]);
    });

    test('a worker already at the position needs no update', () {
      expect(_plan('G01', 'M101', worker: _an).isNoop, isTrue);
    });

    test('a machine used elsewhere does not stop seating a worker', () {
      final plan = _plan('G06', 'M101', worker: _cuong);

      expect(_kinds(plan), [
        PositionCommandKind.changeMachine,
        PositionCommandKind.transferWorker,
      ]);
    });
  });

  group('parsePositionSlotQr', () {
    test('splits the printed label on @, position first', () {
      final slot = parsePositionSlotQr(' g05 @ m105 ');
      expect(slot, isNotNull);
      expect(slot!.positionId, 'G05');
      expect(slot.machineId, 'M105');
      // The label names no Work Center; the supervisor's one applies.
      expect(slot.workCenter, isEmpty);

      expect(parsePositionSlotQr('G05@'), isNull);
      expect(parsePositionSlotQr('@M105'), isNull);
      expect(parsePositionSlotQr('CL100077@G05@M105'), isNull);
    });

    test('no other separator is taken for a position label', () {
      for (final label in ['G05/M105', 'G05|M105', 'G05;M105', 'G05,M105']) {
        expect(parsePositionSlotQr(label), isNull, reason: label);
      }
    });

    test('reads keyed and JSON labels', () {
      final keyed = parsePositionSlotQr('VT=G05;MAY=M1')!;
      expect((keyed.positionId, keyed.machineId), ('G05', 'M1'));

      final json = parsePositionSlotQr(
        '{"WorkCenter":"CL100077","PositionID":"G05","MachineID":"M1"}',
      )!;
      expect(
        (json.workCenter, json.positionId, json.machineId),
        ('CL100077', 'G05', 'M1'),
      );
    });

    test('rejects worker cards and over-long codes', () {
      expect(parsePositionSlotQr('10000001'), isNull);
      expect(parsePositionSlotQr('{"MaNV":"10000001"}'), isNull);
      expect(parsePositionSlotQr('10000001@Nguyễn Văn An'), isNull);
      expect(parsePositionSlotQr('G05@MACHINE-TOO-LONG'), isNull);
    });
  });
}
