import 'package:casla_production/app/theme/casla_theme.dart';
import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/features/worker/screens/w03_history_search_screen.dart';
import 'package:casla_production/main.dart';
import 'package:casla_production/presentation/widgets/worker_search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/database_test_harness.dart';

class _State extends ChangeNotifier implements AppState {
  @override
  UserSession? get currentSession => const UserSession(
    id: 'u',
    maNv: 'CL400111',
    fullName: 'Tổ trưởng ca',
    teamName: '',
    role: UserRole.worker,
    permissions: {Permission.viewTeamProductionHistory},
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(420, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  String describe(Object? extra) {
    final map = extra! as Map<String, dynamic>;
    return [
      for (final key in map.keys.toList()..sort()) '$key=${map[key]}',
    ].join(' ');
  }

  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const W03HistorySearchScreen(),
      ),
      GoRoute(
        path: '/history/worker',
        builder: (context, state) =>
            Scaffold(body: Text('worker ${describe(state.extra)}')),
      ),
      GoRoute(
        path: '/history/operation',
        builder: (context, state) =>
            Scaffold(body: Text('operation ${describe(state.extra)}')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appStateProvider.overrideWith((ref) => _State())],
      child: MaterialApp.router(theme: CaslaTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // The scan listener keeps its reader preferences in SQLite.
  useInMemoryDatabase();

  group('classifyHistoryScan', () {
    test('an operation label names an order and an operation', () {
      final scan = classifyHistoryScan(
        '{"ProductionOrder":"010140000380","Operation":"0010",'
        '"OperationName":"May miệng thân","UnitOfMeasure":"CHC"}',
      );
      expect(scan, isA<OperationHistoryScan>());
      final operation = scan! as OperationHistoryScan;
      expect(operation.productionOrder, '010140000380');
      expect(operation.operation, '0010');
      expect(operation.operationName, 'May miệng thân');
      expect(
        classifyHistoryScan('010140000380|0010'),
        isA<OperationHistoryScan>(),
      );
    });

    test('a worker card or a bare code is a worker', () {
      final card = classifyHistoryScan('{"ma_nv":"cl400082","ten":"Thu"}');
      expect((card! as WorkerHistoryScan).code, 'CL400082');
      expect(
        (classifyHistoryScan('CL400082')! as WorkerHistoryScan).code,
        'CL400082',
      );
    });

    test('anything else is neither', () {
      expect(classifyHistoryScan('Xâu tem qua 2 quai'), isNull);
    });
  });

  test('an operation number is padded to four digits', () {
    expect(normalizeOperationNumber('10'), '0010');
    expect(normalizeOperationNumber('0090'), '0090');
  });

  testWidgets('a typed worker code opens that worker over the period', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.text('Tuần này'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('search-worker-code')),
      'cl400082',
    );
    await tester.tap(find.byKey(const Key('search-worker-go')));
    await tester.pumpAndSettle();

    expect(
      find.text('worker code=CL400082 name= range=HistoryRange.week'),
      findsOneWidget,
    );
  });

  testWidgets('a typed order and operation open that operation', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.byKey(const Key('search-operation-go')));
    await tester.pump();
    expect(find.text('Nhập cả lệnh sản xuất và công đoạn.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('search-production-order')),
      '010140000380',
    );
    await tester.enterText(find.byKey(const Key('search-operation')), '10');
    await tester.tap(find.byKey(const Key('search-operation-go')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'operation operation=0010 operation_name= '
        'production_order=010140000380 range=HistoryRange.day',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
