import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
          '/supervisor/confirm_scan' => Permission.switchUser,
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
              final worker = state.extra as Map<String, dynamic>;
              return S06bEmployeeDailyDetailScreen(worker: worker);
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
              final assignment = state.extra as Assignment;
              return S08AssignmentDetailScreen(assignment: assignment);
            },
          ),
          GoRoute(
            path: 'recall_assignment',
            builder: (context, state) {
              final assignment = state.extra as Assignment;
              return S09RecallScreen(assignment: assignment);
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
