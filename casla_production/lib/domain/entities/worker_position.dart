/// Worker position data returned by ZUI_PP_POS (`zcl_pp_position_api`).
///
/// SAP keeps two tables: positions (Work Center + position + machine, one
/// active machine per position) and assignments (one worker per position, one
/// position per worker). The board joins them and only lists active positions,
/// so everything here is "đang dùng" by definition.
library;

/// One active position on the board, with whoever sits there.
class PositionSeat {
  final String workCenter;
  final String positionId;
  final String machineId;
  final String positionName;

  /// Empty when nobody sits at this position.
  final String workerId;
  final String workerName;

  const PositionSeat({
    required this.workCenter,
    required this.positionId,
    required this.machineId,
    this.positionName = '',
    this.workerId = '',
    this.workerName = '',
  });

  bool get isOccupied => workerId.trim().isNotEmpty;

  /// `Tên CN`, falling back to the worker code when SAP has no name for it.
  String get workerLabel {
    final name = workerName.trim();
    return name.isEmpty ? workerId.trim() : name;
  }

  factory PositionSeat.fromJson(Map<String, dynamic> json) => PositionSeat(
    workCenter: _text(json['WorkCenter']),
    positionId: _text(json['PositionID']),
    machineId: _text(json['MachineID']),
    positionName: _text(json['PositionName']),
    workerId: _text(json['WorkerID']),
    workerName: _text(json['WorkerName']),
  );
}

class PositionBoard {
  final int workCenterCount;
  final List<PositionSeat> seats;

  const PositionBoard({required this.workCenterCount, required this.seats});

  static const empty = PositionBoard(workCenterCount: 0, seats: []);

  factory PositionBoard.fromJson(Map<String, dynamic> json) {
    final raw = json['_Positions'];
    final seats = raw is List
        ? raw
              .whereType<Map>()
              .map(
                (row) => PositionSeat.fromJson(Map<String, dynamic>.from(row)),
              )
              .toList(growable: false)
        : const <PositionSeat>[];
    return PositionBoard(
      workCenterCount: int.tryParse(_text(json['WorkCenterCount'])) ?? 0,
      seats: seats,
    );
  }
}

/// One machine of the catalog (`ZA_PP_MachineItem`): active in
/// `ZTB_PP_MACHINE` by definition, plus the active position it is attached to
/// and whoever sits there.
class MachineOption {
  final String machineId;
  final String machineName;

  /// Where the machine sits now; both empty when it is free. Attaching it at
  /// another position moves it and leaves this one without a machine; SAP
  /// refuses (MACHINE_IN_USE) only when this Work Center is outside the
  /// account's scope.
  final String workCenter;
  final String positionId;

  /// The worker with an active assignment at that position (SAP since
  /// 2026-11-05). Empty when the machine is free or the position has nobody.
  /// An older backend omits both fields; `attachBoardWorkers` can fill them
  /// from the position board instead.
  final String workerId;
  final String workerName;

  const MachineOption({
    required this.machineId,
    this.machineName = '',
    this.workCenter = '',
    this.positionId = '',
    this.workerId = '',
    this.workerName = '',
  });

  bool get isInUse => positionId.trim().isNotEmpty;

  bool get isOccupied => workerId.trim().isNotEmpty;

  /// `Tên máy`, falling back to the code when the catalog has no name.
  String get label {
    final name = machineName.trim();
    return name.isEmpty ? machineId.trim() : name;
  }

  /// `Tên CN`, falling back to the worker code when SAP has no name for it.
  String get workerLabel {
    final name = workerName.trim();
    return name.isEmpty ? workerId.trim() : name;
  }

  MachineOption withWorker({
    required String workerId,
    String workerName = '',
  }) => MachineOption(
    machineId: machineId,
    machineName: machineName,
    workCenter: workCenter,
    positionId: positionId,
    workerId: workerId.trim(),
    workerName: workerName.trim(),
  );

  factory MachineOption.fromJson(Map<String, dynamic> json) {
    final positionId = _text(json['PositionID']).toUpperCase();
    return MachineOption(
      machineId: _text(json['MachineID']).toUpperCase(),
      machineName: _text(json['MachineName']),
      workCenter: _text(json['WorkCenter']).toUpperCase(),
      // SAP's IsInUse is derived from PositionID; keep the position as the
      // source so a flag without a position never reads as "in use".
      positionId: positionId,
      // A worker only makes sense at a position; drop a stray one.
      workerId: positionId.isEmpty ? '' : _text(json['WorkerID']),
      workerName: positionId.isEmpty ? '' : _text(json['WorkerName']),
    );
  }
}

/// `ZA_PP_MachineResult`: every active machine, sorted by code by SAP.
class MachineCatalog {
  final List<MachineOption> machines;

  const MachineCatalog({required this.machines});

  static const empty = MachineCatalog(machines: []);

  MachineOption? byId(String code) {
    final wanted = code.trim().toUpperCase();
    return machines.where((m) => m.machineId == wanted).firstOrNull;
  }

  factory MachineCatalog.fromJson(Map<String, dynamic> json) {
    final raw = json['_Machines'];
    return MachineCatalog(
      machines: raw is List
          ? raw
                .whereType<Map>()
                .map(
                  (row) =>
                      MachineOption.fromJson(Map<String, dynamic>.from(row)),
                )
                .where((machine) => machine.machineId.isNotEmpty)
                .toList(growable: false)
          : const <MachineOption>[],
    );
  }
}

/// `ZA_PP_PosCommandResult`. SAP reports rejections as an error response, so
/// a parsed result always means the command took effect (or already had).
class PositionCommandResult {
  final String status;
  final String workCenter;
  final String positionId;
  final String machineId;
  final String workerId;
  final String message;

  const PositionCommandResult({
    required this.status,
    this.workCenter = '',
    this.positionId = '',
    this.machineId = '',
    this.workerId = '',
    this.message = '',
  });

  factory PositionCommandResult.fromJson(Map<String, dynamic> json) =>
      PositionCommandResult(
        status: _text(json['Status']),
        workCenter: _text(json['WorkCenter']),
        positionId: _text(json['PositionID']),
        machineId: _text(json['MachineID']),
        workerId: _text(json['WorkerID']),
        message: _text(json['Message']),
      );
}

String _text(Object? value) => value == null ? '' : '$value'.trim();
