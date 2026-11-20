import 'dart:convert';
import '../../core/database/casla_database.dart';
import '../../core/utils/device_info.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/operation_qr_parser.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/work_history.dart';
import '../../domain/policies/grouped_confirmation.dart';
import '../../domain/policies/history_work_context.dart';
import '../../domain/policies/seat_balance.dart';
import '../../domain/repositories/repositories.dart';

/// Prefer a fresh report. Offline operation may use the last report for this
/// exact scope, but never switch to an unscoped list of local assignments.
Future<WorkHistoryResult> loadConfirmationHistory(
  WorkHistoryRepository repository, {
  required HistoryRange range,
  required DateTime dateFrom,
  required DateTime dateTo,
  required String shiftId,
  required String workId,
}) async {
  try {
    return await repository.getWorkHistory(
      range: range,
      dateFrom: dateFrom,
      dateTo: dateTo,
      shiftId: shiftId,
      workId: workId,
      forceRefresh: true,
    );
  } catch (error) {
    final cached = await repository.getWorkHistory(
      range: range,
      dateFrom: dateFrom,
      dateTo: dateTo,
      shiftId: shiftId,
      workId: workId,
    );
    // A snapshot written by an older app version has no lineage, which
    // carried-over work needs. Resolving from it would blame the data, so
    // report the SAP failure that forced the fallback instead.
    if (cached.entries.any(
      (e) =>
          e.transactionType == 'REASSIGN' &&
          e.originalTransactionUuid.trim().isEmpty,
    )) {
      rethrow;
    }
    return cached;
  }
}

/// The confirmation groups of one worker that still hold something to
/// confirm in the given shift and work context, read against a fresh report
/// (see [loadConfirmationHistory]). Empty when the worker is done.
Future<List<List<Assignment>>> loadOpenConfirmationGroups({
  required CaslaDatabase db,
  required AssignmentRepository assignments,
  required WorkHistoryRepository workHistory,
  required String workerId,
  required String workerCode,
  required DateTime businessDate,
  required String shiftId,
  required String workId,
  required String workCenter,
}) async {
  final history = await loadConfirmationHistory(
    workHistory,
    range: HistoryRange.day,
    dateFrom: businessDate,
    dateTo: businessDate,
    shiftId: shiftId,
    workId: workId,
  );
  final targets = await resolveConfirmationTargets(
    db: db,
    assignments: assignments,
    history: history,
    workerId: workerId,
    workerCode: workerCode,
    businessDate:
        '${businessDate.year.toString().padLeft(4, '0')}-'
        '${businessDate.month.toString().padLeft(2, '0')}-'
        '${businessDate.day.toString().padLeft(2, '0')}',
    shiftId: shiftId,
    workId: workId,
    workCenter: workCenter,
    includeSettled: true,
  );
  return groupConfirmationTargets(
    targets,
  ).where((group) => group.any((target) => target.canConfirm)).toList();
}

