// Screen S14 — Vị trí & công nhân (ZUI_PP_POS)
//
// Quét gán: scan the position/machine label (required), optionally tick
// "Gán công nhân" and scan the worker card, then Cập nhật. The app reloads the
// board, shows what SAP is about to change and sends
// one command per request once the supervisor confirms.
//
// Bảng vị trí: the active positions in the supervisor's Work Centers, read
// only. Nothing on it can be edited; every change goes through Quét gán.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_spacing.dart';
import '../../../core/scanner/barcode_scanner.dart';
import '../../../core/scanner/scanner_preferences.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../core/utils/worker_qr_parser.dart';
import '../../../data/sap/odata_error.dart';
import '../../../data/sap/sap_odata_client.dart';
import '../../../data/sap/sap_session_provider.dart';
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

enum _Field { slot, worker }

enum _View { scan, board }

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
  PositionSlot? _slot;
  PositionWorker? _worker;
  bool _assignWorker = false;
  _Field _target = _Field.slot;
  _Field? _cameraField;
  bool _isSubmitting = false;

  /// True only while a request is in flight, not while a confirmation waits.
  bool _talkingToSap = false;
  bool _isDialogOpen = false;
  String? _error;

  _View _view = _View.scan;
  _BoardFilter _filter = _BoardFilter.all;
  PositionBoard? _board;
  bool _boardLoading = false;
  String? _boardError;
  int _boardRequest = 0;

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

  Future<void> _loadBoard() async {
    final request = ++_boardRequest;
    setState(() {
      _boardLoading = true;
      _boardError = null;
    });
    try {
      // The supervisor's own Work Center, like every position on this screen.
      // SAP still checks a machine or a worker seated in another one.
      final board = await _api.getBoard(workCenter: _workCenter);
      if (!mounted || request != _boardRequest) return;
      setState(() {
        _board = board;
        _boardLoading = false;
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

  /// [target] is set when the supervisor picked the field (camera, manual
  /// input). A trigger pull lands in the selected field, but a label is
  /// recognised by its shape so it never ends up in the worker field.
  Future<bool> _handleScan(String raw, {_Field? target}) async {
    if (_isSubmitting || _isDialogOpen) return false;
    final want = target ?? _target;
    final slot = parsePositionSlotQr(raw);

    if (slot != null && target != _Field.worker) {
      if (_workCenter.isNotEmpty &&
          slot.workCenter.isNotEmpty &&
          slot.workCenter != _workCenter) {
        setState(
          () => _error =
              'Nhãn thuộc xưởng ${slot.workCenter}, còn bạn đang làm việc ở '
              'xưởng $_workCenter.',
        );
        return false;
      }
      final resolved = _resolveWorkCenter(slot);
      if (resolved == null) {
        setState(
          () => _error =
              'Chưa xác định được xưởng của vị trí ${slot.positionId}. '
              'Hãy chọn xưởng trong ca làm việc trước.',
        );
        return false;
      }
      setState(() {
        _slot = resolved;
        _error = null;
        _target = _assignWorker && _worker == null
            ? _Field.worker
            : _Field.slot;
      });
      return true;
    }

    if (slot == null && target != _Field.slot) {
      final parsed = WorkerQrParser.parse(raw);
      if (parsed.isValid) {
        final code = parsed.maNv.trim().toUpperCase();
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
          name: parsed.name.trim().isNotEmpty
              ? parsed.name.trim()
              : _seatOfWorker(code)?.workerName ?? '',
        );
        setState(() {
          _worker = worker;
          // A worker card on the reader means the supervisor wants to seat one.
          _assignWorker = true;
          _error = null;
          _target = _slot == null ? _Field.slot : _Field.worker;
        });
        if (worker.name.isEmpty) unawaited(_lookupWorkerName(code));
        return true;
      }
    }

    setState(
      () => _error = want == _Field.slot
          ? 'Mã "${_short(raw)}" không phải nhãn vị trí. Nhãn đúng có dạng '
                'G05@M105.'
          : 'Không đọc được mã công nhân từ "${_short(raw)}". Quét lại thẻ '
                'hoặc nhập mã.',
    );
    return false;
  }

  /// A position belongs to the Work Center the supervisor is working in; the
  /// label only decides when no Work Center is selected.
  PositionSlot? _resolveWorkCenter(PositionSlot slot) {
    if (_workCenter.isNotEmpty) return slot.withWorkCenter(_workCenter);
    if (slot.workCenter.isNotEmpty) return slot;
    final centers = {
      for (final seat in _board?.seats ?? const <PositionSeat>[])
        seat.workCenter,
    };
    return centers.length == 1 ? slot.withWorkCenter(centers.first) : null;
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
    final field = _cameraField;
    final accepted = await _handleScan(raw, target: field);
    if (accepted && mounted) setState(() => _cameraField = null);
    return accepted;
  }

  Future<void> _promptManualInput(_Field field) async {
    setState(() => _isDialogOpen = true);
    final value = field == _Field.slot
        ? await showManualSlotDialog(context)
        : await showManualCodeDialog(
            context,
            title: 'Nhập mã công nhân',
            label: 'Mã công nhân',
            helperText: 'Ví dụ: 10000123',
          );
    if (!mounted) return;
    setState(() => _isDialogOpen = false);
    if (value == null || value.trim().isEmpty) return;
    final accepted = await _handleScan(value.trim(), target: field);
    if (accepted && mounted && _cameraField != null) {
      setState(() => _cameraField = null);
    }
  }

  void _setAssignWorker(bool value) {
    setState(() {
      _assignWorker = value;
      if (!value) {
        _worker = null;
        _target = _Field.slot;
      } else if (_slot != null) {
        _target = _Field.worker;
      }
    });
  }

  void _clearForm() {
    setState(() {
      _slot = null;
      _worker = null;
      _assignWorker = false;
      _target = _Field.slot;
      _error = null;
    });
  }

  // ─── Board helpers ───────────────────────────────────────────────

  PositionSeat? _seatAt(PositionSlot slot) => _board?.seats
      .where(
        (seat) =>
            _same(seat.workCenter, slot.workCenter) &&
            _same(seat.positionId, slot.positionId),
      )
      .firstOrNull;

  PositionSeat? _seatOfWorker(String code) =>
      _board?.seats.where((seat) => _same(seat.workerId, code)).firstOrNull;

  bool get _needsWorker => _assignWorker && _worker == null;

  PositionUpdatePlan? get _previewPlan {
    final slot = _slot;
    final board = _board;
    if (slot == null || board == null || _needsWorker) return null;
    return planPositionUpdate(
      board: board.seats,
      slot: slot,
      worker: _assignWorker ? _worker : null,
    );
  }

  // ─── Submit ──────────────────────────────────────────────────────

  Future<void> _submit() async {
    final slot = _slot;
    if (slot == null || _needsWorker || _isSubmitting) return;
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
      if (plan.isNoop) {
        _showSnack(
          worker == null
              ? 'Vị trí ${slot.positionId} đã gắn máy ${slot.machineId}. '
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
        icon: const Icon(
          Icons.error_outline_rounded,
          color: CaslaColors.danger,
          size: 36,
        ),
        title: const Text(
          'SAP chưa cập nhật xong',
          textAlign: TextAlign.center,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              describePositionError(error),
              style: const TextStyle(fontSize: CaslaType.subtitle, height: 1.4),
            ),
            const SizedBox(height: CaslaSpacing.md),
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
    // behind another tab.
    final visible = TickerMode.valuesOf(context).enabled;
    final cameraField = _cameraField;
    if (cameraField != null && visible) return _buildCamera(cameraField);

    return BarcodeScanListener(
      enabled: !_isSubmitting && !_isDialogOpen && _view == _View.scan,
      scanner: widget.scanner,
      preferences: widget.scannerPreferences,
      onScan: _handleScan,
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
        body: _view == _View.scan ? _buildScanView() : _buildBoardView(),
        bottomNavigationBar: _view == _View.scan ? _buildSubmitBar() : null,
      ),
    );
  }

  String _contextLabel() {
    if (widget.workCenter != null) return 'Xưởng ${widget.workCenter}';
    final context = ref.watch(appStateProvider).activeWorkContext;
    final label = context?.workCenterLabel.trim() ?? '';
    return label.isEmpty ? 'Các xưởng được phân quyền' : 'Xưởng $label';
  }

  Widget _buildCamera(_Field field) {
    final isSlot = field == _Field.slot;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          AdaptiveBarcodeScannerView(
            title: isSlot ? 'Quét nhãn vị trí / máy' : 'Quét QR công nhân',
            subtitle: isSlot
                ? 'Đưa nhãn dán trên máy vào khung quét.'
                : 'Đưa thẻ công nhân vào khung quét.',
            onScan: _handleCameraScan,
            onManualInput: () => _promptManualInput(field),
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
                onPressed: () => setState(() => _cameraField = null),
                icon: const Icon(Icons.arrow_back, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanView() {
    final plan = _previewPlan;
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
                isScanTarget: _target == _Field.slot,
                onSelect: () => setState(() => _target = _Field.slot),
                label: 'Vị trí / mã máy',
                required: true,
                icon: Icons.precision_manufacturing_outlined,
                value: _slot?.toString(),
                detail: null,
                filledContent: _slot == null ? null : _slotInfo(_slot!),
                placeholder: 'Chưa chọn vị trí / máy',
                onOpenScanner: () => setState(() => _cameraField = _Field.slot),
                onClear: _slot == null
                    ? null
                    : () => setState(() {
                        _slot = null;
                        _target = _Field.slot;
                      }),
              ),
              const SizedBox(height: CaslaSpacing.md),
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
                        placeholder: 'Chưa chọn công nhân',
                        onOpenScanner: () =>
                            setState(() => _cameraField = _Field.worker),
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

  Widget _slotInfo(PositionSlot slot) {
    final rows = <Widget>[_InfoLine('Xưởng', slot.workCenter)];
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
    final seat = _seatAt(slot);
    if (seat == null) {
      rows.add(
        const _InfoLine('Tình trạng', 'Vị trí chưa có', tone: _Tone.pending),
      );
    } else {
      if (seat.positionName.isNotEmpty) {
        rows.add(_InfoLine('Tên vị trí', seat.positionName));
      }
      rows.add(
        _InfoLine(
          'Máy hiện tại',
          seat.machineId,
          tone: _same(seat.machineId, slot.machineId) ? null : _Tone.pending,
        ),
      );
      rows.add(
        seat.isOccupied
            ? _InfoLine('Công nhân', '${seat.workerLabel} · ${seat.workerId}')
            : const _InfoLine('Công nhân', 'Chưa có', quiet: true),
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
              '${seat.positionId} · ${seat.machineId}',
            ),
    ]);
  }

  Widget _buildSubmitBar() {
    final plan = _previewPlan;
    final noop = plan?.isNoop ?? false;
    final canSubmit = _slot != null && !_needsWorker && !_isSubmitting && !noop;
    final hint = _talkingToSap
        ? 'Đang làm việc với SAP, giữ máy trong tay'
        : _isSubmitting
        ? 'Đang chờ xác nhận'
        : _slot == null
        ? 'Quét nhãn vị trí / máy để tiếp tục'
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

  Widget _buildBoardView() {
    final board = _board;
    final seats = board?.seats ?? const <PositionSeat>[];
    final occupied = seats.where((seat) => seat.isOccupied).length;
    final visible = seats.where((seat) {
      return switch (_filter) {
        _BoardFilter.all => true,
        _BoardFilter.occupied => seat.isOccupied,
        _BoardFilter.empty => !seat.isOccupied,
      };
    }).toList();
    final showWorkCenter =
        {for (final seat in seats) seat.workCenter}.length > 1;

    return RefreshIndicator(
      onRefresh: _loadBoard,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(CaslaSpacing.md),
        children: [
          Wrap(
            spacing: CaslaSpacing.xs,
            runSpacing: CaslaSpacing.xs,
            children: [
              _filterChip(_BoardFilter.all, 'Tất cả · ${seats.length}'),
              _filterChip(_BoardFilter.occupied, 'Có công nhân · $occupied'),
              _filterChip(
                _BoardFilter.empty,
                'Chưa có công nhân · ${seats.length - occupied}',
              ),
            ],
          ),
          const SizedBox(height: CaslaSpacing.sm),
          const Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 16,
                color: CaslaColors.muted,
              ),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Chỉ xem. Chạm một dòng để xem chi tiết.',
                  style: TextStyle(
                    fontSize: CaslaType.caption,
                    color: CaslaColors.muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: CaslaSpacing.sm),
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
                    ? 'Chưa có vị trí nào đang dùng. Quét nhãn trên máy để tạo '
                          'vị trí đầu tiên.'
                    : 'Không có vị trí nào khớp bộ lọc.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: CaslaColors.muted),
              ),
            )
          else
            for (final seat in visible)
              _SeatRow(
                seat: seat,
                showWorkCenter: showWorkCenter,
                onTap: () => _showSeatDetail(seat),
              ),
        ],
      ),
    );
  }

  Widget _filterChip(_BoardFilter filter, String label) => ChoiceChip(
    label: Text(label),
    selected: _filter == filter,
    showCheckmark: false,
    selectedColor: CaslaColors.primaryNavy,
    labelStyle: TextStyle(
      fontWeight: FontWeight.w600,
      color: _filter == filter ? Colors.white : CaslaColors.muted,
    ),
    onSelected: (_) => setState(() => _filter = filter),
  );

  Future<void> _showSeatDetail(PositionSeat seat) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: CaslaColors.surface,
      showDragHandle: true,
      builder: (context) => _SeatDetailSheet(seat: seat),
    );
  }
}

