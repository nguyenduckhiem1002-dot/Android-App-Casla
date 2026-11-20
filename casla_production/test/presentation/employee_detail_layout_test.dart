import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/domain/entities/work_history.dart';
import 'package:flutter/services.dart';
import 'package:casla_production/app/theme/casla_theme.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/features/supervisor/screens/s06b_employee_daily_detail_screen.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();
  testWidgets('populated worker quantities fit at 320dp with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.runAsync(() => CaslaDatabase.instance.ready);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith((ref) => _PopulatedHistoryState()),
        ],
        child: MaterialApp(
          theme: CaslaTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: S06bEmployeeDailyDetailScreen(
            worker: {
              'id': 'NV-1',
              'ma_nv': 'NV-1',
              'ten': 'Worker',
              'date': DateTime(2026, 9, 17),
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(find.text('11.275'), findsOneWidget);
    expect(find.text('10.000'), findsOneWidget);
    expect(find.text('1.275'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a balance carried over by SAP overnight is pinned', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.runAsync(() => CaslaDatabase.instance.ready);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith(
            (ref) => _PopulatedHistoryState(
              entries: [
                WorkHistoryEntry(
                  transactionUuid: 'RA-1',
                  executionDate: DateTime(2026, 9, 17),
                  workerId: 'NV-1',
                  workerName: 'Worker',
                  productionOrder: '010140000365',
                  operation: '0060',
                  operationName: 'May miệng',
                  plant: '1000',
                  workCenter: 'WC',
                  transactionType: 'REASSIGN',
                  quantity: 100,
                  unitOfMeasure: 'CHC',
                  transactionStatus: 'POSTED',
                ),
              ],
            ),
          ),
        ],
        child: MaterialApp(
          theme: CaslaTheme.light,
          home: S06bEmployeeDailyDetailScreen(
            worker: {
              'id': 'NV-1',
              'ma_nv': 'NV-1',
              'ten': 'Worker',
              'date': DateTime(2026, 9, 17),
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(find.text('TỒN TỪ NGÀY TRƯỚC'), findsOneWidget);
    expect(find.text('Tồn từ ngày trước 100 CHC'), findsOneWidget);
    // The carried balance is still open work.
    expect(find.text('Còn lại 100 CHC'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a seat with nothing left hides the confirm button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.runAsync(() => CaslaDatabase.instance.ready);
    final day = DateTime(2026, 10, 28);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith(
            (ref) => _PopulatedHistoryState(
              confirmer: true,
              entries: [
                // Carried over 1.000 and recalled all of it: nothing to post.
                WorkHistoryEntry(
                  transactionUuid: 'RA-1',
                  executionDate: day.add(const Duration(hours: 1)),
                  workerId: 'NV-1',
                  workerName: 'Worker',
                  productionOrder: '010140000374',
                  operation: '0060',
                  operationName: 'Gấp túi',
                  plant: '1000',
                  workCenter: 'WC',
                  transactionType: 'REASSIGN',
                  quantity: 1000,
                  unitOfMeasure: 'CHC',
                  transactionStatus: 'POSTED',
                ),
                WorkHistoryEntry(
                  transactionUuid: 'RC-1',
                  executionDate: day.add(const Duration(hours: 2)),
                  workerId: 'NV-1',
                  workerName: 'Worker',
                  productionOrder: '010140000374',
                  operation: '0060',
                  operationName: 'Gấp túi',
                  plant: '1000',
                  workCenter: 'WC',
                  transactionType: 'RECALL',
                  quantity: 1000,
                  unitOfMeasure: 'CHC',
                  transactionStatus: 'POSTED',
                ),
                // Another seat still open on the same day keeps its button.
                WorkHistoryEntry(
                  transactionUuid: 'RA-2',
                  executionDate: day.add(const Duration(hours: 1)),
                  workerId: 'NV-1',
                  workerName: 'Worker',
                  productionOrder: '010140000380',
                  operation: '0080',
                  operationName: 'May chặn',
                  plant: '1000',
                  workCenter: 'WC',
                  transactionType: 'REASSIGN',
                  quantity: 100,
                  unitOfMeasure: 'CHC',
                  transactionStatus: 'POSTED',
                ),
              ],
            ),
          ),
        ],
        child: MaterialApp(
          theme: CaslaTheme.light,
          home: S06bEmployeeDailyDetailScreen(
            worker: {
              'id': 'NV-1',
              'ma_nv': 'NV-1',
              'ten': 'Worker',
              'date': day,
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(find.text('Còn lại 0 CHC'), findsOneWidget);
    expect(find.text('Còn lại 100 CHC'), findsOneWidget);
    // One button for the open seat, none for the emptied one.
    expect(find.widgetWithText(OutlinedButton, 'Xác nhận'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Xác nhận'),
    );
    expect(button.onPressed, isNotNull);
    final openCard = find.ancestor(
      of: find.text('Còn lại 100 CHC'),
      matching: find.byType(Column),
    );
    expect(
      find.descendant(
        of: openCard.first,
        matching: find.widgetWithText(OutlinedButton, 'Xác nhận'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('worker detail renders period selector under production theme', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 886);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => CaslaDatabase.instance.ready);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: CaslaTheme.light,
          home: S06bEmployeeDailyDetailScreen(
            worker: {
              'id': 'KHIEMND1',
              'ma_nv': 'KHIEMND1',
              'ten': 'Nguyễn Đức Khiêm',
              'date_from': DateTime(2026, 9, 7),
              'date_to': DateTime(2026, 9, 10),
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Đổi ngày ▾').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Đổi ngày ▾'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Thời gian xem dữ liệu').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('history presets clamp a current week to today', () {
    final today = DateTime(2026, 9, 15);
    final monday = DateTime(2026, 9, 14);
    expect(
      clampHistoryDateToToday(
        monday.add(const Duration(days: 6)),
        today: today,
      ),
      today,
    );
    expect(clampHistoryDateToToday(monday, today: today), monday);
  });

  testWidgets('worker detail keeps a real team alias over generic department', (
    tester,
  ) async {
    await tester.runAsync(() => CaslaDatabase.instance.ready);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith((ref) => _MultiTeamAppState()),
        ],
        child: MaterialApp(
          home: S06bEmployeeDailyDetailScreen(
            worker: {
              'id': 'NV-2',
              'ma_nv': 'NV-2',
              'ten': 'Công nhân hai',
              'bo_phan': 'Công nhân sản xuất',
              'department': 'Tổ Cắt 2',
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Tổ Cắt 2'), findsOneWidget);
    expect(find.textContaining('Công nhân sản xuất'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('worker detail shows unknown team for generic department', (
    tester,
  ) async {
    await tester.runAsync(() => CaslaDatabase.instance.ready);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith((ref) => _MultiTeamAppState()),
        ],
        child: MaterialApp(
          home: S06bEmployeeDailyDetailScreen(
            worker: {
              'id': 'NV-3',
              'ma_nv': 'NV-3',
              'ten': 'Công nhân ba',
              'bo_phan': 'Công nhân sản xuất',
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Chưa xác định tổ'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _MultiTeamAppState extends AppState {
  @override
  UserWorkContext? get activeWorkContext => const UserWorkContext(
    workId: 'team-a',
    workName: 'Tổ A',
    plant: '1000',
    workCenter: 'WC-A',
    boPhan: 'Tổ A',
  );
}

class _PopulatedHistoryState extends AppState {
  _PopulatedHistoryState({this.entries = const [], this.confirmer = false});

  final List<WorkHistoryEntry> entries;

  /// Whether the signed-in account may confirm production; without it the
  /// activity card never shows the button, whatever the seat holds.
  final bool confirmer;

  @override
  UserSession? get currentSession => confirmer
      ? const UserSession(
          id: 'sup-1',
          maNv: 'SUP-1',
          fullName: 'Supervisor',
          teamName: 'Team 1',
          role: UserRole.supervisor,
          permissions: {Permission.confirmProduction},
          toIds: ['team-1'],
        )
      : null;

  @override
  WorkHistoryRepositoryImpl get workHistoryRepo => _history;
  late final _history = WorkHistoryRepositoryImpl(
    db,
    cacheSubject: () => null,
    loadRemote:
        ({
          required range,
          dateFrom,
          dateTo,
          shiftId,
          productionOrder,
          operation,
        }) async => WorkHistoryResult(
          scopeCode: 'T',
          dateFrom: dateFrom!,
          dateTo: dateTo!,
          isTruncated: false,
          entries: entries,
          workers: const [
            WorkHistorySummary(
              workerId: 'NV-1',
              workerName: 'Worker',
              assignedQuantity: 11275,
              completedQuantity: 10000,
              remainingQuantity: 1275,
              unitOfMeasure: 'CHC',
              transactionCount: 2,
            ),
          ],
        ),
  );
}
