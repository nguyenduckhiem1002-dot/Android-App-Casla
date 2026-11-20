// Screen S14 — Vị trí & công nhân (ZUI_PP_POS)
//
// Three views under one top bar:
//
// Quét gán: scan the position label (required), then the machine label (for
// a new position, or to change the machine), optionally tick "Gán công nhân"
// and scan the worker card, then Cập nhật. When the position already exists,
// its machine is filled in from the board, so most updates are one scan plus
// a worker card. The app reloads the board, shows what SAP is about to change
// and sends one command per request once the supervisor confirms.
//
// Labels on the floor carry one code each (`A-01` on a position, `A1` on a
// machine) and the two shapes overlap, so a bare code goes to the field the
// supervisor selected; the reader moves on to the next field by itself. A
// worker card is digits only, or a QR naming MaNV, so it is recognised
// anywhere. Keyed, JSON and the older `A-01@A1` labels name their fields.
//
// Chọn máy từ danh mục: the machine may also be picked from SAP's catalog
// (getMachines) instead of scanned.
//
// Bảng vị trí: the active positions in the supervisor's Work Centers, read
// only, with search and scan-to-find. Danh mục máy: every machine of the
// catalog with its position and worker, read only (MachineCatalogView).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';
import '../../../presentation/widgets/casla_dialog_header.dart';
import '../../../core/scanner/barcode_scanner.dart';
import '../../../core/scanner/scanner_preferences.dart';
import '../../../core/utils/worker_qr_parser.dart';
import '../../../data/sap/sap_position_gateway.dart';
import '../../../domain/entities/worker_position.dart';
import '../../../domain/policies/worker_position_policy.dart';
import '../../../main.dart';
import '../../../presentation/widgets/account_avatar_button.dart';
import '../../../presentation/widgets/adaptive_barcode_scanner_view.dart';
import '../../../presentation/widgets/barcode_scan_listener.dart';
import '../../../presentation/widgets/manual_code_dialog.dart';
import '../../../presentation/widgets/scan_slot_field.dart';
import '../../../presentation/widgets/scan_status_strip.dart';
import '../position_error_text.dart';
import '../widgets/compact_filter_chip.dart';
import '../widgets/machine_catalog_view.dart';

enum _Field { position, machine, worker }

enum _View { scan, board, machines }

/// What the camera is open for.
enum _Camera { position, machine, worker, findSeat, findMachine }

enum _BoardFilter { all, occupied, empty }

class S14WorkerPositionScreen extends ConsumerStatefulWidget {
  /// Overrides for tests; production reads all of these from AppState.
  final PositionApi? api;
  final String? workCenter;
  final Future<String?> Function(String workerCode)? workerNameLookup;
  final BarcodeScanner? scanner;
  final ScannerPreferences? scannerPreferences;
  final Widget? accountAction;

  const S14WorkerPositionScreen({
    super.key,
    this.api,
    this.workCenter,
    this.workerNameLookup,
    this.scanner,
    this.scannerPreferences,
    this.accountAction,
  });

  @override
  ConsumerState<S14WorkerPositionScreen> createState() =>
      _S14WorkerPositionScreenState();
}

