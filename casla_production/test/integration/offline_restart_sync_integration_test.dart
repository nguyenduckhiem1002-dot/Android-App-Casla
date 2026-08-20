// Integration tests for the offline queue across a real app restart.
//
// These run against a file-backed database rather than `:memory:`, because the
// behaviour under test is precisely the one an in-memory store cannot provide:
// a record made while the PDA was offline is still there after the app dies.

import 'dart:io';

import 'package:casla_production/core/database/casla_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/database_test_harness.dart';

void main() {
  setUpAll(initSqfliteFfi);

  group('Offline pending queue flow', () {
    late Directory tempDir;
    late CaslaDatabase db;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('casla_offline_test');
      CaslaDatabase.databasePathOverride = p.join(tempDir.path, 'casla.db');
      db = CaslaDatabase.instance;
    });

    tearDown(() async {
      await CaslaDatabase.instance.close();
      CaslaDatabase.databasePathOverride = null;
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
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

    test('2. Pending work survives an app restart', () async {
      await db.recordProductionOffline(
        assignmentId: 'asg-005',
        quantity: 80.0,
        businessDate: '2026-08-08',
        shiftId: 'SHIFT_1',
        createdBy: 'MNV00199',
        deviceId: 'PDA-TEST-002',
      );

      // Close everything the way a process exit would, then come back up
      // against the same file.
      await db.close();
      final restarted = CaslaDatabase.instance;

      expect(identical(restarted, db), isFalse);
      expect(
        await restarted.watchPendingCount().first,
        greaterThanOrEqualTo(2),
      );

      final history = await restarted.getProductionHistory('emp-5');
      final offlineRecord = history.firstWhere((r) => r['quantity'] == 80.0);
      expect(offlineRecord['sync_status'], equals('PENDING'));
      expect(offlineRecord['device_id'], equals('PDA-TEST-002'));
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

    test('4. A FAILED item is never dropped by a restart', () async {
      // Spec 4.7: pending/failed transactions are kept until SAP confirms them,
      // no matter how long that takes.
      await db.updateSyncQueueError(
        'sync-002',
        'HTTP_400',
        'SAP từ chối bản ghi.',
        failureKind: 'permanent',
      );
      await db.close();

      final restarted = CaslaDatabase.instance;
      final feed = await restarted.watchSyncFeed().first;

      expect(feed.where((i) => i['status'] == 'FAILED').length, 2);
    });
  });
}
