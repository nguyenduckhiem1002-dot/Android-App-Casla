import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/enums.dart';
import '../../../main.dart';

class S13AccountScreen extends ConsumerWidget {
  const S13AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appState = ref.watch(appStateProvider);
    final emp = appState.currentSession;
    final userName = emp?.userName ?? 'Nguyễn Văn A';
    final userCode = emp?.maNv ?? 'MNV00123';
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
          'Tài khoản',
          style: TextStyle(
            fontFamily: 'Manrope',
            fontWeight: FontWeight.w700,
            fontSize: 16,
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
                          : 'A',
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
                  const SizedBox(height: 2),
                  Text(
                    userCode,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: CaslaColors.identityMeta,
                    ),
                  ),
                  const SizedBox(height: 8),
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

            // Settings Group
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
                    'Quyền hạn của tài khoản',
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
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  _buildSettingRow('Phạm vi quản lý', 'Tổ Cắt 1–3'),
                  _buildSettingRow('Mã thiết bị', 'PDA-CT02-A17'),
                  _buildSettingRow('Đồng bộ lần cuối', 'Hôm nay 10:45'),
                  _buildSettingRow('Phiên bản app', 'v1.0.0 (MVP)'),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Action Buttons
            OutlinedButton(
              onPressed: () {
                appState.logout();
                context.go('/login');
              },
              child: const Text('Đổi người dùng'),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () {
                appState.logout();
                context.go('/login');
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: CaslaColors.danger,
                foregroundColor: Colors.white,
              ),
              child: const Text('Đăng xuất'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12.5, color: CaslaColors.muted),
          ),
          Text(
            value,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              color: CaslaColors.primaryNavy,
            ),
          ),
        ],
      ),
    );
  }
}
