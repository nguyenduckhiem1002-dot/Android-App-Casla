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
