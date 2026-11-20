/// Rules of S16 Danh mục máy: what a scan means, how the catalog is searched
/// and how a worker is attached to a machine.
///
/// The catalog comes from `Positions/getMachines` (ZUI_PP_POS,
/// docs/POSITION_MANAGEMENT.md): every machine active in `ZTB_PP_MACHINE`,
/// the active position it is attached to and, since 2026-11-05, the worker
/// with an active assignment at that position. The screen is read-only;
/// every change still goes through S14.
library;

import '../../core/utils/scanned_json.dart';
import '../entities/worker_position.dart';
import 'worker_position_policy.dart';

/// Status of a machine on the floor, as the supervisors name it
/// (2026-11-06): the position it is attached to and whether anyone sits there.
enum MachineStatus {
  /// Attached to a position that has a worker: machine, position, worker.
  active('Hoạt động'),

  /// Attached to a position, but nobody sits there.
  missingWorker('Thiếu CN'),

  /// Not attached to any position.
  unassigned('Chưa bố trí');

  final String title;
  const MachineStatus(this.title);
}

MachineStatus machineStatusOf(MachineOption machine) => !machine.isInUse
    ? MachineStatus.unassigned
    : machine.isOccupied
    ? MachineStatus.active
    : MachineStatus.missingWorker;

enum MachineFilter {
  all('Tất cả'),
  active('Hoạt động'),
  missingWorker('Thiếu CN'),
  unassigned('Chưa bố trí');

  final String title;
  const MachineFilter(this.title);

  MachineStatus? get status => switch (this) {
    MachineFilter.all => null,
    MachineFilter.active => MachineStatus.active,
    MachineFilter.missingWorker => MachineStatus.missingWorker,
    MachineFilter.unassigned => MachineStatus.unassigned,
  };
}

/// Reads a machine code from a scan.
///
/// Accepted forms:
/// - the position label (`G05@M105`, keyed `VT=G05;MAY=M105`, or JSON with
///   `PositionID` and `MachineID`) — the machine part is used;
/// - a machine-only label: keyed `MAY=M105` or JSON `{"MachineID":"M105"}`;
/// - a bare machine code such as `M105`.
///
/// Returns null for anything else (a worker card, a damaged payload), so the
/// screen can say the scan was not a machine label.
String? parseMachineScan(String raw) {
  final slot = parsePositionSlotQr(raw);
  if (slot != null) return slot.machineId;

  final text = ScannedJson.normalizeText(raw.trim());
  if (text.isEmpty || text.length > 400) return null;

  final json = ScannedJson.decodeObject(text);
  if (json.isDamaged) return null;
  if (json.fields != null) return _machineOf(json.fields!);

  final keyed = <String, String>{};
  for (final part in text.split(RegExp(r'[;&\n]'))) {
    final pair = part.split(RegExp(r'[=:]'));
    if (pair.length == 2) keyed[pair[0]] = pair[1];
  }
  if (keyed.isNotEmpty) return _machineOf(keyed);

  return _code(text);
}

String? _machineOf(Map<String, dynamic> fields) {
  for (final entry in fields.entries) {
    final key = entry.key.trim().toUpperCase().replaceAll(
      RegExp(r'[^A-Z]'),
      '',
    );
    if (const {'MAY', 'MAMAY', 'MACHINEID', 'MACHINE'}.contains(key)) {
      return _code('${entry.value ?? ''}');
    }
  }
  return null;
}

String? _code(String value) {
  final code = value.trim().toUpperCase();
  if (code.isEmpty || code.length > 10) return null;
  return RegExp(r'^[A-Z0-9._-]+$').hasMatch(code) ? code : null;
}

/// Fills the worker of every attached machine from the position board when
/// SAP did not send one (backend older than 2026-11-05). A worker SAP did
/// send is kept: the catalog and the board were read at different moments
/// and SAP's own join is the fresher of the two for that row.
///
/// The board only covers the supervisor's Work Centers, so a machine attached
/// in another Work Center stays without a worker.
MachineCatalog attachBoardWorkers(
  MachineCatalog catalog,
  PositionBoard? board,
) {
  if (board == null || board.seats.isEmpty) return catalog;
  final seats = {
    for (final seat in board.seats)
      _seatKey(seat.workCenter, seat.positionId): seat,
  };
  return MachineCatalog(
    machines: [
      for (final machine in catalog.machines)
        if (!machine.isInUse || machine.isOccupied)
          machine
        else
          switch (seats[_seatKey(machine.workCenter, machine.positionId)]) {
            final seat? when seat.isOccupied => machine.withWorker(
              workerId: seat.workerId,
              workerName: seat.workerName,
            ),
            _ => machine,
          },
    ],
  );
}

String _seatKey(String workCenter, String positionId) =>
    '${workCenter.trim().toUpperCase()}|${positionId.trim().toUpperCase()}';

/// Machines matching the filter and the free-text query (code, name,
/// position, Work Center, worker code or name), in catalog order.
List<MachineOption> filterMachines(
  Iterable<MachineOption> machines, {
  String query = '',
  MachineFilter filter = MachineFilter.all,
}) {
  final wanted = query.trim().toUpperCase();
  return machines
      .where(
        (machine) =>
            filter.status == null || machineStatusOf(machine) == filter.status,
      )
      .where((machine) {
        if (wanted.isEmpty) return true;
        return machine.machineId.contains(wanted) ||
            machine.machineName.toUpperCase().contains(wanted) ||
            machine.positionId.contains(wanted) ||
            machine.workCenter.contains(wanted) ||
            machine.workerId.toUpperCase().contains(wanted) ||
            machine.workerName.toUpperCase().contains(wanted);
      })
      .toList(growable: false);
}

class MachineCatalogSummary {
  final int total;
  final int active;
  final int missingWorker;
  final int unassigned;

  const MachineCatalogSummary({
    required this.total,
    required this.active,
    required this.missingWorker,
    required this.unassigned,
  });

  /// Attached to a position, with or without a worker.
  int get inUse => active + missingWorker;

  int count(MachineStatus status) => switch (status) {
    MachineStatus.active => active,
    MachineStatus.missingWorker => missingWorker,
    MachineStatus.unassigned => unassigned,
  };
}

MachineCatalogSummary summarizeMachines(Iterable<MachineOption> machines) {
  var total = 0;
  var active = 0;
  var missingWorker = 0;
  var unassigned = 0;
  for (final machine in machines) {
    total++;
    switch (machineStatusOf(machine)) {
      case MachineStatus.active:
        active++;
      case MachineStatus.missingWorker:
        missingWorker++;
      case MachineStatus.unassigned:
        unassigned++;
    }
  }
  return MachineCatalogSummary(
    total: total,
    active: active,
    missingWorker: missingWorker,
    unassigned: unassigned,
  );
}
