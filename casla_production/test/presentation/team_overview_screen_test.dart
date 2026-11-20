import 'package:casla_production/app/theme/casla_theme.dart';
import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/sap_shift_controller.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/features/shared/screens/worker_shell.dart';
import 'package:casla_production/features/worker/screens/w02_team_overview_screen.dart';
import 'package:casla_production/main.dart';
import 'package:casla_production/presentation/widgets/worker_search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/database_test_harness.dart';

class _History implements WorkHistoryRepositoryImpl {
  WorkHistoryResult? result;
  final requestedWorkIds = <String?>[];

  @override
  Stream<WorkHistoryResult> watchWorkHistory({
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? shiftId,
    String? workId,
    String? productionOrder,
    String? operation,
  }) {
    requestedWorkIds.add(workId);
    return Stream.value(result!);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _State extends ChangeNotifier implements AppState {
  _State(this.session);

  final UserSession session;

  @override
  final _History workHistoryRepo = _History();
  @override
  UserSession? get currentSession => session;
  @override
  UserWorkContext? get activeWorkContext => null;
  @override
  SapShift? get activeShift => null;
  @override
  DateTime get activeBusinessDate => DateTime(2026, 10, 23);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UserSession _session(Set<Permission> permissions) => UserSession(
  id: 'u',
  maNv: 'CL400111',
  fullName: 'Tổ trưởng ca',
  teamName: '',
  role: UserRole.worker,
  permissions: permissions,
);

WorkHistoryEntry _row(
  String uuid,
  String type,
  double quantity, {
  required int minute,
  String workerId = 'CL400001',
  String workId = 'XM1',
}) => WorkHistoryEntry(
  transactionUuid: uuid,
  executionDate: DateTime(2026, 10, 23, 8, minute),
  reportedWorkDate: DateTime(2026, 10, 23),
  workerId: workerId,
  workerName: '',
  productionOrder: '010140000380',
  operation: '0010',
  plant: '1000',
  workCenter: 'CL100077',
  workId: workId,
  transactionType: type,
  quantity: quantity,
  unitOfMeasure: 'CHC',
  transactionStatus: 'POSTED',
);

WorkHistorySummary _summary(
  String id,
  String name, {
  required double given,
  required double completed,
  required double remaining,
  double defect = 0,
  String workId = 'XM1',
  String workName = '',
}) => WorkHistorySummary(
  workerId: id,
  workerName: name,
  assignedQuantity: given,
  completedQuantity: completed,
  defectQuantity: defect,
  remainingQuantity: remaining,
  unitOfMeasure: 'CHC',
  transactionCount: 2,
  workId: workId,
  workName: workName,
);

/// Chi: 1.000 given, 1.500 confirmed, 700 given, 200 confirmed. SAP's
/// remaining says 0, the seat still holds 500. Thu, in XM2: 300 open.
WorkHistoryResult _team() => WorkHistoryResult(
  scopeCode: 'T',
  dateFrom: DateTime(2026, 10, 23),
  dateTo: DateTime(2026, 10, 23),
  isTruncated: false,
  entries: [
    _row('a1', 'INITIAL_ASSIGN', 1000, minute: 0),
    _row('c1', 'CONFIRM', 1000, minute: 1),
    _row('a2', 'INITIAL_ASSIGN', 700, minute: 2),
    _row('c2', 'CONFIRM', 200, minute: 3),
    _row(
      'b1',
      'INITIAL_ASSIGN',
      300,
      minute: 4,
      workerId: 'CL400082',
      workId: 'XM2',
    ),
  ],
  workers: [
    _summary(
      'CL400001',
      'Đỗ Thị Chi',
      given: 1700,
      completed: 1700,
      remaining: 0,
      workName: 'Giải chuyền 1',
    ),
    _summary(
      'CL400082',
      'Đinh Thị Thu',
      given: 300,
      completed: 0,
      remaining: 300,
      workId: 'XM2',
      workName: 'May quai lập trình',
    ),
  ],
);

Future<_State> _pumpOverview(
  WidgetTester tester, {
  WorkHistoryResult? result,
}) async {
  tester.view.physicalSize = const Size(420, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = _State(_session({Permission.viewTeamProductionHistory}));
  state.workHistoryRepo.result = result ?? _team();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, routeState) => const W02TeamOverviewScreen(),
      ),
      GoRoute(
        path: '/history/worker',
        builder: (context, routeState) {
          final extra = routeState.extra! as Map<String, dynamic>;
          return Scaffold(
            body: Text('history of ${extra['code']} ${extra['range']}'),
          );
        },
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appStateProvider.overrideWith((ref) => state)],
      child: MaterialApp.router(theme: CaslaTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  // The scan listener keeps its reader preferences in SQLite.
  useInMemoryDatabase();

  group('teamOverviewWorkers', () {
    test(
      'remaining is the sum of the worker rows: 1000 - 1000 + 700 - 200',
      () {
        final workers = teamOverviewWorkers(_team());
        final chi = workers.firstWhere((w) => w.code == 'CL400001');
        expect(chi.remaining, 500);
        expect(chi.department, 'Giải chuyền 1');
        // Both have work: by name.
        expect(workers.map((w) => w.code), ['CL400082', 'CL400001']);
      },
    );

    test('a cut report keeps SAP remaining', () {
      final team = _team();
      final cut = WorkHistoryResult(
        scopeCode: team.scopeCode,
        dateFrom: team.dateFrom,
        dateTo: team.dateTo,
        isTruncated: true,
        entries: team.entries,
        workers: team.workers,
      );
      final chi = teamOverviewWorkers(
        cut,
      ).firstWhere((w) => w.code == 'CL400001');
      expect(chi.remaining, 0);
    });
  });

  group('workerCodeFromScan', () {
    test('reads a worker QR and a bare printed code', () {
      expect(
        workerCodeFromScan('{"ma_nv":"cl400082","ten":"Đinh Thị Thu"}'),
        'CL400082',
      );
      expect(workerCodeFromScan(' cl400082 '), 'CL400082');
    });

    test('refuses what cannot be a worker code', () {
      expect(workerCodeFromScan(''), isNull);
      expect(workerCodeFromScan('G05@M105 not a worker'), isNull);
    });
  });

  testWidgets('one card per worker, narrowed by department', (tester) async {
    final state = await _pumpOverview(tester);

    // The whole authorized scope is asked of SAP.
    expect(state.workHistoryRepo.requestedWorkIds, [null]);
    expect(find.text('Đỗ Thị Chi'), findsOneWidget);
    expect(find.text('Đinh Thị Thu'), findsOneWidget);
    // The overview's card: five columns, the seat's 500 under Còn lại.
    expect(find.text('Hoàn thành'), findsNWidgets(2));
    expect(find.text('500'), findsOneWidget);
    expect(find.text('ĐANG THỰC HIỆN'), findsNWidgets(2));
    expect(find.text('2 NV được giao'), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-work-filter')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('history-department-search')),
      'xm2',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('May quai lập trình'));
    await tester.pumpAndSettle();

    expect(find.text('Tổ: May quai lập trình · XM2'), findsOneWidget);
    expect(find.text('Đinh Thị Thu'), findsOneWidget);
    expect(find.text('Đỗ Thị Chi'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the confirmed total counts scrap beside good output', (
    tester,
  ) async {
    await _pumpOverview(
      tester,
      result: WorkHistoryResult(
        scopeCode: 'T',
        dateFrom: DateTime(2026, 10, 23),
        dateTo: DateTime(2026, 10, 23),
        isTruncated: false,
        entries: const [],
        workers: [
          _summary(
            'CL400001',
            'Đỗ Thị Chi',
            given: 1000,
            completed: 480,
            defect: 5,
            remaining: 515,
          ),
        ],
      ),
    );

    expect(find.text('Đã xác nhận'), findsOneWidget);
    expect(find.text('Đã hoàn thành'), findsNothing);
    // 480 good and 5 scrapped: 485 above, still apart on the card.
    expect(find.text('485'), findsOneWidget);
    expect(find.text('480'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('searching by code and opening a worker history', (tester) async {
    await _pumpOverview(tester);

    await tester.enterText(
      find.byKey(const Key('history-worker-search')),
      '0082',
    );
    await tester.pumpAndSettle();
    expect(find.text('Đỗ Thị Chi'), findsNothing);

    await tester.tap(find.byKey(const Key('team-worker-CL400082-CHC')));
    await tester.pumpAndSettle();
    expect(find.text('history of CL400082 HistoryRange.day'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the overview tab is there only with team history', (
    tester,
  ) async {
    Future<void> pumpShell(Set<Permission> permissions) async {
      final state = _State(_session(permissions));
      state.workHistoryRepo.result = _team();
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [appStateProvider.overrideWith((ref) => state)],
          child: MaterialApp(
            theme: CaslaTheme.light,
            home: const WorkerShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpShell({Permission.viewTeamProductionHistory});
    expect(find.text('Tổng quan'), findsWidgets);
    expect(find.text('Tìm kiếm'), findsOneWidget);
    expect(find.byType(W02TeamOverviewScreen), findsOneWidget);

    await pumpShell({Permission.viewOwnProductionHistory});
    expect(find.byType(W02TeamOverviewScreen), findsNothing);
    expect(find.text('Tìm kiếm'), findsNothing);
    expect(find.text('Lịch sử sản lượng'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
