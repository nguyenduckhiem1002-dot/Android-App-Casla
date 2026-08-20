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
    await db.insertSyncQueueItem({
      'id': 'retry-me',
      'entity_type': 'ASSIGNMENT',
      'entity_id': 'asg-retry',
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
  });
}
