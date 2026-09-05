// Tab shell for the worker role (PP_HIST_SELF/TEAM only) — mirrors
// SupervisorShell's IndexedStack + bottom nav pattern, just with the two
// tabs this role actually has: read-only history, and the same account
// screen the supervisor uses (it already branches its own content by role).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/casla_colors.dart';
import '../../account/screens/s13_account_screen.dart';
import '../../worker/screens/w01_history_screen.dart';

class WorkerShell extends ConsumerStatefulWidget {
  const WorkerShell({super.key});

  @override
  ConsumerState<WorkerShell> createState() => _WorkerShellState();
}

class _WorkerShellState extends ConsumerState<WorkerShell> {
  int _currentIndex = 0;
  final Set<int> _visitedTabIndices = {0};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          const W01HistoryScreen(),
          _visitedTabIndices.contains(1)
              ? TickerMode(
                  enabled: _currentIndex == 1,
                  child: const S13AccountScreen(),
                )
              : const SizedBox.shrink(),
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
          onTap: (index) => setState(() {
            _currentIndex = index;
            _visitedTabIndices.add(index);
          }),
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
