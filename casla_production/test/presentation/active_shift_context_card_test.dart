import 'package:casla_production/data/sap/sap_shift_controller.dart';
import 'package:casla_production/domain/entities/entities.dart';
import 'package:casla_production/presentation/widgets/active_shift_context_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows Xưởng and Bộ phận code - name, never the plant', (
    tester,
  ) async {
    const work = UserWorkContext(
      workId: 'XM2.002',
      workName: 'MAY CHI TIẾT PHỤ-XM2',
      plant: '6711',
      plantName: 'Nhà máy túi CASLA 1',
      workCenter: 'CL100077',
      workCenterName: 'Xưởng may 2',
      boPhan: 'MAY CHI TIẾT PHỤ-XM2',
      location: 'XM2',
    );
    final shift = SapShift(
      workCenter: 'CL100077',
      shiftId: '1',
      validFrom: DateTime(2026, 9, 25),
      shiftName: 'Ca Sáng',
      startTime: '08:00:00',
      endTime: '17:00:00',
      endDayOffset: 0,
      timeZone: 'UTC+7',
      validTo: null,
      isActive: 'A',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActiveShiftContextCard(
            workContext: work,
            shift: shift,
            businessDate: DateTime(2026, 9, 25),
          ),
        ),
      ),
    );

    expect(
      find.text(
        'Xưởng: CL100077 (Xưởng may 2)\n'
        'Bộ phận: XM2.002 - MAY CHI TIẾT PHỤ-XM2',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Nhà máy'), findsNothing);
  });
}
