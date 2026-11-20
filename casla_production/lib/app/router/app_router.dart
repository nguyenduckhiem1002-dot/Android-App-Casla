import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/casla_colors.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';
import '../../main.dart';
import 'app_route_observer.dart';

import '../../features/authentication/screens/s02b_account_login_screen.dart';
import '../../features/account/screens/mandatory_password_change_screen.dart';
import '../../features/account/screens/s13_account_screen.dart';
import '../../features/account/screens/supervisor_shift_setup_screen.dart';
import '../../features/shared/screens/supervisor_shell.dart';
import '../../features/supervisor/screens/s06b_employee_daily_detail_screen.dart';
import '../../features/supervisor/screens/s07_create_assignment_wizard_screen.dart';
import '../../features/supervisor/screens/s08_assignment_detail_screen.dart';
import '../../features/supervisor/screens/s10_confirm_scan_screen.dart';
import '../../features/supervisor/screens/s15_multi_confirm_screen.dart';
import '../../features/sync/screens/s12_sync_screen.dart';
import '../../domain/entities/work_history.dart';
import '../../features/shared/screens/worker_shell.dart';
import '../../features/worker/screens/w01_history_screen.dart';

const _skipSupervisorSetupExtra = 'skip-supervisor-setup';

/// Guarded routes that need no `extra`, so the setup screen can open them
/// again once the shift is chosen. Routes carrying an object cannot be rebuilt
/// from a URL and fall back to the overview.
const _resumableAfterSetup = {
  '/supervisor/confirm_scan',
  '/supervisor/create_assignment',
  '/supervisor/confirm_direct',
  '/sync',
};

String? _resumeTarget(GoRouterState state) {
  final next = state.uri.queryParameters['next'];
  return _resumableAfterSetup.contains(next) ? next : null;
}