class _S14WorkerPositionScreenState
    extends ConsumerState<S14WorkerPositionScreen> {
  String? _positionId;
  String? _machineId;

  /// True while [_machineId] is the board's machine for [_positionId], filled
  /// in by the app rather than scanned. Such a machine never means a change.
  bool _machineFromSap = false;

  /// The supervisor pressed x on the machine SAP filled in: the update takes
  /// the machine off the position. [_machineId] is null while this is set.
  bool _detachMachine = false;
  PositionWorker? _worker;
  bool _assignWorker = false;
  _Field _target = _Field.position;
  _Camera? _camera;
  bool _isSubmitting = false;

  /// True only while a request is in flight, not while a confirmation waits.
  bool _talkingToSap = false;
  bool _isDialogOpen = false;
  String? _error;

  _View _view = _View.scan;
  _BoardFilter _filter = _BoardFilter.all;
  final _boardSearch = TextEditingController();
  String _boardQuery = '';
  String? _boardHighlight;
  String? _boardScanError;
  PositionBoard? _board;
  bool _boardLoading = false;
  String? _boardError;
  int _boardRequest = 0;

  /// Catalog as last read for the picker; dropped with every board reload so
  /// a machine just attached shows as in use the next time the sheet opens.
  MachineCatalog? _machines;

  final _catalogKey = GlobalKey<MachineCatalogViewState>();

  PositionApi get _api =>
      widget.api ?? ref.read(appStateProvider).positionGateway;

  String get _workCenter =>
      (widget.workCenter ??
              ref.read(appStateProvider).activeWorkContext?.workCenter ??
              '')
          .trim()
          .toUpperCase();

  @override
  void initState() {
    super.initState();
    unawaited(_loadBoard());
  }

  @override
  void dispose() {
    _boardSearch.dispose();
    super.dispose();
  }

  Future<void> _loadBoard() async {
    final request = ++_boardRequest;
    setState(() {
      _boardLoading = true;
      _boardError = null;
      _machines = null;
    });
    try {
      // The supervisor's own Work Center, like every position on this screen.
      // SAP still checks a machine or a worker seated in another one.
      final board = await _api.getBoard(workCenter: _workCenter);
      if (!mounted || request != _boardRequest) return;
      setState(() {
        _board = board;
        _boardLoading = false;
        // A machine the app filled in follows the board it came from.
        final position = _positionId;
        if (position != null && _machineFromSap) {
          final current = _seatAtPosition(position)?.machineId.trim() ?? '';
          _machineId = current.isEmpty ? null : current;
          _machineFromSap = _machineId != null;
        }
      });
    } catch (error) {
      if (!mounted || request != _boardRequest) return;
      setState(() {
        _boardLoading = false;
        _boardError = describePositionError(error);
      });
    }
  }

  // ─── Scanning ────────────────────────────────────────────────────

  /// Every read of the hardware trigger lands here; the view decides what a
  /// code means. The camera and manual input name their field instead.
  Future<bool> _onTrigger(String raw) => switch (_view) {
    _View.scan => _handleScan(raw),
    _View.board => Future.value(_handleBoardScan(raw)),
    _View.machines =>
      _catalogKey.currentState?.handleScan(raw) ?? Future.value(false),
  };

  /// [target] is set when the supervisor picked the field (camera, manual
  /// input). A trigger pull lands in the selected field. A label that names
  /// its fields, and a worker card, are routed on their own.
  Future<bool> _handleScan(String raw, {_Field? target}) async {
    if (_isSubmitting || _isDialogOpen) return false;
    final want = target ?? _target;

    final label = parsePositionLabel(raw);
    if (label != null) {
      if (_workCenter.isNotEmpty &&
          label.workCenter.isNotEmpty &&
          label.workCenter != _workCenter) {
        setState(
          () => _error =
              'Nhãn thuộc xưởng ${label.workCenter}, còn bạn đang làm việc ở '
              'xưởng $_workCenter.',
        );
        return false;
      }
      if (label.positionId.isNotEmpty && !_setPosition(label.positionId)) {
        return false;
      }
      if (label.machineId.isNotEmpty) _setMachine(label.machineId);
      return true;
    }

    final card = _workerCard(raw, want);
    if (card != null) {
      final code = card.maNv.trim().toUpperCase();
      if (code.length > PositionFieldLimits.workerId) {
        setState(
          () => _error =
              'Mã công nhân $code dài hơn ${PositionFieldLimits.workerId} '
              'ký tự, SAP không nhận.',
        );
        return false;
      }
      final worker = PositionWorker(
        code: code,
        name: card.name.trim().isNotEmpty
            ? card.name.trim()
            : _seatOfWorker(code)?.workerName ?? '',
      );
      setState(() {
        _worker = worker;
        // A worker card on the reader means the supervisor wants to seat one.
        _assignWorker = true;
        _error = null;
        _target = _positionId == null ? _Field.position : _Field.worker;
      });
      if (worker.name.isEmpty) unawaited(_lookupWorkerName(code));
      return true;
    }

    final code = parsePositionCode(raw);
    if (code == null || want == _Field.worker) {
      setState(
        () => _error = switch (want) {
          _Field.worker =>
            'Không đọc được mã công nhân từ "${_short(raw)}". Quét lại thẻ '
                'hoặc nhập mã.',
          _Field.position =>
            'Mã "${_short(raw)}" không phải mã vị trí. Quét QR vị trí, ví dụ '
                'A-01.',
          _Field.machine =>
            'Mã "${_short(raw)}" không phải mã máy. Quét QR máy, ví dụ A1.',
        },
      );
      return false;
    }
    if (want == _Field.position) return _setPosition(code);
    _setMachine(code);
    return true;
  }

  /// A worker card is recognised anywhere by its shape: a QR naming MaNV, or
  /// digits only. In the worker field any employee code counts, because a
  /// bare `A1` there cannot be a label. Null otherwise.
  WorkerQrResult? _workerCard(String raw, _Field want) {
    final parsed = WorkerQrParser.parse(raw);
    if (!parsed.isValid) return null;
    final text = raw.trim();
    final bare = RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(text);
    if (want == _Field.worker || !bare || RegExp(r'^\d+$').hasMatch(text)) {
      return parsed;
    }
    return null;
  }

  /// The Work Center a scanned position belongs to: the one the supervisor
  /// works in, else the board's only one.
  String? get _resolvedWorkCenter {
    if (_workCenter.isNotEmpty) return _workCenter;
    final centers = {
      for (final seat in _board?.seats ?? const <PositionSeat>[])
        seat.workCenter,
    };
    return centers.length == 1 ? centers.first : null;
  }

  PositionSlot? get _slot {
    final position = _positionId;
    if (position == null) return null;
    return PositionSlot(
      workCenter: _resolvedWorkCenter ?? '',
      positionId: position,
      machineId: _machineId ?? '',
      detachMachine: _detachMachine && _machineId == null,
    );
  }

  /// Sets the position and fills its machine in from the board. The reader
  /// moves to the machine when the position is new or has none, else on to
  /// the worker when one is wanted.
  bool _setPosition(String code) {
    if (_resolvedWorkCenter == null) {
      setState(
        () => _error =
            'Chưa xác định được xưởng của vị trí $code. Hãy chọn xưởng trong '
            'ca làm việc trước.',
      );
      return false;
    }
    final seat = _seatAtPosition(code);
    final current = seat?.machineId.trim() ?? '';
    setState(() {
      _positionId = code;
      _machineId = current.isEmpty ? null : current;
      _machineFromSap = _machineId != null;
      _detachMachine = false;
      _error = null;
      _target = _machineId == null
          ? _Field.machine
          : _assignWorker && _worker == null
          ? _Field.worker
          : _Field.machine;
    });
    // Not on the board as loaded: it may have been created on Fiori since
    // (with or without a machine). Ask SAP again before calling it new.
    if (seat == null && _board != null) unawaited(_recheckPosition(code));
    return true;
  }

  Future<void> _recheckPosition(String code) async {
    await _loadBoard();
    if (!mounted || _positionId != code || _machineId != null) return;
    final seat = _seatAtPosition(code);
    if (seat == null) return;
    final current = seat.machineId.trim();
    setState(() {
      if (current.isNotEmpty) {
        _machineId = current;
        _machineFromSap = true;
      }
      // Known position: a worker is the likely next scan, not a machine.
      if (_assignWorker && _worker == null) _target = _Field.worker;
    });
  }

  void _setMachine(String code) {
    final position = _positionId;
    final current = position == null
        ? ''
        : _seatAtPosition(position)?.machineId ?? '';
    setState(() {
      _machineId = code;
      _machineFromSap = _same(current, code);
      _detachMachine = false;
      _error = null;
      _target = _assignWorker && _worker == null
          ? _Field.worker
          : position == null
          ? _Field.position
          : _Field.machine;
    });
  }

  /// Drops a scanned machine, or a pending removal: back to the board's
  /// machine, or none.
  void _resetMachine() {
    final position = _positionId;
    final current = position == null
        ? ''
        : _seatAtPosition(position)?.machineId.trim() ?? '';
    setState(() {
      _machineId = current.isEmpty ? null : current;
      _machineFromSap = _machineId != null;
      _detachMachine = false;
      _target = _Field.machine;
    });
  }

  /// The x on the machine SAP filled in: the update takes the machine off
  /// the position. Nothing is sent until Cập nhật is confirmed.
  void _markMachineDetached() {
    setState(() {
      _machineId = null;
      _machineFromSap = false;
      _detachMachine = true;
      _error = null;
      _target = _Field.machine;
    });
  }

  Future<void> _lookupWorkerName(String code) async {
    String? name;
    try {
      final lookup = widget.workerNameLookup;
      if (lookup != null) {
        name = await lookup(code);
      } else {
        final row = await ref.read(appStateProvider).db.getEmployeeByCode(code);
        name = row?['ten']?.toString();
      }
    } catch (_) {
      return;
    }
    final trimmed = name?.trim() ?? '';
    if (!mounted || trimmed.isEmpty || _worker?.code != code) return;
    setState(() => _worker = PositionWorker(code: code, name: trimmed));
  }

  Future<bool> _handleCameraScan(String raw) async {
    final camera = _camera;
    if (camera == null) return false;
    final accepted = switch (camera) {
      _Camera.position => await _handleScan(raw, target: _Field.position),
      _Camera.machine => await _handleScan(raw, target: _Field.machine),
      _Camera.worker => await _handleScan(raw, target: _Field.worker),
      _Camera.findSeat => _handleBoardScan(raw),
      _Camera.findMachine =>
        await (_catalogKey.currentState?.handleScan(raw) ??
            Future.value(false)),
    };
    if (accepted && mounted) setState(() => _camera = null);
    return accepted;
  }

  Future<void> _promptManualInput(_Field field) async {
    final value = await _modal(
      () => switch (field) {
        _Field.position => showManualCodeDialog(
          context,
          title: 'Nhập mã vị trí',
          label: 'Mã vị trí',
          helperText: 'Mã in dưới QR vị trí. Ví dụ: A-01',
          codeMaxLength: PositionFieldLimits.positionId,
        ),
        _Field.machine => showManualCodeDialog(
          context,
          title: 'Nhập mã máy',
          label: 'Mã máy',
          helperText: 'Mã in dưới QR máy. Ví dụ: A1',
          codeMaxLength: PositionFieldLimits.machineId,
        ),
        _Field.worker => showManualCodeDialog(
          context,
          title: 'Nhập mã công nhân',
          label: 'Mã công nhân',
          helperText: 'Ví dụ: 10000123',
        ),
      },
    );
    if (!mounted || value == null || value.trim().isEmpty) return;
    final accepted = await _handleScan(value.trim(), target: field);
    if (accepted && mounted && _camera != null) {
      setState(() => _camera = null);
    }
  }

  /// Manual input for the find-by-code of Bảng vị trí and Danh mục máy.
  Future<void> _promptManualFind(_View view) async {
    final value = await _modal(
      () => showManualCodeDialog(
        context,
        title: view == _View.board ? 'Tìm vị trí' : 'Nhập mã máy',
        label: view == _View.board ? 'Mã vị trí, máy hoặc công nhân' : 'Mã máy',
        helperText: view == _View.board
            ? 'Ví dụ: A-01, A1 hoặc 10000123'
            : 'Mã in dưới QR máy. Ví dụ: A1',
      ),
    );
    if (!mounted || value == null || value.trim().isEmpty) return;
    final accepted = view == _View.board
        ? _handleBoardScan(value.trim())
        : await (_catalogKey.currentState?.handleScan(value.trim()) ??
              Future.value(false));
    if (accepted && mounted && _camera != null) {
      setState(() => _camera = null);
    }
  }

  Future<MachineCatalog> _loadMachines({bool refresh = false}) async {
    final cached = _machines;
    if (cached != null && !refresh) return cached;
    final catalog = await _api.getMachines();
    if (mounted) setState(() => _machines = catalog);
    return catalog;
  }

  /// Picks a machine from the catalog. With a position already in the form
  /// the pick is the machine for it; otherwise the position code is asked
  /// for first.
  Future<void> _pickMachine() async {
    if (_isSubmitting || _isDialogOpen) return;
    final picked = await _modal(
      () => showModalBottomSheet<MachineOption>(
        context: context,
        isScrollControlled: true,
        backgroundColor: CaslaColors.surface,
        showDragHandle: true,
        builder: (context) => _MachinePickerSheet(
          load: _loadMachines,
          slot: _slot,
          workCenter: _workCenter,
        ),
      ),
    );
    if (picked == null || !mounted) return;

    if (_positionId == null) {
      final typed = await _modal(
        () => showManualCodeDialog(
          context,
          title: 'Nhập mã vị trí',
          label: 'Mã vị trí',
          helperText: 'Vị trí sẽ gắn máy ${picked.machineId}. Ví dụ: A-01',
          codeMaxLength: PositionFieldLimits.positionId,
        ),
      );
      if (!mounted || typed == null || typed.trim().isEmpty) return;
      final code = parsePositionCode(typed);
      if (code == null) {
        setState(() => _error = 'Mã "${_short(typed)}" không phải mã vị trí.');
        return;
      }
      if (!_setPosition(code)) return;
    }
    _setMachine(picked.machineId);
    final slot = _slot;
    if (slot == null || !picked.isInUse || _atSlot(picked, slot)) return;
    // Not blocked here: SAP moves the machine. Inside this Work Center the
    // machine card says so and the plan asks for confirmation
    // (PositionCase.moveMachine). Another Work Center is not on the board,
    // so say it here:
    // SAP moves it too, or refuses (MACHINE_IN_USE) when out of scope.
    if (_same(picked.workCenter, slot.workCenter)) return;
    setState(
      () => _error =
          'Máy ${picked.machineId} đang gắn ở vị trí ${picked.positionId} '
          '(xưởng ${picked.workCenter}). Cập nhật sẽ chuyển máy sang vị trí '
          '${slot.positionId}, vị trí ${picked.positionId} trống mã máy. Nếu '
          'xưởng ${picked.workCenter} ngoài phạm vi quyền của bạn thì SAP từ '
          'chối (MACHINE_IN_USE).',
    );
  }

  static bool _atSlot(MachineOption machine, PositionSlot slot) =>
      _same(machine.workCenter, slot.workCenter) &&
      _same(machine.positionId, slot.positionId);

  void _setAssignWorker(bool value) {
    setState(() {
      _assignWorker = value;
      if (!value) {
        _worker = null;
        if (_target == _Field.worker) {
          _target = _positionId == null ? _Field.position : _Field.machine;
        }
      } else if (_positionId != null && _worker == null) {
        _target = _Field.worker;
      }
    });
  }

  void _clearForm() {
    setState(() {
      _positionId = null;
      _machineId = null;
      _machineFromSap = false;
      _detachMachine = false;
      _worker = null;
      _assignWorker = false;
      _target = _Field.position;
      _error = null;
    });
  }

  // ─── Board helpers ───────────────────────────────────────────────

  PositionSeat? _seatAtPosition(String positionId) {
    final wc = _resolvedWorkCenter;
    return _board?.seats
        .where(
          (seat) =>
              (wc == null || _same(seat.workCenter, wc)) &&
              _same(seat.positionId, positionId),
        )
        .firstOrNull;
  }

  PositionSeat? _seatOfMachine(String machineId) {
    final wc = _resolvedWorkCenter;
    return _board?.seats
        .where(
          (seat) =>
              (wc == null || _same(seat.workCenter, wc)) &&
              seat.machineId.trim().isNotEmpty &&
              _same(seat.machineId, machineId),
        )
        .firstOrNull;
  }

  PositionSeat? _seatOfWorker(String code) =>
      _board?.seats.where((seat) => _same(seat.workerId, code)).firstOrNull;

  bool get _needsWorker => _assignWorker && _worker == null;

  /// A new position cannot be created without a machine; unknown while the
  /// board has not loaded, and then settled again by [_submit].
  bool get _needsMachine {
    final position = _positionId;
    return position != null &&
        _machineId == null &&
        _board != null &&
        !_boardLoading &&
        _seatAtPosition(position) == null;
  }

  /// The scanned position is not on the board and SAP is being asked again.
  bool get _checkingPosition {
    final position = _positionId;
    return _boardLoading &&
        position != null &&
        _board != null &&
        _seatAtPosition(position) == null;
  }

  PositionUpdatePlan? get _previewPlan {
    final slot = _slot;
    final board = _board;
    if (slot == null || board == null || _needsWorker || _needsMachine) {
      return null;
    }
    return planPositionUpdate(
      board: board.seats,
      slot: slot,
      worker: _assignWorker ? _worker : null,
    );
  }

  // ─── Submit ──────────────────────────────────────────────────────

  Future<void> _submit() async {
    final slot = _slot;
    if (slot == null || _needsWorker || _needsMachine || _isSubmitting) return;
    final worker = _assignWorker ? _worker : null;
    setState(() {
      _isSubmitting = true;
      _talkingToSap = true;
      _error = null;
    });
    void idle() {
      if (mounted) setState(() => _talkingToSap = false);
    }

    try {
      // Plan against the board as it is now, not as it was when the screen
      // opened: another supervisor may have moved the machine or the worker.
      final PositionBoard board;
      try {
        board = await _api.getBoard(workCenter: _workCenter);
      } catch (error) {
        if (mounted) setState(() => _error = describePositionError(error));
        return;
      }
      if (!mounted) return;
      setState(() {
        _board = board;
        _talkingToSap = false;
      });

      final plan = planPositionUpdate(
        board: board.seats,
        slot: slot,
        worker: worker,
      );
      if (plan.needsMachine) {
        setState(
          () => _error =
              'Vị trí ${slot.positionId} chưa có trên SAP. Quét QR máy để tạo '
              'vị trí.',
        );
        return;
      }
      if (plan.isNoop) {
        _showSnack(
          worker == null
              ? 'Vị trí ${slot.positionId}'
                    '${slot.hasMachine ? ' đã gắn máy ${slot.machineId}' : ''}. '
                    'Không có gì để cập nhật.'
              : '${worker.label} đã ngồi vị trí ${slot.positionId}. '
                    'Không có gì để cập nhật.',
        );
        return;
      }
      for (var i = 0; i < plan.warnings.length; i++) {
        final confirmed = await _confirmWarning(
          plan.warnings[i],
          step: i + 1,
          total: plan.warnings.length,
          commands: i == plan.warnings.length - 1 ? plan.commands : null,
        );
        if (!mounted) return;
        if (!confirmed) {
          _showSnack('Đã hủy. Chưa có thay đổi nào được gửi lên SAP.');
          return;
        }
      }

      setState(() => _talkingToSap = true);
      final done = <PositionCommand>[];
      for (final command in plan.commands) {
        try {
          await _execute(command);
          done.add(command);
        } catch (error) {
          if (!mounted) return;
          idle();
          await _showFailure(error, done: done, failed: command);
          unawaited(_loadBoard());
          return;
        }
      }
      if (!mounted) return;
      idle();
      await _showResult(done);
      if (!mounted) return;
      _clearForm();
      unawaited(_loadBoard());
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _talkingToSap = false;
        });
      }
    }
  }

  Future<PositionCommandResult> _execute(PositionCommand command) {
    final slot = command.slot;
    return switch (command.kind) {
      PositionCommandKind.createPosition => _api.createPosition(
        workCenter: slot.workCenter,
        positionId: slot.positionId,
        machineId: slot.machineId,
      ),
      PositionCommandKind.changeMachine => _api.changeMachine(
        workCenter: slot.workCenter,
        positionId: slot.positionId,
        machineId: slot.machineId,
      ),
      PositionCommandKind.detachMachine => _api.detachMachine(
        workCenter: slot.workCenter,
        positionId: slot.positionId,
      ),
      PositionCommandKind.transferWorker => _api.transferWorker(
        workCenter: slot.workCenter,
        positionId: slot.positionId,
        workerId: command.worker!.code,
      ),
    };
  }

  Future<T?> _modal<T>(Future<T?> Function() open) async {
    setState(() => _isDialogOpen = true);
    try {
      return await open();
    } finally {
      if (mounted) setState(() => _isDialogOpen = false);
    }
  }

  Future<bool> _confirmWarning(
    PositionWarning warning, {
    required int step,
    required int total,
    List<PositionCommand>? commands,
  }) async {
    final result = await _modal(
      () => showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _WarningDialog(
          warning: warning,
          step: step,
          total: total,
          commands: commands,
        ),
      ),
    );
    return result ?? false;
  }

  Future<void> _showFailure(
    Object error, {
    required List<PositionCommand> done,
    required PositionCommand failed,
  }) => _modal(
    () => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        iconPadding: CaslaDialog.iconPadding,
        titlePadding: CaslaDialog.titlePadding,
        contentPadding: CaslaDialog.contentPadding,
        icon: const Icon(
          Icons.error_outline_rounded,
          color: CaslaColors.danger,
          size: 26,
        ),
        title: CaslaDialogHeader(
          child: const Text(
            'SAP chưa cập nhật xong',
            textAlign: TextAlign.center,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              describePositionError(error),
              style: const TextStyle(fontSize: CaslaType.body, height: 1.4),
            ),
            const SizedBox(height: CaslaSpacing.sm),
            for (final command in done)
              _CommandLine(command: command, state: _CommandState.done),
            _CommandLine(command: failed, state: _CommandState.failed),
            if (done.isNotEmpty) ...[
              const SizedBox(height: CaslaSpacing.sm),
              const Text(
                'Bước đã xong vẫn được giữ. Bấm Cập nhật lần nữa để làm tiếp.',
                style: TextStyle(
                  fontSize: CaslaType.caption,
                  color: CaslaColors.muted,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            style: CaslaDialog.actionStyle,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Đóng'),
          ),
        ],
      ),
    ),
  );

  Future<void> _showResult(List<PositionCommand> done) => _modal(
    () => showModalBottomSheet<void>(
      context: context,
      backgroundColor: CaslaColors.surface,
      showDragHandle: true,
      builder: (context) => _ResultSheet(done: done),
    ),
  );

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ─── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // The shell keeps this tab mounted offstage; never leave a camera running
    // behind another tab. The main tree stays mounted under the camera so the
    // catalog view keeps its state while the camera looks for a machine.
    final visible = TickerMode.valuesOf(context).enabled;
    final camera = _camera;
    final cameraOpen = camera != null && visible;

    final main = BarcodeScanListener(
      enabled: !_isSubmitting && !_isDialogOpen && !cameraOpen,
      scanner: widget.scanner,
      preferences: widget.scannerPreferences,
      onScan: _onTrigger,
      child: Scaffold(
        backgroundColor: CaslaColors.background,
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Vị trí & công nhân',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w800,
                  fontSize: CaslaType.title,
                ),
              ),
              Text(
                _contextLabel(),
                style: const TextStyle(
                  fontSize: CaslaType.caption,
                  fontWeight: FontWeight.w500,
                  color: CaslaColors.identityMeta,
                ),
              ),
            ],
          ),
          actions: [widget.accountAction ?? const AccountAvatarButton()],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: _ViewSwitch(
              view: _view,
              onChanged: (view) {
                setState(() => _view = view);
                if (view == _View.board && !_boardLoading) {
                  unawaited(_loadBoard());
                }
              },
            ),
          ),
        ),
        body: switch (_view) {
          _View.scan => _buildScanView(),
          _View.board => _buildBoardView(),
          _View.machines => MachineCatalogView(
            key: _catalogKey,
            api: widget.api,
            workCenter: widget.workCenter,
            onScan: () => setState(() => _camera = _Camera.findMachine),
          ),
        },
        bottomNavigationBar: _view == _View.scan ? _buildSubmitBar() : null,
      ),
    );

    if (!cameraOpen) return main;
    return Stack(
      children: [
        Offstage(
          offstage: true,
          child: TickerMode(enabled: false, child: main),
        ),
        // The camera is a state of this tab, not a route: without this the
        // system Back button leaves the app instead of closing the camera.
        PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => _camera = null);
          },
          child: _buildCamera(camera),
        ),
      ],
    );
  }

  /// Icon only: the list behind it is what matters, the tooltip says what
  /// the camera is for.
  String _contextLabel() {
    if (widget.workCenter != null) return 'Xưởng ${widget.workCenter}';
    final context = ref.watch(appStateProvider).activeWorkContext;
    final label = context?.workCenterLabel.trim() ?? '';
    return label.isEmpty ? 'Các xưởng được phân quyền' : 'Xưởng $label';
  }

  Widget _buildCamera(_Camera camera) {
    final (title, subtitle, manualLabel) = switch (camera) {
      _Camera.position => (
        'Quét QR vị trí',
        'Đưa nhãn vị trí vào khung quét.',
        'Nhập mã vị trí',
      ),
      _Camera.machine => (
        'Quét QR máy',
        'Đưa nhãn máy vào khung quét.',
        'Nhập mã máy',
      ),
      _Camera.worker => (
        'Quét QR công nhân',
        'Đưa thẻ công nhân vào khung quét.',
        'Nhập mã công nhân',
      ),
      _Camera.findSeat => (
        'Quét để tìm vị trí',
        'QR vị trí, QR máy hoặc thẻ công nhân đều được.',
        'Nhập mã',
      ),
      _Camera.findMachine => (
        'Quét QR máy',
        'Đưa nhãn máy vào khung quét.',
        'Nhập mã máy',
      ),
    };
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          AdaptiveBarcodeScannerView(
            title: title,
            subtitle: subtitle,
            onScan: _handleCameraScan,
            onManualInput: () => switch (camera) {
              _Camera.position => _promptManualInput(_Field.position),
              _Camera.machine => _promptManualInput(_Field.machine),
              _Camera.worker => _promptManualInput(_Field.worker),
              _Camera.findSeat => _promptManualFind(_View.board),
              _Camera.findMachine => _promptManualFind(_View.machines),
            },
            manualInputLabel: manualLabel,
            hardwareScanner: widget.scanner,
            preferences: widget.scannerPreferences,
          ),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            left: 10,
            child: Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(24),
              child: IconButton(
                tooltip: 'Quay lại',
                onPressed: () => setState(() => _camera = null),
                icon: const Icon(Icons.arrow_back, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Quét gán ────────────────────────────────────────────────────

  Widget _buildScanView() {
    final plan = _previewPlan;
    final position = _positionId;
    final seat = position == null ? null : _seatAtPosition(position);
    final machine = _machineId;
    final newPosition = position != null && _board != null && seat == null;
    final sapMachine = seat?.machineId.trim() ?? '';
    // Pending removal of the machine SAP has at this position.
    final detaching =
        _detachMachine && machine == null && sapMachine.isNotEmpty;
    return Column(
      children: [
        const ScanStatusStrip(),
        if (_error != null)
          ScanErrorBanner(
            message: _error!,
            onDismiss: () => setState(() => _error = null),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(CaslaSpacing.md),
            children: [
              ScanSlotField(
                isScanTarget: _target == _Field.position,
                onSelect: () => setState(() => _target = _Field.position),
                label: '1 · Mã vị trí',
                required: true,
                icon: Icons.place_outlined,
                value: position,
                detail: null,
                filledContent: position == null
                    ? null
                    : _positionInfo(position, seat),
                placeholder: 'Quét QR vị trí',
                onOpenScanner: () => setState(() => _camera = _Camera.position),
                onClear: position == null ? null : _clearForm,
              ),
              ScanSlotField(
                isScanTarget: _target == _Field.machine,
                onSelect: () => setState(() => _target = _Field.machine),
                label: '2 · Mã máy',
                required: newPosition,
                icon: Icons.precision_manufacturing_outlined,
                value: machine,
                detail: null,
                filledContent: machine == null
                    ? null
                    : _machineInfo(machine, seat),
                placeholder: position == null
                    ? 'Quét QR máy'
                    : detaching
                    ? 'Sẽ gỡ máy $sapMachine khỏi vị trí · quét QR máy khác '
                          'nếu muốn đổi máy'
                    : newPosition
                    ? 'Vị trí mới: quét QR máy để tạo'
                    : seat != null && seat.machineId.trim().isEmpty
                    ? 'Vị trí chưa gắn máy · quét QR máy nếu muốn gắn'
                    : 'Quét QR máy',
                onOpenScanner: () => setState(() => _camera = _Camera.machine),
                // Scanned machine: x drops the scan. Machine filled in from
                // SAP: x takes it off the position on the next update.
                onClear: machine == null
                    ? null
                    : _machineFromSap
                    ? _markMachineDetached
                    : _resetMachine,
                clearTooltip: machine != null && _machineFromSap
                    ? 'Gỡ máy khỏi vị trí'
                    : 'Xóa lựa chọn',
                trailing: detaching
                    ? TextButton(
                        onPressed: _resetMachine,
                        child: const Text('Giữ máy'),
                      )
                    : null,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _isSubmitting ? null : _pickMachine,
                  icon: const Icon(Icons.list_alt_rounded, size: 18),
                  label: Text(
                    machine == null
                        ? 'Chọn máy từ danh mục'
                        : 'Chọn máy khác từ danh mục',
                  ),
                ),
              ),
              const SizedBox(height: CaslaSpacing.xs),
              _AssignWorkerCard(
                checked: _assignWorker,
                onChanged: _setAssignWorker,
                child: !_assignWorker
                    ? null
                    : ScanSlotField(
                        isScanTarget: _target == _Field.worker,
                        onSelect: () => setState(() => _target = _Field.worker),
                        label: 'Công nhân',
                        required: false,
                        icon: Icons.badge_outlined,
                        value: _worker?.label,
                        detail: null,
                        filledContent: _worker == null
                            ? null
                            : _workerInfo(_worker!),
                        placeholder: 'Quét thẻ công nhân',
                        onOpenScanner: () =>
                            setState(() => _camera = _Camera.worker),
                        onClear: _worker == null
                            ? null
                            : () => setState(() {
                                _worker = null;
                                _target = _Field.worker;
                              }),
                      ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _promptManualInput(_target),
                  icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                  label: const Text('Không quét được? Nhập mã thủ công'),
                ),
              ),
              if (_boardError != null && _board == null)
                _Notice(
                  tone: _Tone.danger,
                  icon: Icons.cloud_off_rounded,
                  text: 'Chưa tải được sơ đồ vị trí: $_boardError',
                  action: TextButton(
                    onPressed: _boardLoading ? null : _loadBoard,
                    child: const Text('Thử lại'),
                  ),
                )
              else if (plan != null)
                _PlanPreview(plan: plan),
            ],
          ),
        ),
      ],
    );
  }

  Widget _positionInfo(String position, PositionSeat? seat) {
    final rows = <Widget>[_InfoLine('Xưởng', _resolvedWorkCenter ?? '')];
    final board = _board;
    if (board == null) {
      rows.add(
        _InfoLine(
          'Tình trạng',
          _boardLoading ? 'Đang tải sơ đồ vị trí…' : 'Chưa tải được sơ đồ',
          quiet: true,
        ),
      );
      return _InfoColumn(rows);
    }
    if (seat == null) {
      rows.add(
        _boardLoading
            ? const _InfoLine(
                'Tình trạng',
                'Đang kiểm tra trên SAP…',
                quiet: true,
              )
            : const _InfoLine(
                'Tình trạng',
                'Vị trí mới, SAP chưa có',
                tone: _Tone.pending,
              ),
      );
    } else {
      if (seat.positionName.isNotEmpty) {
        rows.add(_InfoLine('Tên vị trí', seat.positionName));
      }
      rows.add(
        seat.machineId.trim().isEmpty
            ? const _InfoLine('Máy hiện tại', 'Chưa gắn máy', quiet: true)
            : _InfoLine('Máy hiện tại', seat.machineId),
      );
      rows.add(
        seat.isOccupied
            ? _InfoLine('Công nhân', '${seat.workerLabel} · ${seat.workerId}')
            : const _InfoLine('Công nhân', 'Chưa có', quiet: true),
      );
    }
    return _InfoColumn(rows);
  }

  Widget _machineInfo(String machine, PositionSeat? seat) {
    final rows = <Widget>[];
    final name = _machines?.byId(machine)?.machineName.trim() ?? '';
    if (name.isNotEmpty) rows.add(_InfoLine('Tên máy', name));
    if (_machineFromSap) {
      rows.add(
        const _InfoLine(
          'Nguồn',
          'Điền sẵn từ SAP · quét QR máy khác để đổi máy, bấm ✕ để gỡ máy',
          quiet: true,
        ),
      );
    } else if (seat != null && seat.machineId.trim().isNotEmpty) {
      rows.add(
        _InfoLine(
          'Thay máy',
          '${seat.machineId} → $machine',
          tone: _Tone.pending,
        ),
      );
    } else {
      rows.add(const _InfoLine('Nguồn', 'Mới quét', quiet: true));
    }
    // SAP moves a machine attached at another position of this Work Center;
    // the plan asks for confirmation on Cập nhật (PositionCase.moveMachine).
    final source = _machineFromSap ? null : _seatOfMachine(machine);
    if (source != null && !_same(source.positionId, _positionId ?? '')) {
      rows.add(
        _InfoLine(
          'Chuyển máy',
          'Đang gắn ở vị trí ${source.positionId}. Cập nhật sẽ chuyển máy, '
              'vị trí ${source.positionId} trống mã máy.',
          tone: _Tone.pending,
        ),
      );
    }
    return _InfoColumn(rows);
  }

  Widget _workerInfo(PositionWorker worker) {
    final seat = _seatOfWorker(worker.code);
    return _InfoColumn([
      _InfoLine('Mã NV', worker.code),
      seat == null
          ? const _InfoLine(
              'Vị trí hiện tại',
              'Chưa ngồi vị trí nào',
              quiet: true,
            )
          : _InfoLine(
              'Vị trí hiện tại',
              seat.machineId.trim().isEmpty
                  ? seat.positionId
                  : '${seat.positionId} · ${seat.machineId}',
            ),
    ]);
  }

  Widget _buildSubmitBar() {
    final plan = _previewPlan;
    final noop = plan?.isNoop ?? false;
    final canSubmit =
        _positionId != null &&
        !_needsWorker &&
        !_needsMachine &&
        !_checkingPosition &&
        !_isSubmitting &&
        !noop;
    final hint = _talkingToSap
        ? 'Đang làm việc với SAP, giữ máy trong tay'
        : _isSubmitting
        ? 'Đang chờ xác nhận'
        : _positionId == null
        ? 'Quét QR vị trí để bắt đầu'
        : _checkingPosition
        ? 'Đang kiểm tra vị trí $_positionId trên SAP…'
        : _needsMachine
        ? 'Vị trí mới $_positionId: quét QR máy để tiếp tục'
        : _needsWorker
        ? 'Quét thẻ công nhân, hoặc bỏ tick gán công nhân'
        : noop
        ? 'Không có thay đổi để gửi'
        : _assignWorker
        ? 'Gửi SAP: vị trí / máy kèm công nhân'
        : 'Gửi SAP: chỉ vị trí / máy';
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          CaslaSpacing.md,
          CaslaSpacing.sm,
          CaslaSpacing.md,
          CaslaSpacing.xs,
        ),
        decoration: const BoxDecoration(
          color: CaslaColors.surface,
          border: Border(top: BorderSide(color: CaslaColors.line)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton.icon(
              onPressed: canSubmit ? _submit : null,
              icon: _talkingToSap
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: CaslaColors.navy900,
                      ),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
              label: Text(_talkingToSap ? 'Đang gửi SAP…' : 'Cập nhật'),
            ),
            const SizedBox(height: CaslaSpacing.xxs),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: CaslaType.caption,
                color: CaslaColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Bảng vị trí ─────────────────────────────────────────────────

  /// A scan on the board finds a seat: by position, by the machine attached
  /// to it, or by the worker seated there. Found: filter to it and open it.
  bool _handleBoardScan(String raw) {
    if (_board == null) {
      setState(
        () => _boardScanError =
            'Chưa tải được sơ đồ vị trí. Tải lại rồi quét tiếp.',
      );
      return false;
    }
    PositionSeat? seat;
    String? what;
    final label = parsePositionLabel(raw);
    if (label != null) {
      seat = label.positionId.isNotEmpty
          ? _seatAtPosition(label.positionId)
          : _seatOfMachine(label.machineId);
      what = label.positionId.isNotEmpty
          ? 'Vị trí ${label.positionId}'
          : 'Máy ${label.machineId}';
    } else {
      final code = parsePositionCode(raw);
      if (code != null) {
        seat = _seatAtPosition(code) ?? _seatOfMachine(code);
        what = 'Mã $code';
      }
      // A bare `A1` is a label shape before it is an employee code; only a
      // digits-only code or a QR naming MaNV is a worker card here.
      final digits = RegExp(r'^\d+$').hasMatch(raw.trim());
      if (seat == null && (code == null || digits)) {
        final card = WorkerQrParser.parse(raw);
        if (card.isValid) {
          final worker = card.maNv.trim().toUpperCase();
          seat = _seatOfWorker(worker);
          what = 'Công nhân $worker';
        }
      }
    }
    if (seat == null) {
      setState(
        () => _boardScanError = what == null
            ? 'Không đọc được "${_short(raw)}".'
            : '$what không phải vị trí đang dùng, máy đang gắn hay công nhân '
                  'đang ngồi trong xưởng này. Sang Quét gán nếu muốn tạo.',
      );
      return false;
    }
    final found = seat;
    _boardSearch.text = found.positionId;
    setState(() {
      _boardScanError = null;
      _boardQuery = found.positionId;
      _filter = _BoardFilter.all;
      _boardHighlight = found.positionId;
    });
    unawaited(_showSeatDetail(found));
    return true;
  }

  Widget _buildBoardView() {
    final board = _board;
    final seats = board?.seats ?? const <PositionSeat>[];
    final occupied = seats.where((seat) => seat.isOccupied).length;
    final query = _boardQuery.trim().toUpperCase();
    final visible = seats.where((seat) {
      final byFilter = switch (_filter) {
        _BoardFilter.all => true,
        _BoardFilter.occupied => seat.isOccupied,
        _BoardFilter.empty => !seat.isOccupied,
      };
      if (!byFilter) return false;
      if (query.isEmpty) return true;
      return seat.positionId.toUpperCase().contains(query) ||
          seat.machineId.toUpperCase().contains(query) ||
          seat.workerId.toUpperCase().contains(query) ||
          seat.workerName.toUpperCase().contains(query);
    }).toList();
    final showWorkCenter =
        {for (final seat in seats) seat.workCenter}.length > 1;

    return Column(
      children: [
        if (_boardScanError != null)
          ScanErrorBanner(
            message: _boardScanError!,
            onDismiss: () => setState(() => _boardScanError = null),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadBoard,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                PinnedHeaderSliver(
                  child: FilterHeader(
                    children: [
                      TextField(
                        controller: _boardSearch,
                        textCapitalization: TextCapitalization.characters,
                        textInputAction: TextInputAction.search,
                        onChanged: (value) => setState(() {
                          _boardQuery = value;
                          _boardHighlight = null;
                        }),
                        decoration: InputDecoration(
                          hintText: 'Tìm vị trí, mã máy, công nhân',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _boardQuery.isEmpty
                              ? IconButton(
                                  tooltip: 'Quét QR tìm vị trí',
                                  onPressed: () => setState(
                                    () => _camera = _Camera.findSeat,
                                  ),
                                  icon: const Icon(Icons.qr_code_scanner),
                                )
                              : IconButton(
                                  tooltip: 'Xóa nội dung tìm kiếm',
                                  onPressed: () {
                                    _boardSearch.clear();
                                    setState(() {
                                      _boardQuery = '';
                                      _boardHighlight = null;
                                    });
                                  },
                                  icon: const Icon(Icons.close),
                                ),
                        ),
                      ),
                      const SizedBox(height: CaslaSpacing.xs),
                      CompactFilterRow(
                        children: [
                          _filterChip(
                            _BoardFilter.all,
                            'Tất cả · ${seats.length}',
                          ),
                          _filterChip(
                            _BoardFilter.occupied,
                            'Có công nhân · $occupied',
                          ),
                          _filterChip(
                            _BoardFilter.empty,
                            'Trống · ${seats.length - occupied}',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    CaslaSpacing.md,
                    CaslaSpacing.sm,
                    CaslaSpacing.md,
                    96,
                  ),
                  sliver: SliverList.list(
                    children: [
                      if (board == null && _boardLoading)
                        const Padding(
                          padding: EdgeInsets.all(CaslaSpacing.xl),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (board == null && _boardError != null)
                        _Notice(
                          tone: _Tone.danger,
                          icon: Icons.cloud_off_rounded,
                          text: _boardError!,
                          action: TextButton(
                            onPressed: _loadBoard,
                            child: const Text('Thử lại'),
                          ),
                        )
                      else if (visible.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(CaslaSpacing.xl),
                          child: Text(
                            seats.isEmpty
                                ? 'Chưa có vị trí nào đang dùng. Sang Quét gán, quét '
                                      'QR vị trí để tạo vị trí đầu tiên.'
                                : query.isEmpty
                                ? 'Không có vị trí nào khớp bộ lọc.'
                                : 'Không có vị trí nào khớp "${_boardQuery.trim()}".',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: CaslaColors.muted),
                          ),
                        )
                      else
                        for (final seat in visible)
                          _SeatRow(
                            seat: seat,
                            showWorkCenter: showWorkCenter,
                            highlighted: _same(
                              seat.positionId,
                              _boardHighlight ?? '',
                            ),
                            onTap: () => _showSeatDetail(seat),
                          ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _filterChip(_BoardFilter filter, String label) => CompactFilterChip(
    label: label,
    selected: _filter == filter,
    onSelected: () => setState(() => _filter = filter),
  );

  Future<void> _showSeatDetail(PositionSeat seat) {
    return _modal(
      () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: CaslaColors.surface,
        showDragHandle: true,
        builder: (context) => _SeatDetailSheet(seat: seat),
      ),
    );
  }
}

String _short(String raw) {
  final text = raw.trim();
  return text.length <= 40 ? text : '${text.substring(0, 40)}…';
}

bool _same(String a, String b) =>
    a.trim().toUpperCase() == b.trim().toUpperCase();

// ─── Widgets ─────────────────────────────────────────────────────────

/// Picks one machine of SAP's catalog. Loads on open so the list reflects
/// what was attached a moment ago; a machine already in use is still
/// selectable, marked so the supervisor knows SAP will want it freed first.
class _MachinePickerSheet extends StatefulWidget {
  final Future<MachineCatalog> Function({bool refresh}) load;
  final PositionSlot? slot;
  final String workCenter;

  const _MachinePickerSheet({
    required this.load,
    required this.slot,
    required this.workCenter,
  });

  @override
  State<_MachinePickerSheet> createState() => _MachinePickerSheetState();
}

class _MachinePickerSheetState extends State<_MachinePickerSheet> {
  final _search = TextEditingController();
  MachineCatalog? _catalog;
  String? _error;
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final catalog = await widget.load(refresh: refresh);
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describePositionError(error);
      });
    }
  }

  List<MachineOption> get _visible {
    final all = _catalog?.machines ?? const <MachineOption>[];
    final query = _query.trim().toUpperCase();
    if (query.isEmpty) return all;
    return all
        .where(
          (m) =>
              m.machineId.contains(query) ||
              m.machineName.toUpperCase().contains(query) ||
              m.positionId.contains(query),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final slot = widget.slot;
    final visible = _visible;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          CaslaSpacing.md,
          0,
          CaslaSpacing.md,
          CaslaSpacing.md + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      slot == null
                          ? 'Chọn máy từ danh mục'
                          : 'Chọn máy cho vị trí ${slot.positionId}',
                      style: const TextStyle(
                        fontFamily: 'Manrope',
                        fontWeight: FontWeight.w800,
                        fontSize: CaslaType.subtitle,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Tải lại danh mục',
                    onPressed: _loading ? null : () => _load(refresh: true),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const Text(
                'Chỉ máy đang dùng trong danh mục SAP. Chọn máy đang gắn ở vị '
                'trí khác thì máy được chuyển sang, vị trí cũ trống mã máy.',
                style: TextStyle(
                  fontSize: CaslaType.caption,
                  color: CaslaColors.muted,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: CaslaSpacing.sm),
              TextField(
                controller: _search,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: 'Tìm mã máy, tên máy hoặc vị trí',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Xóa nội dung tìm kiếm',
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
              const SizedBox(height: CaslaSpacing.xs),
              Expanded(child: _body(visible, slot)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(List<MachineOption> visible, PositionSlot? slot) {
    if (_loading && _catalog == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null && _catalog == null) {
      return Center(
        child: _Notice(
          tone: _Tone.danger,
          icon: Icons.cloud_off_rounded,
          text: 'Chưa tải được danh mục máy: $error',
          action: TextButton(onPressed: _load, child: const Text('Thử lại')),
        ),
      );
    }
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(CaslaSpacing.lg),
          child: Text(
            _query.trim().isEmpty
                ? 'Danh mục chưa có máy nào đang dùng. Báo quản trị thêm máy '
                      'trên Fiori trước.'
                : 'Không có máy nào khớp.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: CaslaColors.muted, height: 1.4),
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final machine = visible[index];
        final here =
            slot != null &&
            _same(machine.workCenter, slot.workCenter) &&
            _same(machine.positionId, slot.positionId);
        final elsewhere = machine.isInUse && !here;
        final where = _same(machine.workCenter, widget.workCenter)
            ? machine.positionId
            : '${machine.positionId} · xưởng ${machine.workCenter}';
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            machine.machineName.trim().isEmpty
                ? machine.machineId
                : '${machine.machineId} · ${machine.machineName.trim()}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: CaslaType.body,
              fontWeight: FontWeight.w700,
              color: CaslaColors.primaryNavy,
            ),
          ),
          subtitle: Text(
            here
                ? 'Máy hiện tại của vị trí này'
                : elsewhere
                ? 'Đang gắn ở vị trí $where'
                : 'Chưa gắn vị trí nào',
            style: TextStyle(
              fontSize: CaslaType.caption,
              color: elsewhere ? CaslaColors.pending : CaslaColors.muted,
            ),
          ),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: elsewhere ? CaslaColors.pendingBg : CaslaColors.successBg,
              borderRadius: BorderRadius.circular(CaslaRadius.pill),
            ),
            child: Text(
              elsewhere ? 'Đang dùng' : 'Rảnh',
              style: TextStyle(
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w700,
                color: elsewhere ? CaslaColors.pending : CaslaColors.success,
              ),
            ),
          ),
          onTap: () => Navigator.of(context).pop(machine),
        );
      },
    );
  }
}

class _ViewSwitch extends StatelessWidget {
  final _View view;
  final ValueChanged<_View> onChanged;

  const _ViewSwitch({required this.view, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget tab(_View value, IconData icon, String label) {
      final selected = view == value;
      return Expanded(
        child: Semantics(
          selected: selected,
          button: true,
          child: Material(
            color: selected ? CaslaColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(CaslaRadius.sm),
            child: InkWell(
              borderRadius: BorderRadius.circular(CaslaRadius.sm),
              onTap: () => onChanged(value),
              child: SizedBox(
                height: 40,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icon,
                        size: 16,
                        color: selected
                            ? CaslaColors.primaryNavy
                            : CaslaColors.identityMeta,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: selected
                              ? CaslaColors.primaryNavy
                              : CaslaColors.identityMeta,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CaslaSpacing.md,
        0,
        CaslaSpacing.md,
        CaslaSpacing.sm,
      ),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            tab(_View.scan, Icons.qr_code_scanner_rounded, 'Quét gán'),
            tab(_View.board, Icons.table_chart_outlined, 'Bảng vị trí'),
            tab(
              _View.machines,
              Icons.precision_manufacturing_outlined,
              'Danh mục máy',
            ),
          ],
        ),
      ),
    );
  }
}

class _AssignWorkerCard extends StatelessWidget {
  final bool checked;
  final ValueChanged<bool> onChanged;
  final Widget? child;

  const _AssignWorkerCard({
    required this.checked,
    required this.onChanged,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CaslaColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CaslaRadius.md),
        side: BorderSide(
          color: checked ? CaslaColors.primaryNavy : CaslaColors.line,
          width: checked ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => onChanged(!checked),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, CaslaSpacing.sm, 4),
              child: Row(
                children: [
                  Checkbox(
                    value: checked,
                    onChanged: (value) => onChanged(value ?? false),
                    activeColor: CaslaColors.primaryNavy,
                  ),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Gán công nhân vào vị trí này',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: CaslaColors.primaryNavy,
                          ),
                        ),
                        Text(
                          'Bỏ trống nếu chỉ thêm vị trí / máy, gán công nhân '
                          'sau.',
                          style: TextStyle(
                            fontSize: CaslaType.caption,
                            color: CaslaColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: CaslaColors.muted100,
                      borderRadius: BorderRadius.circular(CaslaRadius.pill),
                    ),
                    child: const Text(
                      'Tùy chọn',
                      style: TextStyle(
                        fontSize: CaslaType.caption,
                        fontWeight: FontWeight.w700,
                        color: CaslaColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (child != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CaslaSpacing.sm,
                0,
                CaslaSpacing.sm,
                CaslaSpacing.sm,
              ),
              child: child,
            ),
        ],
      ),
    );
  }
}

enum _Tone { pending, danger }

class _InfoColumn extends StatelessWidget {
  final List<Widget> rows;

  const _InfoColumn(this.rows);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: CaslaSpacing.xs),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
  );
}

class _InfoLine extends StatelessWidget {
  final String label;
  final String value;
  final _Tone? tone;
  final bool quiet;

  const _InfoLine(this.label, this.value, {this.tone, this.quiet = false});

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      _Tone.pending => CaslaColors.pending,
      _Tone.danger => CaslaColors.danger,
      null => quiet ? CaslaColors.muted : CaslaColors.primaryNavy,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: const TextStyle(
                color: CaslaColors.muted,
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: CaslaType.body,
                fontWeight: quiet ? FontWeight.w600 : FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final _Tone? tone;
  final IconData icon;
  final String text;
  final Widget? action;

  const _Notice({
    required this.tone,
    required this.icon,
    required this.text,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = switch (tone) {
      _Tone.pending => (CaslaColors.pending, CaslaColors.pendingBg),
      _Tone.danger => (CaslaColors.danger, CaslaColors.dangerBg),
      null => (CaslaColors.success, CaslaColors.successBg),
    };
    return Container(
      padding: const EdgeInsets.all(CaslaSpacing.sm),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(CaslaRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: CaslaSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                ?action,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanPreview extends StatelessWidget {
  final PositionUpdatePlan plan;

  const _PlanPreview({required this.plan});

  @override
  Widget build(BuildContext context) {
    if (plan.isNoop) {
      return const _Notice(
        tone: null,
        icon: Icons.check_circle_outline_rounded,
        text: 'Đã đúng như vừa quét. Không cần cập nhật.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(CaslaSpacing.xxs, CaslaSpacing.sm, 0, 4),
          child: Text(
            'SAP SẼ THỰC HIỆN',
            style: TextStyle(
              fontSize: CaslaType.caption,
              fontWeight: FontWeight.w700,
              letterSpacing: .4,
              color: CaslaColors.muted,
            ),
          ),
        ),
        for (final command in plan.commands)
          _CommandLine(command: command, state: _CommandState.pending),
        const SizedBox(height: CaslaSpacing.xs),
        plan.warnings.isEmpty
            ? const _Notice(
                tone: null,
                icon: Icons.check_circle_outline_rounded,
                text: 'Không có cảnh báo. Bấm Cập nhật để ghi vào SAP.',
              )
            : _Notice(
                tone: _Tone.pending,
                icon: Icons.warning_amber_rounded,
                text:
                    '${plan.warnings.length} thay đổi cần xác nhận trước khi '
                    'gửi SAP.',
              ),
      ],
    );
  }
}

enum _CommandState { pending, done, failed }

class _CommandLine extends StatelessWidget {
  final PositionCommand command;
  final _CommandState state;

  const _CommandLine({required this.command, required this.state});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      _CommandState.pending => (
        Icons.arrow_circle_right_outlined,
        CaslaColors.primaryNavy,
      ),
      _CommandState.done => (Icons.check_circle_rounded, CaslaColors.success),
      _CommandState.failed => (Icons.cancel_rounded, CaslaColors.danger),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              command.description,
              style: const TextStyle(
                fontSize: 13.5,
                color: CaslaColors.navy900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Current value above new value, one row each, so a machine or position
/// change reads as a before/after rather than a sentence.
class _DetailTable extends StatelessWidget {
  final List<PositionDetail> details;

  const _DetailTable({required this.details});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: CaslaSpacing.sm,
        vertical: CaslaSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: CaslaColors.muted100,
        borderRadius: BorderRadius.circular(CaslaRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < details.length; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${details[i].label}: ',
                    style: const TextStyle(
                      fontSize: CaslaType.caption,
                      fontWeight: FontWeight.w600,
                      color: CaslaColors.muted,
                    ),
                  ),
                  TextSpan(
                    text: details[i].value,
                    style: TextStyle(
                      fontSize: CaslaType.body,
                      fontWeight: FontWeight.w800,
                      // The last row is what the scan brings in.
                      color: i == details.length - 1
                          ? CaslaColors.primaryNavy
                          : CaslaColors.navy900,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _WarningDialog extends StatelessWidget {
  final PositionWarning warning;
  final int step;
  final int total;

  /// Shown on the last warning: everything SAP will do on Có.
  final List<PositionCommand>? commands;

  const _WarningDialog({
    required this.warning,
    required this.step,
    required this.total,
    required this.commands,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      iconPadding: CaslaDialog.iconPadding,
      titlePadding: CaslaDialog.titlePadding,
      contentPadding: CaslaDialog.contentPadding,
      icon: const Icon(
        Icons.warning_amber_rounded,
        color: CaslaColors.accentGold,
        size: 26,
      ),
      title: CaslaDialogHeader(
        child: Column(
          children: [
            if (total > 1) ...[
              Text(
                'Cảnh báo $step/$total',
                style: const TextStyle(
                  fontSize: CaslaType.caption,
                  fontWeight: FontWeight.w700,
                  color: CaslaColors.gold700,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 4),
            ],
            Text(
              warning.kind.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontSize: CaslaDialog.titleSize,
                fontWeight: FontWeight.w800,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ],
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              warning.message,
              style: const TextStyle(
                fontSize: CaslaType.body,
                height: 1.4,
                color: CaslaColors.navy900,
              ),
            ),
            if (warning.details.isNotEmpty) ...[
              const SizedBox(height: CaslaSpacing.sm),
              _DetailTable(details: warning.details),
            ],
            if (commands != null && commands!.isNotEmpty) ...[
              const SizedBox(height: CaslaSpacing.md),
              const Text(
                'Khi chọn Có, app gửi SAP:',
                style: TextStyle(
                  fontSize: CaslaType.caption,
                  fontWeight: FontWeight.w700,
                  color: CaslaColors.muted,
                ),
              ),
              const SizedBox(height: CaslaSpacing.xxs),
              for (final command in commands!)
                _CommandLine(command: command, state: _CommandState.pending),
            ],
            const SizedBox(height: CaslaSpacing.sm),
            Text(
              total > 1 && step < total
                  ? 'Còn cảnh báo tiếp theo. Chọn Không để hủy toàn bộ.'
                  : 'Chọn Không để hủy toàn bộ lần cập nhật.',
              style: const TextStyle(
                fontSize: CaslaType.caption,
                color: CaslaColors.muted,
              ),
            ),
          ],
        ),
      ),
      actions: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Không'),
              ),
            ),
            const SizedBox(width: CaslaSpacing.sm),
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Có'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ResultSheet extends StatelessWidget {
  final List<PositionCommand> done;

  const _ResultSheet({required this.done});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          CaslaSpacing.lg,
          0,
          CaslaSpacing.lg,
          CaslaSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  color: CaslaColors.success,
                  size: 28,
                ),
                SizedBox(width: CaslaSpacing.xs),
                Expanded(
                  child: Text(
                    'Đã cập nhật vị trí',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: CaslaType.title,
                      fontWeight: FontWeight.w800,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: CaslaSpacing.sm),
            for (final command in done)
              _CommandLine(command: command, state: _CommandState.done),
            const SizedBox(height: CaslaSpacing.md),
            ElevatedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Quét lượt tiếp'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeatRow extends StatelessWidget {
  final PositionSeat seat;
  final bool showWorkCenter;
  final bool highlighted;
  final VoidCallback onTap;

  const _SeatRow({
    required this.seat,
    required this.showWorkCenter,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (showWorkCenter) seat.workCenter,
      if (seat.positionName.isNotEmpty) seat.positionName,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: CaslaSpacing.xs),
      child: Material(
        color: highlighted ? CaslaColors.gold100 : CaslaColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CaslaRadius.md),
          side: BorderSide(
            color: highlighted ? CaslaColors.accentGold : CaslaColors.line,
            width: highlighted ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(CaslaRadius.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              CaslaSpacing.sm,
              CaslaSpacing.sm,
              CaslaSpacing.xs,
              CaslaSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        seat.machineId.trim().isEmpty
                            ? '${seat.positionId} · chưa gắn máy'
                            : '${seat.positionId} · ${seat.machineId}',
                        style: const TextStyle(
                          fontFamily: 'Manrope',
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: CaslaColors.primaryNavy,
                        ),
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          style: const TextStyle(
                            fontSize: CaslaType.caption,
                            color: CaslaColors.muted,
                          ),
                        ),
                      Text(
                        seat.isOccupied
                            ? '${seat.workerId} · ${seat.workerLabel}'
                            : 'Chưa có công nhân',
                        style: TextStyle(
                          fontSize: 13,
                          color: CaslaColors.muted,
                          fontStyle: seat.isOccupied
                              ? FontStyle.normal
                              : FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),
                _OccupancyChip(occupied: seat.isOccupied),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: CaslaColors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OccupancyChip extends StatelessWidget {
  final bool occupied;

  const _OccupancyChip({required this.occupied});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: occupied ? CaslaColors.successBg : CaslaColors.muted100,
        borderRadius: BorderRadius.circular(CaslaRadius.pill),
      ),
      child: Text(
        occupied ? 'Có người' : 'Trống',
        style: TextStyle(
          fontSize: CaslaType.caption,
          fontWeight: FontWeight.w700,
          color: occupied ? CaslaColors.success : CaslaColors.muted,
        ),
      ),
    );
  }
}

class _SeatDetailSheet extends StatelessWidget {
  final PositionSeat seat;

  const _SeatDetailSheet({required this.seat});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          CaslaSpacing.lg,
          0,
          CaslaSpacing.lg,
          CaslaSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Chi tiết vị trí',
              style: TextStyle(
                fontSize: CaslaType.caption,
                color: CaslaColors.muted,
              ),
            ),
            Text(
              seat.machineId.trim().isEmpty
                  ? seat.positionId
                  : '${seat.positionId} · ${seat.machineId}',
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontSize: CaslaType.title,
                fontWeight: FontWeight.w800,
                color: CaslaColors.primaryNavy,
              ),
            ),
            const SizedBox(height: CaslaSpacing.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(CaslaSpacing.sm),
              decoration: BoxDecoration(
                color: CaslaColors.background,
                borderRadius: BorderRadius.circular(CaslaRadius.md),
              ),
              child: Column(
                children: [
                  _InfoLine('Xưởng', seat.workCenter),
                  _InfoLine('Mã vị trí', seat.positionId),
                  seat.positionName.isEmpty
                      ? const _InfoLine(
                          'Tên vị trí',
                          'Chưa đặt tên',
                          quiet: true,
                        )
                      : _InfoLine('Tên vị trí', seat.positionName),
                  seat.machineId.trim().isEmpty
                      ? const _InfoLine('Mã máy', 'Chưa gắn máy', quiet: true)
                      : _InfoLine('Mã máy', seat.machineId),
                  seat.isOccupied
                      ? _InfoLine(
                          'Công nhân',
                          '${seat.workerLabel} · ${seat.workerId}',
                        )
                      : const _InfoLine(
                          'Công nhân',
                          'Chưa có công nhân',
                          quiet: true,
                        ),
                  const _InfoLine('Trạng thái', 'Đang dùng'),
                ],
              ),
            ),
            const SizedBox(height: CaslaSpacing.md),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Đóng'),
            ),
          ],
        ),
      ),
    );
  }
}
