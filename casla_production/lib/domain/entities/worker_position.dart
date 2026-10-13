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