final routerProvider = Provider<GoRouter>((ref) {
  // `refreshListenable` below re-evaluates redirects on session changes, so the
  // router itself must not be rebuilt when AppState notifies — `watch` here would
  // construct a brand-new GoRouter on every login/logout.
  final appState = ref.read(appStateProvider);
  // A shift edit notifies the app to refresh operational data, but does not
  // change route guards once setup is already complete. Reparsing a pushed
  // setup route on that notification can replace it before its save callback
  // pops it. Only refresh routing when authentication or setup eligibility
  // actually changes; ordinary data notifications still reach the screens.
  final routingState = ValueNotifier((
    session: appState.currentSession,
    needsSetup: appState.needsSupervisorSetup,
    restoring: appState.isRestoringSetup,
  ));
  void refreshRoutingState() {
    routingState.value = (
      session: appState.currentSession,
      needsSetup: appState.needsSupervisorSetup,
      restoring: appState.isRestoringSetup,
    );
  }

  appState.addListener(refreshRoutingState);
  ref.onDispose(() {
    appState.removeListener(refreshRoutingState);
    routingState.dispose();
  });

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
    refreshListenable: routingState,
    redirect: (context, state) {
      final isLoggedIn = appState.isLoggedIn;
      final isGoingToLogin = state.matchedLocation == '/login';
      final isPasswordChangeRoute =
          state.matchedLocation == '/password-change-required';

      if (!isLoggedIn && !isGoingToLogin) {
        return '/login';
      }

      if (isLoggedIn) {
        // Stay put until the saved shift is restored; deciding now would send
        // a supervisor with a valid setup through the setup screen and back.
        if (appState.isRestoringSetup) return null;
        final session = appState.currentSession!;
        final location = state.matchedLocation;
        final homeRoute = session.role == UserRole.worker
            ? '/history'
            : '/supervisor';

        if (session.passwordChangeRequired) {
          return isPasswordChangeRoute ? null : '/password-change-required';
        }

        if (session.role == UserRole.supervisor &&
            appState.needsSupervisorSetup &&
            state.extra != _skipSupervisorSetupExtra) {
          if (state.matchedLocation == '/supervisor-setup') return null;
          return _resumableAfterSetup.contains(location)
              ? Uri(
                  path: '/supervisor-setup',
                  queryParameters: {'next': location},
                ).toString()
              : '/supervisor-setup';
        }

        // A configured supervisor may reopen this screen from Settings to
        // change the active work context or shift. When setup was reached by
        // the auth redirect, leave it as soon as the restored selection is
        // valid; otherwise the app can remain stuck on this screen forever.
        if (state.matchedLocation == '/supervisor-setup') {
          if (state.extra == true) return null;
          return appState.needsSupervisorSetup
              ? null
              : _resumeTarget(state) ?? homeRoute;
        }

        if (isPasswordChangeRoute) return homeRoute;

        if (isGoingToLogin) {
          return homeRoute;
        }

        // A worker account only ever has the read-only history screens —
        // getWorkHistory decides self-vs-team scope server-side, so there is
        // nothing else on this role to permission-gate below. One worker's
        // history opens from the team overview (PP_HIST_TEAM).
        if (session.role == UserRole.worker) {
          return const {
                '/history',
                '/history/worker',
                '/history/operation',
              }.contains(location)
              ? null
              : '/history';
        }

        // Any one of the listed permissions opens the route; null means every
        // supervisor may open it.
        final allowedBy = switch (location) {
          // Every tab's top bar links here, including Vị trí alone.
          '/account' => null,
          '/supervisor/create_assignment' => {Permission.assignQuantity},
          // Give-and-confirm: the confirm tab shows its button only with
          // PP_CONFIRM as well; the route itself is an assignment form.
          '/supervisor/confirm_direct' => {Permission.assignQuantity},
          '/supervisor/employee_detail' => {Permission.viewEmployeeHistory},
          // Each operation screen follows its own SAP FuncID. The scan tab
          // also serves PP_RECALL: the "Xác nhận" form opens for either
          // function and shows only the entries of the ones held.
          // Multi-confirm is all confirmed-quantity entry, so PP_CONFIRM.
          '/supervisor/confirm_scan' => {
            Permission.confirmProduction,
            Permission.recallAssignment,
          },
          '/supervisor/confirm_multi' => {Permission.confirmProduction},
          '/supervisor/assignment_detail' => {
            Permission.confirmProduction,
            Permission.recallAssignment,
          },
          '/sync' => {Permission.viewSyncStatus},
          _ => {Permission.viewTeamProduction},
        };
        if (allowedBy != null &&
            !allowedBy.any(session.hasPermission) &&
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
          final initialUsername = state.extra is String
              ? state.extra as String
              : null;
          return S02bAccountLoginScreen(initialUsername: initialUsername);
        },
      ),
      GoRoute(
        path: '/password-change-required',
        builder: (context, state) => const MandatoryPasswordChangeScreen(),
      ),
      GoRoute(
        path: '/supervisor-setup',
        builder: (context, state) => SupervisorShiftSetupScreen(
          returnToPrevious: state.extra == true,
          next: _resumeTarget(state),
        ),
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
            path: 'confirm_direct',
            builder: (context, state) =>
                const S07CreateAssignmentWizardScreen(confirmImmediately: true),
          ),
          GoRoute(
            path: 'assignment_detail',
            builder: (context, state) {
              final extra = state.extra;
              final assignment =
                  extra is Map<String, dynamic> &&
                      extra['assignment'] is Assignment
                  ? extra['assignment'] as Assignment
                  : null;
              final group =
                  extra is Map<String, dynamic> && extra['group'] is List
                  ? (extra['group'] as List).whereType<Assignment>().toList()
                  : const <Assignment>[];
              return assignment != null
                  ? S08AssignmentDetailScreen(
                      assignment: assignment,
                      confirmationGroup: group,
                    )
                  : const _RouteRecoveryScreen(
                      title: 'Thiếu thông tin phân công',
                      message:
                          'Phiên xem chi tiết đã hết hạn. Hãy mở lại phân công từ danh sách công nhân.',
                      destination: '/supervisor',
                    );
            },
          ),
          GoRoute(
            path: 'confirm_scan',
            builder: (context, state) => const S10ConfirmScanScreen(),
          ),
          GoRoute(
            path: 'confirm_multi',
            builder: (context, state) {
              final extra = state.extra;
              final worker = extra is Map<String, dynamic>
                  ? extra['worker']
                  : null;
              final groups = extra is Map<String, dynamic>
                  ? extra['groups']
                  : null;
              return worker is Map<String, dynamic> &&
                      groups is List<List<Assignment>> &&
                      groups.isNotEmpty
                  ? S15MultiConfirmScreen(worker: worker, groups: groups)
                  : const _RouteRecoveryScreen(
                      title: 'Thiếu thông tin xác nhận',
                      message:
                          'Phiên xác nhận đã hết hạn. Hãy chọn lại công nhân ở tab Xác nhận.',
                      destination: '/supervisor',
                    );
            },
          ),
        ],
      ),
      GoRoute(
        path: '/sync',
        builder: (context, state) => const S12SyncScreen(),
      ),
      // Supervisors reach the account from the avatar in each tab's top bar;
      // workers keep it as a tab in WorkerShell.
      GoRoute(
        path: '/account',
        builder: (context, state) => const S13AccountScreen(),
      ),
      GoRoute(
        path: '/history',
        builder: (context, state) => const WorkerShell(),
        routes: [
          // One worker's history, from a card of the team overview.
          GoRoute(
            path: 'worker',
            builder: (context, state) {
              final extra = state.extra is Map
                  ? Map<String, dynamic>.from(state.extra as Map)
                  : const <String, dynamic>{};
              final range = extra['range'];
              return W01HistoryScreen(
                workerCode: extra['code']?.toString(),
                workerName: extra['name']?.toString(),
                initialRange: range is HistoryRange ? range : null,
              );
            },
          ),
          // One operation's history, from a scanned operation label.
          GoRoute(
            path: 'operation',
            builder: (context, state) {
              final extra = state.extra is Map
                  ? Map<String, dynamic>.from(state.extra as Map)
                  : const <String, dynamic>{};
              final range = extra['range'];
              return W01HistoryScreen(
                productionOrder: extra['production_order']?.toString(),
                operation: extra['operation']?.toString(),
                operationName: extra['operation_name']?.toString(),
                initialRange: range is HistoryRange ? range : null,
              );
            },
          ),
        ],
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
