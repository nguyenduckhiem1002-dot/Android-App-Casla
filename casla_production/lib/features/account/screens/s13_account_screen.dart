import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../core/auth/session_manager.dart';
import '../../../domain/entities/enums.dart';
import '../../../core/utils/device_info.dart';
import '../../../main.dart';
import '../widgets/change_password_dialog.dart';
import '../widgets/scanner_settings_card.dart';

class S13AccountScreen extends ConsumerStatefulWidget {
  const S13AccountScreen({super.key});

  @override
  ConsumerState<S13AccountScreen> createState() => _S13AccountScreenState();
}

class _S13AccountScreenState extends ConsumerState<S13AccountScreen> {
  bool _isRefreshingCache = false;
  bool _cacheInfoExpanded = false;
  String? _cacheRefreshMessage;
  bool _cacheRefreshFailed = false;

  Future<void> _refreshProductionCache() async {
    if (_isRefreshingCache) return;
    setState(() {
      _isRefreshingCache = true;
      _cacheRefreshMessage = null;
    });
    try {
      final result = await ref
          .read(appStateProvider)
          .refreshProductionDataCache();
      if (!mounted) return;
      setState(() {
        _cacheRefreshMessage =
            'Đã cập nhật ${result.entries.length} giao dịch từ SAP.';
        _cacheRefreshFailed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cacheRefreshMessage =
            'Chưa làm mới được. Dữ liệu đang có vẫn được giữ; hãy thử lại khi kết nối SAP ổn định.';
        _cacheRefreshFailed = true;
      });
    } finally {
      if (mounted) setState(() => _isRefreshingCache = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final appState = ref.watch(appStateProvider);
    final emp = appState.currentSession;
    final userName = emp?.fullName ?? emp?.userName ?? 'Người dùng';
    final userCode = emp?.maNv ?? 'Chưa có mã';
    final userEmail = emp?.email.isNotEmpty == true
        ? emp!.email
        : 'Chưa cập nhật';
    final managementScope = emp?.teamName.isNotEmpty == true
        ? emp!.teamName
        : (emp?.toIds.isNotEmpty == true
              ? emp!.toIds.join(', ')
              : 'Chưa được phân phạm vi');
    final role = (emp?.role ?? UserRole.worker).label.toUpperCase();
    final permissions = (emp?.permissions ?? const <Permission>{})
        .map(_permissionLabel)
        .toList();

    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        backgroundColor: CaslaColors.primaryNavy,
        foregroundColor: Colors.white,
        title: const Text(
          'Tài khoản SAP',
          style: TextStyle(
            fontFamily: 'Manrope',
            fontWeight: FontWeight.w800,
            fontSize: 19,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            // Profile Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [CaslaColors.primaryNavy, CaslaColors.navy700],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [CaslaColors.accentGold, CaslaColors.gold700],
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      userName.isNotEmpty
                          ? userName.split(' ').last[0].toUpperCase()
                          : 'B',
                      style: const TextStyle(
                        fontFamily: 'Manrope',
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                        color: CaslaColors.navy900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    userName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tài khoản: $userCode',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: CaslaColors.identityMeta,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    userEmail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      role,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),

            // Settings & Account Info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: CaslaColors.surface,
                border: Border.all(color: CaslaColors.line),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Thông tin chi tiết SAP',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildSettingRow('Họ và tên', userName),
                  _buildSettingRow('Tài khoản SAP', userCode),
                  _buildSettingRow('Email liên hệ', userEmail),
                  _buildSettingRow('Phạm vi quản lý', managementScope),
                  _buildSettingRow(
                    'Mã thiết bị PDA',
                    DeviceInfoHelper.deviceId,
                  ),

                  const SizedBox(height: 14),
                  const Divider(height: 1),
                  const SizedBox(height: 14),

                  const Text(
                    'Quyền hạn tài khoản',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (permissions.isEmpty)
                    const Text(
                      'Chưa có quyền ứng dụng nào được cấp.',
                      style: TextStyle(color: CaslaColors.muted, fontSize: 12),
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: permissions.map((p) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: CaslaColors.muted100,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            p,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Action Buttons
            const ScannerSettingsCard(),
            const SizedBox(height: 12),
            _buildCacheRefreshCard(appState),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () {
                showChangePasswordDialog(context, ref: ref);
              },
              icon: const Icon(Icons.lock_reset_rounded, size: 18),
              label: const Text('Đổi mật khẩu'),
              style: ElevatedButton.styleFrom(
                backgroundColor: CaslaColors.primaryNavy,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => _confirmLogout(context, ref),
              child: const Text('Đăng xuất'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCacheRefreshCard(AppState appState) {
    final date = appState.activeBusinessDate;
    final dateLabel =
        '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
    final shift = appState.activeShift;
    final work = appState.activeWorkContext;
    final scopeLabel = [
      dateLabel,
      if (shift != null)
        shift.shiftName.trim().isNotEmpty
            ? shift.shiftName.trim()
            : shift.shiftId,
      if (work != null)
        work.workName.trim().isNotEmpty ? work.workName.trim() : work.workId,
    ].join(' · ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: CaslaColors.surface,
        border: Border.all(color: CaslaColors.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(
                Icons.storage_rounded,
                color: CaslaColors.primaryNavy,
                size: 20,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Dữ liệu sản lượng',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: CaslaColors.primaryNavy,
                  ),
                ),
              ),
              IconButton(
                tooltip: _isRefreshingCache
                    ? 'Đang làm mới dữ liệu'
                    : 'Làm mới dữ liệu SAP',
                onPressed: _isRefreshingCache ? null : _refreshProductionCache,
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                icon: _isRefreshingCache
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
              IconButton(
                tooltip: _cacheInfoExpanded ? 'Thu gọn' : 'Xem giải thích',
                onPressed: () =>
                    setState(() => _cacheInfoExpanded = !_cacheInfoExpanded),
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                icon: Icon(
                  _cacheInfoExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: CaslaColors.muted,
                ),
              ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _cacheInfoExpanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Tải lại lịch sử từ SAP khi số liệu chưa khớp. '
                          'Cache cũ được giữ nếu làm mới thất bại; '
                          'giao dịch chờ đồng bộ không bị xóa.',
                          style: TextStyle(
                            color: CaslaColors.muted,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          scopeLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: CaslaColors.primaryNavy,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (_cacheRefreshMessage case final message?) ...[
                          const SizedBox(height: 8),
                          Semantics(
                            liveRegion: true,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  _cacheRefreshFailed
                                      ? Icons.error_outline_rounded
                                      : Icons.check_circle_outline_rounded,
                                  size: 18,
                                  color: _cacheRefreshFailed
                                      ? CaslaColors.danger
                                      : CaslaColors.success,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    message,
                                    style: TextStyle(
                                      color: _cacheRefreshFailed
                                          ? CaslaColors.danger
                                          : CaslaColors.success,
                                      fontSize: 12,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12.5, color: CaslaColors.muted),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Đăng xuất?'),
        content: const Text(
          'Các giao dịch chưa đồng bộ vẫn được giữ an toàn trên thiết bị.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Ở lại'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Đăng xuất'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(appStateProvider).logout();
    if (context.mounted) context.go('/login');
  }

  String _permissionLabel(Permission permission) => switch (permission) {
    Permission.assignQuantity => 'Giao chỉ tiêu số lượng',
    Permission.recallAssignment => 'Thu hồi phân công',
    Permission.viewTeamProduction => 'Xem sản lượng tổ',
    Permission.viewEmployeeHistory => 'Xem lịch sử công nhân',
    Permission.viewSyncStatus => 'Xem trạng thái đồng bộ',
    Permission.switchUser => 'Chuyển công nhân',
    Permission.viewOwnProductionHistory => 'Xem lịch sử bản thân',
    Permission.viewTeamProductionHistory => 'Xem lịch sử tổ',
    Permission.managePositions => 'Quản lý vị trí công nhân',
  };
}
