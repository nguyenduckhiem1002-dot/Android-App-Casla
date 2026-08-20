// Integration tests for the current in-memory queue implementation.

import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/core/database/casla_database.dart';

void main() {
  group('In-memory pending queue flow', () {
    late CaslaDatabase db;

    setUp(() {
      CaslaDatabase.resetForTesting();
      db = CaslaDatabase.instance;
    });

    test(
      '1. Create production records while Offline & verify queue items',
      () async {
        final initialPendingCount = await db.watchPendingCount().first;

        // Simulate worker recording production while offline
        await db.recordProductionOffline(
          assignmentId: 'asg-001',
          quantity: 150.0,
          businessDate: '2026-08-08',
          shiftId: 'SHIFT_1',
          createdBy: 'MNV00123',
          deviceId: 'PDA-TEST-001',
        );

        final newPendingCount = await db.watchPendingCount().first;
        expect(newPendingCount, equals(initialPendingCount + 1));

        final syncFeed = await db.watchSyncFeed().first;
        final pendingItem = syncFeed.firstWhere(
          (item) => item['payload_summary'].toString().contains('+150'),
        );

        expect(pendingItem['status'], equals('PENDING'));
        expect(pendingItem['entity_type'], equals('PRODUCTION_RECORD'));
      },
    );

    test('2. Singleton retains state during the current process', () async {
      // Record item before restart
      await db.recordProductionOffline(
        assignmentId: 'asg-005',
        quantity: 80.0,
        businessDate: '2026-08-08',
        shiftId: 'SHIFT_1',
        createdBy: 'MNV00199',
        deviceId: 'PDA-TEST-002',
      );

      final sameProcessDb = CaslaDatabase.instance;
      final pendingCountAfterRestart = await sameProcessDb
          .watchPendingCount()
          .first;

      expect(pendingCountAfterRestart, greaterThanOrEqualTo(2));

      final history = await sameProcessDb.getProductionHistory('emp-5');
      final offlineRecord = history.firstWhere((r) => r['quantity'] == 80.0);
      expect(offlineRecord['sync_status'], equals('PENDING'));
    });

    test('3. Queue items can be removed after a simulated sync', () async {
      // Retrieve all pending queue items
      final pendingQueue = await db.watchSyncFeed().first;
      final pendingItems = pendingQueue
          .where((i) => i['status'] == 'PENDING')
          .toList();

      expect(pendingItems.isNotEmpty, isTrue);

      // Simulate background sync processing for each item
      for (final item in pendingItems) {
        // Simulate successful SAP POST transaction
        await db.deleteSyncQueueItem(item['id']);
      }

      final remainingPending = await db.watchPendingCount().first;
      expect(remainingPending, equals(0));
    });
  });
}
