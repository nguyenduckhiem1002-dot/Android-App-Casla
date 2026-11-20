// Domain — narrowing a team history to the workers a supervisor looks for.
//
// An account with PP_HIST_TEAM sees every worker of its authorized work
// contexts at once, which on a busy line is hundreds of rows. The search box
// matches a worker's code or name, or the code or name of the department
// (WorkID) the work belongs to, without regard to accents or case, so "chi",
// "Chi", "Đỗ Thị Chi" and "XM1" all narrow the same history.

import '../../core/utils/vietnamese_text_normalizer.dart';
import '../entities/work_history.dart';

/// Whether any of [fields] contains [query], ignoring accents and case. An
/// empty query matches everything.
bool historyTextMatches(String query, Iterable<String> fields) {
  final wanted = normalizeVietnameseComparisonKey(query);
  if (wanted.isEmpty) return true;
  return fields.any(
    (field) => normalizeVietnameseComparisonKey(field).contains(wanted),
  );
}

/// Whether a worker known by [workerId] and [workerName] matches [query].
/// An empty query matches everyone.
bool historyWorkerMatches({
  required String workerId,
  required String workerName,
  required String query,
}) => historyTextMatches(query, [workerId, workerName]);

/// How many distinct workers [result] holds, by worker code.
int historyWorkerCount(WorkHistoryResult result) => {
  for (final entry in result.entries) entry.workerId.trim().toUpperCase(),
  for (final worker in result.workers) worker.workerId.trim().toUpperCase(),
}.where((id) => id.isNotEmpty).length;

/// One department (SAP WorkID) seen in a history.
class HistoryDepartment {
  final String workId;

  /// SAP's work name for it, else its BoPhan; empty when neither came back.
  final String name;

  const HistoryDepartment({required this.workId, this.name = ''});

  /// `Tên · mã`, the way the shift picker shows a shift beside its code.
  String get label => name.isEmpty || name.toUpperCase() == workId.toUpperCase()
      ? workId
      : '$name · $workId';
}

/// The departments [result] holds, named from SAP's per-worker summary when
/// it carries a name. Sorted by label.
List<HistoryDepartment> historyDepartments(WorkHistoryResult result) {
  final ids = <String, String>{};
  final names = <String, String>{};
  void see(String workId, [String name = '']) {
    final id = workId.trim();
    if (id.isEmpty) return;
    final key = id.toUpperCase();
    ids.putIfAbsent(key, () => id);
    final named = name.trim();
    if (named.isNotEmpty && (names[key] ?? '').isEmpty) names[key] = named;
  }

  for (final worker in result.workers) {
    see(
      worker.workId,
      worker.workName.trim().isNotEmpty ? worker.workName : worker.boPhan,
    );
  }
  for (final entry in result.entries) {
    see(entry.workId);
  }
  final departments = [
    for (final MapEntry(key: key, value: id) in ids.entries)
      HistoryDepartment(workId: id, name: names[key] ?? ''),
  ];
  departments.sort((a, b) => a.label.compareTo(b.label));
  return departments;
}

/// [result] narrowed to the department [workId]: its ledger rows and the
/// workers SAP reports for it. A summary row without a WorkID stays when its
/// worker has a row in that department. A null or blank [workId] returns
/// [result] untouched.
WorkHistoryResult filterHistoryByWorkId(
  WorkHistoryResult result,
  String? workId,
) {
  final wanted = workId?.trim().toUpperCase() ?? '';
  if (wanted.isEmpty) return result;
  final entries = result.entries
      .where((entry) => entry.workId.trim().toUpperCase() == wanted)
      .toList(growable: false);
  final workersThere = {
    for (final entry in entries) entry.workerId.trim().toUpperCase(),
  };
  return WorkHistoryResult(
    scopeCode: result.scopeCode,
    dateFrom: result.dateFrom,
    dateTo: result.dateTo,
    isTruncated: result.isTruncated,
    entries: entries,
    workers: result.workers
        .where((worker) {
          final id = worker.workId.trim().toUpperCase();
          return id.isEmpty
              ? workersThere.contains(worker.workerId.trim().toUpperCase())
              : id == wanted;
        })
        .toList(growable: false),
  );
}

/// [result] narrowed to what matches [query]: a worker's code or name, or
/// the code or name of the department a row belongs to. A ledger row that
/// carries no name is matched by the names SAP reports for its worker in the
/// summary. An empty query returns [result] untouched.
WorkHistoryResult filterHistoryByWorker(
  WorkHistoryResult result,
  String query,
) {
  if (normalizeVietnameseComparisonKey(query).isEmpty) return result;
  final workerNames = <String, String>{
    for (final worker in result.workers)
      worker.workerId.trim().toUpperCase(): worker.workerName,
  };
  final departmentNames = <String, String>{
    for (final department in historyDepartments(result))
      department.workId.toUpperCase(): department.name,
  };
  bool matches(String workerId, String workerName, String workId) =>
      historyTextMatches(query, [
        workerId,
        workerName.trim().isNotEmpty
            ? workerName
            : workerNames[workerId.trim().toUpperCase()] ?? '',
        workId,
        departmentNames[workId.trim().toUpperCase()] ?? '',
      ]);
  return WorkHistoryResult(
    scopeCode: result.scopeCode,
    dateFrom: result.dateFrom,
    dateTo: result.dateTo,
    isTruncated: result.isTruncated,
    entries: result.entries
        .where(
          (entry) => matches(entry.workerId, entry.workerName, entry.workId),
        )
        .toList(growable: false),
    workers: result.workers
        .where(
          (worker) =>
              matches(worker.workerId, worker.workerName, worker.workId) ||
              historyTextMatches(query, [worker.boPhan]),
        )
        .toList(growable: false),
  );
}
