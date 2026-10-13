import 'package:casla_production/presentation/widgets/manual_code_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Opens the dialog from a button and returns a getter for its result.
  Future<String? Function()> open(
    WidgetTester tester,
    Future<String?> Function(BuildContext context) show,
  ) async {
    String? result = 'not closed';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await show(context),
              child: const Text('Mở'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Mở'));
    await tester.pumpAndSettle();
    return () => result;
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  TextButton confirmButton(WidgetTester tester) =>
      tester.widget<TextButton>(find.widgetWithText(TextButton, 'Xác nhận'));

  group('position and machine', () {
    testWidgets('asks for each code in its own field', (tester) async {
      await open(tester, showManualSlotDialog);

      expect(find.text('Nhập vị trí và mã máy'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
      expect(field('Mã vị trí'), findsOneWidget);
      expect(field('Mã máy'), findsOneWidget);
    });

    testWidgets('confirm stays disabled until both codes are entered', (
      tester,
    ) async {
      final result = await open(tester, showManualSlotDialog);

      expect(confirmButton(tester).onPressed, isNull);
      await tester.enterText(field('Mã vị trí'), 'G05');
      await tester.pump();
      expect(confirmButton(tester).onPressed, isNull);
      await tester.enterText(field('Mã máy'), 'M105');
      await tester.pump();
      expect(confirmButton(tester).onPressed, isNotNull);

      await tester.tap(find.text('Xác nhận'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(result(), 'G05@M105');
    });

    testWidgets('separators and over-long input cannot be typed', (
      tester,
    ) async {
      final result = await open(tester, showManualSlotDialog);

      await tester.enterText(field('Mã vị trí'), ' G0/5 ');
      await tester.enterText(field('Mã máy'), 'M12345678901');
      await tester.pump();
      expect(find.text('G05'), findsOneWidget);
      expect(find.text('M123456789'), findsOneWidget);

      await tester.tap(find.text('Xác nhận'));
      await tester.pumpAndSettle();
      expect(result(), 'G05@M123456789');
    });

    testWidgets('keyboard moves to the machine field, then submits', (
      tester,
    ) async {
      final result = await open(tester, showManualSlotDialog);

      await tester.enterText(field('Mã vị trí'), 'G05');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      final machine = tester.widget<TextField>(field('Mã máy'));
      expect(machine.focusNode!.hasFocus, isTrue);

      await tester.enterText(field('Mã máy'), 'M105');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(result(), 'G05@M105');
    });

    testWidgets('cancel closes cleanly while the exit transition runs', (
      tester,
    ) async {
      final result = await open(tester, showManualSlotDialog);
      await tester.enterText(field('Mã vị trí'), 'G05');
      await tester.enterText(field('Mã máy'), 'M105');
      await tester.tap(find.text('Hủy'));
      // Step through the exit transition frame by frame: the fields keep
      // rebuilding after pop() has already resolved the dialog's Future.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(result(), isNull);
    });
  });

  testWidgets('single code returns the typed text', (tester) async {
    final result = await open(
      tester,
      (context) => showManualCodeDialog(
        context,
        title: 'Nhập mã công nhân',
        label: 'Mã công nhân',
        helperText: 'Ví dụ: 10000123',
      ),
    );
    await tester.enterText(find.byType(TextField), ' 10000123 ');
    await tester.pump();
    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result(), '10000123');
  });
}
