import 'package:casla_production/core/utils/quantity_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps meaningful fractional quantities and removes noise zeros', () {
    expect(formatQuantity(12), '12');
    expect(formatQuantity(12.5), '12.5');
    expect(formatQuantity(12.3456), '12.346');
    expect(formatQuantity(-0.0000001), '0');
  });

  test('uses an explicit unavailable value for non-finite input', () {
    expect(formatQuantity(double.nan), '—');
    expect(formatQuantity(double.infinity), '—');
  });
}
