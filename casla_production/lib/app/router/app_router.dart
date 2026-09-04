import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/casla_colors.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';
import '../../main.dart';
import 'app_route_observer.dart';

import '../../features/authentication/screens/s02b_account_login_screen.dart';
import '../../features/shared/screens/supervisor_shell.dart';
import '../../features/supervisor/screens/s06b_employee_daily_detail_screen.dart';
import '../../features/supervisor/screens/s07_create_assignment_wizard_screen.dart';
import '../../features/supervisor/screens/s08_assignment_detail_screen.dart';
import '../../features/supervisor/screens/s09_recall_screen.dart';
import '../../features/supervisor/screens/s10_confirm_scan_screen.dart';
import '../../features/sync/screens/s12_sync_screen.dart';
import '../../features/shared/screens/worker_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  // `refreshListenable` below re-evaluates redirects on session changes, so the
  // router itself must not be rebuilt when AppState notifies — `watch` here would
  // construct a brand-new GoRouter on every login/logout.
  final appState = ref.read(appStateProvider);

  return GoRouter(
    initialLocation: '/login',
    observers: [appRouteObserver],
    errorBuilder: (context, state) => _RouteRecoveryScreen(
      title: 'Không tìm thấy màn hình',
      message:
          'Đường dẫn này không còn hợp lệ. Bạn có thể quay về màn hình chính để tiếp tục.',
      destination: appState.currentSession?.role == UserRole.worker
          ? '/history'
          : appState.isLoggedIn
          ? '/supervisor'
          : '/login',
    ),
    refreshListenable: appState,
    redirect: (context, state) {
      final isLoggedIn = appState.isLoggedIn;
      final isGoingToLogin = state.matchedLocation == '/login';

      if (!isLoggedIn && !isGoingToLogin) {
        return '/login';
      }

      if (isLoggedIn) {
        final session = appState.currentSession!;
        final location = state.matchedLocation;
        final homeRoute = session.role == UserRole.worker
            ? '/history'
            : '/supervisor';

        if (isGoingToLogin) {
          return homeRoute;
        }

        // A worker account only ever has the read-only history screen —
        // getWorkHistory decides self-vs-team scope server-side, so there is
        // nothing else on this role to permission-gate below.
        if (session.role == UserRole.worker) {
          return location == '/history' ? null : '/history';
        }

        final requiredPermission = switch (location) {
          '/supervisor/create_assignment' => Permission.assignQuantity,
          '/supervisor/recall_assignment' => Permission.recallAssignment,
          '/supervisor/employee_detail' => Permission.viewEmployeeHistory,
          // This screen only resolves a worker inside the supervisor's own
          // scope and opens the same team-production detail available below.
          '/supervisor/confirm_scan' => Permission.viewTeamProduction,
          '/sync' => Permission.viewSyncStatus,
          _ => Permission.viewTeamProduction,
        };
        if (!session.hasPermission(requiredPermission) &&
            location != homeRoute) {
          return homeRoute;
        }
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) {
          final initialUsername = state.extra as String?;
          return S02bAccountLoginScreen(initialUsername: initialUsername);
        },
      ),
      GoRoute(
        path: '/supervisor',
        builder: (context, state) => const SupervisorShell(),
        routes: [
          GoRoute(
            path: 'employee_detail',
            builder: (context, state) {
              final worker = state.extra;
              return worker is Map<String, dynamic>
                  ? S06bEmployeeDailyDetailScreen(worker: worker)
                  : const _RouteRecoveryScreen(
                      title: 'Thiếu thông tin công nhân',
                      message:
                          'Phiên xem chi tiết đã hết hạn. Hãy chọn lại công nhân từ màn hình tổng quan.',
                      destination: '/supervisor',
                    );
            },
          ),
          GoRoute(
            path: 'create_assignment',
            builder: (context, state) =>
                const S07CreateAssignmentWizardScreen(),
          ),
          GoRoute(
            path: 'assignment_detail',
            builder: (context, state) {
              final assignment = state.extra;
              return assignment is Assignment
                  ? S08AssignmentDetailScreen(assignment: assignment)
                  : const _RouteRecoveryScreen(
                      title: 'Thiếu thông tin phân công',
                      message:
                          'Phiên xem chi tiết đã hết hạn. Hãy mở lại phân công từ danh sách công nhân.',
                      destination: '/supervisor',
                    );
            },
          ),
          GoRoute(
            path: 'recall_assignment',
            builder: (context, state) {
              final assignment = state.extra;
              return assignment is Assignment
                  ? S09RecallScreen(assignment: assignment)
                  : const _RouteRecoveryScreen(
                      title: 'Thiếu thông tin phân công',
                      message:
                          'Không thể mở thao tác thu hồi từ đường dẫn này. Hãy chọn lại phân công cần xử lý.',
                      destination: '/supervisor',
                    );
            },
          ),
          GoRoute(
            path: 'confirm_scan',
            builder: (context, state) => const S10ConfirmScanScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/sync',
        builder: (context, state) => const S12SyncScreen(),
      ),
      GoRoute(
        path: '/history',
        builder: (context, state) => const WorkerShell(),
      ),
    ],
  );
});

class _RouteRecoveryScreen extends StatelessWidget {
  final String title;
  final String message;
  final String destination;

  const _RouteRecoveryScreen({
    required this.title,
    required this.message,
    required this.destination,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CaslaColors.background,
      appBar: AppBar(title: const Text('Casla Production')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: CaslaColors.muted100,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(
                      Icons.explore_off_outlined,
                      size: 34,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: CaslaColors.muted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => context.go(destination),
                    icon: const Icon(Icons.home_outlined),
                    label: const Text('Về màn hình chính'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
