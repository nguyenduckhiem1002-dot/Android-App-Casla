import 'dart:async';

import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/telemetry/field_telemetry.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/data/repositories/confirmation_targets.dart';
import 'package:casla_production/data/sap/odata_error.dart';
import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/core/utils/operation_qr_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/database_test_harness.dart';

void main() {
  useInMemoryDatabase();

  late CaslaDatabase db;

  setUp(() {
    CaslaDatabase.resetForTesting();
    db = CaslaDatabase.instance;
  });

  test('fresh cache avoids a second SAP call', () async {
    var calls = 0;
    final now = DateTime(2026, 9, 4, 12);
    final telemetry = FieldTelemetry();
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => 'user-a:self',
      telemetry: telemetry,
      now: () => now,
      loadRemote:
          ({
            required range,
            dateFrom,
            dateTo,
            shiftId,
            productionOrder,
            operation,
          }) async {
            calls++;
            return _result(
              workerName: 'Nguyễn Văn A',
              productionOrder: '990010001234',
              operation: '0090',
            );
          },
    );

    final first = await repo.getWorkHistory(range: HistoryRange.month);
    final second = await repo.getWorkHistory(range: HistoryRange.month);

    expect(calls, 1);
    expect(first.workers.single.workerName, 'Nguyễn Văn A');
    expect(second.workers.single.workerName, 'Nguyễn Văn A');
    final metrics = telemetry.snapshot();
    expect(metrics.count(FieldMetric.workHistoryCacheMiss), 1);
    expect(metrics.count(FieldMetric.workHistoryCacheHit), 1);
    expect(metrics.count(FieldMetric.workHistoryRemoteSuccess), 1);
  });

  test(
    'a SAP failure is reported when the fallback cache lacks lineage',
    () async {
      var failing = false;
      final repo = WorkHistoryRepositoryImpl(
        db,
        cacheSubject: () => 'user-a:team',
        loadRemote:
            ({
              required range,
              dateFrom,
              dateTo,
              shiftId,
              productionOrder,
              operation,
            }) async {
              if (failing) throw const SapBusinessError('SABP_BEHV/100');
              return WorkHistoryResult(
                scopeCode: 'T',
                dateFrom: DateTime(2026, 9, 24),
                dateTo: DateTime(2026, 9, 24),
                isTruncated: false,
                entries: [
                  // As a cache written before lineage was stored reads back.
                  WorkHistoryEntry(
                    transactionUuid: 'R1',
                    executionDate: DateTime(2026, 9, 24, 4),
                    workerId: 'NV01',
                    workerName: 'A',
                    productionOrder: '010140000365',
                    operation: '0020',
                    plant: '6711',
                    workCenter: 'CL100077',
                    transactionType: 'REASSIGN',
                    quantity: 60,
                    unitOfMeasure: 'CHC',
                    transactionStatus: 'POSTED',
                  ),
                ],
                workers: const [],
              );
            },
      );
      Future<WorkHistoryResult> load() => loadConfirmationHistory(
        repo,
        range: HistoryRange.day,
        dateFrom: DateTime(2026, 9, 24),
        dateTo: DateTime(2026, 9, 24),
        shiftId: 'DAY',
        workId: 'XM2.002',
      );

      await load();
      failing = true;
      await expectLater(load(), throwsA(isA<SapBusinessError>()));
    },
  );

  test('cache keeps the work date and lineage of each row', () async {
    var calls = 0;
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => 'user-a:team',
      loadRemote:
          ({
            required range,
            dateFrom,
            dateTo,
            shiftId,
            productionOrder,
            operation,
          }) async {
            calls++;
            return WorkHistoryResult(
              scopeCode: 'T',
              dateFrom: DateTime(2026, 9, 24),
              dateTo: DateTime(2026, 9, 24),
              isTruncated: false,
              entries: [
                WorkHistoryEntry(
                  transactionUuid: 'C1',
                  // Night shift: posted after midnight, belongs to the 24th.
                  executionDate: DateTime(2026, 9, 25, 2, 15),
                  reportedWorkDate: DateTime(2026, 9, 24),
                  workerId: 'NV01',
                  workerName: 'A',
                  productionOrder: '010140000365',
                  operation: '0020',
                  plant: '6711',
                  workCenter: 'CL100077',
                  transactionType: 'CONFIRM',
                  quantity: 5,
                  unitOfMeasure: 'CHC',
                  transactionStatus: 'POSTED',
                  originalTransactionUuid: 'R1',
                ),
              ],
              workers: const [],
            );
          },
    );

    await repo.getWorkHistory(range: HistoryRange.day);
    final cached = (await repo.getWorkHistory(
      range: HistoryRange.day,
    )).entries.single;

    expect(calls, 1, reason: 'the second read is served from the cache');
    expect(cached.workDate, DateTime(2026, 9, 24));
    expect(cached.executionDate.hour, 2);
    expect(cached.originalTransactionUuid, 'R1');
  });

  test(
    'cached history fills metadata learned after the snapshot was stored',
    () async {
      var calls = 0;
      final repo = WorkHistoryRepositoryImpl(
        db,
        cacheSubject: () => 'user-a:self',
        loadRemote:
            ({
              required range,
              dateFrom,
              dateTo,
              shiftId,
              productionOrder,
              operation,
            }) async {
              calls++;
              return _result(
                workerName: 'Nguyễn Văn A',
                productionOrder: '990010001234',
                operation: '0090',
              );
            },
      );

      // The first snapshot predates the local QR/order metadata. This is the
      // shape of existing devices after the history-cache schema upgrade.
      final first = await repo.getWorkHistory(range: HistoryRange.day);
      expect(first.entries.single.operationName, isEmpty);
      expect(first.entries.single.productName, isEmpty);

      await db.upsertOrderFromOperationQr(
        OperationQrParser.parse(
          '{"ProductionOrder":"990010001234",'
          '"Operation":"0090","OperationName":"May thân",'
          '"ProductCode":"200009017",'
          '"ProductName":"Áo khoác công nhân",'
          '"SalesOrder":"5000012345","SalesOrderItem":"000010"}',
        ),
      );

      final cached = await repo.getWorkHistory(range: HistoryRange.day);

      expect(calls, 1);
      expect(cached.entries.single.operationName, 'May thân');
      expect(cached.entries.single.productName, 'Áo khoác công nhân');
      expect(cached.entries.single.productCode, '200009017');
      expect(cached.entries.single.salesOrder, '5000012345');
      expect(cached.entries.single.salesOrderItem, '000010');
    },
  );

  test('refresh keeps metadata from another cached history window', () async {
    var calls = 0;
    final fixedNow = DateTime(2026, 9, 17, 12);
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => 'user-a:self',
      now: () => fixedNow,
      loadRemote:
          ({
            required range,
            dateFrom,
            dateTo,
            shiftId,
            productionOrder,
            operation,
          }) async {
            calls++;
            return _result(
              workerName: 'Nguyễn Văn A',
              productionOrder: '990020001234',
              operation: '0091',
              operationName: calls == 1 ? 'May thân' : '',
              productName: calls == 1 ? 'Áo khoác công nhân' : '',
              productCode: calls == 1 ? '200009017' : '',
              salesOrder: calls == 1 ? '5000012345' : '',
              salesOrderItem: calls == 1 ? '000010' : '',
            );
          },
    );

    await repo.getWorkHistory(range: HistoryRange.day);
    final switchedWindow = await repo.getWorkHistory(
      range: HistoryRange.month,
      forceRefresh: true,
    );

    expect(calls, 2);
    expect(switchedWindow.entries.single.operationName, 'May thân');
    expect(switchedWindow.entries.single.productName, 'Áo khoác công nhân');
    expect(switchedWindow.entries.single.productCode, '200009017');
    expect(switchedWindow.entries.single.salesOrder, '5000012345');
    expect(switchedWindow.entries.single.salesOrderItem, '000010');
    expect(switchedWindow.entries.single.quantity, 10);

    // Replace the month snapshot with the actual failure shape: newer cache
    // metadata is blank while the older day snapshot remains complete.
    await db.replaceWorkHistoryCache(
      cacheKey: 'user-a:self|M|2026-09-17|2026-09-17||||',
      subjectId: 'user-a:self',
      rangeCode: HistoryRange.month.code,
      scopeCode: 'S',
      resultDateFrom: '2026-09-17',
      resultDateTo: '2026-09-17',
      isTruncated: false,
      fetchedAtUtc: fixedNow.millisecondsSinceEpoch,
      entries: [
        {
          'transaction_uuid': 'tx-blank',
          'execution_date': fixedNow.toIso8601String(),
          'worker_id': 'MNV00123',
          'worker_name': 'Nguyễn Văn A',
          'production_order': '990020001234',
          'operation': '0091',
          'operation_name': '',
          'product_name': '',
          'product_code': '',
          'sales_order': '',
          'sales_order_item': '',
          'plant': '6720',
          'work_center': 'WC-01',
          'transaction_type': 'CONFIRM',
          'quantity': 27,
          'unit_of_measure': 'PC',
          'transaction_status': 'SUCCESS',
        },
      ],
      workers: [
        {
          'worker_id': 'MNV00123',
          'worker_name': 'Nguyễn Văn A',
          'assigned_quantity': 20,
          'completed_quantity': 27,
          'remaining_quantity': 0,
          'unit_of_measure': 'PC',
          'transaction_count': 1,
        },
      ],
    );

    final seeded = await db.getWorkHistoryCache(
      'user-a:self|M|2026-09-17|2026-09-17||||',
    );
    expect(seeded?['entries'], isNotEmpty);
    final seededEntries = (seeded!['entries'] as List)
        .cast<Map<String, dynamic>>();
    expect(seededEntries.single['operation_name'], isEmpty);

    final cachedAgain = await repo.getWorkHistory(range: HistoryRange.month);
    expect(calls, 2);
    expect(cachedAgain.entries.single.transactionUuid, 'tx-blank');
    expect(cachedAgain.entries.single.quantity, 27);
    expect(cachedAgain.entries.single.operationName, 'May thân');
    expect(cachedAgain.entries.single.productName, 'Áo khoác công nhân');
    expect(cachedAgain.entries.single.salesOrderItem, '000010');
  });

  test('prior history metadata is isolated by cache subject', () async {
    var subject = 'user-a:self';
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => subject,
      loadRemote:
          ({
            required range,
            dateFrom,
            dateTo,
            shiftId,
            productionOrder,
            operation,
          }) async => _result(
            workerName: 'Nguyễn Văn A',
            operationName: subject.startsWith('user-a') ? 'May thân' : '',
          ),
    );

    await repo.getWorkHistory(range: HistoryRange.day);
    subject = 'user-b:self';
    final otherUser = await repo.getWorkHistory(
      range: HistoryRange.month,
      forceRefresh: true,
    );

    expect(otherUser.entries.single.operationName, isEmpty);
  });

  test(
    'watcher keeps cached data, reports refresh failure, then recovers',
    () async {
      var shouldFail = false;
      final repo = WorkHistoryRepositoryImpl(
        db,
        cacheSubject: () => 'worker-recovery',
        loadRemote:
            ({
              required range,
              dateFrom,
              dateTo,
              shiftId,
              productionOrder,
              operation,
            }) async {
              if (shouldFail) throw Exception('offline');
              return _result(workerName: 'Cached worker');
            },
      );
      await repo.getWorkHistory(range: HistoryRange.day);
      final first = Completer<void>();
      final errorSeen = Completer<void>();
      final recovered = Completer<void>();
      var dataEvents = 0;
      final subscription = repo
          .watchWorkHistory(range: HistoryRange.day)
          .listen(
            (result) {
              expect(result.workers.single.workerName, 'Cached worker');
              dataEvents++;
              if (!first.isCompleted) {
                first.complete();
              } else if (!recovered.isCompleted) {
                recovered.complete();
              }
            },
            onError: (Object error) {
              if (!errorSeen.isCompleted) errorSeen.complete();
            },
          );
      try {
        await first.future;
        shouldFail = true;
        await expectLater(
          repo.getWorkHistory(range: HistoryRange.day, forceRefresh: true),
          throwsException,
        );
        await errorSeen.future;
        expect(
          dataEvents,
          1,
          reason:
              'An offline failure must not replace data with an empty report',
        );
        shouldFail = false;
        await repo.getWorkHistory(range: HistoryRange.day, forceRefresh: true);
        await recovered.future;
        expect(dataEvents, 2);
      } finally {
        await subscription.cancel();
        repo.dispose();
      }
    },
  );

  test('stale cache is returned while one refresh is shared', () async {
    var now = DateTime(2026, 9, 4, 12);
    var calls = 0;
    var currentName = 'Bản cũ';
    final refreshGate = Completer<void>();

    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => 'user-a:self',
      freshFor: const Duration(minutes: 2),
      now: () => now,
      loadRemote:
          ({
            required range,
            dateFrom,
            dateTo,
            shiftId,
            productionOrder,
            operation,
          }) async {
            calls++;
            if (calls == 2) await refreshGate.future;
            return _result(workerName: currentName);
          },
    );

    await repo.getWorkHistory(range: HistoryRange.month);
    now = now.add(const Duration(minutes: 3));
    currentName = 'Bản mới';

    final stale = await repo.getWorkHistory(range: HistoryRange.month);
    expect(stale.workers.single.workerName, 'Bản cũ');
    expect(calls, 2);

    final joinedRefresh = repo.getWorkHistory(
      range: HistoryRange.month,
      forceRefresh: true,
    );
    expect(calls, 2, reason: 'force refresh must join the in-flight request');

    refreshGate.complete();
    final refreshed = await joinedRefresh;
    expect(refreshed.workers.single.workerName, 'Bản mới');
    expect(calls, 2);
  });

  test('remote failures are counted without recording request data', () async {
    final telemetry = FieldTelemetry();
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => 'user-a:self',
      telemetry: telemetry,
      loadRemote:
          ({
            required range,
            dateFrom,
            dateTo,
            shiftId,
            productionOrder,
            operation,
          }) async {
            throw Exception('offline');
          },
    );

    await expectLater(
      repo.getWorkHistory(range: HistoryRange.day),
      throwsException,
    );

    final snapshot = telemetry.snapshot();
    final diagnostics = snapshot.toDiagnosticMap();
    expect(snapshot.count(FieldMetric.workHistoryCacheMiss), 1);
    expect(snapshot.count(FieldMetric.workHistoryRemoteFailure), 1);
    expect(diagnostics.toString(), isNot(contains('user-a')));
    expect(diagnostics.toString(), isNot(contains('offline')));
  });

  test('cache namespace prevents cross-account history reuse', () async {
    var subject = 'user-a:self';
    var workerName = 'User A';
    var calls = 0;
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => subject,
      loadRemote:
          ({
            required range,
            dateFrom,
            dateTo,
            shiftId,
            productionOrder,
            operation,
          }) async {
            calls++;
            return _result(workerName: workerName);
          },
    );

    final a = await repo.getWorkHistory(range: HistoryRange.day);
    subject = 'user-b:self';
    workerName = 'User B';
    final b = await repo.getWorkHistory(range: HistoryRange.day);

    expect(a.workers.single.workerName, 'User A');
    expect(b.workers.single.workerName, 'User B');
    expect(calls, 2);
  });

  test('batch employee upsert preserves existing team scope', () async {
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => 'user-a:team',
      loadRemote:
          ({
            required range,
            dateFrom,
            dateTo,
            shiftId,
            productionOrder,
            operation,
          }) async => _result(workerId: 'MNV00123', workerName: 'Tên cập nhật'),
    );

    await repo.getWorkHistory(range: HistoryRange.month, forceRefresh: true);

    final existing = await db.getEmployeeByCode('MNV00123');
    expect(existing?['ten'], 'Tên cập nhật');
    expect(existing?['to_ids'], contains('team-2'));
  });

  test('new workers are cached without inventing team scope', () async {
    final repo = WorkHistoryRepositoryImpl(
      db,
      cacheSubject: () => 'user-a:team',
      loadRemote:
          ({
            required range,
            dateFrom,
            dateTo,
            shiftId,
            productionOrder,
            operation,
          }) async =>
              _result(workerId: 'MNV00999', workerName: 'Nhân viên SAP'),
    );

    await repo.getWorkHistory(range: HistoryRange.month, forceRefresh: true);

    final inserted = await db.getEmployeeByCode('MNV00999');
    expect(inserted?['ten'], 'Nhân viên SAP');
    expect(inserted?['to_ids'], isEmpty);
  });

  test(
    'known authorization rejection clears the active cache namespace',
    () async {
      var calls = 0;
      var rejected = false;
      var authorizationCallbacks = 0;
      final repo = WorkHistoryRepositoryImpl(
        db,
        cacheSubject: () => 'active-session',
        onAuthorizationRejected: (_) async => authorizationCallbacks++,
        loadRemote:
            ({
              required range,
              dateFrom,
              dateTo,
              shiftId,
              productionOrder,
              operation,
            }) async {
              calls++;
              if (rejected) {
                throw const SapBusinessError('TOKEN_INVALID_OR_EXPIRED');
              }
              return _result(workerName: 'Bản đã lưu');
            },
      );

      await repo.getWorkHistory(range: HistoryRange.day);
      rejected = true;
      await expectLater(
        repo.getWorkHistory(range: HistoryRange.day, forceRefresh: true),
        throwsA(isA<SapBusinessError>()),
      );

      expect(authorizationCallbacks, 1);
      rejected = false;
      final refreshed = await repo.getWorkHistory(range: HistoryRange.day);
      expect(refreshed.workers.single.workerName, 'Bản đã lưu');
      expect(calls, 3, reason: 'the rejected cache must not be reused');
      repo.dispose();
    },
  );

  test(
    'watchWorkHistory publishes a background refresh without rebuilding it',
    () async {
      var workerName = 'Bản đầu';
      final repo = WorkHistoryRepositoryImpl(
        db,
        cacheSubject: () => 'active-session',
        loadRemote:
            ({
              required range,
              dateFrom,
              dateTo,
              shiftId,
              productionOrder,
              operation,
            }) async => _result(workerName: workerName),
      );
      final values = <String>[];
      final firstValue = Completer<void>();
      final subscription = repo
          .watchWorkHistory(range: HistoryRange.day)
          .listen((result) {
            values.add(result.workers.single.workerName);
            if (!firstValue.isCompleted) firstValue.complete();
          });

      await firstValue.future;
      workerName = 'Bản mới';
      await repo.getWorkHistory(range: HistoryRange.day, forceRefresh: true);
      await Future<void>.delayed(Duration.zero);

      expect(values, ['Bản đầu', 'Bản mới']);
      await subscription.cancel();
      repo.dispose();
    },
  );
}

