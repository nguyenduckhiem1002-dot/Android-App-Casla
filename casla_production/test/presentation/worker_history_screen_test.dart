import 'package:casla_production/app/theme/casla_theme.dart';
import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/core/config/app_config.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/sap/sap_shift_controller.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/features/worker/screens/w01_history_screen.dart';
import 'package:casla_production/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

/// The worker's read-only history: the day's SAP rows grouped per operation.
/// Every card must render; a throwing card shows the app's generic error box
/// in place of the worker's own figures.
class _History implements WorkHistoryRepositoryImpl {
  WorkHistoryResult? result;

  /// The WorkID of every request, in order (null for all contexts).
  final requestedWorkIds = <String?>[];

  /// `order/operation` of every request; `-` when none was asked.
  final requestedOperations = <String>[];

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
    requestedOperations.add(
      productionOrder == null ? '-' : '$productionOrder/$operation',
    );
    return Stream.value(result!);
  }

  @override
  Future<WorkHistoryResult> getWorkHistory({
    required HistoryRange range,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? shiftId,
    String? workId,
    String? productionOrder,
    String? operation,
    bool forceRefresh = false,
  }) async => result!;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _xm1 = UserWorkContext(
  workId: 'XM1',
  workName: 'Giải chuyền 1',
  workCenter: 'CL100077',
);
const _xm2 = UserWorkContext(
  workId: 'XM2',
  workName: 'May quai lập trình',
  workCenter: 'CL100077',
);

/// A department of another work center the same account may read.
const _otherWorkCenter = UserWorkContext(
  workId: 'XM9',
  workName: 'May miệng xưởng 2',
  workCenter: 'CL100078',
);

class _State extends ChangeNotifier implements AppState {
  _State({this.session, this.active});

  final UserSession? session;
  final UserWorkContext? active;

