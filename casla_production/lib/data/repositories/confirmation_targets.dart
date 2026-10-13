import 'dart:convert';
import '../../core/database/casla_database.dart';
import '../../core/utils/device_info.dart';
import '../../core/utils/id_generator.dart';
import '../../core/utils/operation_qr_parser.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/work_history.dart';
import '../../domain/policies/history_work_context.dart';
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
      },
      entries: entries,
    );
    return assignments.getAssignmentById(id);
  }

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
          if (mine.length == memberIds.length) {
            // Entered on this device: its own rows carry each allocation's
            // balance, and SAP only checks the group total.
            mine.forEach(keep);
            continue;
          }
          if (mine.isNotEmpty) {
            throw const FormatException(
              'Một phần lần giao bổ sung của công đoạn được tạo trên thiết bị '
              'khác. Hãy tải lại dữ liệu SAP rồi thử lại.',
            );
          }
          // Never seen here: one local allocation carrying the group total.
          final total = WorkHistoryEntry(
            transactionUuid: root.transactionUuid,
            executionDate: root.executionDate,
            reportedWorkDate: root.reportedWorkDate,
            workerId: root.workerId,
            workerName: root.workerName,
            productionOrder: root.productionOrder,
            operation: root.operation,
            operationName: root.operationName,
            productName: root.productName,
            productCode: root.productCode,
            salesOrder: root.salesOrder,
            salesOrderItem: root.salesOrderItem,
            plant: root.plant,
            workCenter: root.workCenter,
            workId: root.workId,
            transactionType: root.transactionType,
            quantity: group.value.fold(0.0, (sum, e) => sum + e.quantity),
            unitOfMeasure: root.unitOfMeasure,
            transactionStatus: root.transactionStatus,
          );
          final target = await importLot(total, [total, ...groupConsumption]);
          keep(target);
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
  return includeSettled ? [...targets, ...settled] : targets;
}
