// Scope and order-lookup tests.
//
// Both behaviours below were stubs that always said yes: getEmployeesByTeamIds
// ignored its argument and returned every worker, and getOrderByCode fell back
// to a substring match on the product name.

import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/utils/operation_qr_parser.dart';
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

    test('accepts SAP team codes as aliases for local team ids', () async {
      final workers = await db.getEmployeesByTeamIds(['TC01']);

      expect(workers, isNotEmpty);
      expect(workers.every((e) => (e['to_ids'] as List).contains('team-1')),
          isTrue);
    });
  });

  group('watchAssignmentsByTeams', () {
    test('returns only assignments inside the requested teams', () async {
      final all = await db.watchAllAssignments().first;
      final team1 = await db.watchAssignmentsByTeams(['team-1']).first;

      expect(team1, isNotEmpty);
      expect(team1.length, lessThan(all.length));
      for (final assignment in team1) {
        expect(assignment['to_id'], 'team-1');
      }
    });

    test('an empty team scope returns nothing', () async {
      expect(await db.watchAssignmentsByTeams([]).first, isEmpty);
    });

    test('resolves SAP team codes when reading local assignments', () async {
      final team1 = await db.watchAssignmentsByTeams(['TC01']).first;

      expect(team1, isNotEmpty);
      expect(team1.every((assignment) => assignment['to_id'] == 'team-1'),
          isTrue);
    });
  });

  group('getTeamsForScope', () {
    test('returns team master rows for SAP business codes', () async {
      final teams = await db.getTeamsForScope(['TC01', 'TC03']);

      expect(teams.map((team) => team['id']), containsAll(['team-1', 'team-3']));
      expect(teams.map((team) => team['ten_to']),
          containsAll(['Tổ Cắt 1', 'Tổ Cắt 3']));
    });
  });

  group('paged sync feed', () {
    test('uses a stable cursor and returns complete summaries', () async {
      await db.createAssignmentAtomically(
        assignment: {
          'id': 'page-assignment-a',
          'nhan_vien_id': 'emp-1',
          'don_hang_id': 'ord-1',
          'to_id': 'team-2',
          'assigned_quantity': 10.0,
          'business_date': '2026-09-05',
          'shift_id': 'SHIFT_1',
          'status': 'OPEN',
          'created_by': 'SUP-A',
          'occurred_at_utc': 10,
          'device_id': 'TEST',
          'sync_status': 'PENDING',
          'idempotency_key': 'page-a',
          'created_at_utc': 10,
        },
        queueItem: {
          'id': 'page-queue-a',
          'entity_type': 'ASSIGNMENT',
          'entity_id': 'page-assignment-a',
          'action': 'CREATE',
          'created_at_utc': 10,
          'retry_count': 0,
        },
        auditLog: {'id': 'page-audit-a', 'occurred_at_utc': 10},
      );
      await db.createAssignmentAtomically(
        assignment: {
          'id': 'page-assignment-b',
          'nhan_vien_id': 'emp-1',
          'don_hang_id': 'ord-1',
          'to_id': 'team-2',
          'assigned_quantity': 10.0,
          'business_date': '2026-09-05',
          'shift_id': 'SHIFT_1',
          'status': 'OPEN',
          'created_by': 'SUP-A',
          'occurred_at_utc': 11,
          'device_id': 'TEST',
          'sync_status': 'PENDING',
          'idempotency_key': 'page-b',
          'created_at_utc': 11,
        },
        queueItem: {
          'id': 'page-queue-b',
          'entity_type': 'ASSIGNMENT',
          'entity_id': 'page-assignment-b',
          'action': 'CREATE',
          'created_at_utc': 11,
          'retry_count': 0,
        },
        auditLog: {'id': 'page-audit-b', 'occurred_at_utc': 11},
      );
      final first = await db.getSyncFeedPage(
        actorId: 'SUP-A',
        teamIds: ['team-2'],
        filter: SyncFeedFilter.pending,
        pageSize: 1,
      );
      expect(first.items, hasLength(1));
      expect(first.items.single['id'], 'page-queue-b');
      expect(first.hasMore, isTrue);
      expect(first.totalCount, 2);
      final second = await db.getSyncFeedPage(
        actorId: 'SUP-A',
        teamIds: ['team-2'],
        filter: SyncFeedFilter.pending,
        pageSize: 1,
        beforeCreatedAtUtc: first.nextCreatedAtUtc,
        beforeId: first.nextId,
      );
      expect(second.items.single['id'], 'page-queue-a');
      expect(second.hasMore, isFalse);
      expect(second.pendingCount, 2);
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

  group('upsertOrderFromOperationQr', () {
    test('keeps SAP keys, product name and raw QR payload', () async {
      const raw = '{"ProductionOrder":"000001000020",'
          '"Operation":"0010","ProductCode":"200009017",'
          '"ProductName":"XE-EU24122750-G-V1-2cm",'
          '"UnitOfMeasure":"KG"}';

      final order = await db.upsertOrderFromOperationQr(
        OperationQrParser.parse(raw),
      );

      expect(order?['production_order'], '000001000020');
      expect(order?['operation'], '0010');
      expect(order?['ten_sp'], 'XE-EU24122750-G-V1-2cm');
      expect(order?['operation_qr_payload'], raw);
      expect(
        await db.getOrderByCode('000001000020-0010'),
        isNotNull,
      );
    });
  });
}
