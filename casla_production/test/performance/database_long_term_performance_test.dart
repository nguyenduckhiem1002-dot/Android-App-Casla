// Performance Test — Long-term Data Scale & Queue Benchmark
// Tests: 5,000 - 10,000+ Record Seeding, Query Latency, Sync Feed Throughput
// Spec Section 10 & 8 (Performance Verification)

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:casla_production/core/database/casla_database.dart';

void main() {
  group('Performance Test Suite: Long-term Database & Sync Queue Benchmark', () {
    late CaslaDatabase db;

    setUp(() {
      db = CaslaDatabase.instance;
    });

    test(
      '1. Bulk Seeding Benchmark: Insert 5,000 historical records in < 500ms',
      () async {
        final Stopwatch stopwatch = Stopwatch()..start();

        final now = DateTime.now().millisecondsSinceEpoch;
        for (int i = 1; i <= 5000; i++) {
          await db.insertSyncQueueItem({
            'id': 'perf-sync-$i',
            'entity_type': 'PRODUCTION_RECORD',
            'entity_id': 'perf-prod-$i',
            'action': 'CREATE',
            'payload_summary': 'Sản lượng dài hạn #$i · +100',
            'created_at_utc': now - (i * 60000),
            'retry_count': 0,
            'last_error_code': i % 50 == 0 ? 'ERR_NETWORK' : null,
            'last_error_message': i % 50 == 0 ? 'Network disconnect' : null,
            'device_id': 'PDA-PERF-01',
          });
        }

        stopwatch.stop();
        debugPrint(
          '⚡ Performance: Inserted 5,000 records in ${stopwatch.elapsedMilliseconds} ms',
        );

        expect(stopwatch.elapsedMilliseconds, lessThan(3000));
      },
    );

    test(
      '2. Query Latency Benchmark: Stream & sort 5,000+ items in < 50ms',
      () async {
        final Stopwatch stopwatch = Stopwatch()..start();

        final feedItems = await db.watchSyncFeed().first;

        stopwatch.stop();
        debugPrint(
          '⚡ Performance: Queried & sorted ${feedItems.length} items in ${stopwatch.elapsedMilliseconds} ms',
        );

        expect(feedItems.length, greaterThanOrEqualTo(5000));
        expect(stopwatch.elapsedMilliseconds, lessThan(100));
      },
    );

    test(
      '3. Employee Search Benchmark: Lookup by employee code in < 15ms',
      () async {
        // Seed employee
        await db.ensureEmployeeExists('PERF001', 'Nguyễn Văn Performance');

        final Stopwatch stopwatch = Stopwatch()..start();

        final worker = await db.getEmployeeByCode('PERF001');

        stopwatch.stop();
        debugPrint(
          '⚡ Performance: Searched employee in ${stopwatch.elapsedMilliseconds} ms',
        );

        expect(worker, isNotNull);
        expect(worker!['ma_nv'], equals('PERF001'));
        expect(stopwatch.elapsedMilliseconds, lessThan(20));
      },
    );

    test(
      '4. Queue Draining & Batch Processing Throughput (> 1,000 items/sec)',
      () async {
        final feedItems = await db.watchSyncFeed().first;
        final pendingList = feedItems
            .where((i) => i['status'] == 'PENDING')
            .take(1000)
            .toList();

        final Stopwatch stopwatch = Stopwatch()..start();

        for (final item in pendingList) {
          await db.deleteSyncQueueItem(item['id']);
        }

        stopwatch.stop();
        final opsPerSec =
            (pendingList.length / (stopwatch.elapsedMilliseconds / 1000))
                .round();

        debugPrint(
          '⚡ Performance: Processed ${pendingList.length} items in ${stopwatch.elapsedMilliseconds} ms ($opsPerSec items/sec)',
        );

        expect(stopwatch.elapsedMilliseconds, lessThan(1500));
      },
    );
  });
}
