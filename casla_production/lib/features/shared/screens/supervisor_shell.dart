import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/enums.dart';
import '../../../main.dart';
import '../../supervisor/screens/s06_supervisor_overview_screen.dart';
import '../../supervisor/screens/s07_create_assignment_wizard_screen.dart';
import '../../supervisor/screens/s10_confirm_scan_screen.dart';
import '../../sync/screens/s12_sync_screen.dart';
import '../../supervisor/screens/s14_worker_position_screen.dart';

class SupervisorShell extends ConsumerStatefulWidget {
  const SupervisorShell({super.key});

  @override
  ConsumerState<SupervisorShell> createState() => _SupervisorShellState();
}

class _SupervisorShellState extends ConsumerState<SupervisorShell> {
  // Tabs are tracked by id, not position: the list is built from the
  // session's permissions, so a refreshed session can shift the positions.
  String? _currentTabId;
  final Set<String> _visitedTabIds = {};
  Stream<int>? _visibleSyncCount;
  String _syncScopeKey = '';

  void _ensureScopedSyncCount(String actorId, List<String> teamIds) {
    final normalizedTeams = teamIds.toList()..sort();
    final key = '$actorId|${normalizedTeams.join(',')}';
    if (key == _syncScopeKey && _visibleSyncCount != null) return;
    _syncScopeKey = key;
    _visibleSyncCount = ref
        .read(appStateProvider)
        .db
        .watchVisibleSyncCount(actorId: actorId, teamIds: normalizedTeams);
  }

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(appStateProvider);
    final session = appState.currentSession;
    if (session == null) return const SizedBox.shrink();
    final syncScope = <String>{...session.toIds};
    final activeWorkId = appState.activeWorkContext?.workId;
    if (activeWorkId != null && activeWorkId.trim().isNotEmpty) {
      syncScope.add(activeWorkId.trim());
    }
    _ensureScopedSyncCount(session.maNv, syncScope.toList());
    final tabs = <({String id, Widget screen, BottomNavigationBarItem item})>[
      if (session.hasPermission(Permission.viewTeamProduction))
        (
          id: 'overview',
          screen: const S06SupervisorOverviewScreen(),
          item: const BottomNavigationBarItem(
            icon: Icon(Icons.grid_view),
            label: 'Tổng quan',
          ),
        ),
      if (session.hasPermission(Permission.assignQuantity))
        (
          id: 'assign',
          screen: const S07CreateAssignmentWizardScreen(),
          item: const BottomNavigationBarItem(
            icon: Icon(Icons.assignment_outlined),
            label: 'Phân công',
          ),
        ),
      if (session.hasPermission(Permission.viewTeamProduction))
        (
          id: 'confirm',
          screen: const S10ConfirmScanScreen(),
          item: const BottomNavigationBarItem(
            icon: Icon(Icons.qr_code_scanner),
            label: 'Xác nhận',
          ),
        ),
      if (session.hasPermission(Permission.managePositions))
        (
          id: 'positions',
          screen: const S14WorkerPositionScreen(),
          item: const BottomNavigationBarItem(
            icon: Icon(Icons.place_outlined),
            activeIcon: Icon(Icons.place),
            label: 'Vị trí',
          ),
        ),
      if (session.hasPermission(Permission.viewSyncStatus))
        (
          id: 'sync',
          screen: const S12SyncScreen(),
          item: BottomNavigationBarItem(
            icon: _SyncQueueNavigationIcon(stream: _visibleSyncCount),
            label: 'Đồng bộ',
          ),
        ),
    ];
    final foundIndex = tabs.indexWhere((tab) => tab.id == _currentTabId);
    final selectedIndex = foundIndex < 0 ? 0 : foundIndex;
    _currentTabId = tabs[selectedIndex].id;
    _visitedTabIds.add(tabs[selectedIndex].id);

    return Scaffold(
      body: IndexedStack(
        index: selectedIndex,
        children: List<Widget>.generate(tabs.length, (index) {
          if (!_visitedTabIds.contains(tabs[index].id)) {
            return const SizedBox.shrink();
          }
          // An offstage hardware scanner must not consume another tab's scans.
          if (index != selectedIndex &&
              tabs[index].screen is S10ConfirmScanScreen) {
            return const SizedBox.shrink();
          }
          // Keyed so a tab keeps its state if its position ever shifts.
          return TickerMode(
            key: ValueKey(tabs[index].id),
            enabled: index == selectedIndex,
            child: tabs[index].screen,
          );
        }),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: CaslaColors.line)),
        ),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: selectedIndex,
          selectedItemColor: CaslaColors.primaryNavy,
          unselectedItemColor: CaslaColors.muted,
          selectedFontSize: 12,
          unselectedFontSize: 12,
          onTap: (index) {
            setState(() {
              _currentTabId = tabs[index].id;
              _visitedTabIds.add(tabs[index].id);
            });
          },
          items: tabs.map((tab) => tab.item).toList(),
        ),
      ),
    );
  }
}

class _SyncQueueNavigationIcon extends StatelessWidget {
  final Stream<int>? stream;

  const _SyncQueueNavigationIcon({required this.stream});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: stream,
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;
        return Badge(
          isLabelVisible: count > 0,
          label: Text(count > 99 ? '99+' : '$count'),
          child: const Icon(Icons.sync),
        );
      },
    );
  }
}
