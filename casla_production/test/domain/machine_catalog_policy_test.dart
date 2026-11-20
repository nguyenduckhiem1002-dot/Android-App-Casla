import 'package:casla_production/domain/entities/worker_position.dart';
import 'package:casla_production/domain/policies/machine_catalog_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const _wc = 'CL100077';

const _m101 = MachineOption(
  machineId: 'M101',
  machineName: 'Máy cắt 1',
  workCenter: _wc,
  positionId: 'G01',
  workerId: '10000001',
  workerName: 'Nguyễn Văn An',
);
const _m102 = MachineOption(
  machineId: 'M102',
  machineName: 'Máy may 2',
  workCenter: _wc,
  positionId: 'G02',
);
const _m103 = MachineOption(
  machineId: 'M103',
  machineName: 'Máy may 3',
  workCenter: 'CL100078',
  positionId: 'G07',
);
const _m109 = MachineOption(machineId: 'M109', machineName: 'Máy dự phòng');

void main() {
  group('parseMachineScan', () {
    test('takes the machine part of a position label', () {
      expect(parseMachineScan('G05@M105'), 'M105');
      expect(parseMachineScan('VT=G05;MAY=m105'), 'M105');
      expect(
        parseMachineScan('{"PositionID":"G05","MachineID":"M105"}'),
        'M105',
      );
    });

    test('accepts a machine-only label and a bare code', () {
      expect(parseMachineScan('MAY=M105'), 'M105');
      expect(parseMachineScan('{"MachineID":"m-105"}'), 'M-105');
      expect(parseMachineScan('  m105 '), 'M105');
    });

    test('rejects what is not a machine label', () {
      expect(parseMachineScan(''), isNull);
      expect(parseMachineScan('{"MaNV":"10000003"}'), isNull);
      expect(parseMachineScan('VT=G05'), isNull);
      expect(parseMachineScan('M105|G05'), isNull);
      expect(parseMachineScan('ABCDEFGHIJK'), isNull, reason: '> 10 chars');
      expect(parseMachineScan('{"MachineID":'), isNull, reason: 'damaged');
    });
  });

  group('attachBoardWorkers', () {
    const board = PositionBoard(
      workCenterCount: 1,
      seats: [
        PositionSeat(
          workCenter: _wc,
          positionId: 'G01',
          machineId: 'M101',
          workerId: '10000009',
          workerName: 'Người khác',
        ),
        PositionSeat(
          workCenter: _wc,
          positionId: 'G02',
          machineId: 'M102',
          workerId: '10000002',
          workerName: 'Trần Thị Bình',
        ),
      ],
    );

    test('fills a worker only where SAP sent none', () {
      final catalog = attachBoardWorkers(
        const MachineCatalog(machines: [_m101, _m102, _m103, _m109]),
        board,
      );
      final byId = {for (final m in catalog.machines) m.machineId: m};
      // SAP's own worker wins over the board.
      expect(byId['M101']!.workerId, '10000001');
      expect(byId['M102']!.workerId, '10000002');
      expect(byId['M102']!.workerLabel, 'Trần Thị Bình');
      // Another Work Center: the board does not cover it.
      expect(byId['M103']!.isOccupied, isFalse);
      // A free machine never gets a worker.
      expect(byId['M109']!.isOccupied, isFalse);
    });

    test('leaves the catalog alone without a board', () {
      const catalog = MachineCatalog(machines: [_m102]);
      expect(attachBoardWorkers(catalog, null), same(catalog));
      expect(
        attachBoardWorkers(
          catalog,
          PositionBoard.empty,
        ).machines.single.isOccupied,
        isFalse,
      );
    });
  });

  group('filterMachines', () {
    const all = [_m101, _m102, _m103, _m109];

    test('filter by use', () {
      expect(
        filterMachines(
          all,
          filter: MachineFilter.missingWorker,
        ).map((m) => m.machineId),
        ['M102', 'M103'],
      );
      expect(
        filterMachines(
          all,
          filter: MachineFilter.unassigned,
        ).map((m) => m.machineId),
        ['M109'],
      );
      expect(
        filterMachines(
          all,
          filter: MachineFilter.active,
        ).map((m) => m.machineId),
        ['M101'],
      );
      expect(machineStatusOf(_m101), MachineStatus.active);
      expect(machineStatusOf(_m102), MachineStatus.missingWorker);
      expect(machineStatusOf(_m109), MachineStatus.unassigned);
    });

    test('query matches code, name, position, Work Center and worker', () {
      List<String> ids(String query) =>
          filterMachines(all, query: query).map((m) => m.machineId).toList();
      expect(ids('m10'), ['M101', 'M102', 'M103', 'M109']);
      expect(ids('dự phòng'), ['M109']);
      expect(ids('g07'), ['M103']);
      expect(ids('CL100078'), ['M103']);
      expect(ids('văn an'), ['M101']);
      expect(ids('10000001'), ['M101']);
      expect(ids('xyz'), isEmpty);
    });

    test('summary counts total, in use and occupied', () {
      final summary = summarizeMachines(all);
      expect(summary.total, 4);
      expect(summary.active, 1);
      expect(summary.missingWorker, 2);
      expect(summary.unassigned, 1);
      expect(summary.inUse, 3);
    });
  });
}
