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
      expect(ProductionMath.validateProductionEntry(0.2, remaining), isNull);
      expect(
        ProductionMath.validateRecallEntry(0.2, remaining, 'NOT_FINISHED', ''),
        isNull,
      );

      // Genuinely over the limit still fails.
      expect(ProductionMath.exceedsAtSapScale(0.201, remaining), isTrue);
    });

    test('the overflow message reads at the quantity, not truncated', () {
      // `remaining.toInt()` used to render "vượt quá ... (0)" for any
      // fractional limit, which reads as a bug to the supervisor.
      expect(ProductionMath.validateProductionEntry(1.0, 0.5), contains('0.5'));
      expect(ProductionMath.formatQuantity(12.0), '12');
    });

    test('validates production and recall boundaries', () {
      expect(ProductionMath.validateProductionEntry(0, 10), isNotNull);
      expect(ProductionMath.validateProductionEntry(11, 10), isNotNull);
      expect(ProductionMath.validateProductionEntry(10, 10), isNull);
      expect(ProductionMath.validateRecallEntry(1, 10, 'OTHER', ''), isNotNull);
      expect(
        ProductionMath.validateRecallEntry(1, 10, 'OTHER', 'Lý do'),
        isNull,
      );
    });
  });
}
