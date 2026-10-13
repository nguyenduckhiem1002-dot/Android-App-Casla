import 'package:casla_production/core/sync/sap_write_gateway.dart';
import 'package:casla_production/data/sap/sap_position_gateway.dart';
import 'package:casla_production/data/sap/sap_shift_controller.dart';
import 'package:casla_production/domain/entities/worker_position.dart';
import 'package:casla_production/features/supervisor/screens/s10_confirm_scan_screen.dart';
import 'package:go_router/go_router.dart';
import 'dart:async';
import 'package:casla_production/core/utils/operation_qr_parser.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/app/router/app_route_observer.dart';
import 'package:casla_production/core/auth/session_manager.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/domain/entities/enums.dart';
import 'package:casla_production/main.dart';
import 'package:casla_production/presentation/widgets/qr_scanner_view.dart';

import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/scanner/barcode_scan_event.dart';
import 'package:casla_production/core/scanner/barcode_scanner.dart';
import 'package:casla_production/core/scanner/scan_feedback.dart';
import 'package:casla_production/core/scanner/scanner_preferences.dart';
import 'package:casla_production/features/supervisor/screens/s07_create_assignment_wizard_screen.dart';
import 'package:casla_production/presentation/widgets/adaptive_barcode_scanner_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

const String _workerQr =
    '{"WorkerID":"QR_FORM","WorkerName":"Worker Form","bo_phan":"Tổ QR"}';
const String _kgOperationQr =
    '{"ProductionOrder":"000001000020","Operation":"0010",'
    '"ProductName":"KG Product","UnitOfMeasure":"KG"}';
const String _pieceOperationQr =
    '{"ProductionOrder":"000001000021","Operation":"0020",'
    '"ProductName":"Other Unit","UnitOfMeasure":"cái"}';

const String _productSlotPlaceholder = 'Chưa chọn công đoạn';
const String _workerSlotPlaceholder = 'Chưa chọn công nhân';