WorkHistoryResult _result({
  String workerId = 'MNV00123',
  required String workerName,
  String productionOrder = '000010001234',
  String operation = '0010',
  String operationName = '',
  String productName = '',
  String productCode = '',
  String salesOrder = '',
  String salesOrderItem = '',
}) {
  final date = DateTime(2026, 9, 4);
  return WorkHistoryResult(
    scopeCode: 'S',
    dateFrom: date,
    dateTo: date,
    isTruncated: false,
    entries: [
      WorkHistoryEntry(
        transactionUuid: 'tx-$workerId',
        executionDate: date,
        workerId: workerId,
        workerName: workerName,
        productionOrder: productionOrder,
        operation: operation,
        operationName: operationName,
        productName: productName,
        productCode: productCode,
        salesOrder: salesOrder,
        salesOrderItem: salesOrderItem,
        plant: '6720',
        workCenter: 'WC-01',
        transactionType: 'CONFIRM',
        quantity: 10,
        unitOfMeasure: 'PC',
        transactionStatus: 'SUCCESS',
      ),
    ],
    workers: [
      WorkHistorySummary(
        workerId: workerId,
        workerName: workerName,
        assignedQuantity: 20,
        completedQuantity: 10,
        remainingQuantity: 10,
        unitOfMeasure: 'PC',
        transactionCount: 1,
      ),
    ],
  );
}
