import 'package:flutter/material.dart';
import '../../../app/theme/casla_colors.dart';
import '../../supervisor/screens/s06_supervisor_overview_screen.dart';
import '../../supervisor/screens/s07_create_assignment_wizard_screen.dart';
import '../../sync/screens/s12_sync_screen.dart';
import '../../account/screens/s13_account_screen.dart';

class SupervisorShell extends StatefulWidget {
  const SupervisorShell({super.key});

  @override
  State<SupervisorShell> createState() => _SupervisorShellState();
}

class _SupervisorShellState extends State<SupervisorShell> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    S06SupervisorOverviewScreen(),
    S07CreateAssignmentWizardScreen(),
    S12SyncScreen(),
    S13AccountScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: CaslaColors.line)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
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
