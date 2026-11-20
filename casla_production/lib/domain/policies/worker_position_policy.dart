/// Turns the scans of S14 into the confirmations and SAP commands of
/// ZUI_PP_POS.
///
/// The rules mirror `zcl_pp_position_api` (abap_casla_app_mobile,
/// docs/POSITION_MANAGEMENT.md):
/// - one position, one row; a position may run without a machine, and a new
///   position needs a machine to be created;
/// - one machine per active position; changing the machine updates the row,
///   and taking it off leaves the position active without a machine;
/// - one worker per position and one position per worker; seating a worker
///   retires both their old seat and whoever sat at the new one.
///
/// A machine attached at another position is not blocked: SAP moves it
/// (2026-11-10), leaving the old position active without a machine and
/// whoever sits there in place. The plan warns about that when the board
/// shows the other position. SAP only refuses (MACHINE_IN_USE) when that
/// position belongs to a Work Center outside the account's scope, which the
/// board of this Work Center cannot show; the answer is then shown as any
/// other rejection.
///
/// SAP applies those side effects on its own. The app only has to tell the
/// supervisor about them first, using the board it just loaded, and then send
/// one command per request.
///
/// Labels on the floor carry one code each: a position label (`A-01`) and a
/// machine label (`A1`), both printed as plain text. Their shapes overlap, so
/// a bare code cannot tell which it is; the screen routes it to the field the
/// supervisor selected. Keyed and JSON labels, and the older combined
/// `A-01@A1` label, name their fields and are routed on their own.
library;

import '../../core/utils/scanned_json.dart';
import '../entities/worker_position.dart';

/// What the form holds: the position, the machine meant for it (empty when the
/// position keeps whatever SAP has, or has none), and the Work Center.
class PositionSlot {
  final String workCenter;
  final String positionId;

  /// Empty means "no machine change": an existing position keeps its machine,
  /// a new one cannot be created ([PositionUpdatePlan.needsMachine]).
  final String machineId;

  /// The supervisor asked to take the machine off the position (the x on a
  /// machine SAP filled in). Only read with an empty [machineId]: a scanned
  /// machine is a change, not a removal.
  final bool detachMachine;

  const PositionSlot({
    required this.workCenter,
    required this.positionId,
    this.machineId = '',
    this.detachMachine = false,
  });

  bool get hasMachine => machineId.trim().isNotEmpty;

  PositionSlot withWorkCenter(String value) => PositionSlot(
    workCenter: value.trim().toUpperCase(),
    positionId: positionId,
    machineId: machineId,
    detachMachine: detachMachine,
  );

  @override
  String toString() => hasMachine ? '$positionId · $machineId' : positionId;
}

class PositionWorker {
  final String code;
  final String name;

  const PositionWorker({required this.code, this.name = ''});

  String get label => name.trim().isEmpty ? code : name.trim();
}

enum PositionCase {
  newPosition('Vị trí chưa tồn tại'),
  changeMachine('Thay đổi máy tại vị trí'),
  moveMachine('Máy đang gắn ở vị trí khác'),
  detachMachine('Gỡ máy khỏi vị trí'),
  transferWorker('Điều chuyển công nhân'),
  replaceWorker('Vị trí đang có công nhân');

  final String title;
  const PositionCase(this.title);
}

/// One line of the before/after block under a warning, such as
/// `Máy hiện tại: M101` followed by `Máy mới: M109`.
class PositionDetail {
  final String label;
  final String value;

  const PositionDetail(this.label, this.value);
}

class PositionWarning {
  final PositionCase kind;
  final String message;

  /// What is there now and what the scan replaces it with, in that order,
  /// so the supervisor can compare the two at a glance.
  final List<PositionDetail> details;

  const PositionWarning(this.kind, this.message, {this.details = const []});
}

enum PositionCommandKind {
  createPosition,
  changeMachine,
  detachMachine,
  transferWorker,
}

class PositionCommand {
  final PositionCommandKind kind;

  /// For [PositionCommandKind.detachMachine] the machine is the one being
  /// taken off, kept for the description; SAP is sent an empty machine.
  final PositionSlot slot;
  final PositionWorker? worker;

  const PositionCommand(this.kind, this.slot, [this.worker]);

