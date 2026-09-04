// Tab shell for the worker role (PP_HIST_SELF/TEAM only) — mirrors
// SupervisorShell's IndexedStack + bottom nav pattern, just with the two
// tabs this role actually has: read-only history, and the same account
// screen the supervisor uses (it already branches its own content by role).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../main.dart';
import '../../account/screens/s13_account_screen.dart';
import '../../account/widgets/change_password_dialog.dart';
import '../../worker/screens/w01_history_screen.dart';

class WorkerShell extends ConsumerStatefulWidget {
  const WorkerShell({super.key});

  @override
  ConsumerState<WorkerShell> createState() => _WorkerShellState();
}

class _WorkerShellState extends ConsumerState<WorkerShell> {
  int _currentIndex = 0;
  bool _hasCheckedMandatoryPassword = false;

  @override
  void initState() {
    super.initState();
    // Same check S06SupervisorOverviewScreen does for the supervisor role —
    // a worker account can just as well log in with PasswordChangeRequired
    // set (confirmed against a real account: 'duck', Status 'P').
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hasCheckedMandatoryPassword && mounted) {
        _hasCheckedMandatoryPassword = true;
        final session = ref.read(appStateProvider).currentSession;
        if (session?.passwordChangeRequired == true) {
          showChangePasswordDialog(context, isMandatory: true, ref: ref);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [W01HistoryScreen(), S13AccountScreen()],
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
          onTap: (index) => setState(() => _currentIndex = index),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.history),
              label: 'Lịch sử',
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
