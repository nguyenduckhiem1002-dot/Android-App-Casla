/// Turns two scans into the confirmations and SAP commands of ZUI_PP_POS.
///
/// The rules mirror `zcl_pp_position_api` (abap_casla_app_mobile,
/// docs/POSITION_MANAGEMENT.md):
/// - one active machine per position; a new machine retires the old row;
/// - one worker per position and one position per worker; seating a worker
///   retires both their old seat and whoever sat at the new one.
///
/// A machine code is not checked for being used at another position: the same
/// code may sit at several positions. Should SAP still refuse one
/// (MACHINE_IN_USE), its answer is shown as any other rejection.
///
/// SAP applies those side effects on its own. The app only has to tell the
/// supervisor about them first, using the board it just loaded, and then send
/// one command per request.
library;

import '../../core/utils/scanned_json.dart';
import '../entities/worker_position.dart';

/// Position + machine read from one label, plus the Work Center it belongs to.
class PositionSlot {
  final String workCenter;
  final String positionId;
  final String machineId;

  const PositionSlot({
    required this.workCenter,
    required this.positionId,
    required this.machineId,
  });

  PositionSlot withWorkCenter(String value) => PositionSlot(
    workCenter: value.trim().toUpperCase(),
    positionId: positionId,
    machineId: machineId,
  );

  @override
  String toString() => '$positionId · $machineId';
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
  transferWorker('Điều chuyển công nhân'),
  replaceWorker('Vị trí đang có công nhân');

  final String title;
  const PositionCase(this.title);
}

class PositionWarning {
  final PositionCase kind;
  final String message;

  const PositionWarning(this.kind, this.message);
}

enum PositionCommandKind { createPosition, changeMachine, transferWorker }

class PositionCommand {
  final PositionCommandKind kind;
  final PositionSlot slot;
  final PositionWorker? worker;

  const PositionCommand(this.kind, this.slot, [this.worker]);

  /// What the supervisor reads in the confirmation and the result sheet.
  String get description => switch (kind) {
    PositionCommandKind.createPosition =>
      'Tạo vị trí ${slot.positionId} với máy ${slot.machineId}',
    PositionCommandKind.changeMachine =>
      'Đổi máy của vị trí ${slot.positionId} sang ${slot.machineId}',
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

  const PositionUpdatePlan({
    this.warnings = const [],
    this.commands = const [],
  });

  /// The board already shows exactly what was scanned.
  bool get isNoop => commands.isEmpty;
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

  if (current == null) {
    warnings.add(
      PositionWarning(
        PositionCase.newPosition,
        'Vị trí ${slot.positionId} / máy ${slot.machineId} chưa tồn tại. '
        'Có tạo mới không?',
      ),
    );
    commands.add(PositionCommand(PositionCommandKind.createPosition, slot));
  } else if (!_same(current.machineId, slot.machineId)) {
    final keeps = current.isOccupied
        ? ' CN ${current.workerLabel} vẫn ngồi vị trí này.'
        : '';
    warnings.add(
      PositionWarning(
        PositionCase.changeMachine,
        'Vị trí ${slot.positionId} đang gắn máy ${current.machineId}. '
        'Có thay đổi sang máy ${slot.machineId} không?$keeps',
      ),
    );
    commands.add(PositionCommand(PositionCommandKind.changeMachine, slot));
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
        ),
      );
    }
    commands.add(
      PositionCommand(PositionCommandKind.transferWorker, slot, worker),
    );
  }

  return PositionUpdatePlan(warnings: warnings, commands: commands);
}

/// Reads a position label.
///
/// Accepted forms:
/// - `G05@M105`, position then machine, as printed on the machine label;
/// - keyed `VT=G05;MAY=M105`;
/// - JSON `{"PositionID":"G05","MachineID":"M105"}`.
///
/// The printed label carries no Work Center: a position belongs to the Work
/// Center the supervisor is working in, and the caller fills that in. Only
/// the keyed and JSON forms can name one, which the caller checks against it.
///
/// Returns null for anything else, so one reader can tell a position label
/// from a worker card.
PositionSlot? parsePositionSlotQr(String raw) {
  final text = ScannedJson.normalizeText(raw.trim());
  if (text.isEmpty || text.length > 400) return null;

  final json = ScannedJson.decodeObject(text);
  if (json.isDamaged) return null;
  if (json.fields != null) return _fromFields(json.fields!);

  final keyed = <String, String>{};
  for (final part in text.split(RegExp(r'[;&\n]'))) {
    final pair = part.split(RegExp(r'[=:]'));
    if (pair.length == 2) keyed[pair[0]] = pair[1];
  }
  if (keyed.isNotEmpty) return _fromFields(keyed);

  // `@` only: codes may contain `-`, `.` or `_`, and a bare `G05|M105` or
  // `G05/M105` is too close to other labels on the floor to guess at.
  final parts = text.split('@');
  return parts.length == 2 ? _slot('', parts[0], parts[1]) : null;
}

PositionSlot? _fromFields(Map<String, dynamic> fields) {
  final normalized = {
    for (final entry in fields.entries)
      entry.key.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z]'), ''):
          '${entry.value ?? ''}'.trim(),
  };
  String pick(List<String> keys) =>
      keys.map((key) => normalized[key]).whereType<String>().firstOrNull ?? '';
  final position = pick(['VT', 'VITRI', 'POSITIONID', 'POSITION', 'POS']);
  final machine = pick(['MAY', 'MAMAY', 'MACHINEID', 'MACHINE']);
  if (position.isEmpty || machine.isEmpty) return null;
  return _slot(pick(['WC', 'WORKCENTER', 'XUONG']), position, machine);
}

PositionSlot? _slot(String wc, String position, String machine) {
  final w = wc.trim().toUpperCase();
  final p = position.trim().toUpperCase();
  final m = machine.trim().toUpperCase();
  final code = RegExp(r'^[A-Z0-9._-]+$');
  if (!code.hasMatch(p) || p.length > 10) return null;
  if (!code.hasMatch(m) || m.length > 10) return null;
  if (w.isNotEmpty && (!code.hasMatch(w) || w.length > 8)) return null;
  return PositionSlot(workCenter: w, positionId: p, machineId: m);
}

bool _same(String a, String b) =>
    a.trim().toUpperCase() == b.trim().toUpperCase();
