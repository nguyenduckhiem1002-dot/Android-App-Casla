import 'package:flutter/material.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../app/theme/casla_typography.dart';
import '../../../domain/entities/entities.dart';
import '../../../domain/entities/enums.dart';
import '../../../core/auth/session_manager.dart';

class AccountScreen extends StatelessWidget {
  final UserSession session;
  final AppState appState;

  const AccountScreen({super.key, required this.session, required this.appState});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(
        title: const Text('Tài khoản', style: CaslaTypography.screenTitle),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // User Info
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: CaslaColors.line),
            ),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: CaslaColors.navy100,
                  child: Text(
                    session.fullName.substring(0, 1).toUpperCase(),
                    style: const TextStyle(fontSize: 32, color: CaslaColors.primaryNavy, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 16),
                Text(session.fullName, style: CaslaTypography.screenTitle),
                const SizedBox(height: 4),
                Text('${session.maNv} • ${session.teamName}', style: CaslaTypography.body.copyWith(color: CaslaColors.muted)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: session.role == UserRole.supervisor ? CaslaColors.accentGold.withOpacity(0.2) : CaslaColors.navy100,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    session.role == UserRole.supervisor ? 'Giám sát (Supervisor)' : 'Công nhân (Worker)',
                    style: TextStyle(
                      color: session.role == UserRole.supervisor ? CaslaColors.gold700 : CaslaColors.primaryNavy,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          
          // Device & Session Info
          const Text('THÔNG TIN PHIÊN', style: CaslaTypography.label),
          const SizedBox(height: 12),
          _buildInfoRow(Icons.phone_android, 'Thiết bị', 'Máy quét cầm tay 01'), // Mock device name
          const SizedBox(height: 12),
          _buildInfoRow(Icons.sync, 'Đồng bộ lần cuối', 'Vừa xong'),
          
          const SizedBox(height: 40),
          
          // Logout Button
          ElevatedButton.icon(
            onPressed: () async => await appState.logout(),
            icon: const Icon(Icons.logout),
            label: const Text('Đăng xuất'),
            style: ElevatedButton.styleFrom(
              backgroundColor: CaslaColors.dangerBg,
              foregroundColor: CaslaColors.danger,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String title, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CaslaColors.line),
      ),
      child: Row(
        children: [
          Icon(icon, color: CaslaColors.muted),
          const SizedBox(width: 16),
          Expanded(child: Text(title, style: CaslaTypography.body)),
          Text(value, style: CaslaTypography.body.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
