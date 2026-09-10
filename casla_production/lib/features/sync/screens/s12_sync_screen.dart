import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/theme/casla_spacing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../core/database/casla_database.dart';
import '../../../core/sync/verified_sync_coordinator.dart';
import '../../../main.dart';
import '../../../presentation/widgets/status_chip.dart';
import '../../../presentation/widgets/worker_verification_dialog.dart';
import '../../../presentation/widgets/casla_empty_state.dart';
import '../../../presentation/widgets/casla_skeleton.dart';

class S12SyncScreen extends ConsumerStatefulWidget {
  const S12SyncScreen({super.key});

  @override
  ConsumerState<S12SyncScreen> createState() => _S12SyncScreenState();
}

class _S12SyncScreenState extends ConsumerState<S12SyncScreen> {
  int _selectedTabIndex = 0;
  final Set<String> _syncingIds = <String>{};
  StreamSubscription<SyncFeedPage>? _feedSubscription;
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
  bool _isReleasingBackoff = false;
  bool _isBulkVerifying = false;

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
    _actorId = actorId;
    _teamIds = normalizedTeams;
    _feedItems = const [];
    _feedLoading = true;
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
          _replaceFirstPage,
          onError: (Object error, StackTrace _) {
            if (!mounted) return;
            setState(() {
              _feedError = error;
              _feedLoading = false;
            });
          },
        );
  }

  void _replaceFirstPage(SyncFeedPage page) {
    if (!mounted) return;
    setState(() {
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
  }

  Future<void> _loadMore() async {
    if (_feedLoadingMore || !_feedHasMore) return;
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
      if (!mounted) return;
      setState(() {
        _feedItems = [..._feedItems, ...page.items];
        _feedHasMore = page.hasMore;
        _nextCreatedAtUtc = page.nextCreatedAtUtc;
        _nextId = page.nextId;
        _feedLoadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _feedLoadingMore = false);
    }
  }

  @override
  void dispose() {
    unawaited(_feedSubscription?.cancel());
    super.dispose();
  }

  bool _isVerifiable(Map<String, dynamic> item) =>
      item['status'] == 'NEEDS_VERIFICATION' ||
      item['last_error_code'] == 'WORKER_AUTH_FAILED';

  /// Returns true when a password was entered and the chain was sent.
  ///
  /// [silent] suppresses the per-item snackbar so a bulk run reports once at
  /// the end rather than flashing a message per worker.
  Future<bool> _verify(Map<String, dynamic> item, {bool silent = false}) async {
    final appState = ref.read(appStateProvider);
    final id = item['id'] as String;
    final generation = appState.sessionGeneration;
    if (_syncingIds.contains(id)) return false;
    setState(() => _syncingIds.add(id));
    try {
      final workerName = await _workerNameForItem(item);
      if (!mounted) return false;

      final password = await showWorkerVerificationDialog(
        context,
        workerName: workerName,
        actionLabel: 'xác minh và gửi các giao dịch đang chờ lên SAP',
      );
      if (!mounted || password == null) return false;
      if (!appState.isSessionGenerationCurrent(generation)) return false;

      final report = await appState.verifiedSync.syncVerifiedWorkerChain(
        anchorQueueItemId: id,
        workerPassword: password,
      );
      if (!mounted) return false;

      final color = switch (report.outcome) {
        VerifiedSyncOutcome.synced => CaslaColors.success,
        VerifiedSyncOutcome.queued => CaslaColors.pending,
        VerifiedSyncOutcome.rejected => CaslaColors.danger,
        VerifiedSyncOutcome.blocked ||
        VerifiedSyncOutcome.notFound => CaslaColors.gold700,
      };
      if (!silent) _snack(report.message, color);
      return report.outcome == VerifiedSyncOutcome.synced;
    } catch (_) {
      if (!mounted) return false;
      _snack(
        'Không thể xử lý lúc này. Giao dịch vẫn được lưu an toàn.',
        CaslaColors.gold700,
      );
      return false;
    } finally {
      if (mounted) setState(() => _syncingIds.remove(id));
    }
  }

  /// Sends everything retryable now instead of waiting out the backoff.
  Future<void> _retryNow() async {
    if (_isReleasingBackoff) return;
    setState(() => _isReleasingBackoff = true);
    final appState = ref.read(appStateProvider);
    try {
      final released = await appState.db.requeueForImmediateRetry(
        actorId: _actorId,
        teamIds: _teamIds,
      );
      final report = await appState.syncEngine.runOnce();
      if (!mounted) return;
      _snack(
        released == 0
            ? 'Không có giao dịch nào đang chờ gửi lại.'
            : 'Đã yêu cầu gửi lại $released giao dịch. '
                  '${report.pushed > 0 ? 'SAP đã nhận ${report.pushed}.' : 'Đang thử lại...'}',
        released == 0 ? CaslaColors.primaryNavy : CaslaColors.success,
      );
    } catch (_) {
      if (!mounted) return;
      _snack(
        'Chưa gửi lại được. Giao dịch vẫn được lưu an toàn trên thiết bị.',
        CaslaColors.gold700,
      );
    } finally {
      if (mounted) setState(() => _isReleasingBackoff = false);
    }
  }

  /// Walks the workers who have items waiting on a password, asking each once.
  ///
  /// [VerifiedSyncCoordinator.syncVerifiedWorkerChain] already drains one
  /// worker's whole chain per password, so the cost of clearing the queue is
  /// one prompt per worker rather than one per transaction. Closing a shift
  /// with twenty rows used to mean twenty prompts.
  Future<void> _verifyAll() async {
    if (_isBulkVerifying) return;
    setState(() => _isBulkVerifying = true);
    try {
      final pending = _feedItems.where(_isVerifiable).toList();
      final handledWorkers = <String>{};
      var completed = 0;

      for (final item in pending) {
        if (!mounted) return;
        final workerId = await _workerIdForItem(item);
        if (workerId == null || !handledWorkers.add(workerId)) continue;
        final done = await _verify(item, silent: true);
        if (!done) break;
        completed += 1;
      }

      if (!mounted) return;
      _snack(
        completed == 0
            ? 'Chưa xác minh được giao dịch nào.'
            : 'Đã xác minh và gửi cho $completed công nhân.',
        completed == 0 ? CaslaColors.gold700 : CaslaColors.success,
      );
    } finally {
      if (mounted) setState(() => _isBulkVerifying = false);
    }
  }

  void _snack(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  /// How long until the engine picks this row up again, for rows that are
  /// simply waiting rather than stuck.
  String? _nextRetryLabel(Map<String, dynamic> item) {
    final raw = item['next_retry_at_utc'];
    if (raw is! int) return null;
    final due = DateTime.fromMillisecondsSinceEpoch(raw);
    final remaining = due.difference(DateTime.now());
    if (remaining.isNegative) return 'Sẽ gửi lại ngay khi có kết nối';
    if (remaining.inMinutes < 1) return 'Tự gửi lại sau vài giây';
    return 'Tự gửi lại sau ${remaining.inMinutes} phút';
  }

  Future<String?> _workerIdForItem(Map<String, dynamic> item) async {
    final db = ref.read(appStateProvider).db;
    final source = await db.getSyncSourceRow(
      item['entity_type'] as String,
      item['entity_id'] as String,
    );
    if (source == null) return null;
    Map<String, dynamic>? assignment;
    if (item['entity_type'] == 'ASSIGNMENT') {
      assignment = source;
    } else {
      final assignmentId = source['phan_cong_id'] as String?;
      if (assignmentId != null) {
        assignment = await db.getAssignmentById(assignmentId);
      }
    }
    return assignment?['nhan_vien_id'] as String?;
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

  String _secondaryText(Map<String, dynamic> item, {required bool isPending}) {
    final device = item['device_id']?.toString().trim();
    final prefix = device?.isNotEmpty == true ? '$device · ' : '';
    final error = item['last_error_message']?.toString().trim();

    // A failed row is not a dead end: the engine keeps retrying on a backoff.
    // Saying so, with the actual schedule, is the difference between "broken"
    // and "waiting".
    if (error != null && error.isNotEmpty) {
      final retry = _nextRetryLabel(item);
      return retry == null ? error : '$error · $retry';
    }
    if (isPending) {
      return '$prefix'
          'Đã lưu an toàn · '
          '${_nextRetryLabel(item) ?? 'sẽ tự động gửi khi có kết nối'}';
    }
    return '$prefix' 'Đã lưu an toàn';
  }

  Future<void> _showFailureDetails(Map<String, dynamic> item) async {
    final code = item['last_error_code']?.toString() ?? 'ERR_UNKNOWN';
    final message =
        item['last_error_message']?.toString() ??
        'SAP đã từ chối giao dịch nhưng không trả về mô tả chi tiết.';
    final summary = item['payload_summary']?.toString() ?? 'Bản ghi';
    final entityId = item['entity_id']?.toString() ?? '';
    final device = item['device_id']?.toString() ?? 'Không rõ thiết bị';
    final diagnostics = [
      'Giao dịch: $summary',
      'Mã lỗi: $code',
      'Mô tả: $message',
      'Entity ID: $entityId',
      'Thiết bị: $device',
    ].join('\n');

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaslaRadius.lg),
        ),
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
                  fontWeight: FontWeight.w800,
                  fontSize: CaslaType.title,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                summary,
                style: const TextStyle(
                  color: CaslaColors.muted,
                  fontSize: CaslaType.body,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Mã lỗi',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: CaslaType.caption,
                ),
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
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: CaslaType.caption,
                ),
              ),
              const SizedBox(height: 5),
              SelectableText(
                message,
                style: const TextStyle(height: 1.45, fontSize: CaslaType.body),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: CaslaColors.muted100,
                  borderRadius: BorderRadius.circular(CaslaRadius.sm),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Lỗi này cần kiểm tra dữ liệu hoặc cấu hình SAP. Giao dịch vẫn được giữ trên thiết bị.',
                        style: TextStyle(
                          fontSize: CaslaType.caption,
                          height: 1.4,
                        ),
                      ),
                    ),
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

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final session = appState.currentSession;
    if (session == null) return const SizedBox.shrink();
    _ensureScopedFeed(session.maNv, session.toIds);

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Đồng bộ',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: CaslaType.title,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Theo dõi và xử lý giao dịch chưa lên SAP',
              style: TextStyle(
                fontSize: CaslaType.caption,
                fontWeight: FontWeight.w500,
                color: CaslaColors.identityMeta,
              ),
            ),
          ],
        ),
      ),
      body: _feedError != null
          ? const CaslaEmptyState(
              icon: Icons.sync_problem_outlined,
              title: 'Không tải được hàng đợi đồng bộ',
              message:
                  'Các giao dịch vẫn được lưu an toàn trên thiết bị. Hãy mở lại màn hình để thử lại.',
            )
          : _feedLoading
          ? const _SyncSkeleton()
          : _buildFeedBody(),
    );
  }

  Widget _buildFeedBody() {
    final visibleItems = _feedItems;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Summary Boxes
          Row(
            children: [
              _buildSummaryBox('$_pendingCount', 'ĐANG CHỜ', tabIndex: 1),
              const SizedBox(width: CaslaSpacing.xs),
              _buildSummaryBox(
                '$_verificationCount',
                'CẦN XÁC MINH',
                color: CaslaColors.gold700,
                tabIndex: 2,
              ),
              const SizedBox(width: CaslaSpacing.xs),
              _buildSummaryBox(
                '$_failedCount',
                'LỖI',
                color: CaslaColors.danger,
                tabIndex: 3,
              ),
            ],
          ),

          const SizedBox(height: CaslaSpacing.sm),

          _SyncActionBar(
            hasRetryable: _pendingCount + _failedCount > 0,
            verificationCount: _verificationCount,
            isRetrying: _isReleasingBackoff,
            isVerifying: _isBulkVerifying,
            onRetryNow: _retryNow,
            onVerifyAll: _verifyAll,
          ),

          const SizedBox(height: CaslaSpacing.sm),

          // Tabs Row
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: CaslaColors.muted100,
              borderRadius: BorderRadius.circular(CaslaRadius.sm),
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

          const SizedBox(height: 14),

          // List Items
          if (visibleItems.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: CaslaColors.surface,
                border: Border.all(color: CaslaColors.line),
                borderRadius: BorderRadius.circular(CaslaRadius.md),
              ),
              child: const Center(
                child: Text(
                  'Không có bản ghi nào trong mục này.',
                  style: TextStyle(
                    color: CaslaColors.muted,
                    fontSize: CaslaType.body,
                  ),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: visibleItems.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = visibleItems[index];
                final isFailed = item['status'] == 'FAILED';
                final isPending = item['status'] == 'PENDING';
                final isVerifiable = _isVerifiable(item);
                final isSyncing = _syncingIds.contains(item['id']);

                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: CaslaColors.muted100,
                          borderRadius: BorderRadius.circular(CaslaRadius.sm),
                        ),
                        child: Icon(
                          isVerifiable
                              ? Icons.lock_outline
                              : isFailed
                              ? Icons.error_outline
                              : (isPending
                                    ? Icons.access_time
                                    : Icons.check_circle_outline),
                          size: 20,
                          color: isVerifiable
                              ? CaslaColors.gold700
                              : isFailed
                              ? CaslaColors.danger
                              : (isPending
                                    ? CaslaColors.pending
                                    : CaslaColors.success),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['payload_summary'] ?? 'Bản ghi',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: CaslaType.body,
                                color: CaslaColors.primaryNavy,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _secondaryText(item, isPending: isPending),
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: CaslaType.caption,
                                color: isVerifiable
                                    ? CaslaColors.gold700
                                    : isFailed
                                    ? CaslaColors.danger
                                    : CaslaColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isVerifiable)
                        ElevatedButton(
                          onPressed: isSyncing ? null : () => _verify(item),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: CaslaColors.primaryNavy,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(82, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
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
                              : const Text(
                                  'Xác minh & gửi',
                                  style: TextStyle(fontSize: CaslaType.caption),
                                ),
                        )
                      else if (isFailed)
                        OutlinedButton(
                          onPressed: () => _showFailureDetails(item),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(72, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            foregroundColor: CaslaColors.danger,
                            side: const BorderSide(color: CaslaColors.danger),
                          ),
                          child: const Text(
                            'Chi tiết',
                            style: TextStyle(fontSize: CaslaType.caption),
                          ),
                        )
                      else
                        StatusChip(status: item['status']),
                    ],
                  ),
                );
              },
            ),
          if (_feedHasMore) ...[
            const SizedBox(height: 12),
            SizedBox(
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
          ],
        ],
      ),
    );
  }

  /// A count tile that also filters the list below it.
  ///
  /// These sat directly above a tab bar filtering on the same three states and
  /// did nothing when tapped, which is the first thing anyone tries.
  Widget _buildSummaryBox(
    String count,
    String label, {
    required int tabIndex,
    Color? color,
  }) {
    final isSelected = _selectedTabIndex == tabIndex;

    return Expanded(
      child: Semantics(
        button: true,
        selected: isSelected,
        label: '$label, $count giao dịch',
        child: InkWell(
          onTap: () => setState(() => _selectedTabIndex = tabIndex),
          borderRadius: BorderRadius.circular(CaslaRadius.sm),
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.all(CaslaSpacing.xs),
            decoration: BoxDecoration(
              color: CaslaColors.surface,
              border: Border.all(
                color: isSelected
                    ? (color ?? CaslaColors.primaryNavy)
                    : CaslaColors.line,
                width: isSelected ? 1.8 : 1,
              ),
              borderRadius: BorderRadius.circular(CaslaRadius.sm),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  count,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: CaslaType.title,
                    color: color ?? CaslaColors.primaryNavy,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: CaslaType.caption,
                    fontWeight: FontWeight.w700,
                    color: CaslaColors.muted,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
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
            borderRadius: BorderRadius.circular(CaslaRadius.sm),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? CaslaColors.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(CaslaRadius.sm),
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
                  fontSize: CaslaType.caption,
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

/// Manual controls for the two things a supervisor closing a shift wants:
/// push everything now, and clear the password-blocked backlog in one pass.
class _SyncActionBar extends StatelessWidget {
  final bool hasRetryable;
  final int verificationCount;
  final bool isRetrying;
  final bool isVerifying;
  final Future<void> Function() onRetryNow;
  final Future<void> Function() onVerifyAll;

  const _SyncActionBar({
    required this.hasRetryable,
    required this.verificationCount,
    required this.isRetrying,
    required this.isVerifying,
    required this.onRetryNow,
    required this.onVerifyAll,
  });

  @override
  Widget build(BuildContext context) {
    if (!hasRetryable && verificationCount == 0) return const SizedBox.shrink();
    final busy = isRetrying || isVerifying;

    return Row(
      children: [
        if (hasRetryable)
          Expanded(
            child: SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => onRetryNow(),
                icon: isRetrying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync, size: 18),
                label: const Text('Gửi lại ngay'),
              ),
            ),
          ),
        if (hasRetryable && verificationCount > 0)
          const SizedBox(width: CaslaSpacing.xs),
        if (verificationCount > 0)
          Expanded(
            child: SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: busy ? null : () => onVerifyAll(),
                style: FilledButton.styleFrom(
                  backgroundColor: CaslaColors.primaryNavy,
                  foregroundColor: Colors.white,
                ),
                icon: isVerifying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.lock_open_outlined, size: 18),
                label: const Text('Xác minh tất cả'),
              ),
            ),
          ),
      ],
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