/// Vietnamese text for a position call failure. Codes come from
/// `zcl_pp_position_api` (docs/POSITION_MANAGEMENT.md, "Lỗi").
@visibleForTesting
String describePositionError(Object error) {
  if (error is SapConfigurationException) return error.message;
  if (error is SapBusinessError) {
    final text = switch (error.code) {
      'AUTH_FAILED' ||
      'TOKEN_INVALID_OR_EXPIRED' ||
      'DEVICE_MISMATCH' ||
      'USER_INACTIVE' =>
        'Phiên đăng nhập đã hết hạn hoặc không hợp lệ. Hãy '
            'đăng nhập lại.',
      'PASSWORD_CHANGE_REQUIRED' =>
        'Tài khoản cần đổi mật khẩu trước khi tiếp tục.',
      'MISSING_PERMISSION' =>
        'Tài khoản chưa được cấp quyền quản lý vị trí (PP_POS_MANAGE).',
      'NO_WORK_CENTER_SCOPE' =>
        'Xưởng của vị trí, hoặc chỗ ngồi hiện tại của công nhân, nằm ngoài '
            'phạm vi quyền của bạn.',
      'INPUT_INVALID' =>
        'Thiếu hoặc sai mã xưởng, vị trí, máy hay công nhân. Kiểm tra lại '
            'nhãn vừa quét.',
      'POSITION_EXISTS' =>
        'Vị trí này đang gắn máy khác. Quét lại để SAP đổi máy thay vì tạo '
            'mới.',
      'POSITION_NOT_ACTIVE' => 'Vị trí chưa có hoặc đang ngừng dùng.',
      'MACHINE_IN_USE' =>
        'Máy đang dùng ở vị trí khác. Cần ngừng dùng máy ở vị trí cũ trước.',
      'WORKER_NOT_IN_WORK_CENTER' =>
        'Công nhân không thuộc xưởng này theo danh sách nhân công hôm nay.',
      'POSITION_LOCKED' =>
        'Dòng này đang được mở chỉnh sửa trên Fiori. Thử lại sau ít phút.',
      'POSITION_SAVE_FAILED' => 'SAP không ghi được thay đổi. Thử lại sau.',
      _ => null,
    };
    if (text != null) return text;
  }
  if (error is SapSessionInvalidatedException) {
    return 'Phiên đăng nhập vừa thay đổi. Hãy thử lại.';
  }
  return classifySyncError(error).message;
}

