import 'package:casla_production/presentation/widgets/worker_verification_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<WorkerPasswordRun<bool>?> start(
    WidgetTester tester,
    List<String> seen,
  ) async {
    WorkerPasswordRun<bool>? outcome;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              outcome = await runWithWorkerPassword<bool>(
                context,
                workerName: 'CN A',
                actionLabel: 'gửi',
                // `true` = SAP accepted; the password "ok" is the right one.
                submit: (password) async {
                  seen.add(password);
                  return password == 'ok';
                },
                isWrongPassword: (accepted) => !accepted,
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return outcome;
  }

  Future<void> enter(WidgetTester tester, String password) async {
    await tester.enterText(find.byType(TextField), password);
    await tester.tap(find.text('Xác minh & gửi SAP'));
    await tester.pumpAndSettle();
  }

  testWidgets('re-opens with the error and closes after 3 wrong passwords', (
    tester,
  ) async {
    final seen = <String>[];
    await start(tester, seen);

    await enter(tester, 'x1');
    expect(find.textContaining('Còn 2 lần nhập'), findsOneWidget);
    await enter(tester, 'x2');
    expect(find.textContaining('Còn 1 lần nhập'), findsOneWidget);
    await enter(tester, 'x3');

    expect(find.byType(AlertDialog), findsNothing);
    expect(seen, ['x1', 'x2', 'x3']);
    expect(find.text(workerPasswordExhaustedMessage), findsOneWidget);

    // The notice clears itself.
    await tester.pump(const Duration(seconds: 4));
    expect(find.text(workerPasswordExhaustedMessage), findsNothing);
  });

  testWidgets('a correct password on a retry finishes the run', (tester) async {
    final seen = <String>[];
    await start(tester, seen);

    await enter(tester, 'x1');
    await enter(tester, 'ok');

    expect(find.byType(AlertDialog), findsNothing);
    expect(seen, ['x1', 'ok']);
    expect(find.text(workerPasswordExhaustedMessage), findsNothing);
  });
}