  /// What the supervisor reads in the confirmation and the result sheet.
  String get description => switch (kind) {
    PositionCommandKind.createPosition =>
      'Tạo vị trí ${slot.positionId} với máy ${slot.machineId}',
    PositionCommandKind.changeMachine =>
      'Đổi máy của vị trí ${slot.positionId} sang ${slot.machineId}',
    PositionCommandKind.detachMachine =>
      'Gỡ máy ${slot.machineId} khỏi vị trí ${slot.positionId}',
    PositionCommandKind.transferWorker =>
      'Xếp ${worker!.label} (${worker!.code}) vào vị trí ${slot.positionId}',
  };
}

class PositionUpdatePlan {
  /// Asked in order; declining any of them cancels the whole update.
  final List<PositionWarning> warnings;

  /// Sent in order, one request each. The position command always comes
  /// before the worker, because SAP only seats a worker at an active position.
  final List<PositionCommand> commands;

  /// The position does not exist on the board and no machine was scanned:
  /// SAP cannot create it (INPUT_INVALID), so nothing is sent until one is.
  final bool needsMachine;

  const PositionUpdatePlan({
    this.warnings = const [],
    this.commands = const [],
    this.needsMachine = false,
  });

  /// The board already shows exactly what was scanned.
  bool get isNoop => commands.isEmpty && !needsMachine;
}

PositionUpdatePlan planPositionUpdate({
  required List<PositionSeat> board,
  required PositionSlot slot,
  PositionWorker? worker,
}) {
  bool atSlot(PositionSeat seat) =>
      _same(seat.workCenter, slot.workCenter) &&
      _same(seat.positionId, slot.positionId);

  final current = board.where(atSlot).firstOrNull;
  final warnings = <PositionWarning>[];
  final commands = <PositionCommand>[];
  // SAP keeps the seated worker on a machine change or removal; say so.
  final keeps = current != null && current.isOccupied
      ? ' CN ${current.workerLabel} vẫn ngồi vị trí này.'
      : '';
  // True once a command attaches slot.machineId to this position.
  var attaches = false;

  if (current == null) {
    if (!slot.hasMachine) return const PositionUpdatePlan(needsMachine: true);
    warnings.add(
      PositionWarning(
        PositionCase.newPosition,
        'Vị trí ${slot.positionId} / máy ${slot.machineId} chưa tồn tại. '
        'Có tạo mới không?',
        details: [PositionDetail('Vị trí mới', '$slot')],
      ),
    );
    commands.add(PositionCommand(PositionCommandKind.createPosition, slot));
    attaches = true;
  } else if (slot.hasMachine && !_same(current.machineId, slot.machineId)) {
    final hadMachine = current.machineId.trim().isNotEmpty;
    warnings.add(
      PositionWarning(
        PositionCase.changeMachine,
        hadMachine
            ? 'Vị trí ${slot.positionId} đang gắn máy ${current.machineId}. '
                  'Có thay đổi sang máy ${slot.machineId} không?$keeps'
            : 'Vị trí ${slot.positionId} chưa gắn máy. Có gắn máy '
                  '${slot.machineId} không?$keeps',
        details: [
          PositionDetail(
            'Máy hiện tại',
            hadMachine ? current.machineId : 'Chưa có',
          ),
          PositionDetail('Máy mới', slot.machineId),
        ],
      ),
    );
    commands.add(PositionCommand(PositionCommandKind.changeMachine, slot));
    attaches = true;
  } else if (slot.detachMachine &&
      !slot.hasMachine &&
      current.machineId.trim().isNotEmpty) {
    final machine = current.machineId.trim();
    warnings.add(
      PositionWarning(
        PositionCase.detachMachine,
        'Vị trí ${slot.positionId} đang gắn máy $machine. Có gỡ máy khỏi vị '
        'trí không? Vị trí vẫn đang dùng, máy $machine thành máy rảnh.$keeps',
        details: [
          PositionDetail('Máy hiện tại', machine),
          const PositionDetail('Sau khi gỡ', 'Chưa gắn máy'),
        ],
      ),
    );
    commands.add(
      PositionCommand(
        PositionCommandKind.detachMachine,
        PositionSlot(
          workCenter: slot.workCenter,
          positionId: slot.positionId,
          machineId: machine,
        ),
      ),
    );
  }

  // If the board shows the attached machine at another position, SAP moves
  // it and that position loses its machine.
  if (attaches) {
    final source = board
        .where(
          (seat) =>
              !atSlot(seat) &&
              seat.machineId.trim().isNotEmpty &&
              _same(seat.machineId, slot.machineId),
        )
        .firstOrNull;
    if (source != null) {
      final stays = source.isOccupied
          ? ' CN ${source.workerLabel} vẫn ngồi vị trí ${source.positionId}.'
          : '';
      warnings.add(
        PositionWarning(
          PositionCase.moveMachine,
          'Máy ${slot.machineId} đang gắn ở vị trí ${source.positionId}. '
          'Có chuyển máy sang vị trí ${slot.positionId} không? Vị trí '
          '${source.positionId} sẽ trống mã máy.$stays',
          details: [
            PositionDetail('Vị trí đang gắn', source.positionId),
            PositionDetail('Vị trí mới', slot.positionId),
          ],
        ),
      );
    }
  }

  if (worker != null && !_same(current?.workerId ?? '', worker.code)) {
    final seatedElsewhere = board
        .where((seat) => _same(seat.workerId, worker.code) && !atSlot(seat))
        .firstOrNull;
    if (seatedElsewhere != null) {
      warnings.add(
        PositionWarning(
          PositionCase.transferWorker,
          'CN ${worker.label} đang ở vị trí ${seatedElsewhere.positionId} / '
          'máy ${seatedElsewhere.machineId}. Có điều chuyển CN sang vị trí mới '
          '${slot.positionId} không?',
          details: [
            PositionDetail(
              'Vị trí hiện tại',
              '${seatedElsewhere.positionId} · ${seatedElsewhere.machineId}',
            ),
            PositionDetail('Vị trí mới', '$slot'),
          ],
        ),
      );
    }
    if (current != null && current.isOccupied) {
      warnings.add(
        PositionWarning(
          PositionCase.replaceWorker,
          'Vị trí ${slot.positionId} đang có CN ${current.workerLabel} '
          '(${current.workerId}). Có thay bằng CN ${worker.label} không? '
          'CN ${current.workerLabel} sẽ rời vị trí.',
          details: [
            PositionDetail(
              'CN hiện tại',
              '${current.workerLabel} (${current.workerId})',
            ),
            PositionDetail('CN mới', '${worker.label} (${worker.code})'),
          ],
        ),
      );
    }
    commands.add(
      PositionCommand(PositionCommandKind.transferWorker, slot, worker),
    );
  }

  return PositionUpdatePlan(warnings: warnings, commands: commands);
}

