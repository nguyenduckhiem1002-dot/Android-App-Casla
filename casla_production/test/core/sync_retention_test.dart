// Unsent work is kept for its own day only (decided 2026-10-28): the next
// day, the first thing the app does with the queue is drop what is left,
// record and all. Synced history and today's work are untouched.

import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/sync/sync_retention.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();

  group('isExpiredSyncItem', () {
    final now = DateTime(2026, 10, 28, 7, 30);

    test('an entry from yesterday has expired, even at 00:01', () {
      final lateYesterday = DateTime(2026, 10, 27, 23, 59);
      expect(
        isExpiredSyncItem(
          createdAtUtcMs: lateYesterday.toUtc().millisecondsSinceEpoch,
          now: DateTime(2026, 10, 28, 0, 1),
        ),
        isTrue,
      );
    });

    test('an entry from today is kept however old within the day', () {
      final earlyToday = DateTime(2026, 10, 28, 0, 5);
      expect(
        isExpiredSyncItem(
          createdAtUtcMs: earlyToday.toUtc().millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });

    test('a missing timestamp never expires', () {
      expect(isExpiredSyncItem(createdAtUtcMs: 0, now: now), isFalse);
    });
  });

  group('CaslaDatabase.purgeExpiredSyncItems', () {
    late CaslaDatabase db;

    setUp(() {
      CaslaDatabase.resetForTesting();
      db = CaslaDatabase.instance;
    });

    Future<void> queueProduction(
      String id, {
      required int createdAtUtc,
      required String status,
      String? sapId,
    }) async {
      await db.insertProductionRecord({
        'id': id,
        'phan_cong_id': 'asg-001',
        'quantity': 5.0,
        'defect_quantity': 0.0,
        'business_date': '2026-10-27',
        'shift_id': 'SHIFT_1',
        'created_by': 'MNV00100',
        'occurred_at_utc': createdAtUtc,
        'device_id': 'PDA-TEST',
        'sync_status': status == 'SYNCED' ? 'SYNCED' : 'PENDING',
        'idempotency_key': 'idem-$id',
        'created_at_utc': createdAtUtc,
        'sap_id': ?sapId,
      });
      if (status != 'SYNCED') {
        await db.insertSyncQueueItem({
          'id': 'queue-$id',
          'entity_type': 'PRODUCTION',
          'entity_id': id,
          'action': 'CREATE',
          'idempotency_key': 'idem-$id',
          'priority': 5,
          'status': status,
          'retry_count': 0,
          'created_at_utc': createdAtUtc,
        });
      }
    }

    test(
      'drops yesterday\'s unsent work with its records, keeps the rest',
      () async {
        final now = DateTime(2026, 10, 28, 8);
        final yesterday = DateTime(
          2026,
          10,
          27,
          15,
        ).toUtc().millisecondsSinceEpoch;
        final today = DateTime(2026, 10, 28, 6).toUtc().millisecondsSinceEpoch;

        await queueProduction(
          'old-failed',
          createdAtUtc: yesterday,
          status: 'FAILED',
        );
        await queueProduction(
          'old-verify',
          createdAtUtc: yesterday,
          status: 'NEEDS_VERIFICATION',
        );
        await queueProduction(
          'old-pending',
          createdAtUtc: yesterday,
          status: 'PENDING',
        );
        await queueProduction(
          'old-synced',
          createdAtUtc: yesterday,
          status: 'SYNCED',
          sapId: 'sap-old',
        );
        await queueProduction(
          'new-failed',
          createdAtUtc: today,
          status: 'FAILED',
        );

        final purged = await db.purgeExpiredSyncItems(now: now);

        expect(purged, 3);
        final queue = await db.getSyncQueueItemById('queue-old-failed');
        expect(queue, isNull);
        expect(await db.getSyncQueueItemById('queue-old-verify'), isNull);
        expect(await db.getSyncQueueItemById('queue-old-pending'), isNull);
        expect(await db.getSyncQueueItemById('queue-new-failed'), isNotNull);

        // Seed asg-001 holds 436 completed; the five test rows added 25. The
        // three expired ones are gone with their quantities, the synced one and
        // today's one still count.
        expect(await db.getCompletedQuantity('asg-001'), closeTo(446.0, 0.001));
      },
    );

    test('a second pass on the same day finds nothing to do', () async {
      final now = DateTime(2026, 10, 28, 8);
      final yesterday = DateTime(
        2026,
        10,
        27,
        15,
      ).toUtc().millisecondsSinceEpoch;
      await queueProduction(
        'old-failed',
        createdAtUtc: yesterday,
        status: 'FAILED',
      );

      expect(await db.purgeExpiredSyncItems(now: now), 1);
      expect(await db.purgeExpiredSyncItems(now: now), 0);
    });
  });
}
