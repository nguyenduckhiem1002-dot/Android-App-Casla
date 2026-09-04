import 'dart:async';

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

  tearDown(CaslaDatabase.resetForTesting);

  test('a new subscriber does not rebuild existing subscribers', () async {
    var firstEmissions = 0;
    final firstReady = Completer<void>();
    final firstSubscription = db.watchAllAssignments().listen((_) {
      firstEmissions++;
      if (!firstReady.isCompleted) firstReady.complete();
    });
    await firstReady.future;

    await db.watchAllAssignments().first;
    await Future<void>.delayed(Duration.zero);

    expect(firstEmissions, 1);
    await firstSubscription.cancel();
  });

  test('retry keeps the transaction queued until SAP confirms it', () async {
    await db.updateAssignmentStatus('asg-001', 'OPEN', 'FAILED');
    await db.insertSyncQueueItem({
      'id': 'retry-me',
      'entity_type': 'ASSIGNMENT',
      'entity_id': 'asg-001',
      'action': 'CREATE',
      'created_at_utc': 1,
      'retry_count': 0,
      'last_error_code': 'HTTP_500',
      'last_error_message': 'Server error',
    });

    expect(await db.retrySyncItem('retry-me'), isTrue);
    final item = (await db.watchSyncFeed().first).firstWhere(
      (entry) => entry['id'] == 'retry-me',
    );

    expect(item['status'], 'PENDING');
    expect(item['last_error_code'], isNull);
    expect((await db.getAssignmentById('asg-001'))!['sync_status'], 'PENDING');
  });

  test('outstanding count includes every unresolved sync state', () async {
    for (final item in await db.watchSyncQueue().first) {
      await db.deleteSyncQueueItem(item['id'] as String);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in const [
      ('sync-pending', 'PENDING'),
      ('sync-verify', 'NEEDS_VERIFICATION'),
      ('sync-failed', 'FAILED'),
    ]) {
      await db.insertSyncQueueItem({
        'id': entry.$1,
        'entity_type': 'ASSIGNMENT',
        'entity_id': 'asg-001',
        'action': 'CREATE',
        'status': entry.$2,
        'created_at_utc': now,
      });
    }

    expect(await db.watchOutstandingSyncCount().first, 3);
    expect(await db.watchPendingCount().first, 1);
  });
}
