import 'dart:async';

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

const String _workerQr = '{"WorkerID":"QR_FORM","WorkerName":"Worker Form"}';
const String _kgOperationQr =
    '{"ProductionOrder":"000001000020","Operation":"0010",'
    '"ProductName":"KG Product","UnitOfMeasure":"KG"}';
const String _pieceOperationQr =
    '{"ProductionOrder":"000001000021","Operation":"0020",'
    '"ProductName":"Other Unit","UnitOfMeasure":"cái"}';

const String _productSlotPlaceholder = 'Bóp cò quét nhãn công đoạn';
const String _workerSlotPlaceholder = 'Bóp cò quét thẻ nhân viên';

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

  Future<void> pumpAssignmentScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: S07CreateAssignmentWizardScreen(
            scanner: scanner,
            scannerPreferences: InMemoryScannerPreferences(),
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
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (finder.evaluate().isNotEmpty) {
        await tester.pump();
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    fail('Timed out waiting for $finder');
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
    await scan(tester, payload);
    await answerUnknownWorkerPrompt(
      tester,
      'Vẫn thêm',
      settlesOn: find.text('Worker Form'),
    );
  }

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

    await scan(tester, _kgOperationQr, settlesOn: find.text('KG Product'));
    expect(find.byType(AdaptiveBarcodeScannerView), findsNothing);
  });

  testWidgets('the payload decides the field, so scan order does not matter', (
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

    await scan(tester, _workerQr);
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
    await scan(
      tester,
      '8934673001234',
      settlesOn: find.text('Có thể quét nhầm mã hàng'),
    );
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
