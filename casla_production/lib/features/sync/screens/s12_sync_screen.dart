import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../core/database/casla_database.dart';
import '../../../core/sync/verified_sync_coordinator.dart';
import '../../../core/sync/sync_failure.dart';
import '../../../data/sap/odata_error.dart';
import '../../../domain/entities/entities.dart';
import '../../../core/utils/quantity_formatter.dart';
import '../../../main.dart';
import '../../../presentation/widgets/account_avatar_button.dart';
import '../../../presentation/widgets/status_chip.dart';
import '../../../presentation/widgets/worker_verification_dialog.dart';
import '../../../presentation/widgets/casla_skeleton.dart';
import '../../../presentation/widgets/sync_failure_dialog.dart';

class _SyncItemDetails {
  final String productionOrder;
  final String operation;
  final String businessDate;
  final String shift;
  final String workId;
  final String productName;
  final String productCode;
  final String workerName;
  final String workerCode;
  final String transactionType;
  final String quantity;
  final String unit;
  final String executedAt;

  const _SyncItemDetails({
    this.productionOrder = '',
    this.operation = '',
    this.businessDate = '',
    this.shift = '',
    this.workId = '',
    this.productName = '',
    this.productCode = '',
    this.workerName = '',
    this.workerCode = '',
    this.transactionType = '',
    this.quantity = '',
    this.unit = '',
    this.executedAt = '',
  });
}

class S12SyncScreen extends ConsumerStatefulWidget {
  const S12SyncScreen({super.key});

  @override
  ConsumerState<S12SyncScreen> createState() => _S12SyncScreenState();
}

class _S12SyncScreenState extends ConsumerState<S12SyncScreen> {
  int _selectedTabIndex = 0;
  final TextEditingController _workerCodeSearchController =
      TextEditingController();
  final Set<String> _syncingIds = <String>{};
  StreamSubscription<SyncFeedPage>? _feedSubscription;
  Timer? _feedExpiryTimer;
  bool _feedRetentionRefreshing = false;
  String _scopeKey = '';
  String _actorId = '';
  List<String> _teamIds = const [];
  List<Map<String, dynamic>> _feedItems = const [];
  bool _feedLoading = true;
  bool _feedLoadingMore = false;
  bool _feedHasMore = false;
  int? _nextCreatedAtUtc;
  String? _nextId;
  int _pendingCount = 0;
  int _verificationCount = 0;
  int _failedCount = 0;
  int _totalCount = 0;
  Object? _feedError;
  int _feedGeneration = 0;
  final Map<String, String> _workerCodesByItemId = <String, String>{};
  final Map<String, _SyncItemDetails> _detailsByItemId =
      <String, _SyncItemDetails>{};

