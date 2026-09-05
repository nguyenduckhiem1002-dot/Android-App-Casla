import 'dart:async';

import 'package:flutter/material.dart';
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(report.message), backgroundColor: color),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Không thể xử lý lúc này. Giao dịch vẫn được lưu an toàn.',
          ),
          backgroundColor: CaslaColors.gold700,
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

  String _secondaryText(Map<String, dynamic> item, {required bool isPending}) {
    final error = item['last_error_message']?.toString().trim();
    if (error != null && error.isNotEmpty) return error;
    final device = item['device_id']?.toString().trim();
    if (isPending) {
      return '${device?.isNotEmpty == true ? '$device · ' : ''}Đã lưu an toàn · sẽ tự động gửi khi có kết nối';
    }
    return '${device?.isNotEmpty == true ? '$device · ' : ''}Đã lưu an toàn';
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
              const SizedBox(height: 6),
              Text(
                summary,
                style: const TextStyle(color: CaslaColors.muted, fontSize: 13),
              ),
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
                  color: CaslaColors.muted100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Lỗi này cần kiểm tra dữ liệu hoặc cấu hình SAP. Giao dịch vẫn được giữ trên thiết bị.',
                        style: TextStyle(fontSize: 12.5, height: 1.4),
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

          const SizedBox(height: 14),

          // Tabs Row
          Container(
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

          const SizedBox(height: 14),

          // List Items
          if (visibleItems.isEmpty)
            Container(
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
                          borderRadius: BorderRadius.circular(10),
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
                                fontSize: 13,
                                color: CaslaColors.primaryNavy,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _secondaryText(item, isPending: isPending),
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
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
                                  style: TextStyle(fontSize: 11),
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
                            style: TextStyle(fontSize: 11),
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
