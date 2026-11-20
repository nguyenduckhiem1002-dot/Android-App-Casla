// The "Tổ" filter shared by the history and team overview screens.
//
// Its list is the session's own work contexts plus every department (SAP
// WorkID) the history holds, so an account whose session names one context
// can still narrow a team history that spans several. Each row shows the
// name with its code, the way the shift picker shows a shift.

import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../domain/entities/entities.dart';
import '../../domain/entities/work_history.dart';
import '../../domain/policies/history_worker_filter.dart';

/// A department a history can be narrowed to: one of the session's work
/// contexts (SAP may then be asked for it alone) or one seen only in the
/// history.
class HistoryDepartmentOption {
  final String workId;
  final String name;
  final String detail;
  final bool inSession;

  const HistoryDepartmentOption({
    required this.workId,
    required this.name,
    required this.detail,
    required this.inSession,
  });

  /// `Tên · mã`.
  String get label => name.isEmpty || name.toUpperCase() == workId.toUpperCase()
      ? workId
      : '$name · $workId';
}

/// The session's work contexts, one per WorkID.
List<UserWorkContext> uniqueWorkContexts(UserSession? session) {
  final seen = <String>{};
  return [
    for (final context in session?.workContexts ?? const <UserWorkContext>[])
      if (context.workId.trim().isNotEmpty &&
          seen.add(context.workId.trim().toUpperCase()))
        context,
  ];
}

/// `Tên · mã` of a session work context.
String workContextLabel(UserWorkContext context) {
  final id = context.workId.trim();
  final name = context.workName.trim();
  return name.isEmpty || name == id ? id : '$name · $id';
}

/// Session contexts and the departments [result] holds, one per WorkID,
/// sorted by label. [within] (upper-cased WorkIDs, from
/// `historyFilterWorkIds`) keeps the list to the shift's work center; null
/// offers every department.
List<HistoryDepartmentOption> historyDepartmentOptions({
  required List<UserWorkContext> contexts,
  required WorkHistoryResult result,
  Set<String>? within,
}) {
  bool offered(String workId) =>
      within == null || within.contains(workId.trim().toUpperCase());
  final byId = <String, HistoryDepartmentOption>{};
  for (final work in contexts) {
    final id = work.workId.trim();
    if (!offered(id)) continue;
    byId[id.toUpperCase()] = HistoryDepartmentOption(
      workId: id,
      name: work.workName.trim(),
      detail: [
        id,
        if (work.workCenter.trim().isNotEmpty) work.workCenter.trim(),
      ].join(' · '),
      inSession: true,
    );
  }
  for (final department in historyDepartments(result)) {
    if (!offered(department.workId)) continue;
    final key = department.workId.toUpperCase();
    final known = byId[key];
    if (known == null) {
      byId[key] = HistoryDepartmentOption(
        workId: department.workId,
        name: department.name,
        detail: department.workId,
        inSession: false,
      );
    } else if (known.name.isEmpty && department.name.isNotEmpty) {
      byId[key] = HistoryDepartmentOption(
        workId: known.workId,
        name: department.name,
        detail: known.detail,
        inSession: known.inSession,
      );
    }
  }
  final options = byId.values.toList()
    ..sort((a, b) => a.label.compareTo(b.label));
  return options;
}

/// Opens the department list with a search box. [onSelected] receives the
/// chosen option, or null for "Tất cả tổ"; it is not called when the
/// sheet is dismissed.
Future<void> showHistoryDepartmentSheet(
  BuildContext context, {
  required List<HistoryDepartmentOption> options,
  required String? selectedWorkId,
  required ValueChanged<HistoryDepartmentOption?> onSelected,
}) async {
  var query = '';
  bool isSelected(String? workId) =>
      (selectedWorkId?.toUpperCase() ?? '') == (workId?.toUpperCase() ?? '');
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) {
        final shown = options
            .where(
              (option) =>
                  historyTextMatches(query, [option.workId, option.name]),
            )
            .toList();
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.75,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 10),
                    child: Text(
                      'Lọc theo tổ',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      key: const Key('history-department-search'),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 20),
                        hintText: 'Tìm tổ theo mã hoặc tên',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onChanged: (value) => setSheetState(() => query = value),
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                      children: [
                        if (query.trim().isEmpty)
                          Material(
                            color: Colors.transparent,
                            child: ListTile(
                              minTileHeight: 52,
                              leading: const Icon(Icons.all_inclusive),
                              title: const Text('Tất cả tổ'),
                              selected: isSelected(null),
                              trailing: isSelected(null)
                                  ? const Icon(Icons.check)
                                  : null,
                              onTap: () {
                                Navigator.pop(sheetContext);
                                onSelected(null);
                              },
                            ),
                          ),
                        for (final option in shown)
                          Material(
                            color: Colors.transparent,
                            child: ListTile(
                              minTileHeight: 58,
                              leading: const Icon(Icons.groups_outlined),
                              title: Text(
                                option.name.isEmpty
                                    ? option.workId
                                    : option.name,
                              ),
                              // WorkID · xưởng, as shifts show their code.
                              subtitle: Text(option.detail),
                              selected: isSelected(option.workId),
                              trailing: isSelected(option.workId)
                                  ? const Icon(Icons.check)
                                  : null,
                              onTap: () {
                                Navigator.pop(sheetContext);
                                onSelected(option);
                              },
                            ),
                          ),
                        if (shown.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              'Không tìm thấy tổ phù hợp.',
                              style: TextStyle(color: CaslaColors.muted),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// The outlined "Tổ: …" button that opens the sheet.
class HistoryDepartmentButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const HistoryDepartmentButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: OutlinedButton.icon(
        key: const Key('history-work-filter'),
        onPressed: onPressed,
        icon: const Icon(Icons.groups_outlined, size: 17),
        label: Text('Tổ: $label', maxLines: 1, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          foregroundColor: CaslaColors.primaryNavy,
          side: const BorderSide(color: CaslaColors.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );
  }
}
