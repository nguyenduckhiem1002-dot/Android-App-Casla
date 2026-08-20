import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:casla_production/main.dart';

import 'support/database_test_harness.dart';

void main() {
  // Building the app reaches CaslaDatabase through AppState, so the widget test
  // needs a real SQLite backend just like the data tests do.
  useInMemoryDatabase();

  testWidgets('shows the login screen on startup', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: CaslaApp()));
    await tester.pump();

    expect(find.byType(CaslaApp), findsOneWidget);
    expect(find.textContaining('Supervisor'), findsWidgets);
  });
}
