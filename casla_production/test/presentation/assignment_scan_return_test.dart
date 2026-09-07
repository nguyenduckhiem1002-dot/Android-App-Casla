import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/features/supervisor/screens/s07_create_assignment_wizard_screen.dart';
import 'package:casla_production/presentation/widgets/adaptive_barcode_scanner_view.dart';
import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();
  testWidgets('worker returns to assignment and operation supplies KG suffix', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('casla/scanner/control'),
      (_) async => true,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('casla/scanner/events'),
      (_) async => null,
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('casla/scanner/control'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('casla/scanner/events'),
        null,
      );
    });
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
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: S07CreateAssignmentWizardScreen()),
      ),
    );
    await tester.tap(find.byTooltip('Quét mã QR công nhân'));
    await tester.pumpAndSettle();
    var scanner = tester.widget<AdaptiveBarcodeScannerView>(
      find.byType(AdaptiveBarcodeScannerView),
    );
    await tester.runAsync(() async {
      await scanner.onScan('{"WorkerID":"QR_FORM","WorkerName":"Worker Form"}');
    });
    await tester.pumpAndSettle();
    expect(find.byType(AdaptiveBarcodeScannerView), findsNothing);
    expect(find.byType(S07CreateAssignmentWizardScreen), findsOneWidget);
    expect(find.textContaining('Worker Form'), findsWidgets);
    await tester.tap(find.byIcon(Icons.qr_code_scanner).first);
    await tester.pumpAndSettle();
    scanner = tester.widget<AdaptiveBarcodeScannerView>(
      find.byType(AdaptiveBarcodeScannerView),
    );
    await tester.runAsync(() async {
      await scanner.onScan(
        '{"ProductionOrder":"000001000020","Operation":"0010","ProductName":"KG Product","UnitOfMeasure":"KG"}',
      );
    });
    await tester.pumpAndSettle();
    expect(find.byType(AdaptiveBarcodeScannerView), findsNothing);
    expect(find.text('KG Product'), findsOneWidget);
    final unitLabel = find.text('KG');
    expect(unitLabel, findsOneWidget);
    final unitOpacity = tester.widgetList<AnimatedOpacity>(
      find.ancestor(of: unitLabel, matching: find.byType(AnimatedOpacity)),
    );
    expect(
      unitOpacity.every((widget) => widget.opacity == 1),
      isTrue,
      reason: 'QR unit must remain visible before quantity input is focused',
    );
    final inputs = tester.widgetList<TextField>(find.byType(TextField));
    expect(
      find.byKey(const ValueKey('assignment-quantity-unit')),
      findsOneWidget,
    );
    expect(
      inputs.any((field) => field.decoration?.suffixText == 'cái'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.qr_code_scanner).first);
    await tester.pumpAndSettle();
    scanner = tester.widget<AdaptiveBarcodeScannerView>(
      find.byType(AdaptiveBarcodeScannerView),
    );
    await tester.runAsync(() async {
      await scanner.onScan(
        '{"ProductionOrder":"000001000020","Operation":"0010","ProductName":"Other Unit","UnitOfMeasure":"cái"}',
      );
    });
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('assignment-quantity-unit')))
          .data,
      'cái',
    );
    expect(find.text('KG'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
