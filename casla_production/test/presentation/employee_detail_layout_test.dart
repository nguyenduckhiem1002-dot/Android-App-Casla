import 'package:casla_production/app/theme/casla_theme.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/features/supervisor/screens/s06b_employee_daily_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();
  testWidgets('worker detail renders period selector under production theme', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 886);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => CaslaDatabase.instance.ready);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: CaslaTheme.light,
          home: S06bEmployeeDailyDetailScreen(
            worker: {
              'id': 'KHIEMND1',
              'ma_nv': 'KHIEMND1',
              'ten': 'Nguyễn Đức Khiêm',
              'date_from': DateTime(2026, 9, 7),
              'date_to': DateTime(2026, 9, 10),
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Đổi ngày ▾').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Đổi ngày ▾'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Thời gian xem dữ liệu').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
