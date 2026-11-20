import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import 'casla_dialog_header.dart';
import '../../core/utils/quantity_formatter.dart';
import '../../domain/policies/recall_all.dart';

/// The question asked before "Thu hồi không mật khẩu" on the worker list
/// sends anything: who it is about, the total taken back, and every
/// order/operation with its quantity. It stands in for the password popup —
/// nobody is there to sign, so the supervisor reads the figures instead.
///
/// Returns true only when the supervisor chose "Thu hồi & gửi SAP".
Future<bool> showRecallAllConfirmDialog(
  BuildContext context, {
  required String workerName,
  required String workerCode,
  required List<RecallAllLine> lines,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RecallAllConfirmDialog(
      workerName: workerName,
      workerCode: workerCode,
      lines: lines,
    ),
  );
  return confirmed == true;
}

/// The question asked before a password-less recall of one order on S08's
/// "Xác nhận" form: everything still open on it goes back. It stands in for
/// the password popup, so the supervisor reads the figure once more.
///
/// Returns true only when the supervisor chose "Thu hồi & gửi SAP".
Future<bool> showRecallRemainingConfirmDialog(
  BuildContext context, {
  required String quantityText,
  required String uom,
  required String workerName,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: CaslaColors.surface,
      surfaceTintColor: Colors.transparent,
      titlePadding: CaslaDialog.titlePadding,
      contentPadding: CaslaDialog.contentPadding,
      title: const CaslaDialogHeader(child: Text('Thu hồi không cần mật khẩu')),
      content: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'Thu hồi toàn bộ '),
            TextSpan(
              text: '$quantityText $uom',
              style: const TextStyle(
                fontSize: CaslaDialog.figureSize,
                fontWeight: FontWeight.w800,
              ),
            ),
            const TextSpan(text: ' còn lại của '),
            TextSpan(
              text: workerName,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const TextSpan(
              text: ' và gửi lên SAP mà không cần mật khẩu công nhân?',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: CaslaDialog.actionStyle,
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Hủy'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: CaslaColors.primaryNavy,
            foregroundColor: Colors.white,
          ).merge(CaslaDialog.actionStyle),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Thu hồi & gửi SAP'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

class RecallAllConfirmDialog extends StatelessWidget {
  final String workerName;
  final String workerCode;
  final List<RecallAllLine> lines;

  const RecallAllConfirmDialog({
    super.key,
    required this.workerName,
    required this.workerCode,
    required this.lines,
  });

  /// One unit: the bare figure, as on the paperwork. Several units are never
  /// added up, so each keeps its unit.
  String get _totalText {
    final totals = recallAllTotals(lines);
    if (totals.length == 1) {
      final entry = totals.entries.single;
      return formatQuantity(entry.value, uom: entry.key);
    }
    return [
      for (final entry in totals.entries)
        '${formatQuantity(entry.value, uom: entry.key)} ${entry.key}',
    ].join(' + ');
  }

  @override
  Widget build(BuildContext context) {
    final name = workerName.trim();
    final code = workerCode.trim();
    return AlertDialog(
      backgroundColor: CaslaColors.surface,
      surfaceTintColor: Colors.transparent,
      titlePadding: CaslaDialog.titlePadding,
      contentPadding: const EdgeInsets.fromLTRB(
        CaslaDialog.padding,
        CaslaDialog.headerGap,
        CaslaDialog.padding,
        12,
      ),
      // Who is affected sits in the header; the figures below the line.
      title: CaslaDialogHeader(
        subtitle: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: name.isEmpty ? code : name,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: CaslaColors.primaryNavy,
                ),
              ),
              if (name.isNotEmpty && code.isNotEmpty && code != name)
                TextSpan(text: '  ·  $code'),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        child: const Text('Thu hồi không mật khẩu'),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              key: const ValueKey('recall-all-total'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: CaslaColors.background,
                borderRadius: BorderRadius.circular(CaslaRadius.md),
              ),
              child: Row(
                children: [
                  const Text(
                    'TỔNG THU HỒI',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                      color: CaslaColors.primaryNavy,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _totalText,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontFamily: 'Manrope',
                        fontSize: CaslaDialog.totalSize,
                        fontWeight: FontWeight.w800,
                        color: CaslaColors.primaryNavy,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Only the list scrolls: the header and the total stay in view
            // however many orders there are.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final line in lines)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                recallAllLineLabel(line, lines),
                                style: const TextStyle(
                                  fontSize: 16,
                                  height: 1.35,
                                  fontWeight: FontWeight.w700,
                                  color: CaslaColors.primaryNavy,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '${formatQuantity(line.quantity, uom: line.target.uom)} '
                              '${line.target.uom}',
                              style: const TextStyle(
                                fontSize: CaslaDialog.figureSize,
                                height: 1.3,
                                fontWeight: FontWeight.w800,
                                color: CaslaColors.primaryNavy,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: CaslaDialog.actionStyle,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text(
            'Hủy',
            style: TextStyle(color: CaslaColors.primaryNavy),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: CaslaColors.danger,
            foregroundColor: Colors.white,
            shape: const StadiumBorder(),
          ).merge(CaslaDialog.actionStyle),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Thu hồi & gửi SAP'),
        ),
      ],
    );
  }
}