  @override
  void initState() {
    super.initState();
    // The database stream emits on writes. A small periodic refresh is also
    // needed so a failed row disappears while this screen stays open and no
    // new queue write occurs at the ten-minute boundary.
    _feedExpiryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshFeedAfterRetentionTick(),
    );
  }

  SyncFeedFilter get _feedFilter => switch (_selectedTabIndex) {
    1 => SyncFeedFilter.pending,
    2 => SyncFeedFilter.verification,
    3 => SyncFeedFilter.failed,
    _ => SyncFeedFilter.all,
  };

  void _ensureScopedFeed(String actorId, List<String> teamIds) {
    final normalizedTeams = teamIds.toList()..sort();
    final key = '$actorId|${normalizedTeams.join(',')}|$_selectedTabIndex';
    if (key == _scopeKey && _feedSubscription != null) return;
    _scopeKey = key;
    final generation = ++_feedGeneration;
    _actorId = actorId;
    _teamIds = normalizedTeams;
    _feedItems = const [];
    _workerCodesByItemId.clear();
    _detailsByItemId.clear();
    _workerCodeSearchController.clear();
    _feedLoading = true;
    _feedLoadingMore = false;
    _feedError = null;
    _feedHasMore = false;
    _nextCreatedAtUtc = null;
    _nextId = null;
    unawaited(_feedSubscription?.cancel());
    _feedSubscription = ref
        .read(appStateProvider)
        .db
        .watchSyncFeedPage(
          actorId: actorId,
          teamIds: normalizedTeams,
          filter: _feedFilter,
        )
        .listen(
          (page) => _replaceFirstPage(page, generation),
          onError: (Object error, StackTrace _) {
            if (!mounted) return;
            setState(() {
              _feedError = error;
              _feedLoading = false;
            });
          },
        );
  }

  void _replaceFirstPage(SyncFeedPage page, int generation) {
    if (!mounted || generation != _feedGeneration) return;
    setState(() {
      // The live stream owns the first cursor page. Older pages are discarded
      // so rows that were deleted or moved out of the active filter cannot
      // remain visible, and the cursor always matches the rendered list.
      _feedItems = page.items;
      _feedLoading = false;
      _feedHasMore = page.hasMore;
      _nextCreatedAtUtc = page.nextCreatedAtUtc;
      _nextId = page.nextId;
      _pendingCount = page.pendingCount;
      _verificationCount = page.verificationCount;
      _failedCount = page.failedCount;
      _totalCount = page.totalCount;
    });
    unawaited(_hydrateWorkerCodes(page.items, generation));
    unawaited(_hydrateSyncDetails(page.items, generation));
  }

  Future<void> _hydrateWorkerCodes(
    List<Map<String, dynamic>> items,
    int generation,
  ) async {
    final resolved = <String, String>{};
    for (final item in items) {
      final id = item['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final code = await _workerCodeForItem(item);
      if (code.isNotEmpty) resolved[id] = code;
    }
    if (!mounted || generation != _feedGeneration || resolved.isEmpty) return;
    setState(() => _workerCodesByItemId.addAll(resolved));
  }

  Future<String> _workerCodeForItem(Map<String, dynamic> item) async {
    final db = ref.read(appStateProvider).db;
    final source = await db.getSyncSourceRow(
      item['entity_type'] as String,
      item['entity_id'] as String,
    );
    if (source == null) return '';
    Map<String, dynamic>? assignment;
    if (item['entity_type'] == 'ASSIGNMENT') {
      assignment = source;
    } else {
      final assignmentId = source['phan_cong_id'] as String?;
      if (assignmentId != null) {
        assignment = await db.getAssignmentById(assignmentId);
      }
    }
    final workerId = assignment?['nhan_vien_id'] as String?;
    if (workerId == null || workerId.trim().isEmpty) return '';
    final employee = await db.getEmployeeById(workerId);
    return employee?['ma_nv']?.toString().trim() ?? workerId.trim();
  }

  Future<void> _hydrateSyncDetails(
    List<Map<String, dynamic>> items,
    int generation,
  ) async {
    final resolved = <String, _SyncItemDetails>{};
    for (final item in items) {
      final id = item['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final details = await _syncDetailsForItem(item);
      if (details != null) resolved[id] = details;
    }
    if (!mounted || generation != _feedGeneration || resolved.isEmpty) return;
    setState(() => _detailsByItemId.addAll(resolved));
  }

  Future<_SyncItemDetails?> _syncDetailsForItem(
    Map<String, dynamic> item,
  ) async {
    final db = ref.read(appStateProvider).db;
    final entityType = item['entity_type']?.toString() ?? '';
    final entityId = item['entity_id']?.toString() ?? '';
    if (entityType.isEmpty || entityId.isEmpty) return null;
    final source = await db.getSyncSourceRow(entityType, entityId);
    if (source == null) return null;

    Map<String, dynamic>? assignment;
    if (entityType == 'ASSIGNMENT') {
      assignment = source;
    } else {
      final assignmentId = source['phan_cong_id']?.toString();
      if (assignmentId != null && assignmentId.isNotEmpty) {
        assignment = await db.getAssignmentById(assignmentId);
      }
    }

    Map<String, dynamic>? order;
    final orderId = assignment?['don_hang_id']?.toString();
    if (orderId != null && orderId.isNotEmpty) {
      order = await db.getOrderById(orderId);
    }

    final workerId = assignment?['nhan_vien_id']?.toString().trim() ?? '';
    final employee = workerId.isEmpty
        ? null
        : await db.getEmployeeById(workerId);
    final workerCode = employee?['ma_nv']?.toString().trim() ?? '';
    final workerName = employee?['ten']?.toString().trim() ?? '';
    final number =
        source[entityType == 'ASSIGNMENT' ? 'assigned_quantity' : 'quantity'];
    final unit = (source['unit_of_measure'] ?? order?['uom'] ?? '')
        .toString()
        .trim();
    final quantity = number is num
        ? formatQuantity(number.toDouble(), uom: unit)
        : '';
    final businessDate =
        (source['business_date'] ?? assignment?['business_date'] ?? '')
            .toString()
            .trim();
    final shiftId = (source['shift_id'] ?? assignment?['shift_id'] ?? '')
        .toString()
        .trim();
    final productionOrder =
        (order?['production_order'] ?? order?['ma_don_hang'] ?? '')
            .toString()
            .trim();
    final operation = (order?['operation'] ?? '').toString().trim();
    final productName = (order?['ten_sp'] ?? '').toString().trim();
    final productCode = (order?['ma_sp'] ?? '').toString().trim();
    final workId = (assignment?['to_id'] ?? '').toString().trim();
    final transactionType = switch (entityType) {
      'ASSIGNMENT' => 'Phân công',
      'RECALL' || 'RECALL_RECORD' => 'Thu hồi',
      'PRODUCTION' || 'PRODUCTION_RECORD' => 'Xác nhận',
      _ => item['action']?.toString().trim() ?? 'Giao dịch',
    };

    return _SyncItemDetails(
      productionOrder: productionOrder,
      operation: operation,
      businessDate: _displayDate(businessDate),
      shift: _displayShift(shiftId),
      workId: workId,
      productName: productName,
      productCode: productCode,
      workerName: workerName,
      workerCode: workerCode,
      transactionType: transactionType,
      quantity: quantity,
      unit: unit,
      executedAt: source['occurred_at_utc'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (source['occurred_at_utc'] as num).toInt(),
              isUtc: true,
            ).toIso8601String()
          : '',
    );
  }

  String _displayDate(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    return '${parsed.day.toString().padLeft(2, '0')}/'
        '${parsed.month.toString().padLeft(2, '0')}/${parsed.year}';
  }

  String _displayShift(String value) {
    if (value.isEmpty) return '';
    final normalized = value.toUpperCase();
    if (normalized == 'SHIFT_1' || normalized == '1') return 'Ca ngày';
    if (normalized == 'SHIFT_2' || normalized == '2') return 'Ca đêm';
    return value;
  }

  String _displayExecutedAt(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return value;
    final local = parsed.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year} · '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  void _retryFeed() {
    final session = ref.read(appStateProvider).currentSession;
    if (session == null) return;
    _scopeKey = '';
    _ensureScopedFeed(session.maNv, _effectiveTeamIds(session));
  }

  List<String> _effectiveTeamIds(UserSession session) {
    final ids = <String>{...session.toIds};
    final activeWorkId = ref.read(appStateProvider).activeWorkContext?.workId;
    if (activeWorkId != null && activeWorkId.trim().isNotEmpty) {
      ids.add(activeWorkId.trim());
    }
    return ids.where((id) => id.trim().isNotEmpty).toList();
  }

  Future<void> _refreshFeedAfterRetentionTick() async {
    if (!mounted ||
        _feedLoading ||
        _feedRetentionRefreshing ||
        _actorId.isEmpty ||
        _teamIds.isEmpty) {
      return;
    }
    _feedRetentionRefreshing = true;
    final generation = _feedGeneration;
    try {
      final page = await ref
          .read(appStateProvider)
          .db
          .getSyncFeedPage(
            actorId: _actorId,
            teamIds: _teamIds,
            filter: _feedFilter,
          );
      _replaceFirstPage(page, generation);
    } catch (_) {
      // The live stream remains the source of truth; a retention refresh is
      // best-effort and must not replace a usable feed with an error state.
    } finally {
      _feedRetentionRefreshing = false;
    }
  }

  Future<void> _loadMore() async {
    if (_feedLoadingMore || !_feedHasMore) return;
    final generation = _feedGeneration;
    setState(() => _feedLoadingMore = true);
    try {
      final page = await ref
          .read(appStateProvider)
          .db
          .getSyncFeedPage(
            actorId: _actorId,
            teamIds: _teamIds,
            filter: _feedFilter,
            beforeCreatedAtUtc: _nextCreatedAtUtc,
            beforeId: _nextId,
          );
      if (!mounted || generation != _feedGeneration) return;
      setState(() {
        final existingIds = _feedItems.map((item) => item['id']).toSet();
        _feedItems = [
          ..._feedItems,
          ...page.items.where((item) => existingIds.add(item['id'])),
        ];
        _feedHasMore = page.hasMore;
        _nextCreatedAtUtc = page.nextCreatedAtUtc;
        _nextId = page.nextId;
        _feedLoadingMore = false;
      });
      unawaited(_hydrateWorkerCodes(page.items, generation));
      unawaited(_hydrateSyncDetails(page.items, generation));
    } catch (_) {
      if (mounted) setState(() => _feedLoadingMore = false);
    }
  }

  Future<void> _refreshFeedNow() async {
    if (!mounted || _actorId.isEmpty || _teamIds.isEmpty) return;
    final generation = _feedGeneration;
    try {
      final page = await ref
          .read(appStateProvider)
          .db
          .getSyncFeedPage(
            actorId: _actorId,
            teamIds: _teamIds,
            filter: _feedFilter,
          );
      _replaceFirstPage(page, generation);
    } catch (_) {
      // The live watcher will retry on its next database tick. Keep the
      // already-rendered feed visible when this immediate refresh is offline.
    }
  }

  @override
  void dispose() {
    _workerCodeSearchController.dispose();
    _feedExpiryTimer?.cancel();
    unawaited(_feedSubscription?.cancel());
    super.dispose();
  }

  bool _isVerifiable(Map<String, dynamic> item) =>
      item['status'] == 'NEEDS_VERIFICATION' ||
      item['last_error_code'] == 'WORKER_AUTH_FAILED';

  Future<void> _verify(Map<String, dynamic> item) async {
    final appState = ref.read(appStateProvider);
    final id = item['id'] as String;
    final generation = appState.sessionGeneration;
    if (_syncingIds.contains(id)) return;
    setState(() => _syncingIds.add(id));
    try {
      final workerName = await _workerNameForItem(item);
      if (!mounted) return;

      final password = await showWorkerVerificationDialog(
        context,
        workerName: workerName,
        actionLabel: 'xác minh và gửi các giao dịch đang chờ lên SAP',
      );
      if (!mounted || password == null) return;
      if (!appState.isSessionGenerationCurrent(generation)) return;

      final report = await appState.verifiedSync.syncVerifiedWorkerChain(
        anchorQueueItemId: id,
        workerPassword: password,
      );
      if (!mounted) return;

      final color = switch (report.outcome) {
        VerifiedSyncOutcome.synced => CaslaColors.success,
        VerifiedSyncOutcome.queued => CaslaColors.pending,
        VerifiedSyncOutcome.rejected => CaslaColors.danger,
        VerifiedSyncOutcome.blocked ||
        VerifiedSyncOutcome.notFound => CaslaColors.gold700,
      };
      Map<String, dynamic>? failedItem;
      _SyncItemDetails? failedDetails;
      final failedId = report.failedQueueItemId;
      if (failedId != null) {
        failedItem = await appState.db.getSyncQueueItemById(
          failedId,
          actorId: _actorId,
          teamIds: _teamIds,
        );
        if (failedItem != null) {
          failedDetails = await _syncDetailsForItem(failedItem);
        }
      }
      if (!mounted) return;

      // A verified push can move the item from NEEDS_VERIFICATION to SYNCED,
      // or leave a new SAP error on the same queue row. Do one synchronous
      // read after the coordinator returns so the tab reflects that result
      // immediately even when the screen is kept alive by the shell.
      await _refreshFeedNow();
      if (!mounted) return;
      if (report.outcome == VerifiedSyncOutcome.synced) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(report.message), backgroundColor: color),
        );
      } else {
        final code = _resolveFailureCode(failedItem, report.message);
        final summary = failedItem?['payload_summary']?.toString().trim();
        await showSyncFailureDialog(
          context,
          data: SyncFailureDialogData(
            title: report.outcome == VerifiedSyncOutcome.rejected
                ? 'Không thể đồng bộ'
                : 'Chưa thể đồng bộ',
            statusLabel: _failureStatusLabel(code),
            message: _syncFailureMessage(
              code: code,
              fallback: report.message,
              details: failedDetails,
            ),
            guidance: _failureGuidance(code),
            transactionSummary: summary != null && summary.isNotEmpty
                ? summary
                : _transactionSummary(failedDetails),
            orderOperation: failedDetails == null
                ? ''
                : [
                    failedDetails.productionOrder,
                    failedDetails.operation,
                  ].where((value) => value.isNotEmpty).join(' · '),
            businessDateShift: failedDetails == null
                ? ''
                : [
                    failedDetails.businessDate,
                    failedDetails.shift,
                  ].where((value) => value.isNotEmpty).join(' · '),
            createdAt: failedDetails == null
                ? ''
                : _displayExecutedAt(failedDetails.executedAt),
            technicalCode: code == 'SYNC_FAILED' ? '' : code,
            technicalMessage: _technicalMessage(report.message),
            stoppedWorkerChain: failedId != null && failedId != id,
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      final failure = classifySyncError(error);
      await showSyncFailureDialog(
        context,
        data: SyncFailureDialogData(
          title: 'Chưa thể đồng bộ',
          statusLabel: _failureStatusLabel(failure.code),
          message: failure.message,
          guidance: failure.isRetryable
              ? 'Kiểm tra kết nối rồi thử lại. Giao dịch vẫn được lưu an toàn trên thiết bị.'
              : _failureGuidance(failure.code),
          technicalCode: failure.code,
        ),
      );
    } finally {
      if (mounted) setState(() => _syncingIds.remove(id));
    }
  }

  Future<String> _workerNameForItem(Map<String, dynamic> item) async {
    final db = ref.read(appStateProvider).db;
    final source = await db.getSyncSourceRow(
      item['entity_type'] as String,
      item['entity_id'] as String,
    );
    if (source == null) return 'Công nhân';
    Map<String, dynamic>? assignment;
    if (item['entity_type'] == 'ASSIGNMENT') {
      assignment = source;
    } else {
      final assignmentId = source['phan_cong_id'] as String?;
      if (assignmentId != null) {
        assignment = await db.getAssignmentById(assignmentId);
      }
    }
    final workerId = assignment?['nhan_vien_id'] as String?;
    if (workerId == null) return 'Công nhân';
    final employee = await db.getEmployeeById(workerId);
    return employee?['ten'] as String? ?? 'Công nhân';
  }

  String? _errorMessage(Map<String, dynamic> item) {
    final raw = item['last_error_message']?.toString().trim();
    final code = item['last_error_code']?.toString().trim();
    if (code == null || code.isEmpty) {
      return raw == null || raw.isEmpty ? null : raw;
    }
    final mapped = friendlySapErrorMessage(SapBusinessError(code));
    final hasKnownMapping = mapped != 'SAP từ chối yêu cầu (mã $code).';
    // Prefer the current code mapping whenever SAP returned a known code.
    // This also repairs queue rows created by older builds that stored the
    // generic verification sentence instead of the business explanation.
    if (hasKnownMapping) return mapped;
    if (raw == null ||
        raw.isEmpty ||
        raw == code ||
        raw.toUpperCase().contains('SABP_BEHV')) {
      return mapped;
    }
    return raw;
  }

  String _resolveFailureCode(Map<String, dynamic>? item, String reportMessage) {
    final combined = [
      item?['last_error_code'],
      item?['last_error_message'],
      reportMessage,
    ].whereType<Object>().map((value) => value.toString()).join(' ');
    const businessCodes = [
      'SHIFT_WORK_DATE_MISMATCH',
      'SHIFT_NOT_APPLICABLE',
      'OUTSIDE_SHIFT',
      'EXECUTED_AT_IN_FUTURE',
      'OPERATION_QUANTITY_EXCEEDED',
      'CONFIRM_QUANTITY_EXCEEDED',
      'CONFIRM_ORIGINAL_QUANTITY_EXCEEDED',
      'SOURCE_BALANCE_INSUFFICIENT',
      'WORKER_AUTH_FAILED',
      'SHIFT_CLOSED',
      'SHIFT_NOT_ALLOWED',
    ];
    for (final code in businessCodes) {
      if (combined.contains(code)) return code;
    }
    final storedCode = item?['last_error_code']?.toString().trim();
    return storedCode == null || storedCode.isEmpty
        ? 'SYNC_FAILED'
        : storedCode;
  }

  String _failureStatusLabel(String code) {
    return switch (code) {
      'SHIFT_WORK_DATE_MISMATCH' ||
      'SHIFT_NOT_APPLICABLE' ||
      'OUTSIDE_SHIFT' => 'Ngày hoặc ca không hợp lệ',
      'EXECUTED_AT_IN_FUTURE' => 'Giờ thiết bị nhanh hơn SAP',
      'OPERATION_QUANTITY_EXCEEDED' ||
      'CONFIRM_QUANTITY_EXCEEDED' ||
      'CONFIRM_ORIGINAL_QUANTITY_EXCEEDED' ||
      'SOURCE_BALANCE_INSUFFICIENT' => 'Số lượng không hợp lệ',
      'WORKER_AUTH_FAILED' => 'Cần xác minh công nhân',
      _ => 'Cần kiểm tra dữ liệu',
    };
  }

  String _syncFailureMessage({
    required String code,
    required String fallback,
    _SyncItemDetails? details,
  }) {
    if (code == 'SHIFT_WORK_DATE_MISMATCH' && details != null) {
      final recordedDate = details.businessDate;
      final createdAt = _displayExecutedAt(details.executedAt);
      if (recordedDate.isNotEmpty && createdAt.isNotEmpty) {
        return 'Giao dịch ghi nhận ngày $recordedDate nhưng được tạo lúc '
            '$createdAt. SAP không chấp nhận vì ngày làm việc không khớp '
            'với ca tại thời điểm tạo.';
      }
    }

    final mapped = friendlySapErrorMessage(SapBusinessError(code));
    if (mapped != 'SAP từ chối yêu cầu (mã $code).') return mapped;
    final trimmed = fallback.trim();
    final onlyTechnicalCodes = RegExp(
      r'^[A-Z][A-Z0-9_]*(?:\s+[A-Z][A-Z0-9_]*)*$',
    ).hasMatch(trimmed);
    if (trimmed.isNotEmpty && !onlyTechnicalCodes) return trimmed;
    return 'SAP chưa chấp nhận giao dịch này. Vui lòng kiểm tra thông tin trước khi xử lý lại.';
  }

  String _transactionSummary(_SyncItemDetails? details) {
    if (details == null) return '';
    final amount = [
      details.quantity,
      details.unit,
    ].where((value) => value.isNotEmpty).join(' ');
    return [
      details.transactionType,
      amount,
    ].where((value) => value.isNotEmpty).join(' · ');
  }

  String _technicalMessage(String message) {
    final trimmed = message.trim();
    return RegExp(r'\b[A-Z][A-Z0-9_]{2,}\b').hasMatch(trimmed) ? trimmed : '';
  }

  String _failureGuidance(String code) {
    return switch (code) {
      'OPERATION_QUANTITY_EXCEEDED' || 'CONFIRM_QUANTITY_EXCEEDED' =>
        'Làm mới sản lượng công đoạn rồi nhập lại số lượng giao hoặc xác nhận.',
      'SOURCE_BALANCE_INSUFFICIENT' || 'CONFIRM_ORIGINAL_QUANTITY_EXCEEDED' =>
        'Kiểm tra số dư giao dịch gốc trước khi gửi lại.',
      'WORKER_AUTH_FAILED' =>
        'Xác minh lại bằng mật khẩu của công nhân rồi gửi lại giao dịch.',
      'SHIFT_WORK_DATE_MISMATCH' || 'SHIFT_NOT_APPLICABLE' || 'OUTSIDE_SHIFT' =>
        'Đối chiếu ngày/ca đã lưu với thời điểm tạo giao dịch và múi giờ ca trên SAP. '
            'Đổi cài đặt hoặc nhập lại mật khẩu không sửa bản ghi cũ. '
            'Kiểm tra với quản lý trước khi xóa và tạo lại giao dịch.',
      'EXECUTED_AT_IN_FUTURE' =>
        'Bật "Ngày và giờ tự động" trong Cài đặt máy để tránh lặp lại.',
      'SHIFT_CLOSED' || 'SHIFT_NOT_ALLOWED' =>
        'Chọn đúng ca đang làm việc rồi thử lại giao dịch.',
      _ =>
        'Kiểm tra dữ liệu giao dịch hoặc cấu hình SAP. Giao dịch vẫn được giữ trên thiết bị.',
    };
  }

  Future<void> _showFailureDetails(Map<String, dynamic> item) async {
    final code = item['last_error_code']?.toString() ?? 'ERR_UNKNOWN';
    final message =
        _errorMessage(item) ??
        'SAP đã từ chối giao dịch nhưng không trả về mô tả chi tiết.';
    final summary = item['payload_summary']?.toString() ?? 'Bản ghi';
    final entityId = item['entity_id']?.toString() ?? '';
    final device = item['device_id']?.toString() ?? 'Không rõ thiết bị';
    final details = _detailsByItemId[item['id']?.toString()];
    final diagnostics = [
      'Giao dịch: $summary',
      'Mã lỗi: $code',
      'Mô tả: $message',
      'Entity ID: $entityId',
      'Thiết bị: $device',
      if (details != null)
        'Ngày/ca: ${details.businessDate} · ${details.shift}',
      if (details != null) 'Thời điểm tạo (UTC): ${details.executedAt}',
    ].join('\n');

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Chi tiết lỗi đồng bộ',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: const Text('Đóng'),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                summary,
                style: const TextStyle(color: CaslaColors.muted, fontSize: 13),
              ),
              if (details != null) ...[
                const SizedBox(height: 12),
                _buildFailureMetadata(details),
              ],
              const SizedBox(height: 18),
              const Text(
                'Mã lỗi',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              ),
              const SizedBox(height: 5),
              SelectableText(
                code,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: CaslaColors.danger,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'SAP phản hồi',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
              ),
              const SizedBox(height: 5),
              SelectableText(
                message,
                style: const TextStyle(height: 1.45, fontSize: 13.5),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: CaslaColors.gold100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_failureGuidance(code))),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: diagnostics));
                    if (!sheetContext.mounted) return;
                    ScaffoldMessenger.of(sheetContext).showSnackBar(
                      const SnackBar(
                        content: Text('Đã sao chép thông tin để gửi hỗ trợ.'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Sao chép thông tin hỗ trợ'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFailureMetadata(_SyncItemDetails details) {
    final values = <String, String>{
      if (details.productionOrder.isNotEmpty || details.operation.isNotEmpty)
        'LSX · Công đoạn': '${details.productionOrder} · ${details.operation}',
      if (details.businessDate.isNotEmpty || details.shift.isNotEmpty)
        'Ngày · Ca': '${details.businessDate} · ${details.shift}',
      if (details.executedAt.isNotEmpty)
        'Thời điểm tạo (UTC)': details.executedAt,
      if (details.productName.isNotEmpty) 'Tên hàng': details.productName,
      if (details.productCode.isNotEmpty) 'Mã hàng': details.productCode,
      if (details.workId.isNotEmpty) 'WorkID': details.workId,
    };
    if (values.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CaslaColors.muted100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 10,
        children: values.entries
            .map((entry) => _buildSyncFact(entry.key, entry.value))
            .toList(growable: false),
      ),
    );
  }

  Future<bool> _confirmAndDeleteSyncItem(Map<String, dynamic> item) async {
    final isVerification = _isVerifiable(item);
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: CaslaColors.danger,
              size: 30,
            ),
            title: Text(
              isVerification ? 'Xóa bản ghi cần xác minh?' : 'Xóa bản ghi lỗi?',
            ),
            content: const Text(
              'Giao dịch sẽ bị xóa hẳn khỏi thiết bị và không thể khôi phục. '
              'Nếu là giao việc, các xác nhận/thu hồi nhập theo lần giao này '
              'cũng bị xóa. Nếu đang cần xác minh, SAP có thể đã ghi nhận '
              'giao dịch; hãy đồng bộ lại để đối soát số liệu.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Hủy'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: CaslaColors.danger,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Xóa bản ghi'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return false;

    final id = item['id']?.toString().trim();
    if (id == null || id.isEmpty) return false;
    final db = ref.read(appStateProvider).db;
    final bool deleted;
    try {
      deleted = await db.deleteSyncQueueItem(id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể xóa bản ghi: $error')),
        );
      }
      return false;
    }
    if (!mounted) return deleted;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            deleted
                ? 'Đã xóa hẳn bản ghi đồng bộ khỏi thiết bị.'
                : 'Bản ghi đã đổi trạng thái hoặc không còn trên thiết bị.',
          ),
        ),
      );
    return deleted;
  }

  Widget _buildDeleteBackground({required bool alignRight}) {
    return Container(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: CaslaColors.danger,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.delete_outline_rounded, color: Colors.white, size: 22),
          SizedBox(height: 2),
          Text(
            'Xóa',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final session = appState.currentSession;
    if (session == null) return const SizedBox.shrink();
    _ensureScopedFeed(session.maNv, _effectiveTeamIds(session));

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Cập nhật giao dịch',
            onPressed: _refreshFeedNow,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const AccountAvatarButton(),
        ],
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Đồng bộ',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Theo dõi và xử lý giao dịch chưa lên SAP',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: CaslaColors.identityMeta,
              ),
            ),
          ],
        ),
      ),
      body: _feedError != null
          ? _buildFeedError()
          : _feedLoading
          ? const _SyncSkeleton()
          : _buildFeedBody(),
    );
  }

  Widget _buildFeedError() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.sync_problem_outlined,
              size: 42,
              color: CaslaColors.danger,
            ),
            const SizedBox(height: 12),
            const Text(
              'Không tải được hàng đợi đồng bộ',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: CaslaColors.primaryNavy,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Giao dịch vẫn được lưu trên thiết bị. Thử tải lại khi mạng ổn định.',
              textAlign: TextAlign.center,
              style: TextStyle(color: CaslaColors.muted, height: 1.4),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _retryFeed,
              icon: const Icon(Icons.refresh),
              label: const Text('Thử tải lại'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeedBody() {
    final query = _workerCodeSearchController.text.trim().toLowerCase();
    final visibleItems = query.isEmpty
        ? _feedItems
        : _feedItems
              .where(
                (item) => (_workerCodesByItemId[item['id']?.toString()] ?? '')
                    .toLowerCase()
                    .contains(query),
              )
              .toList(growable: false);
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                _buildSummaryBox('$_pendingCount', 'ĐANG CHỜ'),
                const SizedBox(width: 8),
                _buildSummaryBox(
                  '$_verificationCount',
                  'CẦN XÁC MINH',
                  color: CaslaColors.gold700,
                ),
                const SizedBox(width: 8),
                _buildSummaryBox(
                  '$_failedCount',
                  'LỖI',
                  color: CaslaColors.danger,
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 14)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          sliver: SliverToBoxAdapter(
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: CaslaColors.muted100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  _buildTab('Tất cả', 0),
                  _buildTab('Đang chờ', 1),
                  _buildTab('Xác minh', 2),
                  _buildTab('Lỗi', 3),
                ],
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 14)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          sliver: SliverToBoxAdapter(
            child: TextField(
              controller: _workerCodeSearchController,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Tìm theo mã nhân viên',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Xóa tìm kiếm',
                        onPressed: () {
                          _workerCodeSearchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 14)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          sliver: SliverToBoxAdapter(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Expanded(
                  child: Text(
                    'Giao dịch cần xử lý',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                ),
                Text(
                  '${visibleItems.length} giao dịch',
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: CaslaColors.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        if (visibleItems.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            sliver: SliverToBoxAdapter(child: _buildEmptyFeed()),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            sliver: SliverList.separated(
              itemCount: visibleItems.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) =>
                  _buildSyncRow(visibleItems[index]),
            ),
          ),
        if (_feedHasMore)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            sliver: SliverToBoxAdapter(
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _feedLoadingMore ? null : _loadMore,
                  icon: const Icon(Icons.expand_more_rounded),
                  label: Text(
                    _feedLoadingMore
                        ? 'Đang tải thêm…'
                        : 'Xem thêm • ${visibleItems.length}/$_totalCount giao dịch',
                  ),
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 18)),
        if (visibleItems.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            sliver: SliverToBoxAdapter(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: CaslaColors.muted100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 17,
                      color: CaslaColors.muted,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Giao dịch vẫn được lưu an toàn trên thiết bị. Mở Chi tiết để xem phản hồi SAP.',
                        style: TextStyle(
                          color: CaslaColors.muted,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyFeed() => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: CaslaColors.surface,
      border: Border.all(color: CaslaColors.line),
      borderRadius: BorderRadius.circular(14),
    ),
    child: const Center(
      child: Text(
        'Không có bản ghi nào trong mục này.',
        style: TextStyle(color: CaslaColors.muted, fontSize: 13),
      ),
    ),
  );

  Widget _buildSyncRow(Map<String, dynamic> item) {
    final isFailed = item['status'] == 'FAILED';
    final isPending = item['status'] == 'PENDING';
    final isVerifiable = _isVerifiable(item);
    final isSyncing = _syncingIds.contains(item['id']);
    final itemId = item['id']?.toString() ?? '';
    final details = _detailsByItemId[itemId];
    final workerCode = details?.workerCode.isNotEmpty == true
        ? details!.workerCode
        : _workerCodesByItemId[itemId] ?? '';
    final statusLabel = isVerifiable
        ? 'CẦN XÁC MINH'
        : isFailed
        ? 'LỖI'
        : isPending
        ? 'ĐANG CHỜ'
        : 'ĐÃ GỬI';
    final statusColor = isVerifiable
        ? CaslaColors.gold700
        : isFailed
        ? CaslaColors.danger
        : isPending
        ? CaslaColors.pending
        : CaslaColors.success;
    final quantitySuffix = details?.quantity.isNotEmpty == true
        ? ' · +${details!.quantity} ${details.unit}'.trimRight()
        : '';
    final title = details == null || details.transactionType.isEmpty
        ? item['payload_summary']?.toString() ?? 'Bản ghi'
        : '${details.transactionType}$quantitySuffix';
    final workerLabel = details?.workerName.isNotEmpty == true
        ? '${details!.workerName}${workerCode.isEmpty ? '' : ' · $workerCode'}'
        : workerCode.isEmpty
        ? ''
        : 'NV $workerCode';
    final errorMessage = _errorMessage(item);
    final errorCode = item['last_error_code']?.toString().trim() ?? '';
    final row = Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        border: Border.all(
          color: isFailed ? const Color(0xFFF0CACA) : CaslaColors.line,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: isFailed ? CaslaColors.dangerBg : CaslaColors.muted100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isVerifiable
                      ? Icons.lock_outline
                      : isFailed
                      ? Icons.error_outline
                      : isPending
                      ? Icons.access_time
                      : Icons.check_circle_outline,
                  size: 19,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .3,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                    if (workerLabel.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      _buildWorkerLabel(
                        details: details,
                        workerCode: workerCode,
                        fallback: workerLabel,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (details != null) ...[
            const SizedBox(height: 12),
            _buildSyncFactsGrid(details),
          ],
          if ((isFailed || isVerifiable) &&
              errorMessage != null &&
              errorMessage.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: isFailed ? CaslaColors.dangerBg : CaslaColors.gold100,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 17,
                    color: isFailed ? CaslaColors.danger : CaslaColors.gold700,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          errorMessage,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isFailed
                                ? CaslaColors.danger
                                : CaslaColors.gold700,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                        if (errorCode.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            errorCode,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              color: isFailed
                                  ? CaslaColors.danger
                                  : CaslaColors.gold700,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              if (isFailed && !isVerifiable)
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _showFailureDetails(item),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      foregroundColor: CaslaColors.danger,
                      side: const BorderSide(color: CaslaColors.danger),
                    ),
                    child: const Text('Chi tiết'),
                  ),
                )
              else if (!isVerifiable)
                Expanded(child: StatusChip(status: item['status'])),
              if (isVerifiable) ...[
                Expanded(
                  child: ElevatedButton(
                    onPressed: isSyncing ? null : () => _verify(item),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: CaslaColors.primaryNavy,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 42),
                    ),
                    child: isSyncing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Xác minh & gửi'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
    if (!isFailed && !isVerifiable) return row;

    final id = item['id']?.toString();
    if (id == null || id.isEmpty) return row;
    return Dismissible(
      key: ValueKey<String>('sync-$id'),
      direction: DismissDirection.horizontal,
      background: _buildDeleteBackground(alignRight: false),
      secondaryBackground: _buildDeleteBackground(alignRight: true),
      confirmDismiss: (_) => _confirmAndDeleteSyncItem(item),
      child: row,
    );
  }

  Widget _buildSyncFactsGrid(_SyncItemDetails details) {
    final facts = <({String label, String value})>[
      if (details.productionOrder.isNotEmpty || details.operation.isNotEmpty)
        (
          label: 'LSX · Công đoạn',
          value:
              '${details.productionOrder.isEmpty ? '—' : details.productionOrder} · ${details.operation.isEmpty ? '—' : details.operation}',
        ),
      if (details.businessDate.isNotEmpty || details.shift.isNotEmpty)
        (
          label: 'Ngày · Ca',
          value:
              '${details.businessDate.isEmpty ? '—' : details.businessDate} · ${details.shift.isEmpty ? '—' : details.shift}',
        ),
      if (details.productName.isNotEmpty)
        (label: 'Tên hàng', value: details.productName),
      if (details.productCode.isNotEmpty)
        (label: 'Mã hàng', value: details.productCode),
    ];
    if (facts.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (var index = 0; index < facts.length; index += 2) ...[
          if (index > 0) const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _buildSyncFact(
                  facts[index].label,
                  facts[index].value,
                  width: null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: index + 1 < facts.length
                    ? _buildSyncFact(
                        facts[index + 1].label,
                        facts[index + 1].value,
                        width: null,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSyncFact(String label, String value, {double? width = 150}) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 9.5, color: CaslaColors.muted),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: CaslaColors.primaryNavy,
          ),
        ),
      ],
    );
    return width == null ? content : SizedBox(width: width, child: content);
  }

  Widget _buildWorkerLabel({
    required _SyncItemDetails? details,
    required String workerCode,
    required String fallback,
  }) {
    final workerName = details?.workerName.trim() ?? '';
    if (workerName.isEmpty) {
      return Text(
        fallback,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: CaslaColors.primaryNavy,
        ),
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: workerName,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: CaslaColors.primaryNavy,
            ),
          ),
          if (workerCode.isNotEmpty)
            TextSpan(
              text: ' · $workerCode',
              style: const TextStyle(fontSize: 11, color: CaslaColors.muted),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildSummaryBox(String count, String label, {Color? color}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: CaslaColors.surface,
          border: Border.all(color: CaslaColors.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(
              count,
              style: TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: color ?? CaslaColors.primaryNavy,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: CaslaColors.muted,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTab(String label, int index) {
    final isSelected = _selectedTabIndex == index;
    return Expanded(
      child: Semantics(
        button: true,
        selected: isSelected,
        label: label,
        child: SizedBox(
          height: 48,
          child: InkWell(
            onTap: () => setState(() {
              _selectedTabIndex = index;
            }),
            borderRadius: BorderRadius.circular(7),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? CaslaColors.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 3,
                        ),
                      ]
                    : null,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: isSelected
                      ? CaslaColors.primaryNavy
                      : CaslaColors.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SyncSkeleton extends StatelessWidget {
  const _SyncSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Row(
          children: [
            Expanded(child: CaslaSkeleton(height: 62, radius: 8)),
            SizedBox(width: 8),
            Expanded(child: CaslaSkeleton(height: 62, radius: 8)),
            SizedBox(width: 8),
            Expanded(child: CaslaSkeleton(height: 62, radius: 8)),
          ],
        ),
        const SizedBox(height: 14),
        const CaslaSkeleton(height: 44, radius: 10),
        const SizedBox(height: 14),
        for (var index = 0; index < 4; index++) ...[
          const CaslaSkeleton(height: 62, radius: 10),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}