String _short(String raw) {
  final text = raw.trim();
  return text.length <= 40 ? text : '${text.substring(0, 40)}…';
}

bool _same(String a, String b) =>
    a.trim().toUpperCase() == b.trim().toUpperCase();

// ─── Widgets ─────────────────────────────────────────────────────────

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
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: selected
                          ? CaslaColors.primaryNavy
                          : CaslaColors.identityMeta,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
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
    if (plan.warnings.isEmpty) {
      return const _Notice(
        tone: null,
        icon: Icons.check_circle_outline_rounded,
        text: 'Không có cảnh báo. Bấm Cập nhật để ghi vào SAP.',
      );
    }
    return _Notice(
      tone: _Tone.pending,
      icon: Icons.warning_amber_rounded,
      text: 'Có thay đổi cần xác nhận trước khi gửi SAP.',
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
      icon: const Icon(
        Icons.warning_amber_rounded,
        color: CaslaColors.accentGold,
        size: 36,
      ),
      title: Column(
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
              fontSize: CaslaType.title,
              fontWeight: FontWeight.w800,
              color: CaslaColors.primaryNavy,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              warning.message,
              style: const TextStyle(
                fontSize: CaslaType.subtitle,
                height: 1.4,
                color: CaslaColors.navy900,
              ),
            ),
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
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
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
  final VoidCallback onTap;

  const _SeatRow({
    required this.seat,
    required this.showWorkCenter,
    required this.onTap,
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
        color: CaslaColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CaslaRadius.md),
          side: const BorderSide(color: CaslaColors.line),
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
                        '${seat.positionId} · ${seat.machineId}',
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
              '${seat.positionId} · ${seat.machineId}',
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
                  _InfoLine('Mã máy', seat.machineId),
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