void main() {
  useInMemoryDatabase();

  late _FakeScanner scanner;

  setUp(() async {
    ScanFeedback.setMuted(true);
    scanner = _FakeScanner();

    // A fresh in-memory store per test. Without this the worker created by
    // one test is still present in the next, so the "unknown worker" prompt
    // silently stops appearing.
    CaslaDatabase.resetForTesting();

    // Open it here, not on first use inside a test. `setUp` runs outside
    // testWidgets' fake-async zone, so the schema-creation future can actually
    // complete; started from inside a test it never resolves and the scan
    // handlers wait forever on it.
    await CaslaDatabase.instance.ready;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final suffix in ['method', 'event', 'deviceOrientation']) {
      final channel = MethodChannel(
        'dev.steenbakker.mobile_scanner/scanner/$suffix',
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'state') return 0;
        if (call.method == 'request') return false;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    for (final name in ['casla/scanner/control', 'casla/scanner/events']) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'isAvailable' ? true : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
        null,
      ),
    );
  });

  tearDown(() async {
    ScanFeedback.setMuted(false);
    await scanner.close();
  });

  Future<void> pumpAssignmentScreen(
    WidgetTester tester, {
    AppState? appState,
    PositionApi? positionApi,
  }) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (appState != null)
            appStateProvider.overrideWith((ref) => appState),
        ],
        child: MaterialApp(
          navigatorObservers: [appRouteObserver],
          home: S07CreateAssignmentWizardScreen(
            scanner: scanner,
            scannerPreferences: InMemoryScannerPreferences(),
            now: () => DateTime.utc(2026, 9, 14, 3),
            positionApi: positionApi,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Pumps in short real-time slices until [finder] matches.
  ///
  /// The scan handlers hit the real sqflite engine, whose futures only settle
  /// on the wall clock, so a fixed [WidgetTester.runAsync] window is really a
  /// guess about how fast this machine is. Waiting on the outcome instead lets
  /// the test describe the behaviour.
  ///
  /// Deliberately `pump`, not `pumpAndSettle`: settling would block on the
  /// very future being waited for.
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    for (
      var elapsed = Duration.zero;
      elapsed < timeout;
      elapsed += const Duration(milliseconds: 25)
    ) {
      if (finder.evaluate().isNotEmpty) {
        await tester.pump();
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
    fail(
      'Timed out waiting for $finder; visible text: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(" | ")}',
    );
  }

  /// Fires the reader, then waits for the screen to reflect it.
  Future<void> scan(
    WidgetTester tester,
    String payload, {
    Finder? settlesOn,
  }) async {
    await tester.runAsync(() async {
      scanner.emit(payload);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    });
    await tester.pump();
    if (settlesOn != null) await pumpUntil(tester, settlesOn);
  }

  /// Answers the "not in the catalogue" prompt raised by an unknown card.
  Future<void> answerUnknownWorkerPrompt(
    WidgetTester tester,
    String action, {
    Finder? settlesOn,
  }) async {
    await pumpUntil(tester, find.text(action));
    await tester.tap(find.text(action));
    await tester.pump();
    if (settlesOn != null) await pumpUntil(tester, settlesOn);
  }

  Future<void> scanAndConfirmWorker(WidgetTester tester, String payload) async {
    await tester.tap(find.text(_workerSlotPlaceholder));
    await tester.pump();
    await scan(tester, payload, settlesOn: find.text('Worker Form'));
    expect(find.text('Vẫn thêm'), findsNothing);
  }

  testWidgets(
    'SAP history retains local pending assignments for the same operation',
    (tester) async {
      final state = _OperationHistoryState();
      final db = CaslaDatabase.instance;
      await tester.runAsync(() async {
        final order = await db.upsertOrderFromOperationQr(
          OperationQrParser.parse(
            '{"lenh_san_xuat":"010140000032","cong_doan":"0020","sl_cong_doan":"1.200","unit":"ST"}',
          ),
        );
        final template = (await db.getAssignmentById('asg-001'))!;
        await db.createAssignmentAtomically(
          assignment: {
            ...template,
            'id': 'pending-operation',
            'don_hang_id': order!['id'],
            'assigned_quantity': 50.0,
            'sync_status': 'PENDING',
            'sap_id': null,
            'idempotency_key': 'pending-operation',
          },
          queueItem: {
            'id': 'queue-operation',
            'entity_type': 'ASSIGNMENT',
            'entity_id': 'pending-operation',
            'action': 'CREATE',
            'idempotency_key': 'pending-operation',
            'priority': 1,
            'retry_count': 0,
            'created_at_utc': 1,
          },
          auditLog: {'id': 'audit-operation', 'occurred_at_utc': 1},
        );
      });
      await pumpAssignmentScreen(tester, appState: state);
      await scan(
        tester,
        '{"lenh_san_xuat":"010140000032","cong_doan":"0020","ten_cong_doan":"May thân","sl_cong_doan":"1.200","unit":"ST"}',
        settlesOn: find.text('May thân'),
      );
      await pumpUntil(tester, find.text('800 ST'));
      expect(find.text('400 ST'), findsOneWidget);
      expect(find.text('100 ST'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('slow history does not block scanning a worker', (tester) async {
    final gate = Completer<void>();
    final state = _OperationHistoryState(gate: gate);
    await pumpAssignmentScreen(tester, appState: state);
    await scan(
      tester,
      '{"lenh_san_xuat":"010140000032","cong_doan":"0020","ten_cong_doan":"May thân","sl_cong_doan":"1.200","unit":"ST"}',
      settlesOn: find.text('May thân'),
    );
    await scanAndConfirmWorker(tester, _workerQr);
    expect(find.text('Worker Form'), findsOneWidget);
    expect(gate.isCompleted, isFalse);
    final submit = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Xác nhận phân công'),
    );
    expect(submit.onPressed, isNull);
    gate.complete();
    await pumpUntil(tester, find.text('750 ST'));
    expect(find.text('450 ST'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'cached operation from another department is selected with a warning',
    (tester) async {
      final state = _OperationHistoryState();
      state.department = 'Bộ phận A';
      await tester.runAsync(
        () => CaslaDatabase.instance.upsertOrderFromOperationQr(
          OperationQrParser.parse(
            '{"lenh_san_xuat":"010140000032","cong_doan":"0020","ten_hang":"Cached wrong department","bo_phan":"Bộ phận B","work_center":"WC"}',
          ),
        ),
      );
      await pumpAssignmentScreen(tester, appState: state);
      await tester.tap(find.byTooltip('Camera').first);
      await tester.pumpAndSettle();
      final scannerView = tester.widget<AdaptiveBarcodeScannerView>(
        find.byType(AdaptiveBarcodeScannerView),
      );
      scannerView.onManualInput!();
      await pumpUntil(tester, find.text('Cached wrong department'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Cached wrong department'));
      await tester.tap(find.text('Cached wrong department'));
      await tester.pumpAndSettle();
      // The department no longer stops the choice; it is flagged instead.
      expect(find.text(_productSlotPlaceholder), findsNothing);
      expect(
        find.textContaining(
          'thuộc bộ phận "Bộ phận B", còn ca đang chọn thuộc bộ phận "Bộ phận A"',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'department match trims edges and accepts Vietnamese unicode variants',
    (tester) async {
      final state = _OperationHistoryState()
        ..department = 'Tổ may miệng (Xưởng may 1)';
      await pumpAssignmentScreen(tester, appState: state);
      await scan(
        tester,
        '{"lenh_san_xuat":"010140000032","cong_doan":"0020",'
        '"ten_cong_doan":"May thân",'
        '"bo_phan":"  Tổ may miệng (Xưởng may 1)  ",'
        '"sl_cong_doan":"1.200","unit":"ST"}',
        settlesOn: find.text('May thân'),
      );

      expect(
        find.text('Công đoạn được giao không thuộc phiên làm việc được chọn'),
        findsNothing,
      );
      expect(find.text('May thân'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('the department warning follows the operation on the form', (
    tester,
  ) async {
    final state = _OperationHistoryState()
      ..department = 'MAY MIỆNG-XM2'
      ..workCenter = 'CL100077';
    await pumpAssignmentScreen(tester, appState: state);
    const qrB =
        '{"lenh_san_xuat":"010140000365","cong_doan":"0060",'
        '"bo_phan":"MAY LẬP TRÌNH-XM2","work_center":"CL100077","ten_cong_doan":"Công đoạn B"}';
    const qrA =
        '{"lenh_san_xuat":"010140000365","cong_doan":"0010",'
        '"bo_phan":"MAY MIỆNG-XM2","work_center":"CL100077","ten_cong_doan":"Công đoạn A"}';
    await scan(tester, qrB, settlesOn: find.text('Công đoạn B'));
    expect(
      find.textContaining('thuộc bộ phận "MAY LẬP TRÌNH-XM2"'),
      findsOneWidget,
    );

    // Scanning the right label replaces the operation and its warning.
    await scan(tester, qrA, settlesOn: find.text('Công đoạn A'));
    expect(find.text('Công đoạn B'), findsNothing);
    expect(
      find.textContaining('thuộc bộ phận "MAY LẬP TRÌNH-XM2"'),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a shared work center admits another department with a warning', (
    tester,
  ) async {
    final state = _OperationHistoryState()
      ..department = 'GẤP TÚI VIỀN-XM2'
      ..workCenter = 'CL100077';
    await pumpAssignmentScreen(tester, appState: state);
    await scan(
      tester,
      '{"lenh_san_xuat":"010140000365","cong_doan":"0060",'
      '"bo_phan":"MAY LẬP TRÌNH-XM2","work_center":"CL100077",'
      '"ten_cong_doan":"Gấp túi","sl_cong_doan":"10.000","unit":"CHC"}',
      settlesOn: find.text('Gấp túi'),
    );
    expect(
      find.textContaining(
        'thuộc bộ phận "MAY LẬP TRÌNH-XM2", còn ca đang chọn thuộc bộ phận '
        '"GẤP TÚI VIỀN-XM2"',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('another work center is still refused', (tester) async {
    final state = _OperationHistoryState()
      ..department = 'GẤP TÚI VIỀN-XM2'
      ..workCenter = 'CL100077';
    await pumpAssignmentScreen(tester, appState: state);
    await scan(
      tester,
      '{"lenh_san_xuat":"010140000365","cong_doan":"0060",'
      '"bo_phan":"GẤP TÚI VIỀN-XM2","work_center":"CL999999",'
      '"ten_cong_doan":"Gấp túi","sl_cong_doan":"10.000","unit":"CHC"}',
      settlesOn: find.textContaining('QR thuộc Xưởng "CL999999"'),
    );
    expect(find.text('Gấp túi'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'matching department accepts typographic dash with shared work center',
    (tester) async {
      final state = _OperationHistoryState()..department = 'GẤP TÚI VIỀN-XM2';
      await pumpAssignmentScreen(tester, appState: state);
      await scan(
        tester,
        '{"lenh_san_xuat":"010140000365","cong_doan":"0040",'
        '"bo_phan":"GẤP TÚI VIỀN–XM2","work_center":"WC",'
        '"ten_cong_doan":"Viền thành phẩm","sl_cong_doan":"10.000",'
        '"unit":"CHC"}',
        settlesOn: find.text('Viền thành phẩm'),
      );

      expect(find.textContaining('Work Center'), findsNothing);
      expect(find.textContaining('GẤP TÚI VIỀN'), findsNothing);
      expect(find.text('Viền thành phẩm'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'camera accepts matching department and rejects another work center',
    (tester) async {
      final state = _OperationHistoryState()
        ..department = 'GẤP TÚI VIỀN-XM2'
        ..workCenter = 'CL100077';
      await pumpAssignmentScreen(tester, appState: state);
      await tester.tap(find.byTooltip('Camera').first);
      await tester.pumpAndSettle();
      final scannerView = tester.widget<AdaptiveBarcodeScannerView>(
        find.byType(AdaptiveBarcodeScannerView),
      );
      const wrongWorkCenterQr =
          '{"lenh_san_xuat":"010140000365","cong_doan":"0040",'
          '"bo_phan":"GẤP TÚI VIỀN-XM2","work_center":"CL100078",'
          '"ten_cong_doan":"Viền thành phẩm","sl_cong_doan":"10.000","unit":"CHC"}';
      final rejected = await tester.runAsync(
        () => Future<bool>.sync(() => scannerView.onScan(wrongWorkCenterQr)),
      );
      await tester.pump();
      expect(rejected, isFalse);
      expect(find.textContaining('QR thuộc Xưởng'), findsOneWidget);
      final accepted = await tester.runAsync(
        () => Future<bool>.sync(
          () => scannerView.onScan(
            wrongWorkCenterQr.replaceAll('CL100078', 'CL100077'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(accepted, isTrue);
      expect(find.text('Viền thành phẩm'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'retained operation updates after assignment even when history refresh fails',
    (tester) async {
      final state = _SubmittingState();
      await pumpAssignmentScreen(tester, appState: state);
      await scan(
        tester,
        '{"lenh_san_xuat":"010140000032","cong_doan":"0020","ten_cong_doan":"May thân","sl_cong_doan":"1.200","unit":"ST"}',
        settlesOn: find.text('May thân'),
      );
      await pumpUntil(tester, find.text('750 ST'));
      await scanAndConfirmWorker(tester, _workerQr);
      await tester.ensureVisible(find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, '50');
      await tester.tap(find.text('Xác nhận phân công'));
      await pumpUntil(tester, find.text('Xác minh công nhân'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Xác minh công nhân'), findsOneWidget);
      state.failHistory = true;
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'test-only',
      );
      await tester.tap(find.text('Xác minh & gửi SAP'));
      await pumpUntil(tester, find.text('800 ST'));
      expect(find.text('400 ST'), findsOneWidget);
      expect(find.text(_workerSlotPlaceholder), findsOneWidget);
      expect(find.text('May thân'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a top-up without the position of the earlier assignment is stopped',
    (tester) async {
      final state = _SubmittingState();
      final db = CaslaDatabase.instance;
      await tester.runAsync(() async {
        await db.ensureEmployeeExists(
          id: 'QR_FORM',
          maNv: 'QR_FORM',
          name: 'Worker Form',
        );
        final order = await db.upsertOrderFromOperationQr(
          OperationQrParser.parse(
            '{"lenh_san_xuat":"010140000032","cong_doan":"0020","sl_cong_doan":"1.200","unit":"ST"}',
          ),
        );
        final template = (await db.getAssignmentById('asg-001'))!;
        // Same worker, operation, work date and shift, already given at G05.
        await db.createAssignmentAtomically(
          assignment: {
            ...template,
            'id': 'earlier-at-g05',
            'nhan_vien_id': 'QR_FORM',
            'don_hang_id': order!['id'],
            'assigned_quantity': 10.0,
            'business_date': '2026-09-14',
            'shift_id': 'DAY',
            'position_id': 'G05',
            'machine_id': 'M105',
            'sync_status': 'SYNCED',
            'idempotency_key': 'earlier-at-g05',
          },
          queueItem: {
            'id': 'queue-earlier-at-g05',
            'entity_type': 'ASSIGNMENT',
            'entity_id': 'earlier-at-g05',
            'action': 'CREATE',
            'idempotency_key': 'earlier-at-g05',
            'priority': 1,
            'retry_count': 0,
            'created_at_utc': 1,
          },
          auditLog: {'id': 'audit-earlier-at-g05', 'occurred_at_utc': 1},
        );
      });
      await pumpAssignmentScreen(tester, appState: state);
      await scan(
        tester,
        '{"lenh_san_xuat":"010140000032","cong_doan":"0020","ten_cong_doan":"May thân","sl_cong_doan":"1.200","unit":"ST"}',
        settlesOn: find.text('May thân'),
      );
      await scanAndConfirmWorker(tester, _workerQr);

      // Told on the form itself, before anything is sent.
      final refusal = find.textContaining('Hãy quét vị trí G05 để giao tiếp');
      await pumpUntil(tester, refusal);

      // The quantity is valid, so only the position can stop this.
      await pumpUntil(tester, find.textContaining(RegExp(r'^[\d.]+ ST$')));
      await tester.ensureVisible(find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, '5');
      await tester.ensureVisible(find.text('Xác nhận phân công'));
      await tester.tap(find.text('Xác nhận phân công'));
      await pumpUntil(tester, find.byType(AlertDialog));

      expect(refusal, findsNWidgets(2));
      expect(find.text('Xác minh công nhân'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'standalone confirmation stays on selection when worker has no actionable work',
    (tester) async {
      final state = _SubmittingState()..department = 'WORK-A';
      Map<String, dynamic>? received;
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const S10ConfirmScanScreen()),
          GoRoute(
            path: '/supervisor/employee_detail',
            builder: (_, route) {
              received = Map<String, dynamic>.from(route.extra! as Map);
              return const Scaffold(body: Text('Detail destination'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appStateProvider.overrideWith((ref) => state)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Quét QR nhân viên'));
      await tester.pump();
      final view = tester.widget<AdaptiveBarcodeScannerView>(
        find.byType(AdaptiveBarcodeScannerView),
      );
      // The scan callback completes on return from detail, so do not await it here.
      await tester.runAsync(() async {
        unawaited(Future<bool>.sync(() => view.onScan(_workerQr)));
      });
      await pumpUntil(
        tester,
        find.text(
          'Nhân viên không còn sản lượng cần xác nhận trong ca và bộ phận đang chọn.',
        ),
      );
      expect(received, isNull);
      expect(tester.takeException(), isNull);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('an operation with nothing left can still be given', (
    tester,
  ) async {
    final state = _SubmittingState();
    await pumpAssignmentScreen(tester, appState: state);
    // 450 ST of this operation are already out, which is all of it.
    await scan(
      tester,
      '{"lenh_san_xuat":"010140000032","cong_doan":"0020","ten_cong_doan":"May thân","sl_cong_doan":"450","unit":"ST"}',
      settlesOn: find.text('May thân'),
    );
    await pumpUntil(tester, find.text('0 ST'));
    await scanAndConfirmWorker(tester, _workerQr);
    await tester.ensureVisible(find.byType(TextField).first);
    await tester.enterText(find.byType(TextField).first, '50');
    await tester.pump();
    // Said under the operation and again under the quantity field.
    expect(
      find.text('Tổng số lượng giao vượt quá số lượng công đoạn.'),
      findsNWidgets(2),
    );

    await tester.tap(find.text('Xác nhận phân công'));
    await pumpUntil(tester, find.text('Xác minh công nhân'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'test-only',
    );
    await tester.tap(find.text('Xác minh & gửi SAP'));
    // The form empties its worker slot once the assignment is saved.
    await pumpUntil(tester, find.text(_workerSlotPlaceholder));
    expect(find.text('May thân'), findsOneWidget);
    expect(
      find.text('Tổng số lượng giao vượt quá số lượng công đoạn.'),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('department differences warn on the form and do not stop sending', (
    tester,
  ) async {
    final state = _SubmittingState()..department = 'Bộ phận A';
    await pumpAssignmentScreen(tester, appState: state);
    await scan(
      tester,
      '{"lenh_san_xuat":"010140000032","cong_doan":"0020","ten_cong_doan":"May thân","bo_phan":"Bộ phận A","work_center":"WC","sl_cong_doan":"1.200","unit":"ST"}',
      settlesOn: find.text('May thân'),
    );
    await pumpUntil(tester, find.text('750 ST'));
    await scanAndConfirmWorker(tester, _workerQr);
    await tester.ensureVisible(find.byType(TextField).first);
    await tester.enterText(find.byType(TextField).first, '50');
    state.department = 'Bộ phận B';
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    state.notifyListeners();
    await tester.pump();
    // The session's department now differs from the operation's: said under
    // the operation. The worker's own department (Tổ QR) is not compared.
    expect(find.textContaining('Vẫn giao được.'), findsOneWidget);
    expect(find.textContaining('Công nhân thuộc bộ phận'), findsNothing);
    await tester.tap(find.text('Xác nhận phân công'));
    // A warning only: no dialog between the button and the password.
    await pumpUntil(tester, find.text('Xác minh công nhân'));
    expect(find.textContaining('cảnh báo cần xác nhận'), findsNothing);
    expect(find.text('Vẫn giao'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('(+) adds an operation; the tighter one sets the warning', (
    tester,
  ) async {
    final state = _SubmittingState();
    await pumpAssignmentScreen(tester, appState: state);
    await scan(
      tester,
      '{"lenh_san_xuat":"010140000032","cong_doan":"0020","ten_cong_doan":"May thân","sl_cong_doan":"1.200","unit":"ST"}',
      settlesOn: find.text('May thân'),
    );
    await pumpUntil(tester, find.text('750 ST'));
    // One operation: the card is as it always was, with no fold arrow.
    expect(find.byTooltip('Thu gọn'), findsNothing);

    await tester.ensureVisible(find.text('Quét thêm công đoạn'));
    await tester.tap(find.text('Quét thêm công đoạn'));
    await tester.pump();
    await scan(
      tester,
      '{"lenh_san_xuat":"010140000099","cong_doan":"0030","ten_cong_doan":"Đóng nút","sl_cong_doan":"300","unit":"ST"}',
      settlesOn: find.text('Đóng nút'),
    );
    // The new card is open, the first one folded down to its remaining.
    await pumpUntil(tester, find.text('Theo công đoạn còn ít nhất: Đóng nút'));
    expect(find.text('Ít nhất'), findsOneWidget);
    expect(find.byTooltip('Mở rộng'), findsOneWidget);
    expect(find.byTooltip('Thu gọn'), findsOneWidget);

    await scanAndConfirmWorker(tester, _workerQr);
    await tester.ensureVisible(find.byType(TextField).first);
    await tester.enterText(find.byType(TextField).first, '400');
    await tester.pump();
    // Above what Đóng nút has left but not May thân: one warning, under the
    // operation it is about, and the form still sends.
    // Said under the operation and again under the quantity field.
    expect(
      find.text('Tổng số lượng giao vượt quá số lượng công đoạn.'),
      findsNWidgets(2),
    );
    await tester.ensureVisible(find.text('Xác nhận phân công · 2 công đoạn'));
    await tester.tap(find.text('Xác nhận phân công · 2 công đoạn'));
    await pumpUntil(tester, find.text('Xác minh công nhân'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'test-only',
    );
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await pumpUntil(tester, find.text('Đã giao 2 công đoạn'));
    expect(find.text('Đã gửi SAP'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('(+) refuses an operation counted in another unit', (
    tester,
  ) async {
    await pumpAssignmentScreen(tester);
    final unitKey = find.byKey(const ValueKey('assignment-quantity-unit'));
    await scan(tester, _kgOperationQr, settlesOn: unitKey);
    await tester.ensureVisible(find.text('Quét thêm công đoạn'));
    await tester.tap(find.text('Quét thêm công đoạn'));
    await tester.pump();
    await scan(
      tester,
      '{"lenh_san_xuat":"010140000099","cong_doan":"0030","ten_cong_doan":"Đóng nút","sl_cong_doan":"300","unit":"ST"}',
      settlesOn: find.textContaining('khác đơn vị'),
    );
    expect(find.text('Đóng nút'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final incomplete in ['truncated', 'summary-only']) {
    testWidgets('$incomplete history keeps local operation quantities', (
      tester,
    ) async {
      final appState = _OperationHistoryState(incomplete: incomplete);
      await pumpAssignmentScreen(tester, appState: appState);
      await scan(
        tester,
        '{"lenh_san_xuat":"010140000032","cong_doan":"0020","ten_cong_doan":"May thân","sl_cong_doan":"1.200","unit":"ST"}',
        settlesOn: find.text('Đã nhận. Mời quét tiếp.'),
      );
      await pumpUntil(tester, find.text('1.200 ST'));
      expect(appState.requestedOperation, '0020');
      expect(find.text('11.275 ST'), findsNothing);
      expect(find.text('250 ST'), findsNothing);
      // Đã xác nhận, Số lượng phế and Số lượng đã giao.
      expect(find.text('0 ST'), findsNWidgets(3));
      expect(find.text('1.200 ST'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'operation quantities accumulate all dates for the selected operation',
    (tester) async {
      final appState = _OperationHistoryState();
      await pumpAssignmentScreen(tester, appState: appState);
      await scan(
        tester,
        '{"lenh_san_xuat":"010140000032","cong_doan":"0020","ten_cong_doan":"May thân","sl_cong_doan":"1.200","unit":"ST"}',
        settlesOn: find.text('May thân'),
      );
      await pumpUntil(tester, find.text('750 ST'));
      expect(find.text('11.275 ST'), findsNothing);
      expect(find.text('100 ST'), findsOneWidget);
      expect(find.text('450 ST'), findsOneWidget);
      expect(find.text('Số lượng đã giao'), findsOneWidget);
      expect(find.text('Đã giao hôm nay'), findsNothing);
      expect(appState.requestedOrder, '010140000032');
      expect(appState.requestedOperation, '0020');
      expect(appState.requestedDate, DateTime(2026, 9, 14));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'manual worker picker closes scanner then returns safely to camera',
    (tester) async {
      final appState = _ManualSelectionState();
      await tester.runAsync(
        () => CaslaDatabase.instance.acceptWorkerQr(
          code: 'CACHED-NV',
          name: 'Nhân viên lưu từ QR',
        ),
      );
      await pumpAssignmentScreen(tester, appState: appState);
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.ensureVisible(find.byTooltip('Camera').last);
        await tester.tap(find.byTooltip('Camera').last);
        await tester.pump(const Duration(milliseconds: 25));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.ensureVisible(find.text('Dùng camera thay thế'));
        await tester.tap(find.text('Dùng camera thay thế'));
        await tester.pump();
        await tester.pump();
        await tester.ensureVisible(find.text('Nhập mã thủ công'));
        await tester.tap(find.text('Nhập mã thủ công'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await pumpUntil(tester, find.text('Chọn công nhân'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(AdaptiveBarcodeScannerView), findsNothing);
        expect(find.text('Nhân viên lưu từ QR'), findsOneWidget);
        await tester.enterText(find.byType(TextField).last, 'not-found');
        await tester.pump();
        expect(find.text('Không tìm thấy kết quả phù hợp.'), findsOneWidget);
        await tester.tap(find.byTooltip('Đóng danh sách'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Camera').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.ensureVisible(find.text('Dùng camera thay thế'));
        await tester.tap(find.text('Dùng camera thay thế'));
        await tester.pump();
        await tester.pump();
        expect(find.byType(QrScannerView), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Quay lại').last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Camera').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Nhập mã thủ công'));
      await tester.tap(find.text('Nhập mã thủ công'));
      await pumpUntil(tester, find.text('Chọn công nhân'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'CACHED-NV');
      await tester.pump();
      await tester.tap(find.text('Nhân viên lưu từ QR'));
      await tester.pumpAndSettle();
      expect(find.text('Chọn công nhân'), findsNothing);
      expect(find.text('Nhân viên lưu từ QR'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'worker scanner rejects operation QR without changing the order',
    (tester) async {
      await pumpAssignmentScreen(tester);
      await tester.tap(find.byTooltip('Camera').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final view = tester.widget<AdaptiveBarcodeScannerView>(
        find.byType(AdaptiveBarcodeScannerView),
      );
      final accepted = await tester.runAsync(
        () => Future<bool>.sync(() => view.onScan(_kgOperationQr)),
      );
      await tester.pump();
      expect(accepted, isFalse);
      expect(find.byType(AdaptiveBarcodeScannerView), findsOneWidget);
      expect(find.textContaining('Hãy quét thẻ công nhân'), findsOneWidget);
      final orders = await tester.runAsync(
        CaslaDatabase.instance.getOpenOrders,
      );
      expect(orders!.where((row) => row['ten_sp'] == 'KG Product'), isEmpty);
    },
  );

  testWidgets('operation scanner rejects worker QR without creating employee', (
    tester,
  ) async {
    await pumpAssignmentScreen(tester);
    await tester.tap(find.byTooltip('Camera').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final view = tester.widget<AdaptiveBarcodeScannerView>(
      find.byType(AdaptiveBarcodeScannerView),
    );
    final accepted = await tester.runAsync(
      () => Future<bool>.sync(() => view.onScan(_workerQr)),
    );
    await tester.pump();
    expect(accepted, isFalse);
    final worker = await tester.runAsync(
      () => CaslaDatabase.instance.getEmployeeByCode('QR_FORM'),
    );
    expect(worker, isNull);
  });

  testWidgets('a trigger pull fills the form without opening a scanner page', (
    tester,
  ) async {
    await pumpAssignmentScreen(tester);

    // The whole point of the rework: no full-screen scanner route stands
    // between the operator and the form.
    expect(find.byType(AdaptiveBarcodeScannerView), findsNothing);

    await scanAndConfirmWorker(tester, _workerQr);
    expect(find.byType(AdaptiveBarcodeScannerView), findsNothing);
    expect(find.text('Worker Form'), findsOneWidget);

    final worker = await tester.runAsync(
      () => CaslaDatabase.instance.getEmployeeByCode('QR_FORM'),
    );
    expect(worker?['bo_phan'], 'Tổ QR');

    await tester.tap(find.text(_productSlotPlaceholder));
    await tester.pump();
    await scan(tester, _kgOperationQr, settlesOn: find.text('KG Product'));
    expect(find.byType(AdaptiveBarcodeScannerView), findsNothing);
  });

  testWidgets('the selected field can be filled in either order', (
    tester,
  ) async {
    await pumpAssignmentScreen(tester);

    // Operation first this time. An operator working down a pallet should not
    // have to remember which field the app expects next.
    await scan(tester, _kgOperationQr, settlesOn: find.text('KG Product'));
    await scanAndConfirmWorker(tester, _workerQr);

    expect(find.text('KG Product'), findsOneWidget);
    expect(find.text('Worker Form'), findsOneWidget);
  });

  testWidgets('the quantity unit follows the scanned operation', (
    tester,
  ) async {
    await pumpAssignmentScreen(tester);

    final unitKey = find.byKey(const ValueKey('assignment-quantity-unit'));
    await scan(tester, _kgOperationQr, settlesOn: unitKey);
    expect(tester.widget<Text>(unitKey).data, 'KG');

    // Never fall back to a hardcoded "cái" for a KG operation.
    final inputs = tester.widgetList<TextField>(find.byType(TextField));
    expect(
      inputs.any((field) => field.decoration?.suffixText == 'cái'),
      isFalse,
    );

    await scan(tester, _pieceOperationQr, settlesOn: find.text('Other Unit'));
    expect(tester.widget<Text>(unitKey).data, 'cái');
  });

  testWidgets('after the operation QR the worker card is scanned with no tap', (
    tester,
  ) async {
    await tester.runAsync(
      () => CaslaDatabase.instance.ensureEmployeeExists(
        id: 'QR_FORM',
        maNv: 'QR_FORM',
        name: 'Worker Form',
      ),
    );
    await pumpAssignmentScreen(tester);

    final unitKey = find.byKey(const ValueKey('assignment-quantity-unit'));
    await scan(tester, _kgOperationQr, settlesOn: unitKey);
    // No tap on the worker slot: the scanner already points at it.
    await scan(tester, _workerQr, settlesOn: find.text('Worker Form'));
    expect(find.text('Worker Form'), findsOneWidget);
  });

  testWidgets('the worker seat pre-fills the position; a label overrides it', (
    tester,
  ) async {
    await tester.runAsync(
      () => CaslaDatabase.instance.ensureEmployeeExists(
        id: 'QR_FORM',
        maNv: 'QR_FORM',
        name: 'Worker Form',
      ),
    );
    final positions = _SeatBoard();
    await pumpAssignmentScreen(tester, positionApi: positions);

    final unitKey = find.byKey(const ValueKey('assignment-quantity-unit'));
    await scan(tester, _kgOperationQr, settlesOn: unitKey);
    await scan(
      tester,
      _workerQr,
      settlesOn: find.text('Mã vị trí: G05', findRichText: true),
    );
    expect(find.text('Mã vị trí: G05', findRichText: true), findsOneWidget);
    expect(find.text('Mã máy: M105', findRichText: true), findsOneWidget);

    // Select the position field, then pull the trigger at another machine.
    await tester.tap(find.text('Mã vị trí: G05', findRichText: true));
    await tester.pump();
    expect(find.text('Đang chọn quét'), findsOneWidget);
    await scan(
      tester,
      'G07@M107',
      settlesOn: find.text('Mã vị trí: G07', findRichText: true),
    );
    expect(find.text('Mã máy: M107', findRichText: true), findsOneWidget);
    expect(find.text('Dùng vị trí gốc G05'), findsOneWidget);

    await tester.tap(find.text('Dùng vị trí gốc G05'));
    await tester.pump();
    expect(find.text('Mã vị trí: G05', findRichText: true), findsOneWidget);
    expect(find.text('Dùng vị trí gốc G05'), findsNothing);
  });

  testWidgets('a camera scan of the operation only focuses the worker slot', (
    tester,
  ) async {
    await pumpAssignmentScreen(tester);
    await tester.tap(find.byTooltip('Camera').first);
    await tester.pumpAndSettle();
    final view = tester.widget<AdaptiveBarcodeScannerView>(
      find.byType(AdaptiveBarcodeScannerView),
    );
    expect(
      await tester.runAsync(
        () => Future<bool>.sync(() => view.onScan(_kgOperationQr)),
      ),
      isTrue,
    );
    await tester.pumpAndSettle();
    // Back on the form, no second camera opened on its own.
    expect(find.byType(AdaptiveBarcodeScannerView), findsNothing);
    expect(
      find.byKey(const ValueKey('assignment-quantity-unit')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a worker already in the catalogue is accepted with no prompt', (
    tester,
  ) async {
    // Real sqflite I/O has to run outside the fake-async zone, or the future
    // never completes and the test hangs instead of failing.
    await tester.runAsync(
      () => CaslaDatabase.instance.ensureEmployeeExists(
        id: 'QR_FORM',
        maNv: 'QR_FORM',
        name: 'Worker Form',
      ),
    );
    await pumpAssignmentScreen(tester);

    await tester.tap(find.text(_workerSlotPlaceholder));
    await tester.pump();
    await scan(tester, _workerQr, settlesOn: find.text('Worker Form'));

    // The confirmation exists to stop mis-scans creating phantom employees.
    // Making it appear for every known worker would just train people to
    // dismiss it.
    expect(find.text('Vẫn thêm'), findsNothing);
  });

  testWidgets('declining the prompt leaves the worker field empty', (
    tester,
  ) async {
    await pumpAssignmentScreen(tester);

    await tester.tap(find.text(_workerSlotPlaceholder));
    await tester.pump();
    await scan(tester, 'QR_FORM');
    await answerUnknownWorkerPrompt(
      tester,
      'Quét lại',
      settlesOn: find.text(_workerSlotPlaceholder),
    );

    expect(find.text('Worker Form'), findsNothing);
  });

  testWidgets('a product barcode swept up by the laser is called out', (
    tester,
  ) async {
    await pumpAssignmentScreen(tester);

    // A bare EAN-13 passes the permissive employee-code check, so before this
    // confirmation existed a stray sweep silently created an employee named
    // after a carton.
    await tester.tap(find.text(_workerSlotPlaceholder));
    await tester.pump();
    await scan(
      tester,
      '8934673001234',
      settlesOn: find.text('Có thể quét nhầm mã hàng'),
    );
  });

  testWidgets('narrow screen shows operation details and warns above remaining', (
    tester,
  ) async {
    await pumpAssignmentScreen(tester);
    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();
    await scan(
      tester,
      '{"ProductionOrder":"000001000099","Operation":"0010","ProductName":"Áo khoác công nhân dài tay nhiều lớp size XL","ProductCode":"SP-000099","sl_cong_doan":"100","UnitOfMeasure":"KG"}',
      settlesOn: find.text('Áo khoác công nhân dài tay nhiều lớp size XL'),
    );
    expect(find.text('000001000099'), findsOneWidget);
    expect(find.text('SP-000099'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await pumpUntil(tester, find.text('100 KG'));
    final quantityField = find.byType(TextField).first;
    await tester.ensureVisible(quantityField);
    await tester.enterText(quantityField, '101');
    await tester.pump();
    // Said under the operation and again under the quantity field.
    expect(
      find.text('Tổng số lượng giao vượt quá số lượng công đoạn.'),
      findsNWidgets(2),
    );
    // A warning only: the field itself carries no error.
    expect(
      tester.widget<TextField>(quantityField).decoration?.errorText,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unrecognised payload is reported and fills nothing', (
    tester,
  ) async {
    await pumpAssignmentScreen(tester);

    await scan(
      tester,
      'https://example.invalid/not-a-casla-code',
      // The banner has to persist: a snackbar would be gone before an operator
      // looking at the pallet had looked back at the screen.
      settlesOn: find.byIcon(Icons.error_outline_rounded),
    );

    expect(find.text(_productSlotPlaceholder), findsOneWidget);
    expect(find.text(_workerSlotPlaceholder), findsOneWidget);
  });
}

class _OperationHistoryState extends AppState {
  _OperationHistoryState({this.incomplete, this.gate});
  final Completer<void>? gate;
  String? department;
  String workCenter = 'WC';
  @override
  UserWorkContext? get activeWorkContext => department == null
      ? null
      : UserWorkContext(
          workId: department!,
          workName: department!,
          plant: '6711',
          workCenter: workCenter,
          boPhan: department!,
        );
  final String? incomplete;
  bool failHistory = false;
  String? requestedOrder;
  String? requestedOperation;
  DateTime? requestedDate;
  @override
  DateTime get activeBusinessDate => DateTime(2026, 9, 14);

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
        }) async {
          if (gate != null) await gate!.future;
          if (failHistory) throw StateError('history unavailable');
          requestedOrder = productionOrder;
          requestedOperation = operation;
          requestedDate = dateFrom;
          WorkHistoryEntry entry(
            String id,
            double quantity, {
            String order = '010140000032',
            String op = '0020',
            int day = 14,
            String type = 'INITIAL_ASSIGN',
          }) => WorkHistoryEntry(
            transactionUuid: id,
            executionDate: DateTime(2026, 9, day, 10),
            workerId: 'NV-1',
            workerName: 'Worker',
            productionOrder: order,
            operation: op,
            plant: '6711',
            workCenter: 'WC',
            transactionType: type,
            quantity: quantity,
            unitOfMeasure: 'ST',
            transactionStatus: 'POSTED',
          );
          return WorkHistoryResult(
            scopeCode: 'T',
            dateFrom: dateFrom!,
            dateTo: dateTo!,
            isTruncated: incomplete == 'truncated',
            entries: incomplete == 'summary-only'
                ? []
                : [
                    entry('a', 100),
                    entry('b', 175),
                    entry('r', 25, type: 'RECALL'),
                    entry('c', 40, type: 'CONFIRM'),
                    entry('other-order', 9000, order: '010140000034'),
                    entry('other-operation', 2000, op: '0010'),
                    entry('yesterday', 500, day: 13),
                    entry('confirmed-earlier', 60, day: 12, type: 'CONFIRM'),
                  ],
            workers: const [
              WorkHistorySummary(
                workerId: 'NV-1',
                workerName: 'Worker',
                assignedQuantity: 11275,
                completedQuantity: 500,
                remainingQuantity: 10775,
                unitOfMeasure: 'ST',
                transactionCount: 7,
              ),
            ],
          );
        },
  );
}

class _ManualSelectionState extends AppState {
  @override
  UserSession get currentSession => const UserSession(
    id: 'manual-test',
    maNv: 'MANUAL-SUP',
    fullName: 'Supervisor',
    teamName: 'Team 2',
    role: UserRole.supervisor,
    permissions: {Permission.assignQuantity},
    toIds: ['team-2'],
  );
}

class _SeatBoard implements PositionApi {
  @override
  Future<PositionBoard> getBoard({String workCenter = ''}) async =>
      const PositionBoard(
        workCenterCount: 1,
        seats: [
          PositionSeat(
            workCenter: 'CL100077',
            positionId: 'G05',
            machineId: 'M105',
            workerId: 'QR_FORM',
            workerName: 'Worker Form',
          ),
        ],
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeScanner implements BarcodeScanner {
  // Synchronous so the listener sees the event inside the caller's zone,
  // rather than on a microtask the fake-async zone would have to drain.
  final StreamController<BarcodeScanEvent> _controller =
      StreamController<BarcodeScanEvent>.broadcast(sync: true);

  var _tick = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<BarcodeScanEvent> get scans => _controller.stream;

  void emit(String rawValue) {
    // Spaced apart so consecutive scans are never taken for a double fire.
    _tick += 1;
    _controller.add(
      BarcodeScanEvent(
        rawValue: rawValue,
        source: BarcodeScanSource.hardware,
        timestamp: DateTime(2026, 9, 4).add(Duration(seconds: _tick)),
      ),
    );
  }

  Future<void> close() => _controller.close();
}

class _SubmittingState extends _OperationHistoryState {
  @override
  AssignmentRepositoryImpl get assignmentRepo => _assignments;
  late final _assignments = AssignmentRepositoryImpl(
    db,
    gateway: _SuccessGateway(),
  );
  @override
  bool isSessionGenerationCurrent(int generation) =>
      generation == sessionGeneration;
  @override
  SapShift get activeShift => SapShift(
    workCenter: workCenter,
    shiftId: 'DAY',
    validFrom: DateTime(2026),
    shiftName: 'Ca ngày',
    startTime: '08:00:00',
    endTime: '17:00:00',
    endDayOffset: 0,
    timeZone: 'UTC+7',
    validTo: null,
    isActive: 'A',
  );
}

class _SuccessGateway implements SapWriteGateway {
  @override
  Future<SapWriteResult> push(SyncPushRequest request) async =>
      SapWriteResult(sapId: 'posted-${request.entityId}');
  @override
  Future<bool> refreshSession() async => false;
}
