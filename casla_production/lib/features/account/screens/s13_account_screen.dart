import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/enums.dart';
import '../../../main.dart';
import '../widgets/change_password_dialog.dart';

class S13AccountScreen extends ConsumerWidget {
  const S13AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appStateProvider);
    final emp = appState.currentSession;
    final userName = emp?.fullName ?? emp?.userName ?? 'Trần Thị B';
    final userCode = emp?.maNv ?? 'PB9_LO';
    final userEmail = emp?.email.isNotEmpty == true ? emp!.email : '$userCode@caslastone.com';
    final isSupervisor = emp?.role == UserRole.supervisor;
    final role = isSupervisor ? 'SUPERVISOR' : 'CÔNG NHÂN';

    final permissions = isSupervisor
        ? [
            'Giao chỉ tiêu số lượng',
            'Xác nhận hoàn thành',
            'Thu hồi phân công',
            'Xem sản lượng tổ',
            'Xem trạng thái đồng bộ',
          ]
        : ['Xem lịch sử bản thân'];

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
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
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
                  _buildSettingRow('Phạm vi quản lý', 'Tổ Cắt 1–3'),
                  _buildSettingRow('Mã thiết bị PDA', 'PDA-CT02-A17'),

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
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: permissions.map((p) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: CaslaColors.muted100,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          p,
                          style: const TextStyle(
                            fontSize: 10.5,
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
              onPressed: () async {
                await appState.logout();
                if (context.mounted) {
                  context.go('/login');
                }
              },
              child: const Text('Đăng xuất'),
            ),
          ],
        ),
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
}