/// Resolve against the same scoped SAP ledger as Overview even when a stale
/// local assignment already exists. Totals must not be borrowed from another
/// operation or used with an unrelated OriginalTransactionUUID.
Future<List<Assignment>> resolveConfirmationTargets({
  required CaslaDatabase db,
  required AssignmentRepository assignments,
  required WorkHistoryResult history,
  required String workerId,
  required String workerCode,
  required String businessDate,
  required String shiftId,
  required String workId,
  required String workCenter,
  String? productionOrder,
  String? operation,
  bool includeSettled = false,
}) async {
  // Screens know a worker by the local employee id or by the SAP code. Use
  // the local id when one exists, so local assignments and history imports
  // are always filed under one identity.
  final employee =
      await db.getEmployeeByCode(workerCode.trim()) ??
      await db.getEmployeeById(workerId.trim());
  final employeeId = employee?['id']?.toString().trim() ?? '';
  if (employeeId.isNotEmpty) workerId = employeeId;
  String normalized(String value) => value.trim().toUpperCase();
  String uuid(String? value) => normalized(value ?? '').replaceAll('-', '');
  String dateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  if (history.isTruncated ||
      workId.trim().isEmpty ||
      shiftId.trim().isEmpty ||
      dateKey(history.dateFrom) != businessDate ||
      dateKey(history.dateTo) != businessDate) {
    throw const FormatException(
      'Chưa đủ lịch sử của ngày và ca đang chọn để xác nhận sản lượng.',
    );
  }
  final local =
      (await assignments
              .watchWorkerAssignments(
                workerId,
                fromBusinessDate: businessDate,
                toBusinessDate: businessDate,
                shiftId: shiftId,
              )
              .first)
          .where(
            (a) =>
                normalized(a.teamId) == normalized(workId) &&
                (productionOrder == null ||
                    a.productionOrder.trim() == productionOrder.trim()) &&
                (operation == null || a.operation.trim() == operation.trim()) &&
                (workCenter.isEmpty ||
                    normalized(a.workCenter) == normalized(workCenter)),
          )
          .toList();
  final scoped = history.entries.where(
    (e) =>
        {
          normalized(workerId),
          normalized(workerCode),
        }.contains(normalized(e.workerId)) &&
        (productionOrder == null ||
            e.productionOrder.trim() == productionOrder.trim()) &&
        (operation == null || e.operation.trim() == operation.trim()) &&
        // The shift's business day, not the posting time: a night shift's
        // post-midnight work belongs to the day it started.
        dateKey(e.workDate) == businessDate &&
        normalized(e.workId) == normalized(workId) &&
        (workCenter.isEmpty ||
            normalized(e.workCenter) == normalized(workCenter)),
  );
  // A row's position as SAP counts it on a seat (zcl_pp_alloc_lineage
  // row_position): its own, else that of the row it consumed. Blank is a
  // position of its own.
  final byUuid = {for (final e in scoped) uuid(e.transactionUuid): e};
  String positionOf(WorkHistoryEntry entry) {
    var current = entry;
    for (var hop = 0; hop < 5; hop++) {
      final own = normalized(current.positionId);
      if (own.isNotEmpty) return own;
      final parent = byUuid[uuid(current.originalTransactionUuid)];
      if (parent == null || identical(parent, current)) return '';
      current = parent;
    }
    return normalized(current.positionId);
  }

  final seen = <String>{};
  final groups = <(String, String, String), List<WorkHistoryEntry>>{};
  for (final entry in scoped) {
    // REASSIGN is the overnight carry-over snapshot; a re-run of SAP's job
    // posts a signed delta, so it alone may be negative.
    final isCarryOver = entry.transactionType == 'REASSIGN';
    if (entry.transactionUuid.trim().isEmpty ||
        !entry.quantity.isFinite ||
        (entry.quantity < 0 && !isCarryOver) ||
        !const [
          'INITIAL_ASSIGN',
          'REASSIGN',
          'CONFIRM',
          'RECALL',
          'CORRECTION',
          'REVERSE',
        ].contains(entry.transactionType)) {
      throw const FormatException(
        'Lịch sử công đoạn chưa đủ thông tin để đối chiếu số lượng. Vui lòng tải lại dữ liệu SAP.',
      );
    }
    if (!seen.add(uuid(entry.transactionUuid))) continue;
    (groups[(
              entry.productionOrder.trim(),
              entry.operation.trim(),
              normalized(entry.unitOfMeasure),
            )] ??=
            [])
        .add(entry);
  }
  // What SAP still holds open per seat (order, operation, unit, position):
  // the day's rows added up, plus this device's rows SAP has not posted yet.
  // Each target carries its seat's figure, so the confirmation form shows the
  // pile SAP will settle against rather than the sum of the allocations' own
  // remainders. The position is part of the seat (2026-11-11): a spent blank
  // seat must not borrow the balance of a later allocation at TR1.
  final seatEvents = <(String, String, String, String), List<SeatEvent>>{};
  (String, String, String, String) seatKey(
    String order,
    String operationCode,
    String unit,
    String position,
  ) => (
    order.trim(),
    operationCode.trim(),
    normalized(unit),
    normalized(position),
  );
  for (final entry in scoped) {
    (seatEvents[seatKey(
              entry.productionOrder,
              entry.operation,
              entry.unitOfMeasure,
              positionOf(entry),
            )] ??=
            [])
        .addAll(seatEventsFromHistory([entry]));
  }
  final posted = {for (final entry in scoped) uuid(entry.transactionUuid)};
  for (final a in local) {
    if (a.note == historyImportedAssignmentNote ||
        posted.contains(uuid(a.sapId))) {
      continue;
    }
    (seatEvents[seatKey(
              a.productionOrder,
              a.operation,
              a.uom,
              a.positionId,
            )] ??=
            [])
        .add(
          SeatEvent(
            at: DateTime.fromMillisecondsSinceEpoch(a.createdAtUtc),
            delta:
                a.assignedQuantity -
                a.recalledQuantity -
                a.completedQuantity -
                a.defectQuantity,
            order: a.id,
          ),
        );
  }
  // Confirmations and recalls entered here on imported lots that SAP has not
  // posted yet (queued, or waiting for the worker's password). The worker
  // list already nets them off SAP's figure; the form must show the same
  // pile, or the supervisor is invited to confirm the queued quantity again.
  final importedById = {
    for (final a in local)
      if (a.note == historyImportedAssignmentNote) a.id: a,
  };
  if (importedById.isNotEmpty) {
    final rows = await db.getConsumptionRowsForAssignments(
      importedById.keys.toList(),
    );
    for (final row in rows) {
      final lot = importedById[row['phan_cong_id']?.toString()];
      if (lot == null) continue;
      final idempotency = row['idempotency_key']?.toString() ?? '';
      // Balance rows mirror SAP's own report; posted rows are in [scoped].
      if (idempotency.startsWith('history-balance:') ||
          posted.contains(uuid(row['sap_id']?.toString()))) {
        continue;
      }
      final quantity = (row['quantity'] as num?)?.toDouble() ?? 0;
      final defect = (row['defect_quantity'] as num?)?.toDouble() ?? 0;
      final delta = row['kind'] == 'RECALL' ? -quantity : -(quantity + defect);
      if (delta == 0) continue;
      (seatEvents[seatKey(
                lot.productionOrder,
                lot.operation,
                lot.uom,
                lot.positionId,
              )] ??=
              [])
          .add(
            SeatEvent(
              at: DateTime.fromMillisecondsSinceEpoch(lot.createdAtUtc),
              delta: delta,
              order: idempotency,
            ),
          );
    }
  }
  double? seatRemainingFor(
    String order,
    String operationCode,
    String unit,
    String position,
  ) {
    final events = seatEvents[seatKey(order, operationCode, unit, position)];
    return events == null ? null : settleSeatBalance(events);
  }

  final targets = <Assignment>[];
  // Posted allocations with nothing left. Kept only on request, so a
  // confirmation form can show the operation's full assigned/confirmed totals
  // while quantities are still split across the open allocations alone.
  final settled = <Assignment>[];
  void keep(Assignment? target) {
    if (target == null) return;
    (target.canRecord ? targets : settled).add(target);
  }

  /// Materializes one SAP allocation (its INITIAL_ASSIGN plus the rows that
  /// consumed it) as a local assignment with an exact balance.
  Future<Assignment?> importLot(
    WorkHistoryEntry source,
    List<WorkHistoryEntry> entries,
  ) async {
    final metadata = await db.getOrderMetadataBySapKeys([
      (source.productionOrder, source.operation),
    ]);
    final cachedOrder =
        metadata['${source.productionOrder}\u0000${source.operation}'];
    final cachedPayload =
        cachedOrder?['operation_qr_payload']?.toString() ?? '';
    final order = await db.upsertOrderFromOperationQr(
      OperationQrResult(
        isValid: true,
        // History refresh must never erase the scanned department/QR payload.
        rawPayload: cachedPayload.trim().isNotEmpty
            ? cachedPayload
            : jsonEncode({
                'lenh_san_xuat': source.productionOrder,
                'cong_doan': source.operation,
                'work_center': source.workCenter,
                'unit': source.unitOfMeasure,
                'ma_hang': source.productCode,
                'ten_hang': source.productName,
              }),
        productionOrder: source.productionOrder,
        operation: source.operation,
        operationName: source.operationName,
        productCode: source.productCode,
        productName: source.productName,
        plant: source.plant,
        workCenter: source.workCenter,
        unitOfMeasure: source.unitOfMeasure,
        workCenterDescription: '',
        orderCode: source.productionOrder,
        operationQuantity: null,
        salesOrder: source.salesOrder,
        salesOrderItem: source.salesOrderItem,
      ),
    );
    if (order == null) {
      throw const FormatException(
        'Thiếu mã lệnh hoặc công đoạn trong lịch sử SAP.',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final position = positionOf(source);
    final id = await db.reconcileHistoryConfirmationAssignment(
      assignment: {
        'id': IdGenerator.newId(),
        'nhan_vien_id': workerId,
        'don_hang_id': order['id'],
        'to_id': workId,
        'assigned_quantity': source.quantity,
        'unit_of_measure': source.unitOfMeasure,
        'business_date': businessDate,
        'shift_id': shiftId,
        'status': 'OPEN',
        'note': historyImportedAssignmentNote,
        'created_by': 'SAP_HISTORY',
        'occurred_at_utc': source.executionDate.toUtc().millisecondsSinceEpoch,
        'device_id': DeviceInfoHelper.deviceId,
        'sync_status': 'SYNCED',
        'idempotency_key': 'history-import:${uuid(source.transactionUuid)}',
        'sap_id': source.transactionUuid,
        'created_at_utc': now,
        'position_id': position.isEmpty ? null : position,
      },
      entries: entries,
      seatRemaining: seatRemainingFor(
        source.productionOrder,
        source.operation,
        source.unitOfMeasure,
        position,
      ),
    );
    return assignments.getAssignmentById(id);
  }

  /// One INITIAL_ASSIGN standing for several: [anchor]'s identity with the
  /// members' quantities added up, so one local row can carry the balance
  /// SAP keeps for the whole group.
  WorkHistoryEntry lotTotal(
    WorkHistoryEntry anchor,
    Iterable<WorkHistoryEntry> members,
  ) => WorkHistoryEntry(
    transactionUuid: anchor.transactionUuid,
    executionDate: anchor.executionDate,
    reportedWorkDate: anchor.reportedWorkDate,
    workerId: anchor.workerId,
    workerName: anchor.workerName,
    productionOrder: anchor.productionOrder,
    operation: anchor.operation,
    operationName: anchor.operationName,
    productName: anchor.productName,
    productCode: anchor.productCode,
    salesOrder: anchor.salesOrder,
    salesOrderItem: anchor.salesOrderItem,
    plant: anchor.plant,
    workCenter: anchor.workCenter,
    workId: anchor.workId,
    transactionType: 'INITIAL_ASSIGN',
    quantity: members.fold(0.0, (sum, e) => sum + e.quantity),
    unitOfMeasure: anchor.unitOfMeasure,
    transactionStatus: anchor.transactionStatus,
    positionId: positionOf(anchor),
  );

  // Carried-over work. SAP's overnight job posts yesterday's open balance as
  // REASSIGN rows pointing at their allocation root A, and a top-up given
  // today in the same group (operation, worker, WorkID, shift, day, unit)
  // also points at A. SAP resolves a CONFIRM against the whole group, so the
  // carried 60 plus a new 20 is one target of 80, confirmed in one go. The
  // target is identified by the REASSIGN's own UUID: A usually belongs to
  // another day (and may be a local row of that day on this device), while
  // SAP's CONFIRM accepts the REASSIGN UUID and keeps it for exact retries.
  const consumptionTypes = {'CONFIRM', 'RECALL', 'CORRECTION', 'REVERSE'};
  for (final key in groups.keys.toList()) {
    final entries = groups[key]!;
    final carried = entries
        .where((e) => e.transactionType == 'REASSIGN')
        .toList();
    if (carried.isEmpty) continue;
    final byRoot = <String, List<WorkHistoryEntry>>{};
    for (final entry in carried) {
      final root = uuid(entry.originalTransactionUuid);
      if (root.isEmpty) {
        throw const FormatException(
          'Tồn chuyển từ ngày trước thiếu lần giao gốc. Vui lòng tải lại dữ liệu SAP.',
        );
      }
      (byRoot[root] ??= []).add(entry);
    }
    final claimed = <String>{};
    for (final MapEntry(key: root, value: snapshot) in byRoot.entries) {
      final topUps = entries
          .where(
            (e) =>
                e.transactionType == 'INITIAL_ASSIGN' &&
                uuid(e.originalTransactionUuid) == root,
          )
          .toList();
      final members = <String>{
        root,
        for (final e in [...snapshot, ...topUps]) uuid(e.transactionUuid),
      };
      // Everything consuming the group, whichever member it references —
      // including corrections/reversals that point at a confirmation.
      final consumption = <WorkHistoryEntry>[];
      for (var changed = true; changed;) {
        changed = false;
        for (final e in entries) {
          final id = uuid(e.transactionUuid);
          if (consumptionTypes.contains(e.transactionType) &&
              !members.contains(id) &&
              members.contains(uuid(e.originalTransactionUuid))) {
            members.add(id);
            consumption.add(e);
            changed = true;
          }
        }
      }
      final marker = snapshot.firstWhere(
        (e) => e.quantity > 0,
        orElse: () => throw const FormatException(
          'Tồn chuyển từ ngày trước không còn số lượng để xác nhận.',
        ),
      );
      final total = WorkHistoryEntry(
        transactionUuid: marker.transactionUuid,
        executionDate: marker.executionDate,
        reportedWorkDate: marker.reportedWorkDate,
        workerId: marker.workerId,
        workerName: marker.workerName,
        productionOrder: marker.productionOrder,
        operation: marker.operation,
        operationName: marker.operationName,
        productName: marker.productName,
        productCode: marker.productCode,
        salesOrder: marker.salesOrder,
        salesOrderItem: marker.salesOrderItem,
        plant: marker.plant,
        workCenter: marker.workCenter,
        workId: marker.workId,
        // One allocation for the local ledger: opening balance (net of any
        // re-run deltas) plus today's top-ups.
        transactionType: 'INITIAL_ASSIGN',
        quantity: [
          ...snapshot,
          ...topUps,
        ].fold(0.0, (sum, e) => sum + e.quantity),
        unitOfMeasure: marker.unitOfMeasure,
        transactionStatus: marker.transactionStatus,
        positionId: positionOf(marker),
      );
      keep(await importLot(total, [total, ...consumption]));
      claimed.addAll(members);
    }
    final rest = entries
        .where((e) => !claimed.contains(uuid(e.transactionUuid)))
        .toList();
    if (rest.isEmpty) {
      groups.remove(key);
    } else {
      groups[key] = rest;
    }
  }

  // Before any completion/recall, each allocation has its own known full
  // balance, including allocations made on another device. No parent lookup
  // is needed to materialize those independent sources.
  final allocations = groups.values.expand(
    (entries) =>
        entries.every((entry) => entry.transactionType == 'INITIAL_ASSIGN')
        ? entries.map((entry) => <WorkHistoryEntry>[entry])
        : <List<WorkHistoryEntry>>[entries],
  );

  for (final entries in allocations) {
    final initial = entries
        .where((e) => e.transactionType == 'INITIAL_ASSIGN')
        .toList();
    if (initial.isEmpty) {
      throw const FormatException(
        'Thiếu lịch sử giao việc gốc của công đoạn. Vui lòng tải lại dữ liệu SAP.',
      );
    }
    if (initial.length > 1) {
      // Several allocations of one operation. SAP checks every confirmation
      // and recall against the allocation it references, so each needs its
      // own balance; the confirmation screen then shows them as one total.
      final sourceIds = initial.map((e) => uuid(e.transactionUuid)).toSet();
      final consumption = entries
          .where((e) => e.transactionType != 'INITIAL_ASSIGN')
          .toList();

      // SAP books a later allocation for the same worker, order, operation,
      // work context, shift and work date as a top-up of the first one: its
      // OriginalTransactionUUID names that root, and SAP checks confirmations
      // and recalls against the root's total. Such a group is one balance.
      final parentOf = <String, String>{
        for (final e in initial)
          if (sourceIds.contains(uuid(e.originalTransactionUuid)) &&
              uuid(e.originalTransactionUuid) != uuid(e.transactionUuid))
            uuid(e.transactionUuid): uuid(e.originalTransactionUuid),
      };
      String rootOf(String id) {
        var current = id;
        final visited = <String>{};
        while (visited.add(current)) {
          final parent = parentOf[current];
          if (parent == null) break;
          current = parent;
        }
        return current;
      }

      final consumptionLinked = consumption.every(
        (e) => sourceIds.contains(uuid(e.originalTransactionUuid)),
      );
      if (parentOf.isNotEmpty && consumptionLinked) {
        final rootGroups = <String, List<WorkHistoryEntry>>{};
        for (final e in initial) {
          (rootGroups[rootOf(uuid(e.transactionUuid))] ??= []).add(e);
        }
        for (final group in rootGroups.entries) {
          final memberIds = {
            for (final e in group.value) uuid(e.transactionUuid),
          };
          final groupConsumption = consumption
              .where(
                (e) => rootOf(uuid(e.originalTransactionUuid)) == group.key,
              )
              .toList();
          final root = group.value.firstWhere(
            (e) => uuid(e.transactionUuid) == group.key,
          );
          if (group.value.length == 1) {
            final target = await importLot(root, [root, ...groupConsumption]);
            keep(target);
            continue;
          }
          final mine = local
              .where(
                (a) =>
                    memberIds.contains(uuid(a.sapId)) &&
                    a.note != historyImportedAssignmentNote,
              )
              .toList();
          // Rows entered on this device carry each allocation's own balance,
          // and SAP only checks the group total, so they are kept as they
          // are. Whatever the group holds beyond them (all of it when nothing
          // was entered here) becomes one imported lot: the root when it is
          // among the missing, else the first missing top-up, since SAP
          // resolves a CONFIRM on any member to the group.
          mine.forEach(keep);
          final mineIds = {for (final a in mine) uuid(a.sapId)};
          final missing = group.value
              .where((e) => !mineIds.contains(uuid(e.transactionUuid)))
              .toList();
          if (missing.isEmpty) continue;
          final missingIds = {for (final e in missing) uuid(e.transactionUuid)};
          final anchor = missing.firstWhere(
            (e) => uuid(e.transactionUuid) == group.key,
            orElse: () => missing.first,
          );
          final total = lotTotal(anchor, missing);
          final consumed = mine.isEmpty
              ? groupConsumption
              : groupConsumption
                    .where(
                      (e) =>
                          missingIds.contains(uuid(e.originalTransactionUuid)),
                    )
                    .toList();
          keep(await importLot(total, [total, ...consumed]));
        }
        continue;
      }

      // Newer SAP services name the allocation each row consumed: exact.
      final linked =
          consumption.isNotEmpty &&
          consumption.every(
            (e) => sourceIds.contains(uuid(e.originalTransactionUuid)),
          );
      if (consumption.isEmpty || linked) {
        for (final source in initial) {
          final lotId = uuid(source.transactionUuid);
          final target = await importLot(source, [
            source,
            ...consumption.where(
              (e) => uuid(e.originalTransactionUuid) == lotId,
            ),
          ]);
          keep(target);
        }
        continue;
      }

      // Otherwise attribute SAP's rows through this device's own records:
      // every confirmation/recall posted from here carries its SAP id on the
      // allocation it was entered against.
      final known = <String, Assignment>{
        for (final a in local)
          if (sourceIds.contains(uuid(a.sapId)) &&
              a.note != historyImportedAssignmentNote)
            uuid(a.sapId): a,
      };
      final localRows = await db.getConsumptionRowsForAssignments(
        known.values.map((a) => a.id).toList(),
      );
      final localSapIds = {
        for (final row in localRows) uuid(row['sap_id']?.toString()),
      }..remove('');
      double balanceRows(String kind) => localRows
          .where(
            (row) =>
                row['kind'] == kind &&
                (row['idempotency_key']?.toString() ?? '').startsWith(
                  'history-balance:',
                ),
          )
          .fold(
            0.0,
            (sum, row) =>
                sum +
                ((row['quantity'] as num?) ?? 0) +
                ((row['defect_quantity'] as num?) ?? 0),
          );
      double unexplained(String kind, bool Function(WorkHistoryEntry) isKind) {
        final remote = consumption
            .where(isKind)
            .where((e) => !localSapIds.contains(uuid(e.transactionUuid)))
            .fold(
              0.0,
              (sum, e) =>
                  sum +
                  (e.transactionType == 'REVERSE'
                      ? -(e.quantity + e.defectQuantity)
                      : e.quantity + e.defectQuantity),
            );
        return remote - balanceRows(kind);
      }

      final unexplainedConfirm = unexplained(
        'CONFIRM',
        (e) => const [
          'CONFIRM',
          'CORRECTION',
          'REVERSE',
        ].contains(e.transactionType),
      );
      final unexplainedRecall = unexplained(
        'RECALL',
        (e) => e.transactionType == 'RECALL',
      );
      if (unexplainedConfirm.abs() > 0.0001 ||
          unexplainedRecall.abs() > 0.0001) {
        final uom = initial.first.unitOfMeasure;
        final open = (unexplainedConfirm + unexplainedRecall).abs();
        throw FormatException(
          'Có ${open.toStringAsFixed(open.truncateToDouble() == open ? 0 : 3)} '
          '$uom đã xác nhận/thu hồi trên SAP (thường từ thiết bị khác) chưa '
          'xác định được thuộc lần giao nào, nên chưa chia được số lượng '
          'chính xác. Cần cập nhật SAP trả về lần giao gốc '
          '(OriginalTransactionUUID) trong lịch sử.',
        );
      }

      // Everything SAP consumed is accounted for on this device, so an
      // allocation this device never saw has not been consumed at all.
      for (final source in initial) {
        final mine = known[uuid(source.transactionUuid)];
        final target = mine ?? await importLot(source, [source]);
        keep(target);
      }
      continue;
    }
    final target = await importLot(initial.single, entries);
    keep(target);
  }
  // An allocation SAP has not posted yet (queued, or waiting for the worker's
  // password in the sync tab) cannot be confirmed: SAP would reject a
  // confirmation that references it. It becomes a target once posted.
  if (targets.isEmpty &&
      local.any(
        (a) =>
            a.canRecord &&
            a.note != historyImportedAssignmentNote &&
            a.syncStatus != SyncStatus.synced &&
            a.syncStatus != SyncStatus.failed,
      )) {
    throw const FormatException(
      'Lần giao việc chưa được gửi lên SAP (đang chờ ở tab Đồng bộ). '
      'Hãy gửi xong rồi mới xác nhận.',
    );
  }
  Assignment withSeat(Assignment target) {
    final events =
        seatEvents[seatKey(
          target.productionOrder,
          target.operation,
          target.uom,
          target.positionId,
        )];
    if (events == null) return target;
    return target.copyWith(seatRemaining: settleSeatBalance(events));
  }

  // A seat SAP still holds open while every allocation on it is spent on
  // paper: an over-confirmation closed the earlier ones and a later
  // allocation reopened the pile. The newest allocation of that seat takes
  // the next confirmation; SAP settles it against the whole seat anyway.
  for (final key in seatEvents.keys) {
    if (settleSeatBalance(seatEvents[key]!) <= 0.0001) continue;
    bool onSeat(Assignment a) =>
        seatKey(a.productionOrder, a.operation, a.uom, a.positionId) == key;
    if (targets.any(onSeat)) continue;
    final closed = settled
        .where((a) => onSeat(a) && a.status != AssignmentStatus.recalled)
        .toList();
    if (closed.isEmpty) continue;
    closed.sort((a, b) {
      final byCreated = a.createdAtUtc.compareTo(b.createdAtUtc);
      return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
    });
    final newest = closed.last;
    await db.reopenAssignmentForSeat(newest.id);
    final reopened = await assignments.getAssignmentById(newest.id);
    if (reopened == null) continue;
    settled.remove(newest);
    targets.add(reopened);
  }

  return [
    for (final target in includeSettled ? [...targets, ...settled] : targets)
      withSeat(target),
  ];
}