  @override
  final _History workHistoryRepo = _History();
  @override
  UserSession? get currentSession => session;
  @override
  UserWorkContext? get activeWorkContext => active;
  @override
  SapShift? get activeShift => null;
  @override
  DateTime get activeBusinessDate => DateTime(2026, 10, 23);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

WorkHistoryEntry _row(
  String uuid,
  String type,
  double quantity, {
  required int hour,
  String original = '',
  String workerId = 'CL400001',
  String workerName = 'Đỗ Thị Chi',
  String operation = '0010',
  String workId = 'XM1',
  double defect = 0,
}) => WorkHistoryEntry(
  transactionUuid: uuid,
  originalTransactionUuid: original,
  executionDate: DateTime(2026, 10, 23, hour),
  reportedWorkDate: DateTime(2026, 10, 23),
  workerId: workerId,
  workerName: workerName,
  productionOrder: '010140000380',
  operation: operation,
  operationName: 'May miệng thân 2 đường chỉ',
  productName: 'TM-SO25104467-G-HA',
  productCode: '200009410',
  salesOrder: '10001684',
  salesOrderItem: '10',
  plant: '1000',
  workCenter: 'CL100077',
  workId: workId,
  transactionType: type,
  quantity: quantity,
  defectQuantity: defect,
  unitOfMeasure: 'CHC',
  transactionStatus: 'POSTED',
);

/// An account holding PP_HIST_SELF alone: SAP reports its own rows only.
const _selfOnly = UserSession(
  id: 'self',
  maNv: 'CL400001',
  fullName: 'Đỗ Thị Chi',
  teamName: '',
  role: UserRole.worker,
  permissions: {Permission.viewOwnProductionHistory},
);

WorkHistorySummary _summary(
  String id,
  String name,
  double given, {
  String workId = 'XM1',
  String workName = '',
}) => WorkHistorySummary(
  workerId: id,
  workerName: name,
  assignedQuantity: given,
  completedQuantity: 0,
  remainingQuantity: given,
  unitOfMeasure: 'CHC',
  transactionCount: 1,
  workId: workId,
  workName: workName,
);

WorkHistoryResult _result(
  List<WorkHistoryEntry> entries, {
  String scope = 'S',
  List<WorkHistorySummary> workers = const [],
}) => WorkHistoryResult(
  scopeCode: scope,
  dateFrom: DateTime(2026, 10, 1),
  dateTo: DateTime(2026, 10, 23),
  isTruncated: false,
  entries: entries,
  workers: workers,
);

Future<void> _pump(WidgetTester tester, _State state, {Size? size}) async {
  tester.view.physicalSize = size ?? const Size(420, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appStateProvider.overrideWith((ref) => state)],
      // The app's own theme: tiles and buttons take their shape from it.
      child: MaterialApp(
        theme: CaslaTheme.light,
        home: const W01HistoryScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // The scan listener keeps its reader preferences in SQLite.
  useInMemoryDatabase();

  testWidgets('every history card renders for a day of SAP rows', (
    tester,
  ) async {
    final state = _State();
    state.workHistoryRepo.result = _result(
      [
        _row('a1', 'INITIAL_ASSIGN', 1000, hour: 8),
        _row('c1', 'CONFIRM', 1500, hour: 9, original: 'a1'),
        _row('a2', 'INITIAL_ASSIGN', 700, hour: 10, original: 'a1'),
        _row('r1', 'RECALL', 100, hour: 11, original: 'a1'),
      ],
      workers: [_summary('CL400001', 'Đỗ Thị Chi', 1700)],
    );
    await _pump(tester, state);

    expect(find.text('May miệng thân 2 đường chỉ'), findsOneWidget);
    expect(find.textContaining('Giao: 1.000 CHC'), findsOneWidget);
    expect(find.textContaining('Hoàn thành: 1.500 CHC'), findsOneWidget);
    expect(find.textContaining('Thu hồi: -100 CHC'), findsOneWidget);
    // The shift lookup is hidden while the plant runs a single shift.
    expect(
      find.textContaining('Ca tra cứu'),
      AppConfig.showShiftLookup ? findsOneWidget : findsNothing,
    );
    // One worker only: no search box, no worker line on the card.
    expect(find.byKey(const Key('history-worker-search')), findsNothing);
    // No ParentDataWidget conflict or other build-time fault anywhere.
    expect(tester.takeException(), isNull);
  });

  testWidgets('cards survive a scroll followed by a range change', (
    tester,
  ) async {
    // The TC22 fault: the list remembers its scroll offset in PageStorage and
    // a keyless ExpansionTile read that double back as its expanded flag.
    final state = _State();
    state.workHistoryRepo.result = _result([
      for (var i = 0; i < 12; i++) ...[
        _row('a$i', 'INITIAL_ASSIGN', 100, hour: 8, operation: '00${10 + i}'),
        _row('c$i', 'CONFIRM', 50, hour: 9, operation: '00${10 + i}'),
      ],
    ]);
    await _pump(tester, state, size: const Size(420, 900));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tuần này'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tháng này'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.textContaining('Giao: 100 CHC'), findsWidgets);
  });

  testWidgets('a team history is searched by worker code or name', (
    tester,
  ) async {
    final state = _State();
    state.workHistoryRepo.result = _result(
      [
        _row('a1', 'INITIAL_ASSIGN', 1000, hour: 8),
        _row(
          'b1',
          'INITIAL_ASSIGN',
          300,
          hour: 9,
          workerId: 'CL400082',
          workerName: 'Đinh Thị Thu',
        ),
      ],
      scope: 'T',
      workers: [
        _summary('CL400001', 'Đỗ Thị Chi', 1000),
        _summary('CL400082', 'Đinh Thị Thu', 300),
      ],
    );
    await _pump(tester, state);

    // Both workers, each on a card of their own.
    expect(find.text('Đỗ Thị Chi · CL400001'), findsOneWidget);
    expect(find.text('Đinh Thị Thu · CL400082'), findsOneWidget);
    // Given and left, both over the two workers.
    expect(find.text('1.300'), findsNWidgets(2));

    // Without accents or case, by name.
    await tester.enterText(
      find.byKey(const Key('history-worker-search')),
      'dinh thi',
    );
    await tester.pumpAndSettle();
    expect(find.text('Đinh Thị Thu · CL400082'), findsOneWidget);
    expect(find.text('Đỗ Thị Chi · CL400001'), findsNothing);
    expect(find.text('300'), findsWidgets);

    // By code.
    await tester.enterText(
      find.byKey(const Key('history-worker-search')),
      '400001',
    );
    await tester.pumpAndSettle();
    expect(find.text('Đỗ Thị Chi · CL400001'), findsOneWidget);
    expect(find.text('Đinh Thị Thu · CL400082'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('history-worker-search')),
      'khong co ai',
    );
    await tester.pumpAndSettle();
    expect(find.text('Không tìm thấy nhân viên phù hợp.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the department filter asks SAP for that WorkID', (tester) async {
    final state = _State(
      session: const UserSession(
        id: 'u',
        maNv: 'CL400111',
        fullName: 'Tổ trưởng',
        teamName: '',
        role: UserRole.supervisor,
        permissions: {},
        workContexts: [_xm1, _xm2],
      ),
      active: _xm1,
    );
    state.workHistoryRepo.result = _result([
      _row('a1', 'INITIAL_ASSIGN', 1000, hour: 8),
    ]);
    await _pump(tester, state);

    // SAP is asked for the whole scope; the active context is shown first,
    // labelled with its code.
    expect(state.workHistoryRepo.requestedWorkIds, [null]);
    expect(find.text('Tổ: Giải chuyền 1 · XM1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-work-filter')));
    await tester.pumpAndSettle();
    expect(find.text('XM2 · CL100077'), findsOneWidget);
    await tester.tap(find.text('May quai lập trình'));
    await tester.pumpAndSettle();
    // A complete report is narrowed on the device, not asked again.
    expect(state.workHistoryRepo.requestedWorkIds, [null]);
    expect(find.text('Tổ: May quai lập trình · XM2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('history-work-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tất cả tổ').last);
    await tester.pumpAndSettle();
    expect(state.workHistoryRepo.requestedWorkIds.last, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with a shift, the filter lists its work center only', (
    tester,
  ) async {
    final state = _State(
      session: const UserSession(
        id: 'u',
        maNv: 'CL400111',
        fullName: 'Tổ trưởng',
        teamName: '',
        role: UserRole.supervisor,
        permissions: {},
        workContexts: [_xm1, _xm2, _otherWorkCenter],
      ),
      active: _xm1,
    );
    // The history also holds a department of the other work center that the
    // session does not name.
    state.workHistoryRepo.result = _result(
      [
        _row('a1', 'INITIAL_ASSIGN', 1000, hour: 8),
        WorkHistoryEntry(
          transactionUuid: 'z1',
          executionDate: DateTime(2026, 10, 23, 9),
          reportedWorkDate: DateTime(2026, 10, 23),
          workerId: 'CL400082',
          workerName: 'Đinh Thị Thu',
          productionOrder: '010140000381',
          operation: '0020',
          plant: '1000',
          workCenter: 'CL100078',
          workId: 'XM8',
          transactionType: 'INITIAL_ASSIGN',
          quantity: 300,
          unitOfMeasure: 'CHC',
          transactionStatus: 'POSTED',
        ),
      ],
      scope: 'T',
      workers: [
        _summary('CL400001', 'Đỗ Thị Chi', 1000),
        _summary(
          'CL400082',
          'Đinh Thị Thu',
          300,
          workId: 'XM8',
          workName: 'Đóng gói xưởng 2',
        ),
      ],
    );
    await _pump(tester, state);

    await tester.tap(find.byKey(const Key('history-work-filter')));
    await tester.pumpAndSettle();
    expect(find.text('Giải chuyền 1'), findsOneWidget);
    expect(find.text('May quai lập trình'), findsOneWidget);
    expect(find.text('May miệng xưởng 2'), findsNothing);
    expect(find.text('Đóng gói xưởng 2'), findsNothing);

    // "Tất cả tổ" still shows every row SAP reported.
    await tester.tap(find.text('Tất cả tổ').last);
    await tester.pumpAndSettle();
    expect(find.text('Đinh Thị Thu · CL400082'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cut report asks SAP again for the chosen context', (
    tester,
  ) async {
    final state = _State(
      session: const UserSession(
        id: 'u',
        maNv: 'CL400111',
        fullName: 'Tổ trưởng',
        teamName: '',
        role: UserRole.supervisor,
        permissions: {},
        workContexts: [_xm1, _xm2],
      ),
      active: _xm1,
    );
    state.workHistoryRepo.result = WorkHistoryResult(
      scopeCode: 'T',
      dateFrom: DateTime(2026, 10, 1),
      dateTo: DateTime(2026, 10, 23),
      isTruncated: true,
      entries: [_row('a1', 'INITIAL_ASSIGN', 1000, hour: 8)],
      workers: const [],
    );
    await _pump(tester, state);

    await tester.tap(find.byKey(const Key('history-work-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('May quai lập trình'));
    await tester.pumpAndSettle();
    expect(state.workHistoryRepo.requestedWorkIds, [null, 'XM2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('departments come from the history and are looked up by code', (
    tester,
  ) async {
    // A worker account with one context of its own; SAP's team history
    // still spans two departments.
    final state = _State();
    state.workHistoryRepo.result = _result(
      [
        _row('a1', 'INITIAL_ASSIGN', 1000, hour: 8),
        _row(
          'b1',
          'INITIAL_ASSIGN',
          300,
          hour: 9,
          workerId: 'CL400082',
          workerName: 'Đinh Thị Thu',
          workId: 'XM2',
        ),
      ],
      scope: 'T',
      workers: [
        _summary('CL400001', 'Đỗ Thị Chi', 1000, workName: 'Giải chuyền 1'),
        _summary(
          'CL400082',
          'Đinh Thị Thu',
          300,
          workId: 'XM2',
          workName: 'May quai lập trình',
        ),
      ],
    );
    await _pump(tester, state);

    await tester.tap(find.byKey(const Key('history-work-filter')));
    await tester.pumpAndSettle();
    expect(find.text('Giải chuyền 1'), findsOneWidget);
    expect(find.text('May quai lập trình'), findsOneWidget);

    // Looked up by code in the sheet.
    await tester.enterText(
      find.byKey(const Key('history-department-search')),
      'xm2',
    );
    await tester.pumpAndSettle();
    expect(find.text('Giải chuyền 1'), findsNothing);
    await tester.tap(find.text('May quai lập trình'));
    await tester.pumpAndSettle();

    // Narrowed on the device; SAP is not asked for a WorkID it never gave.
    expect(state.workHistoryRepo.requestedWorkIds, [null]);
    expect(find.text('Tổ: May quai lập trình · XM2'), findsOneWidget);
    expect(find.text('Đinh Thị Thu · CL400082'), findsOneWidget);
    expect(find.text('Đỗ Thị Chi · CL400001'), findsNothing);

    // Back to all, then the search box finds a department by its name.
    await tester.tap(find.byKey(const Key('history-work-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tất cả tổ').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('history-worker-search')),
      'giai chuyen',
    );
    await tester.pumpAndSettle();
    expect(find.text('Đỗ Thị Chi · CL400001'), findsOneWidget);
    expect(find.text('Đinh Thị Thu · CL400082'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an operation view asks SAP for that order and operation', (
    tester,
  ) async {
    final state = _State();
    state.workHistoryRepo.result = _result([
      _row('a1', 'INITIAL_ASSIGN', 1000, hour: 8),
      _row(
        'b1',
        'INITIAL_ASSIGN',
        300,
        hour: 9,
        workerId: 'CL400082',
        workerName: 'Đinh Thị Thu',
      ),
    ], scope: 'T');
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStateProvider.overrideWith((ref) => state)],
        child: MaterialApp(
          theme: CaslaTheme.light,
          home: const W01HistoryScreen(
            productionOrder: '010140000380',
            operation: '0010',
            operationName: 'May miệng thân',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(state.workHistoryRepo.requestedOperations, ['010140000380/0010']);
    expect(
      find.text('LSX 010140000380 · CĐ 0010 · May miệng thân'),
      findsOneWidget,
    );
    // Every worker who took the operation, each on a card.
    expect(find.text('Đỗ Thị Chi · CL400001'), findsOneWidget);
    expect(find.text('Đinh Thị Thu · CL400082'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('PP_HIST_SELF alone', () {
    // The day of one worker: 1.000 given, 20 carried over, 600 good and 30
    // scrap confirmed, 100 recalled, a confirmation SAP refused.
    List<WorkHistoryEntry> day() => [
      _row('a1', 'INITIAL_ASSIGN', 1000, hour: 8),
      _row('t1', 'REASSIGN', 20, hour: 7),
      _row('c1', 'CONFIRM', 600, hour: 9, defect: 30, original: 'a1'),
      _row('r1', 'RECALL', 100, hour: 11, original: 'a1'),
      WorkHistoryEntry(
        transactionUuid: 'f1',
        executionDate: DateTime(2026, 10, 23, 12),
        reportedWorkDate: DateTime(2026, 10, 23),
        workerId: 'CL400001',
        workerName: 'Đỗ Thị Chi',
        productionOrder: '010140000380',
        operation: '0010',
        plant: '1000',
        workCenter: 'CL100077',
        workId: 'XM1',
        transactionType: 'CONFIRM',
        quantity: 999,
        unitOfMeasure: 'CHC',
        transactionStatus: 'FAILED',
      ),
    ];

    testWidgets('the totals add up: given = recalled + done + scrap + left', (
      tester,
    ) async {
      final state = _State(session: _selfOnly);
      state.workHistoryRepo.result = _result(
        day(),
        workers: const [
          WorkHistorySummary(
            workerId: 'CL400001',
            workerName: 'Đỗ Thị Chi',
            assignedQuantity: 1020,
            completedQuantity: 600,
            defectQuantity: 30,
            recalledQuantity: 100,
            remainingQuantity: 290,
            unitOfMeasure: 'CHC',
            transactionCount: 4,
            workId: 'XM1',
          ),
        ],
      );
      await _pump(tester, state);

      // The header: every figure SAP reports, scrap and recall included.
      expect(find.text('Tổng giao'), findsOneWidget);
      expect(find.text('1.020'), findsOneWidget);
      expect(find.text('Thu hồi'), findsOneWidget);
      expect(find.text('Phế'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('290'), findsOneWidget);

      // The order card carries its own figures; the refused row moves none.
      String badge(String label) => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(ValueKey('history-group-total-$label')),
              matching: find.byType(Text),
            ),
          )
          .data!;
      expect(badge('Giao'), 'Giao 1.000 CHC');
      expect(badge('Tồn chuyển'), 'Tồn chuyển 20 CHC');
      expect(badge('Hoàn thành'), 'Hoàn thành 600 CHC');
      expect(badge('Phế'), 'Phế 30 CHC');
      expect(badge('Thu hồi'), 'Thu hồi 100 CHC');
      expect(badge('Còn lại'), 'Còn lại 290 CHC');

      // The confirmation row shows its scrap next to the good quantity.
      expect(
        find.textContaining('Hoàn thành: 600 CHC · Phế 30'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a card counts rows past the visible page', (tester) async {
      final state = _State(session: _selfOnly);
      state.workHistoryRepo.result = _result([
        _row('a0', 'INITIAL_ASSIGN', 1000, hour: 6),
        for (var i = 0; i < 60; i++)
          _row('c$i', 'CONFIRM', 10, hour: 7 + i ~/ 10),
      ]);
      await _pump(tester, state);

      final completed = tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('history-group-total-Hoàn thành')),
              matching: find.byType(Text),
            ),
          )
          .data;
      expect(completed, 'Hoàn thành 600 CHC');
      // ...while only the first page of rows is listed.
      await tester.scrollUntilVisible(
        find.byKey(const Key('history-load-more')),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Xem thêm • 50/61'), findsOneWidget);
    });

    testWidgets('Hôm nay and Tuần này keep the department filter', (
      tester,
    ) async {
      final state = _State(session: _selfOnly);
      // This month: work in two departments.
      state.workHistoryRepo.result = _result(
        [
          _row('a1', 'INITIAL_ASSIGN', 100, hour: 8),
          _row('a2', 'INITIAL_ASSIGN', 200, hour: 9, workId: 'XM2'),
        ],
        workers: [
          _summary('CL400001', 'Đỗ Thị Chi', 100, workName: 'Giải chuyền 1'),
          _summary(
            'CL400001',
            'Đỗ Thị Chi',
            200,
            workId: 'XM2',
            workName: 'May quai lập trình',
          ),
        ],
      );
      await _pump(tester, state);

      await tester.tap(find.byKey(const Key('history-work-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('May quai lập trình'));
      await tester.pumpAndSettle();
      expect(find.text('Tổ: May quai lập trình · XM2'), findsOneWidget);

      // Today holds one department only; the filter stays and can change.
      state.workHistoryRepo.result = _result(
        [_row('a3', 'INITIAL_ASSIGN', 50, hour: 10)],
        workers: [
          _summary('CL400001', 'Đỗ Thị Chi', 50, workName: 'Giải chuyền 1'),
        ],
      );
      await tester.tap(find.text('Hôm nay'));
      await tester.pumpAndSettle();
      expect(find.text('Tổ: May quai lập trình · XM2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('history-work-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Giải chuyền 1'));
      await tester.pumpAndSettle();
      expect(find.text('Tổ: Giải chuyền 1 · XM1'), findsOneWidget);
      expect(find.textContaining('Giao: 50 CHC'), findsOneWidget);

      await tester.tap(find.text('Tuần này'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('history-work-filter')), findsOneWidget);
      await tester.tap(find.byKey(const Key('history-work-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tất cả tổ').last);
      await tester.pumpAndSettle();
      expect(find.text('Tổ: Tất cả tổ'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('one department alone still offers the filter', (tester) async {
      final state = _State(session: _selfOnly);
      state.workHistoryRepo.result = _result(
        [_row('a1', 'INITIAL_ASSIGN', 100, hour: 8)],
        workers: [
          _summary('CL400001', 'Đỗ Thị Chi', 100, workName: 'Giải chuyền 1'),
        ],
      );
      await _pump(tester, state);
      await tester.tap(find.text('Hôm nay'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('history-work-filter')), findsOneWidget);
    });
  });
}
