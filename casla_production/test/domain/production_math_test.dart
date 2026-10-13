import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/domain/policies/production_math.dart';

void main() {
  group('ProductionMath', () {
    test('calculates effective, remaining and recall quantities', () {
      expect(ProductionMath.calculateEffectiveAssigned(100, 20), 80);
      expect(ProductionMath.calculateRemaining(80, 30), 50);
      expect(ProductionMath.calculateMaxRecall(100, 30, 20), 50);
    });

    test('never returns negative quantities', () {
      expect(ProductionMath.calculateEffectiveAssigned(10, 20), 0);
      expect(ProductionMath.calculateRemaining(10, 20), 0);
      expect(ProductionMath.calculateMaxRecall(10, 20, 5), 0);
    });

    test('rounds quantities to the scale SAP can store', () {
      // quan(15,3): a 4th decimal has nowhere to go, so it must be resolved
      // before the value is stored, not silently on the wire.
      expect(ProductionMath.toSapScale(1.2345), 1.234);
      expect(ProductionMath.toSapScale(1.2346), 1.235);
      expect(ProductionMath.toSapScale(double.nan), 0.0);
    });

    test('an exact decimal completion is not treated as an overflow', () {
      // 0.3 assigned, 0.1 completed. In double space the remainder is
      // 0.19999999999999998, so a raw `0.2 > remaining` rejected valid input.
      final remaining = ProductionMath.calculateRemaining(0.3, 0.1);
      expect(ProductionMath.exceedsAtSapScale(0.2, remaining), isFalse);
      expect(ProductionMath.validateProductionEntry(0.2), isNull);
      expect(
        ProductionMath.validateRecallEntry(0.2, remaining, 'NOT_FINISHED', ''),
        isNull,
      );

      // Genuinely over the limit still fails.
      expect(ProductionMath.exceedsAtSapScale(0.201, remaining), isTrue);
    });

    test('converts an entered remaining balance to completion', () {
      expect(ProductionMath.calculateCompletionFromRemaining(10, 3.25), 6.75);
      expect(ProductionMath.calculateCompletionFromRemaining(0.3, 0.1), 0.2);
      expect(ProductionMath.calculateCompletionFromRemaining(10, 10), 0.0);
      expect(ProductionMath.calculateCompletionFromRemaining(10, 11), 0.0);
      expect(ProductionMath.calculateCompletionFromRemaining(10, -1), 0.0);
    });

    test(
      'the recall overflow message reads at the quantity, not truncated',
      () {
        // `maxRecall.toInt()` used to render "vượt quá ... (0)" for any
        // fractional limit, which reads as a bug to the supervisor.
        expect(
          ProductionMath.validateRecallEntry(1.0, 0.5, 'DEFECT', null),
          contains('0.5'),
        );
        expect(ProductionMath.formatQuantity(12.0), '12');
      },
    );

    test('validates production and recall boundaries', () {
      expect(ProductionMath.validateProductionEntry(0), isNotNull);
      expect(ProductionMath.validateProductionEntry(-1), isNotNull);
      expect(ProductionMath.validateProductionEntry(10), isNull);
      // Confirming more than is left is a warning on the form, not an error;
      // a recall is still capped by what the worker holds.
      expect(ProductionMath.exceedsAtSapScale(11, 10), isTrue);
      expect(
        ProductionMath.validateRecallEntry(11, 10, 'DEFECT', null),
        isNotNull,
      );
      expect(ProductionMath.validateRecallEntry(1, 10, 'OTHER', ''), isNotNull);
      expect(
        ProductionMath.validateRecallEntry(1, 10, 'OTHER', 'Lý do'),
        isNull,
      );
    });
  });
}
