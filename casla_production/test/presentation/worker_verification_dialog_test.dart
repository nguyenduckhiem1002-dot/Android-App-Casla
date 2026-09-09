import 'package:casla_production/presentation/widgets/worker_verification_dialog.dart';
import 'package:casla_production/app/theme/casla_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [
    const Size(320, 480),
    const Size(360, 640),
    const Size(640, 360),
  ]) {
    testWidgets(
      'PDA $size keyboard does not overlap password field and actions',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final keyboardHeight = size.height < 400 ? 140.0 : 220.0;
        tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpWidget(
          MaterialApp(
            theme: CaslaTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showWorkerVerificationDialog(
                    context,
                    workerName: 'Test 1',
                    actionLabel: 'gửi phân công lên SAP',
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byType(TextField));
        await tester.pumpAndSettle();
        final field = tester.getRect(find.byType(TextField));
        final cancel = tester.getRect(find.widgetWithText(TextButton, 'Hủy'));
        expect(field.overlaps(cancel), isFalse);
        expect(
          tester.getRect(find.byType(FilledButton)).bottom,
          lessThanOrEqualTo(size.height - keyboardHeight),
        );
        await tester.enterText(find.byType(TextField), 'test-password');
        await tester.tap(find.text('Xác minh & gửi SAP'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'keyboard and button submitting together only close the dialog once',
    (tester) async {
      final observer = _PopObserver();
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showWorkerVerificationDialog(
                    context,
                    workerName: 'Công nhân A',
                    actionLabel: 'nhận sản phẩm',
                  );
                },
                child: const Text('Mở xác minh'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Mở xác minh'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'test-password');
      final keyboardSubmit = tester
          .widget<TextField>(find.byType(TextField))
          .onSubmitted!;
      final buttonSubmit = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      keyboardSubmit('test-password');
      buttonSubmit();
      await tester.pumpAndSettle();
      expect(observer.pops, 1);
      expect(result, 'test-password');
      expect(find.text('Mở xác minh'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Mở xác minh'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.tap(find.text('Hủy'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    },
  );

  testWidgets('worker password opts out of platform autofill', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showWorkerVerificationDialog(
                context,
                workerName: 'Công nhân A',
                actionLabel: 'xác nhận sản lượng',
              ),
              child: const Text('Mở xác minh'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Mở xác minh'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autofillHints, isNull);
    expect(field.enableIMEPersonalizedLearning, isFalse);
  });
}

class _PopObserver extends NavigatorObserver {
  int pops = 0;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
  }
}
