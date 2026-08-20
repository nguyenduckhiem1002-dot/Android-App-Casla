// Scope and order-lookup tests.
//
// Both behaviours below were stubs that always said yes: getEmployeesByTeamIds
// ignored its argument and returned every worker, and getOrderByCode fell back
// to a substring match on the product name.

import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/core/database/casla_database.dart';
import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;

  setUp(() {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
  });

  group('getEmployeesByTeamIds', () {
    test('returns only workers in the requested teams', () async {
      // Seed: emp-2 is in team-1; emp-1 and emp-5 and emp-6 are in team-2.
      final team1 = await db.getEmployeesByTeamIds(['team-1']);

      expect(team1, isNotEmpty);
      for (final e in team1) {
        expect(e['to_ids'], contains('team-1'));
        expect(e['vai_tro'], 'CONG_NHAN');
      }
    });

    test('narrows the result as the scope narrows', () async {
      final all = await db.getEmployeesByTeamIds([
        'team-1',
        'team-2',
        'team-3',
      ]);
      final one = await db.getEmployeesByTeamIds(['team-1']);

      expect(one.length, lessThan(all.length));
    });

    test('never returns the supervisor', () async {
      final workers = await db.getEmployeesByTeamIds([
        'team-1',
        'team-2',
        'team-3',
      ]);

      expect(workers.any((e) => e['ma_nv'] == 'MNV00100'), isFalse);
    });

    test('an empty scope returns nothing, not everything', () async {
      expect(await db.getEmployeesByTeamIds([]), isEmpty);
    });
  });

  group('isEmployeeInScope', () {
    test('accepts a worker inside the supervisor scope', () async {
      expect(await db.isEmployeeInScope('emp-2', ['team-1']), isTrue);
    });

    test('rejects a worker outside the scope', () async {
      // emp-2 is in team-1 only.
      expect(await db.isEmployeeInScope('emp-2', ['team-3']), isFalse);
    });

    test('rejects an unknown employee', () async {
      expect(await db.isEmployeeInScope('emp-nope', ['team-1']), isFalse);
    });

    test('an empty scope grants nothing', () async {
      expect(await db.isEmployeeInScope('emp-2', []), isFalse);
    });
  });

  group('getOrderByCode', () {
    test('matches an exact QR code', () async {
      final order = await db.getOrderByCode('QR-AKG-L');
      expect(order?['ma_don_hang'], 'DH-2026-00417');
    });

    test('matches an exact order code, case-insensitively', () async {
      final order = await db.getOrderByCode('dh-2026-00391');
      expect(order?['ma_sp'], 'SP-QJN');
    });

    test('a single letter matches nothing', () async {
      // The old substring fallback on product name made "a" match nearly every
      // order and return the first one.
      expect(await db.getOrderByCode('a'), isNull);
    });

    test('a partial product name matches nothing', () async {
      expect(await db.getOrderByCode('Áo'), isNull);
    });

    test('an empty code matches nothing', () async {
      expect(await db.getOrderByCode('   '), isNull);
    });

    test('reads the code out of a JSON QR payload', () async {
      final order = await db.getOrderByCode('{"productCode":"SP-AKG"}');
      expect(order?['ma_don_hang'], 'DH-2026-00417');
    });

    test('handles a JSON payload whose values contain commas', () async {
      // The previous regex-and-splitQueryString approach broke on this.
      const payload =
          '{"orderCode":"DH-2026-00502","dac_tinh":"Cotton 100%, cổ bẻ, trắng"}';

      final order = await db.getOrderByCode(payload);

      expect(order?['ma_sp'], 'SP-ATN');
    });

    test(
      'falls back to a bare code when the payload is not valid JSON',
      () async {
        expect(await db.getOrderByCode('{not json'), isNull);
      },
    );
  });
}
