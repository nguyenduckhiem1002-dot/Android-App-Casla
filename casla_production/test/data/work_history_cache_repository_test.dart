import 'dart:async';

import 'package:casla_production/core/database/casla_database.dart';
import 'package:casla_production/core/telemetry/field_telemetry.dart';
import 'package:casla_production/data/repositories/repositories_impl.dart';
import 'package:casla_production/domain/entities/work_history.dart';
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
      loadRemote: ({required range, dateFrom, dateTo}) async {
        calls++;
        return _result(workerName: 'Nguyễn Văn A');
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
      loadRemote: ({required range, dateFrom, dateTo}) async {
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
      loadRemote: ({required range, dateFrom, dateTo}) async {
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
      loadRemote: ({required range, dateFrom, dateTo}) async {
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
      loadRemote: ({required range, dateFrom, dateTo}) async =>
          _result(workerId: 'MNV00123', workerName: 'Tên cập nhật'),
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
      loadRemote: ({required range, dateFrom, dateTo}) async =>
          _result(workerId: 'MNV00999', workerName: 'Nhân viên SAP'),
    );

    await repo.getWorkHistory(range: HistoryRange.month, forceRefresh: true);

    final inserted = await db.getEmployeeByCode('MNV00999');
    expect(inserted?['ten'], 'Nhân viên SAP');
    expect(inserted?['to_ids'], isEmpty);
  });
}

WorkHistoryResult _result({
  String workerId = 'MNV00123',
  required String workerName,
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
        productionOrder: '000010001234',
        operation: '0010',
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
