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
      expect(
        plan.warnings.single.details.map((d) => '${d.label}: ${d.value}'),
        ['Máy hiện tại: M101', 'Máy mới: M109'],
      );
      expect(_kinds(plan), [PositionCommandKind.changeMachine]);
    });

    test('a machine attached at another position is moved after a warning', () {
      // M102 sits at G02: SAP moves it and G02 is left without a machine.
      final plan = _plan('G01', 'M102');

      expect(plan.warnings.map((w) => w.kind), [
        PositionCase.changeMachine,
        PositionCase.moveMachine,
      ]);
      final move = plan.warnings.last;
      expect(
        move.message,
        'Máy M102 đang gắn ở vị trí G02. Có chuyển máy sang vị trí G01 không? '
        'Vị trí G02 sẽ trống mã máy. CN Trần Thị Bình vẫn ngồi vị trí G02.',
      );
      expect(move.details.map((d) => '${d.label}: ${d.value}'), [
        'Vị trí đang gắn: G02',
        'Vị trí mới: G01',
      ]);
      // Still one command: SAP clears the old position in the same request.
      expect(_kinds(plan), [PositionCommandKind.changeMachine]);
    });

    test('a new position taking a machine from another one warns too', () {
      final plan = _plan('G05', 'm106');

      expect(plan.warnings.map((w) => w.kind), [
        PositionCase.newPosition,
        PositionCase.moveMachine,
      ]);
      // G06 has nobody: nothing to say about a worker.
      expect(
        plan.warnings.last.message,
        'Máy m106 đang gắn ở vị trí G06. Có chuyển máy sang vị trí G05 không? '
        'Vị trí G06 sẽ trống mã máy.',
      );
      expect(_kinds(plan), [PositionCommandKind.createPosition]);
    });

    test('a free machine moves nothing', () {
      expect(_plan('G01', 'M109').warnings.map((w) => w.kind), [
        PositionCase.changeMachine,
      ]);
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
      expect(plan.warnings.first.details.map((d) => d.label), [
        'Vị trí hiện tại',
        'Vị trí mới',
      ]);
      expect(plan.warnings.first.details.last.value, 'G02 · M102');
      expect(plan.warnings.last.details.map((d) => d.label), [
        'CN hiện tại',
        'CN mới',
      ]);
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

      expect(plan.warnings.map((w) => w.kind), [
        PositionCase.changeMachine,
        PositionCase.moveMachine,
      ]);
      expect(_kinds(plan), [
        PositionCommandKind.changeMachine,
        PositionCommandKind.transferWorker,
      ]);
    });
  });

  group('machine optional', () {
    test('a known position without a machine scan keeps its machine', () {
      final plan = _plan('G01', '', worker: _cuong);
      expect(_kinds(plan), [PositionCommandKind.transferWorker]);
      expect(plan.needsMachine, isFalse);
    });

    test('a new position without a machine cannot be created', () {
      final plan = _plan('G05', '');
      expect(plan.needsMachine, isTrue);
      expect(plan.commands, isEmpty);
      expect(plan.isNoop, isFalse);
    });

    test('a position that had no machine gets one', () {
      final plan = planPositionUpdate(
        board: const [
          PositionSeat(workCenter: _wc, positionId: 'G09', machineId: ''),
        ],
        slot: const PositionSlot(
          workCenter: _wc,
          positionId: 'G09',
          machineId: 'M1',
        ),
      );
      expect(_kinds(plan), [PositionCommandKind.changeMachine]);
      expect(plan.warnings.single.message, contains('chưa gắn máy'));
      expect(plan.warnings.single.details.first.value, 'Chưa có');
    });
  });

  group('taking the machine off', () {
    PositionUpdatePlan detach(
      String position, {
      String machine = '',
      PositionWorker? worker,
      List<PositionSeat> board = _board,
    }) => planPositionUpdate(
      board: board,
      slot: PositionSlot(
        workCenter: _wc,
        positionId: position,
        machineId: machine,
        detachMachine: true,
      ),
      worker: worker,
    );

    test('the position keeps running without a machine after a warning', () {
      final plan = detach('G01');

      expect(plan.warnings.single.kind, PositionCase.detachMachine);
      expect(
        plan.warnings.single.message,
        'Vị trí G01 đang gắn máy M101. Có gỡ máy khỏi vị trí không? Vị trí '
        'vẫn đang dùng, máy M101 thành máy rảnh. CN Nguyễn Văn An vẫn ngồi '
        'vị trí này.',
      );
      expect(
        plan.warnings.single.details.map((d) => '${d.label}: ${d.value}'),
        ['Máy hiện tại: M101', 'Sau khi gỡ: Chưa gắn máy'],
      );
      expect(_kinds(plan), [PositionCommandKind.detachMachine]);
      expect(plan.commands.single.description, 'Gỡ máy M101 khỏi vị trí G01');
    });

    test('an empty position says nothing about a worker', () {
      expect(
        detach('G06').warnings.single.message,
        'Vị trí G06 đang gắn máy M106. Có gỡ máy khỏi vị trí không? Vị trí '
        'vẫn đang dùng, máy M106 thành máy rảnh.',
      );
    });

    test('a position already without a machine needs no update', () {
      final plan = detach(
        'G09',
        board: const [
          PositionSeat(workCenter: _wc, positionId: 'G09', machineId: ''),
        ],
      );
      expect(plan.isNoop, isTrue);
    });

    test('a scanned machine is a change, not a removal', () {
      final plan = detach('G01', machine: 'M109');
      expect(_kinds(plan), [PositionCommandKind.changeMachine]);
    });

    test('a position SAP does not have still needs a machine', () {
      expect(detach('G05').needsMachine, isTrue);
    });

    test('the worker is seated after the machine is taken off', () {
      final plan = detach('G06', worker: _cuong);
      expect(_kinds(plan), [
        PositionCommandKind.detachMachine,
        PositionCommandKind.transferWorker,
      ]);
    });
  });

  group('parsePositionLabel', () {
    test('reads a label naming one field or both', () {
      final position = parsePositionLabel('VT=a-01')!;
      expect(position.positionId, 'A-01');
      expect(position.machineId, '');
      final machine = parsePositionLabel('{"MachineID":"vlt16"}')!;
      expect(machine.positionId, '');
      expect(machine.machineId, 'VLT16');
      final both = parsePositionLabel('A-01@A1')!;
      expect((both.positionId, both.machineId), ('A-01', 'A1'));
    });

    test('a bare code is not a label', () {
      expect(parsePositionLabel('A-01'), isNull);
      expect(parsePositionLabel('A1'), isNull);
      expect(parsePositionLabel('{"MaNV":"10000003"}'), isNull);
    });

    test('parsePositionCode accepts SAP codes only', () {
      expect(parsePositionCode(' a-01 '), 'A-01');
      expect(parsePositionCode('VLT16'), 'VLT16');
      expect(parsePositionCode('A B'), isNull);
      expect(parsePositionCode('ABCDEFGHIJK'), isNull);
      expect(parsePositionCode(''), isNull);
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