/// What a label names: a position, a machine, or both. At least one is set.
class PositionLabel {
  final String workCenter;
  final String positionId;
  final String machineId;

  const PositionLabel({
    this.workCenter = '',
    this.positionId = '',
    this.machineId = '',
  });
}

/// Reads a label that names its fields.
///
/// Accepted forms:
/// - keyed `VT=A-01`, `MAY=A1` or `VT=A-01;MAY=A1`;
/// - JSON `{"PositionID":"A-01"}`, `{"MachineID":"A1"}` or both;
/// - the older combined `A-01@A1`, position then machine.
///
/// A bare code (`A-01`, `A1`) is not a label in this sense: it could be
/// either, so it returns null and the caller decides by the selected field
/// ([parsePositionCode]). Worker cards return null too.
///
/// The printed label carries no Work Center: a position belongs to the Work
/// Center the supervisor is working in, and the caller fills that in. Only
/// the keyed and JSON forms can name one, which the caller checks against it.
PositionLabel? parsePositionLabel(String raw) {
  final text = ScannedJson.normalizeText(raw.trim());
  if (text.isEmpty || text.length > 400) return null;

  final json = ScannedJson.decodeObject(text);
  if (json.isDamaged) return null;
  if (json.fields != null) return _labelFromFields(json.fields!);

  final keyed = <String, String>{};
  for (final part in text.split(RegExp(r'[;&\n]'))) {
    final pair = part.split(RegExp(r'[=:]'));
    if (pair.length == 2) keyed[pair[0]] = pair[1];
  }
  if (keyed.isNotEmpty) return _labelFromFields(keyed);

  // `@` only: codes may contain `-`, `.` or `_`, and a bare `G05|M105` or
  // `G05/M105` is too close to other labels on the floor to guess at.
  final parts = text.split('@');
  if (parts.length != 2) return null;
  final position = parsePositionCode(parts[0]);
  final machine = parsePositionCode(parts[1]);
  return position == null || machine == null
      ? null
      : PositionLabel(positionId: position, machineId: machine);
}

