import 'package:casla_production/domain/entities/work_history.dart';
import 'package:casla_production/domain/policies/local_history_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WorkHistoryEntry entry(String id, String type, double qty) =>
      WorkHistoryEntry(
        transactionUuid: id,
        executionDate: DateTime(2026, 9, 23),
        workerId: 'NV01',
        workerName: 'A',
        productionOrder: 'PO',
        operation: '0010',
        plant: '6711',
        workCenter: 'WC',
        transactionType: type,
        quantity: qty,
        unitOfMeasure: 'PC',
        transactionStatus: 'POSTED',
      );

  WorkHistoryResult sap(
    List<WorkHistoryEntry> entries, {
    bool truncated = false,
  }) => WorkHistoryResult(
    scopeCode: 'T',
    dateFrom: DateTime(2026, 9, 23),
    dateTo: DateTime(2026, 9, 23),
    isTruncated: truncated,
    entries: entries,
    workers: const [],
  );

  const summary = WorkHistorySummary(
    workerId: 'NV01',
    workerName: 'A',
    assignedQuantity: 100,
    completedQuantity: 40,
    remainingQuantity: 50, // 10 already recalled in SAP
    recalledQuantity: 10,
    unitOfMeasure: 'PC',
    transactionCount: 3,
  );

  LocalLedgerRow row(
    LocalLedgerKind kind,
    double qty, {
    String status = 'PENDING',
    String sapId = '',
    String key = '',
  }) => LocalLedgerRow(
    kind: kind,
    workerId: 'emp-1',
    workerCode: 'NV01',
    quantity: qty,
    syncStatus: status,
    sapId: sapId,
    idempotencyKey: key,
  );

  test('pending local writes are added on top of the SAP summary', () {
    final ledger = buildLocalPendingLedger(
      sap: sap([entry('A-1', 'INITIAL_ASSIGN', 100)]),
      rows: [
        row(LocalLedgerKind.assign, 20, key: 'k-assign'),
        row(LocalLedgerKind.confirm, 30, key: 'k-confirm'),
        row(LocalLedgerKind.recall, 5, key: 'k-recall'),
      ],
    );
    final totals = overlayWorkerSummary(summary, ledger.forWorker(['NV01']));
    expect(totals.assigned, 120);
    expect(totals.completed, 70);
    expect(totals.recalled, 10 + 5);
    expect(totals.remaining, 50 + 20 - 5 - 30);
  });

  test('rows SAP already reports are not counted twice', () {
    final ledger = buildLocalPendingLedger(
      sap: sap([
        entry('0000-AAAA', 'CONFIRM', 30),
        entry('k-recall', 'RECALL', 5),
      ]),
      rows: [
        row(LocalLedgerKind.confirm, 30, status: 'SYNCED', sapId: '0000aaaa'),
        row(LocalLedgerKind.recall, 5, key: 'K-RECALL'),
      ],
    );
    expect(ledger.forWorker(['NV01']).isEmpty, isTrue);
  });

  test('a posted row missing from a stale cached report is still shown', () {
    final ledger = buildLocalPendingLedger(
      sap: sap(const []),
      rows: [row(LocalLedgerKind.confirm, 30, status: 'SYNCED', sapId: 'X')],
    );
    expect(ledger.forWorker(['emp-1']).completed, 30);
  });

  test('failed, unmatched-synced and truncated-synced rows are ignored', () {
    final complete = buildLocalPendingLedger(
      sap: sap(const []),
      rows: [
        row(LocalLedgerKind.confirm, 30, status: 'FAILED'),
        row(LocalLedgerKind.confirm, 7, status: 'SYNCED'),
      ],
    );
    expect(complete.forWorker(['NV01']).isEmpty, isTrue);

    final truncated = buildLocalPendingLedger(
      sap: sap(const [], truncated: true),
      rows: [
        row(LocalLedgerKind.confirm, 30, status: 'SYNCED', sapId: 'X'),
        row(LocalLedgerKind.confirm, 4),
      ],
    );
    expect(truncated.forWorker(['NV01']).completed, 4);
  });

  test('id and code resolve to one worker without double counting', () {
    final ledger = buildLocalPendingLedger(
      sap: null,
      rows: [row(LocalLedgerKind.confirm, 3), row(LocalLedgerKind.confirm, 4)],
    );
    expect(
      identical(ledger.forWorker(['emp-1']), ledger.forWorker(['nv01'])),
      isTrue,
    );
    expect(ledger.forWorker(['NV01', 'emp-1']).completed, 7);
    expect(ledger.forWorker(['other']).isEmpty, isTrue);
  });
}
