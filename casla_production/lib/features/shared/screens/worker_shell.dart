// Tab shell for the worker role (PP_HIST_SELF/TEAM only) — mirrors
// SupervisorShell's IndexedStack + bottom nav pattern, with the tabs this
// role has: an overview of the team and a search tab (only with
// PP_HIST_TEAM), the read-only
// history, and the same account screen the supervisor uses (it already
// branches its own content by role).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/enums.dart';
import '../../../main.dart';
import '../../account/screens/s13_account_screen.dart';
import '../../worker/screens/w01_history_screen.dart';
import '../../worker/screens/w02_team_overview_screen.dart';
import '../../worker/screens/w03_history_search_screen.dart';

class WorkerShell extends ConsumerStatefulWidget {
  const WorkerShell({super.key});

  @override
  ConsumerState<WorkerShell> createState() => _WorkerShellState();
}

class _Tab {
  final IconData icon;
  final String label;
  final Widget Function() build;

  const _Tab(this.icon, this.label, this.build);
}

class _WorkerShellState extends ConsumerState<WorkerShell> {
  int _currentIndex = 0;
  final Set<int> _visitedTabIndices = {0};

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(appStateProvider).currentSession;
    final team =
        session?.hasPermission(Permission.viewTeamProductionHistory) == true;
    final tabs = [
      if (team)
        _Tab(
          Icons.dashboard_outlined,
          'Tổng quan',
          () => const W02TeamOverviewScreen(),
        ),
      if (team)
        _Tab(
          Icons.manage_search,
          'Tìm kiếm',
          () => const W03HistorySearchScreen(),
        ),
      _Tab(Icons.history, 'Lịch sử', () => const W01HistoryScreen()),
      _Tab(Icons.person_outline, 'Tài khoản', () => const S13AccountScreen()),
    ];
    final index = _currentIndex.clamp(0, tabs.length - 1);

    return Scaffold(
      body: IndexedStack(
        index: index,
        children: [
          for (var i = 0; i < tabs.length; i++)
            _visitedTabIndices.contains(i)
                // A hidden tab keeps no ticker running, and its scan listener
                // stays quiet: the PDA trigger only reaches the visible tab.
                ? TickerMode(enabled: i == index, child: tabs[i].build())
                : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: CaslaColors.line)),
        ),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: index,
          selectedItemColor: CaslaColors.primaryNavy,
          unselectedItemColor: CaslaColors.muted,
          selectedFontSize: 11,
          unselectedFontSize: 11,
          onTap: (tapped) => setState(() {
            _currentIndex = tapped;
            _visitedTabIndices.add(tapped);
          }),
          items: [
            for (final tab in tabs)
              BottomNavigationBarItem(icon: Icon(tab.icon), label: tab.label),
          ],
        ),
      ),
    );
  }
}
