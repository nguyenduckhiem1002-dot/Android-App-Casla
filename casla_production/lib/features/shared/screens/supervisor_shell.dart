import 'package:flutter/material.dart';
import '../../../app/theme/casla_colors.dart';
import '../../supervisor/screens/s06_supervisor_overview_screen.dart';
import '../../supervisor/screens/s07_create_assignment_wizard_screen.dart';
import '../../supervisor/screens/s10_confirm_scan_screen.dart';
import '../../sync/screens/s12_sync_screen.dart';
import '../../account/screens/s13_account_screen.dart';

class SupervisorShell extends StatefulWidget {
  const SupervisorShell({super.key});

  @override
  State<SupervisorShell> createState() => _SupervisorShellState();
}

class _SupervisorShellState extends State<SupervisorShell> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          const S06SupervisorOverviewScreen(),
          const S07CreateAssignmentWizardScreen(),
          _currentIndex == 2
              ? const S10ConfirmScanScreen()
              : const SizedBox.shrink(),
          const S12SyncScreen(),
          const S13AccountScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: CaslaColors.line)),
        ),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: _currentIndex,
          selectedItemColor: CaslaColors.primaryNavy,
          unselectedItemColor: CaslaColors.muted,
          selectedFontSize: 11,
          unselectedFontSize: 11,
          onTap: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.grid_view),
              label: 'Tổng quan',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.assignment_outlined),
              label: 'Phân công',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.qr_code_scanner),
              label: 'Xác nhận',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.sync),
              label: 'Đồng bộ',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              label: 'Tài khoản',
            ),
          ],
        ),
      ),
    );
  }
}