/// The combined label only: position and machine both named.
PositionSlot? parsePositionSlotQr(String raw) {
  final label = parsePositionLabel(raw);
  if (label == null || label.positionId.isEmpty || label.machineId.isEmpty) {
    return null;
  }
  return PositionSlot(
    workCenter: label.workCenter,
    positionId: label.positionId,
    machineId: label.machineId,
  );
}

/// A bare position or machine code as SAP stores it: up to 10 characters of
/// letters, digits, `.`, `_` and `-`, upper-cased. Null for anything else.
String? parsePositionCode(String raw) {
  final code = raw.trim().toUpperCase();
  if (code.isEmpty || code.length > 10) return null;
  return RegExp(r'^[A-Z0-9._-]+$').hasMatch(code) ? code : null;
}

PositionLabel? _labelFromFields(Map<String, dynamic> fields) {
  final normalized = {
    for (final entry in fields.entries)
      entry.key.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z]'), ''):
          '${entry.value ?? ''}'.trim(),
  };
  String pick(List<String> keys) =>
      keys.map((key) => normalized[key]).whereType<String>().firstOrNull ?? '';
  final position = pick(['VT', 'VITRI', 'POSITIONID', 'POSITION', 'POS']);
  final machine = pick(['MAY', 'MAMAY', 'MACHINEID', 'MACHINE']);
  final wc = pick(['WC', 'WORKCENTER', 'XUONG']).toUpperCase();
  if (position.isEmpty && machine.isEmpty) return null;
  final p = position.isEmpty ? '' : parsePositionCode(position);
  final m = machine.isEmpty ? '' : parsePositionCode(machine);
  if (p == null || m == null) return null;
  if (wc.isNotEmpty &&
      (!RegExp(r'^[A-Z0-9._-]+$').hasMatch(wc) || wc.length > 8)) {
    return null;
  }
  return PositionLabel(workCenter: wc, positionId: p, machineId: m);
}

bool _same(String a, String b) =>
    a.trim().toUpperCase() == b.trim().toUpperCase();

/// What a scan on the overview (S06) points at once the board is known:
/// the worker seated at a scanned position, an empty position, or a position
/// the board does not have. Null when the scan is not a position at all.
sealed class SeatLookup {
  const SeatLookup();
}

/// The position is on the board and someone sits there.
class SeatLookupWorker extends SeatLookup {
  final PositionSeat seat;

  const SeatLookupWorker(this.seat);
}

/// The position is on the board but nobody sits there.
class SeatLookupEmpty extends SeatLookup {
  final String positionId;

  const SeatLookupEmpty(this.positionId);
}

/// A label that names a position the board does not have.
class SeatLookupUnknown extends SeatLookup {
  final String positionId;

  const SeatLookupUnknown(this.positionId);
}

/// Reads [raw] as a position and finds its seat on [seats].
///
/// A label that names a position (keyed, JSON or `A-01@A1`) is always a
/// position: on the board or not. A bare code is a position only when the
/// board has it; otherwise null, and the caller treats it as a worker code,
/// since the two shapes overlap. [workCenter] narrows the board when set.
SeatLookup? lookupSeatForScan({
  required Iterable<PositionSeat> seats,
  required String raw,
  String workCenter = '',
}) {
  final label = parsePositionLabel(raw);
  final explicit = label?.positionId ?? '';
  final code = explicit.isNotEmpty ? explicit : parsePositionCode(raw);
  if (code == null) return null;
  final wc = label != null && label.workCenter.isNotEmpty
      ? label.workCenter
      : workCenter;
  final seat = seats
      .where(
        (seat) =>
            (wc.isEmpty || _same(seat.workCenter, wc)) &&
            _same(seat.positionId, code),
      )
      .firstOrNull;
  if (seat == null) return explicit.isEmpty ? null : SeatLookupUnknown(code);
  return seat.isOccupied ? SeatLookupWorker(seat) : SeatLookupEmpty(code);
}
