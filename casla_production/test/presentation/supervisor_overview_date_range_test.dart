import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/features/supervisor/screens/s06_supervisor_overview_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();

  for (final scenario in [
    (name: 'landscape', size: const Size(812, 375), scale: 1.0),
    (name: 'large text', size: const Size(375, 740), scale: 2.0),
  ]) {
    testWidgets('overview fits ${scenario.name} with bottom navigation', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => CaslaDatabase.instance.ready);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
              child: child!,
            ),
            home: const Scaffold(
              body: S06SupervisorOverviewScreen(),
              bottomNavigationBar: SizedBox(height: 70),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('small Android overview exposes and opens a two-date picker', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => CaslaDatabase.instance.ready);
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: S06SupervisorOverviewScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Lọc').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Lọc').hitTestable());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Lọc dữ liệu'), findsOneWidget);
    expect(find.text('Hôm nay'), findsAtLeastNWidgets(1));
    expect(find.text('Tuần này'), findsOneWidget);
    expect(find.text('Tháng này'), findsOneWidget);
    await tester.tap(find.textContaining('Ngày khác / Từ ngày'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    expect(find.byType(DatePickerDialog), findsNothing);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('Từ ngày'), findsOneWidget);
    expect(find.text('Đến ngày'), findsOneWidget);
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    // MaterialApp's default locale is en_US; enter two distinct dates and
    // verify the applied range appears on the overview, not a single date.
    await tester.enterText(
      find.byType(TextField).at(0),
      '$month/01/${now.year}',
    );
    await tester.enterText(
      find.byType(TextField).at(1),
      '$month/07/${now.year}',
    );
    await tester.tap(find.text('ÁP DỤNG'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DateRangePickerDialog), findsNothing);
    expect(find.text('Áp dụng bộ lọc').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Áp dụng bộ lọc').hitTestable());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('01/$month - 07/$month').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
