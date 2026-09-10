import 'package:casla_production/domain/entities/entities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('initialsFor', () {
    test('takes the last two name parts', () {
      expect(UserSession.initialsFor('Nguyen Van An'), 'VA');
      expect(UserSession.initialsFor('Le Thi Hoa'), 'TH');
    });

    test('a single name yields one letter', () {
      expect(UserSession.initialsFor('An'), 'A');
    });

    test('trailing whitespace does not crash', () {
      // SAP CHAR fields arrive space-padded, so this is the shape most real
      // names take. Splitting on ' ' left an empty trailing segment, and
      // indexing it threw a RangeError on the overview header and the account
      // card — the two screens every supervisor sees after login.
      expect(UserSession.initialsFor('Nguyen Van An '), 'VA');
      expect(UserSession.initialsFor('  Nguyen   Van   An  '), 'VA');
      expect(UserSession.initialsFor('An '), 'A');
    });

    test('an empty or whitespace-only name uses the fallback', () {
      expect(UserSession.initialsFor(''), 'CG');
      expect(UserSession.initialsFor('   '), 'CG');
      expect(UserSession.initialsFor(' ', fallback: 'B'), 'B');
    });

    test('output is upper case regardless of input', () {
      expect(UserSession.initialsFor('nguyen van an'), 'VA');
      expect(UserSession.initialsFor('bachdv'), 'B');
    });
  });
}
