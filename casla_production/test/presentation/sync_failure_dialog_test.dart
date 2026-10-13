import 'package:casla_production/presentation/widgets/sync_failure_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sync failure dialog prioritizes recovery over technical codes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showSyncFailureDialog(
                context,
                data: const SyncFailureDialogData(
                  statusLabel: 'Ngày hoặc ca không hợp lệ',
                  message:
                      'Giao dịch ghi nhận ngày 19/09/2026 nhưng được tạo lúc 22/09/2026 · 10:21.',
                  guidance:
                      'Kiểm tra với quản lý trước khi xóa và tạo lại giao dịch.',
                  transactionSummary: 'Xác nhận · +10 CHC',
                  orderOperation: '010140000342 · 0020',
                  businessDateShift: '19/09/2026 · Ca ngày',
                  createdAt: '22/09/2026 · 10:21',
                  technicalCode: 'SHIFT_WORK_DATE_MISMATCH',
                  technicalMessage: 'CONFIRM_INPUT_INVALID',
                ),
              ),
              child: const Text('Mở'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Mở'));
    await tester.pumpAndSettle();

    expect(find.text('Không thể đồng bộ'), findsOneWidget);
    expect(find.text('Ngày hoặc ca không hợp lệ'), findsOneWidget);
    expect(find.text('Cách xử lý'), findsOneWidget);
    expect(find.text('SHIFT_WORK_DATE_MISMATCH'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Chi tiết kỹ thuật'));
    await tester.pumpAndSettle();

    expect(find.textContaining('SHIFT_WORK_DATE_MISMATCH'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sync failure dialog remains scrollable with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: const Scaffold(
            body: SyncFailureDialog(
              data: SyncFailureDialogData(
                message:
                    'SAP chưa chấp nhận giao dịch này. Vui lòng kiểm tra thông tin trước khi xử lý lại.',
                guidance:
                    'Giao dịch vẫn được giữ trên thiết bị. Kiểm tra dữ liệu rồi thử lại.',
                transactionSummary: 'Xác nhận · +10 CHC',
                orderOperation: '010140000342 · 0020',
                businessDateShift: '19/09/2026 · Ca ngày',
                createdAt: '22/09/2026 · 10:21',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
