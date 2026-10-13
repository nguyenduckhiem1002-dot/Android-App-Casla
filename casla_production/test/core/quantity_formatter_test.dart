import 'package:casla_production/core/utils/quantity_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats count units as integers regardless of case or whitespace', () {
    for (final unit in ['CHC', 'BOO', 'CAI', 'TAM', 'THH', 'lIN', ' chc ']) {
      expect(formatQuantity(1234.0, uom: unit), '1.234');
      expect(formatQuantity(12.4, uom: unit), '12');
      expect(formatQuantity(12.6, uom: unit), '13');
      expect(formatQuantity(0, uom: unit), '0');
    }
    expect(formatQuantity(12.345, uom: 'KG'), '12.345');
    expect(formatQuantity(12.5, uom: 'M'), '12.5');
    expect(formatQuantity(12.5), '12.5');
  });
  test('keeps meaningful fractional quantities and removes noise zeros', () {
    expect(formatQuantity(12), '12');
    expect(formatQuantity(12.5), '12.5');
    expect(formatQuantity(12.3456), '12.346');
    expect(formatQuantity(10000), '10.000');
    expect(formatQuantity(-0.0000001), '0');
  });

  test('uses an explicit unavailable value for non-finite input', () {
    expect(formatQuantity(double.nan), '—');
    expect(formatQuantity(double.infinity), '—');
  });

  test('parses Vietnamese thousands separators without dropping magnitude', () {
    expect(parseLocalizedQuantity('10.000'), 10000);
    expect(parseLocalizedQuantity('10.000,500'), 10000.5);
    expect(parseLocalizedQuantity('10.5'), 10.5);
  });

  test('rejects fractional input for count units only', () {
    for (final unit in ['CHC', 'BOO', 'CAI', 'TAM', 'THH', 'lIN', ' chc ']) {
      expect(wholeQuantityInputError('10.5', unit), isNotNull);
      expect(wholeQuantityInputError('10,5', unit), isNotNull);
      expect(wholeQuantityInputError('0.25', unit), isNotNull);
      expect(wholeQuantityInputError('10', unit), isNull);
      expect(wholeQuantityInputError('10.000', unit), isNull);
      expect(wholeQuantityInputError('', unit), isNull);
    }
    expect(wholeQuantityInputError('10.5', 'KG'), isNull);
    expect(wholeQuantityInputError('10.5', 'M'), isNull);
    expect(wholeQuantityInputError('10.5', null), isNull);
  });

  test('remaining that shows as 0 is nothing left', () {
    // 0,4 CHC displays as "0": the worker is done, not still open.
    expect(hasRemainingQuantity(0.4, uom: 'CHC'), isFalse);
    expect(hasRemainingQuantity(0, uom: 'CHC'), isFalse);
    expect(hasRemainingQuantity(-2, uom: 'CHC'), isFalse);
    expect(hasRemainingQuantity(1, uom: 'CHC'), isTrue);
    // Units with decimals keep their fractions.
    expect(hasRemainingQuantity(0.4, uom: 'KG'), isTrue);
  });
}
