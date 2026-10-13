import 'package:casla_production/domain/entities/mutation_receipt.dart';
import 'package:casla_production/presentation/widgets/mutation_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final state in [
    MutationDeliveryState.rejected,
    MutationDeliveryState.queued,
    MutationDeliveryState.needsVerification,
  ]) {
    testWidgets('$state stays visible until acknowledged', (tester) async {
      var acknowledged = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () async {
                    await showMutationFeedback(
                      context,
                      receipt: MutationReceipt(
                        id: 'assignment',
                        state: state,
                        code: 'MANUFACTURING_ORDER_NOT_FOUND',
                        message: 'Chi tiết cần kiểm tra',
                      ),
                      successMessage: 'Đã giao',
                      persistNonSuccess: true,
                    );
                    acknowledged = true;
                  },
                  child: const Text('Gửi'),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Gửi'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('MANUFACTURING_ORDER_NOT_FOUND'), findsOneWidget);
      expect(find.text('SAP phản hồi'), findsOneWidget);
      expect(find.byTooltip('Đóng'), findsOneWidget);
      expect(find.textContaining('Chi tiết cần kiểm tra'), findsOneWidget);
      expect(acknowledged, isFalse);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Đã hiểu'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(acknowledged, isTrue);
      await tester.tap(find.text('Gửi'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Đóng'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  }
}
