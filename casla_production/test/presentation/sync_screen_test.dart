// End to end for the sync screen: the real S12 widget over the real SQLite
// schema and its live queue stream. Each row must show the worker, order and
// quantity behind its queue item, and follow the queue as items are written,
// sent and removed while the screen stays open.

import 'package:casla_production/app/theme/casla_theme.dart';
import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/features/sync/screens/s12_sync_screen.dart';
import 'package:casla_production/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

const _actor = 'SUP-S12';
const _team = 'XM2.S12';

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;
  late Map<String, dynamic> template;
  var sequence = 0;

  Future<String> assignment({
    String worker = 'emp-1',
    String order = 'ord-1',
    double quantity = 40,
    String team = _team,
    String actor = _actor,
  }) async {
    final id = 'asg-s12-${++sequence}';
    await db.insertAssignment({
      ...template,
      'id': id,
      'idempotency_key': id,
      'nhan_vien_id': worker,
      'don_hang_id': order,
      'to_id': team,
      'assigned_quantity': quantity,
      'unit_of_measure': 'CHC',
      'business_date': '2026-03-04',
      'shift_id': 'SHIFT_2',
      'created_by': actor,
      'sync_status': 'PENDING',
      'sap_id': null,
    });
    return id;
  }

  Future<String> production(String assignmentId, double quantity) async {
    final id = 'prod-s12-${++sequence}';
    await db.insertProductionRecord({
      'id': id,
      'phan_cong_id': assignmentId,
      'quantity': quantity,
      'unit_of_measure': 'CHC',
      'business_date': '2026-03-05',
      'shift_id': 'SHIFT_1',
      'created_by': _actor,
      'occurred_at_utc': 1,
      'device_id': 'test',
      'sync_status': 'PENDING',
      'idempotency_key': id,
      'created_at_utc': 1,
    });
    return id;
  }

  Future<String> recall(String assignmentId, double quantity) async {
    final id = 'rec-s12-${++sequence}';
    await db.insertRecallRecord({
      'id': id,
      'phan_cong_id': assignmentId,
      'quantity': quantity,
      'unit_of_measure': 'CHC',
      'reason_code': 'PLAN_CHANGE',
      'business_date': '2026-03-06',
      'shift_id': 'SHIFT_2',
      'created_by': _actor,
      'occurred_at_utc': 1,
      'device_id': 'test',
      'sync_status': 'PENDING',
      'idempotency_key': id,
      'created_at_utc': 1,
    });
    return id;
  }

  Future<String> queue(
    String entityType,
    String entityId, {
    String status = 'PENDING',
    String? errorCode,
    String? errorMessage,
  }) async {
    final id = 'q-s12-${++sequence}';
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insertSyncQueueItem({
      'id': id,
      'entity_type': entityType,
      'entity_id': entityId,
      'action': 'CREATE',
      'payload_summary': 'Bản ghi $id',
      'created_at_utc': now + sequence,
      'updated_at_utc': now + sequence,
      'status': status,
      'last_error_code': errorCode,
      'last_error_message': errorMessage,
    });
    return id;
  }

  /// Lets real SQLite work finish, then rebuilds: the database runs outside
  /// the fake clock of a widget test.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  /// [height] is tall enough for every row: the list builds lazily.
  Future<void> openScreen(WidgetTester tester, {double height = 4200}) async {
    tester.view.physicalSize = Size(420, height);
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStateProvider.overrideWith((ref) => _SyncState())],
        child: MaterialApp(
          theme: CaslaTheme.light,
          home: const S12SyncScreen(),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> prepare(WidgetTester tester) async {
    await tester.runAsync(() async {
      CaslaDatabase.resetForTesting();
      db = CaslaDatabase.instance;
      await db.ready;
      sequence = 0;
      template = (await db.getAssignmentById('asg-001'))!;
    });
  }

  Future<void> closeScreen(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  }

  testWidgets('each row shows the worker, order and quantity it stands for', (
    tester,
  ) async {
    await prepare(tester);
    await tester.runAsync(() async {
      final first = await assignment(quantity: 40);
      await queue('ASSIGNMENT', first);
      await queue('PRODUCTION', await production(first, 7));
      await queue('RECALL', await recall(first, 3));
      // A worker and an order this device has no master data for.
      await queue(
        'ASSIGNMENT',
        await assignment(worker: 'CL-NOT-HERE', order: 'ord-not-here'),
      );
    });

    await openScreen(tester);

    expect(find.text('4 giao dịch'), findsOneWidget);
    expect(find.text('Phân công · +40 CHC'), findsNWidgets(2));
    expect(find.text('Xác nhận · +7 CHC'), findsOneWidget);
    expect(find.text('Thu hồi · +3 CHC'), findsOneWidget);
    // Three rows belong to the worker on the device, by name and code.
    expect(
      find.text('Nguyễn Văn A · MNV00123', findRichText: true),
      findsNWidgets(3),
    );
    // The fourth falls back to the raw worker id.
    expect(find.text('NV CL-NOT-HERE'), findsOneWidget);
    // Order facts come from the order of the row's assignment.
    expect(find.text('000010001234 · 0010'), findsNWidgets(3));
    expect(find.text('Áo khoác gió — size L'), findsNWidgets(3));
    expect(find.text('SP-AKG'), findsNWidgets(3));
    // Date and shift are the transaction's own.
    expect(find.text('04/03/2026 · Ca đêm'), findsNWidgets(2));
    expect(find.text('05/03/2026 · Ca ngày'), findsOneWidget);
    expect(find.text('06/03/2026 · Ca đêm'), findsOneWidget);
    // No row is left on its raw queue summary.
    expect(find.textContaining('Bản ghi q-s12'), findsNothing);

    await closeScreen(tester);
  });

  testWidgets('the open screen follows writes, sends and removals', (
    tester,
  ) async {
    await prepare(tester);
    late String first;
    late String firstQueue;
    await tester.runAsync(() async {
      first = await assignment(quantity: 40);
      firstQueue = await queue('ASSIGNMENT', first);
    });

    await openScreen(tester);
    expect(find.text('1 giao dịch'), findsOneWidget);
    expect(find.text('Phân công · +40 CHC'), findsOneWidget);
    expect(find.text('Xác nhận · +7 CHC'), findsNothing);

    // A confirmation queued while the screen is open appears, hydrated.
    late String confirmation;
    late String confirmationQueue;
    await tester.runAsync(() async {
      confirmation = await production(first, 7);
      confirmationQueue = await queue('PRODUCTION', confirmation);
    });
    await settle(tester);
    expect(find.text('2 giao dịch'), findsOneWidget);
    expect(find.text('Xác nhận · +7 CHC'), findsOneWidget);
    expect(
      find.text('Nguyễn Văn A · MNV00123', findRichText: true),
      findsNWidgets(2),
    );

    // SAP accepted the assignment: its row leaves, the other stays.
    await tester.runAsync(
      () => db.markSyncItemSynced(
        firstQueue,
        entityType: 'ASSIGNMENT',
        entityId: first,
        sapId: 'SAP-1',
      ),
    );
    await settle(tester);
    expect(find.text('1 giao dịch'), findsOneWidget);
    expect(find.text('Phân công · +40 CHC'), findsNothing);
    expect(find.text('Xác nhận · +7 CHC'), findsOneWidget);

    // SAP rejected the confirmation: the same row turns into an error.
    // The summary box carries the same word, so count rather than expect one.
    final errorLabels = find.text('LỖI').evaluate().length;
    await tester.runAsync(
      () => db.updateSyncQueueError(
        confirmationQueue,
        'NO_REMAINING_QUANTITY',
        'NO_REMAINING_QUANTITY',
        status: 'FAILED',
        failureKind: 'permanent',
      ),
    );
    await settle(tester);
    expect(find.text('LỖI'), findsNWidgets(errorLabels + 1));
    expect(find.text('Xác nhận · +7 CHC'), findsOneWidget);
    expect(find.text('05/03/2026 · Ca ngày'), findsOneWidget);

    await closeScreen(tester);
  });

  testWidgets('searching by worker code narrows the list', (tester) async {
    await prepare(tester);
    await tester.runAsync(() async {
      await queue(
        'ASSIGNMENT',
        await assignment(worker: 'emp-1', quantity: 40),
      );
      await queue(
        'ASSIGNMENT',
        await assignment(worker: 'emp-2', quantity: 55),
      );
      await queue(
        'ASSIGNMENT',
        await assignment(worker: 'CL-NOT-HERE', quantity: 66),
      );
    });

    await openScreen(tester);
    expect(find.text('3 giao dịch'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'mnv00147');
    await settle(tester);
    expect(find.text('1 giao dịch'), findsOneWidget);
    expect(find.text('Phân công · +55 CHC'), findsOneWidget);
    expect(find.text('Phân công · +40 CHC'), findsNothing);

    // A worker without master data is still found by the raw id.
    await tester.enterText(find.byType(TextField), 'not-here');
    await settle(tester);
    expect(find.text('1 giao dịch'), findsOneWidget);
    expect(find.text('Phân công · +66 CHC'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await settle(tester);
    expect(find.text('3 giao dịch'), findsOneWidget);

    await closeScreen(tester);
  });

  testWidgets('another team or creator stays out of the list', (tester) async {
    await prepare(tester);
    await tester.runAsync(() async {
      await queue('ASSIGNMENT', await assignment(quantity: 40));
      await queue(
        'ASSIGNMENT',
        await assignment(quantity: 77, team: 'XM9.OTHER'),
      );
      await queue(
        'ASSIGNMENT',
        await assignment(quantity: 88, actor: 'SOMEONE-ELSE'),
      );
    });

    await openScreen(tester);

    expect(find.text('1 giao dịch'), findsOneWidget);
    expect(find.text('Phân công · +40 CHC'), findsOneWidget);
    expect(find.text('Phân công · +77 CHC'), findsNothing);
    expect(find.text('Phân công · +88 CHC'), findsNothing);

    await closeScreen(tester);
  });

  testWidgets('a full page of fifty rows is hydrated in one pass', (
    tester,
  ) async {
    await prepare(tester);
    await tester.runAsync(() async {
      final parent = await assignment(quantity: 500);
      for (var index = 0; index < 50; index++) {
        await queue('PRODUCTION', await production(parent, 1));
      }
    });

    await openScreen(tester, height: 16000);

    expect(find.text('50 giao dịch'), findsOneWidget);
    expect(find.text('Xác nhận · +1 CHC'), findsNWidgets(50));
    expect(
      find.text('Nguyễn Văn A · MNV00123', findRichText: true),
      findsNWidgets(50),
    );
    expect(find.textContaining('Bản ghi q-s12'), findsNothing);

    await closeScreen(tester);
  });
}

class _SyncState extends AppState {
  @override
  UserSession? get currentSession => const UserSession(
    id: 'sup-s12',
    maNv: _actor,
    fullName: 'Supervisor',
    teamName: 'Team',
    role: UserRole.supervisor,
    permissions: {Permission.confirmProduction},
    toIds: [_team],
  );
}
