import 'package:casla_production/presentation/widgets/worker_verification_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}

class _PopObserver extends NavigatorObserver {
  int pops = 0;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
  }
}
