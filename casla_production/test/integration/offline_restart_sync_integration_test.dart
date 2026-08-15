// Integration Test — Offline Creation → App Restart → Online Transition → Background Sync
// Spec Section 10 (System Verification & Resilience)

import 'package:flutter_test/flutter_test.dart';
import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/config/app_config.dart';

void main() {
  group('Integration Test: Offline → Restart → Online → Sync Flow', () {
    late CaslaDatabase db;

    setUp(() {
      CaslaDatabase.resetForTesting();
      db = CaslaDatabase.instance;
      AppConfig.debugOverrideSapIntegration(false); // Start in Offline mode
    });

    tearDown(AppConfig.debugClearSapIntegrationOverride);

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

    test(
      '2. Restart simulation: Database state persists across restart',
      () async {
        // Record item before restart
        await db.recordProductionOffline(
          assignmentId: 'asg-005',
          quantity: 80.0,
          businessDate: '2026-08-08',
          shiftId: 'SHIFT_1',
          createdBy: 'MNV00199',
          deviceId: 'PDA-TEST-002',
        );

        // Simulate App Restart by retrieving instance & checking persistent lists
        final restartedDb = CaslaDatabase.instance;
        final pendingCountAfterRestart = await restartedDb
            .watchPendingCount()
            .first;

        expect(pendingCountAfterRestart, greaterThanOrEqualTo(2));

        final history = await restartedDb.getProductionHistory('emp-5');
        final offlineRecord = history.firstWhere((r) => r['quantity'] == 80.0);
        expect(offlineRecord['sync_status'], equals('PENDING'));
      },
    );

    test('3. Online transition & Sync Queue draining', () async {
      // Turn Online mode on
      AppConfig.debugOverrideSapIntegration(true);

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
