import 'package:casla_production/core/database/casla_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();
  late CaslaDatabase db;
  setUp(() {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
  });

  test('cache retention never removes durable queue rows', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final entries = [
      for (var i = 0; i < 1000; i++)
        {
          'transaction_uuid': 'tx-$i',
          'execution_date': '2026-09-05',
          'worker_id': 'worker-$i',
          'worker_name': 'Worker $i',
          'production_order': 'ORDER-$i',
          'operation': '0010',
          'plant': 'PLANT',
          'work_center': 'CENTER',
          'transaction_type': 'CONFIRM',
          'quantity': 1.0,
          'unit_of_measure': 'cái',
          'transaction_status': 'POSTED',
        },
    ];
    await db.insertSyncQueueItem({
      'id': 'durable-retention',
      'entity_type': 'ASSIGNMENT',
      'entity_id': 'asg-001',
      'action': 'CREATE',
      'created_at_utc': now,
      'retry_count': 0,
    });
    await db.replaceWorkHistoryCache(
      cacheKey: 'large-cache',
      subjectId: 'subject',
      rangeCode: 'DAY',
      scopeCode: 'SELF',
      resultDateFrom: '2026-09-05',
      resultDateTo: '2026-09-05',
      isTruncated: false,
      fetchedAtUtc: now,
      entries: entries,
      workers: const [],
    );
    expect(await db.getSyncQueueItemById('durable-retention'), isNotNull);
  });

  Future<void> writeSnapshot(String cacheKey, DateTime fetchedAt) =>
      db.replaceWorkHistoryCache(
        cacheKey: cacheKey,
        subjectId: 'subject',
        rangeCode: 'D',
        scopeCode: 'S',
        resultDateFrom: '2026-09-04',
        resultDateTo: '2026-09-04',
        isTruncated: false,
        fetchedAtUtc: fetchedAt.millisecondsSinceEpoch,
        entries: const [],
        workers: const [],
      );

  test(
    'retention is measured from the snapshot clock, not the wall clock',
    () async {
      // The repository injects its own clock. A snapshot that is "fresh" by
      // that clock must survive even when the wall clock has moved on; the
      // 30-day window applies between snapshots.
      final anchor = DateTime.now().subtract(const Duration(days: 60));

      await writeSnapshot('old-window', anchor);
      expect(await db.getWorkHistoryCache('old-window'), isNotNull);

      await writeSnapshot('same-day', anchor.add(const Duration(hours: 1)));
      expect(await db.getWorkHistoryCache('old-window'), isNotNull);
      expect(await db.getWorkHistoryCache('same-day'), isNotNull);

      await writeSnapshot('next-month', anchor.add(const Duration(days: 31)));
      expect(await db.getWorkHistoryCache('old-window'), isNull);
      expect(await db.getWorkHistoryCache('same-day'), isNull);
      expect(await db.getWorkHistoryCache('next-month'), isNotNull);
    },
  );
}
