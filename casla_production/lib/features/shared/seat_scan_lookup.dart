// Resolving a scan to the seat it names, for the overview screens (S06 Tổng
// quan, W02 Xem team): a position label, or a bare code the board knows as a
// position, points at whoever sits there. The board of the active Work
// Center is read through getPositionBoard, which SAP grants to PP_POS_MANAGE
// and (read only) to PP_HIST_TEAM, and is kept for a minute so one scan
// costs at most one call.

import '../../data/sap/sap_position_gateway.dart';
import '../../domain/entities/worker_position.dart';
import '../../domain/policies/worker_position_policy.dart';
import '../supervisor/position_error_text.dart';

class SeatScanLookup {
  final PositionApi Function() api;
  final Duration ttl;
  final DateTime Function() now;

  PositionBoard? _board;
  String _boardWorkCenter = '';
  DateTime? _boardAt;

  SeatScanLookup({
    required this.api,
    this.ttl = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  /// Null when [raw] is not a position, or when the board could not be read
  /// and [raw] is a bare code (then it reads as a worker code). A position
  /// label with no board is reported through [onError] and still null.
  Future<SeatLookup?> resolve(
    String raw, {
    required String workCenter,
    required bool explicit,
    void Function(String message)? onError,
  }) async {
    final board = await _boardFor(
      workCenter,
      onError: explicit ? onError : null,
    );
    if (board == null) return null;
    return lookupSeatForScan(
      seats: board.seats,
      raw: raw,
      workCenter: workCenter,
    );
  }

  /// Drops the cached board, e.g. after the Work Center changes.
  void invalidate() {
    _board = null;
    _boardAt = null;
  }

  Future<PositionBoard?> _boardFor(
    String workCenter, {
    void Function(String message)? onError,
  }) async {
    final cached = _board;
    final at = _boardAt;
    if (cached != null &&
        at != null &&
        _boardWorkCenter == workCenter &&
        now().difference(at) < ttl) {
      return cached;
    }
    try {
      final board = await api().getBoard(workCenter: workCenter);
      _board = board;
      _boardWorkCenter = workCenter;
      _boardAt = now();
      return board;
    } catch (error) {
      onError?.call('Chưa tra được vị trí: ${describePositionError(error)}');
      return null;
    }
  }
}
