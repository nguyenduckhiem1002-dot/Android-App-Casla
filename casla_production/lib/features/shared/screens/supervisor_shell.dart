import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/theme/casla_colors.dart';
import '../../../domain/entities/enums.dart';
import '../../../main.dart';
import '../../supervisor/screens/s06_supervisor_overview_screen.dart';
import '../../supervisor/screens/s07_create_assignment_wizard_screen.dart';
import '../../supervisor/screens/s10_confirm_scan_screen.dart';
import '../../sync/screens/s12_sync_screen.dart';
import '../../account/screens/s13_account_screen.dart';

class SupervisorShell extends ConsumerStatefulWidget {
  const SupervisorShell({super.key});

  @override
  ConsumerState<SupervisorShell> createState() => _SupervisorShellState();
}

class _SupervisorShellState extends ConsumerState<SupervisorShell> {
  int _currentIndex = 0;
  late final Stream<int> _outstandingSyncCount;

  @override
  void initState() {
    super.initState();
    _outstandingSyncCount = ref
        .read(appStateProvider)
        .db
        .watchOutstandingSyncCount();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(appStateProvider).currentSession;
    if (session == null) return const SizedBox.shrink();
    final tabs = <({Widget screen, BottomNavigationBarItem item})>[
      if (session.hasPermission(Permission.viewTeamProduction))
        (
          screen: const S06SupervisorOverviewScreen(),
          item: const BottomNavigationBarItem(
            icon: Icon(Icons.grid_view),
            label: 'Tổng quan',
          ),
        ),
      if (session.hasPermission(Permission.assignQuantity))
        (
          screen: const S07CreateAssignmentWizardScreen(),
          item: const BottomNavigationBarItem(
            icon: Icon(Icons.assignment_outlined),
            label: 'Phân công',
          ),
        ),
      if (session.hasPermission(Permission.viewTeamProduction))
        (
          screen: const S10ConfirmScanScreen(),
          item: const BottomNavigationBarItem(
            icon: Icon(Icons.qr_code_scanner),
            label: 'Xác nhận',
          ),
        ),
      if (session.hasPermission(Permission.viewSyncStatus))
        (
          screen: const S12SyncScreen(),
          item: BottomNavigationBarItem(
            icon: _SyncQueueNavigationIcon(stream: _outstandingSyncCount),
            label: 'Đồng bộ',
          ),
        ),
      (
        screen: const S13AccountScreen(),
        item: const BottomNavigationBarItem(
          icon: Icon(Icons.person_outline),
          label: 'Tài khoản',
        ),
      ),
    ];
    final selectedIndex = _currentIndex.clamp(0, tabs.length - 1);

    return Scaffold(
      body: IndexedStack(
        index: selectedIndex,
        children: tabs
            .asMap()
            .entries
            .map(
              (entry) =>
                  entry.value.screen is S10ConfirmScanScreen &&
                      selectedIndex != entry.key
                  ? const SizedBox.shrink()
                  : entry.value.screen,
            )
            .toList(),
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
          selectedFontSize: 11,
          unselectedFontSize: 11,
          onTap: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          items: tabs.map((tab) => tab.item).toList(),
        ),
      ),
    );
  }
}

class _SyncQueueNavigationIcon extends StatelessWidget {
  final Stream<int> stream;

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
