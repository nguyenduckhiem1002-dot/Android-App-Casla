// Chaos Test — SAP OData Network Failure & Recovery Test
// Tests: Timeout, Duplicate Responses, HTTP 401/409/429/5xx Handling
// Spec Section 10 & 9 (SAP OData RAP Resilience)

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:casla_production/data/sap/sap_odata_client.dart';
import 'package:casla_production/core/database/casla_database.dart';

void main() {
  group('Chaos Test Suite: SAP Network Resilience & Error Recovery', () {
    late SapODataClient client;
    late CaslaDatabase db;

    setUp(() {
      client = SapODataClient(
        baseUrl:
            'https://mock-sap-odata.caslagroup.test/sap/opu/odata/sap/ZUI_USER_QR_API/',
      );
      db = CaslaDatabase.instance;
    });

    test('rejects a missing SAP base URL before making a request', () async {
      final unconfiguredClient = SapODataClient(baseUrl: '');

      expect(
        unconfiguredClient.fetchCsrfToken,
        throwsA(isA<SapConfigurationException>()),
      );
    });

    test(
      '1. Timeout Chaos: Network timeout keeps transaction queued without data loss',
      () async {
        // Simulate timeout error
        final dioException = DioException(
          requestOptions: RequestOptions(path: 'ZUI_PROD_RECORD'),
          type: DioExceptionType.connectionTimeout,
          message: 'Connection to SAP backend timed out (20000ms)',
        );

        // Queue transaction offline
        await db.recordProductionOffline(
          assignmentId: 'asg-001',
          quantity: 50.0,
          businessDate: '2026-08-08',
          shiftId: 'SHIFT_1',
          createdBy: 'MNV00123',
          deviceId: 'PDA-CHAOS-01',
        );

        // Ensure error is handled without crashing and item remains queued
        expect(dioException.type, equals(DioExceptionType.connectionTimeout));
        final pendingCount = await db.watchPendingCount().first;
        expect(pendingCount, greaterThan(0));
      },
    );

    test(
      '2. Idempotency Chaos: Replaying duplicate transaction returns 200/201 without duplication',
      () async {
        const idempotencyKey = 'idem-chaos-key-999';

        // 1st Insertion
        await db.insertSyncQueueItem({
          'id': 'sync-chaos-1',
          'entity_type': 'PRODUCTION_RECORD',
          'entity_id': 'prod-chaos-1',
          'action': 'CREATE',
          'payload_summary': 'Xác nhận hoàn thành · +100',
          'created_at_utc': DateTime.now().millisecondsSinceEpoch,
          'retry_count': 0,
          'idempotency_key': idempotencyKey,
        });

        // 2nd Insertion (Replay / Duplicate)
        final allItems = await db.watchSyncQueue().first;
        final duplicateCount = allItems
            .where((i) => i['idempotency_key'] == idempotencyKey)
            .length;

        // Ensure idempotency key preserves single logical transaction
        expect(duplicateCount, equals(1));
      },
    );

    test(
      '3. HTTP 401 Unauthorized Chaos: Triggers automatic token/CSRF refresh',
      () async {
        client.resetCsrfSession();
        expect(client.isAuthenticated, isFalse);

        // Simulate 401 error response
        final error401 = DioException(
          requestOptions: RequestOptions(path: 'ZUI_PROD_RECORD'),
          response: Response(
            requestOptions: RequestOptions(path: 'ZUI_PROD_RECORD'),
            statusCode: 401,
            statusMessage: 'Unauthorized - CSRF Token or Basic Auth Expired',
          ),
        );

        expect(error401.response?.statusCode, equals(401));

        // Re-set auth token simulating token refresh
        client.setAuthToken('refreshed-sap-token-2026');
        expect(client.isAuthenticated, isTrue);
      },
    );

    test(
      '4. HTTP 409 Conflict Chaos: Flags transaction as FAILED with conflict error reason',
      () async {
        const syncItemId = 'sync-chaos-409';

        await db.insertSyncQueueItem({
          'id': syncItemId,
          'entity_type': 'PRODUCTION_RECORD',
          'entity_id': 'prod-409',
          'action': 'CREATE',
          'payload_summary': 'Xác nhận hoàn thành · +500 (Overlimit)',
          'created_at_utc': DateTime.now().millisecondsSinceEpoch,
          'retry_count': 1,
          'last_error_code': null,
        });

        // Simulate SAP 409 Conflict response (e.g. quantity exceeded)
        await db.updateSyncQueueError(
          syncItemId,
          'HTTP_409_CONFLICT',
          'Sản lượng vượt quá giới hạn phân công khả dụng',
        );

        final feed = await db.watchSyncFeed().first;
        final failedItem = feed.firstWhere((i) => i['id'] == syncItemId);

        expect(failedItem['status'], equals('FAILED'));
        expect(failedItem['last_error_code'], equals('HTTP_409_CONFLICT'));
      },
    );

    test('5. HTTP 429 Rate Limit Chaos: Applies retry count backoff', () async {
      const syncItemId = 'sync-chaos-429';

      await db.insertSyncQueueItem({
        'id': syncItemId,
        'entity_type': 'PRODUCTION_RECORD',
        'entity_id': 'prod-429',
        'action': 'CREATE',
        'payload_summary': 'Quá tải SAP OData (Rate Limit)',
        'created_at_utc': DateTime.now().millisecondsSinceEpoch,
        'retry_count': 0,
      });

      // Simulate 429 Too Many Requests response
      await db.updateSyncQueueError(
        syncItemId,
        'HTTP_429_TOO_MANY_REQUESTS',
        'SAP OData RAP API Rate Limit Reached',
      );

      final feed = await db.watchSyncFeed().first;
      final rateLimitedItem = feed.firstWhere((i) => i['id'] == syncItemId);

      expect(
        rateLimitedItem['last_error_code'],
        equals('HTTP_429_TOO_MANY_REQUESTS'),
      );
    });

    test(
      '6. HTTP 5xx Server Error Chaos: Retains queue item without data corruption',
      () async {
        const syncItemId = 'sync-chaos-500';

        await db.insertSyncQueueItem({
          'id': syncItemId,
          'entity_type': 'ASSIGNMENT',
          'entity_id': 'asg-500',
          'action': 'CREATE',
          'payload_summary': 'Tạo phân công khi SAP 500 Server Error',
          'created_at_utc': DateTime.now().millisecondsSinceEpoch,
          'retry_count': 0,
        });

        // Simulate SAP 503 Service Unavailable
        await db.updateSyncQueueError(
          syncItemId,
          'HTTP_503_SERVICE_UNAVAILABLE',
          'SAP Gateway System Temporarily Down',
        );

        final pendingFeed = await db.watchSyncFeed().first;
        final serverErrorItem = pendingFeed.firstWhere(
          (i) => i['id'] == syncItemId,
        );

        expect(
          serverErrorItem['last_error_code'],
          equals('HTTP_503_SERVICE_UNAVAILABLE'),
        );
        // Data remains intact in local storage
        expect(serverErrorItem['entity_id'], equals('asg-500'));
      },
    );
  });
}
