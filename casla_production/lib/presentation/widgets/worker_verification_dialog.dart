import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import 'casla_dialog_header.dart';
import '../../core/utils/quantity_formatter.dart';
import '../../domain/entities/entities.dart';

/// How many times a worker may re-enter a password SAP refused before the
/// operation is abandoned.
const int maxWorkerPasswordAttempts = 3;

/// The figures about to be posted, shown above the password field so the
/// worker reads what they are signing off.
class WorkerQuantitySummary {
  /// Employee number; hidden when blank or equal to the displayed name.
  final String workerCode;
  final String uom;

  /// What an assignment gives the worker: the total over every operation
  /// given in the same send.
  final double assigned;

  /// What a confirmation of several operations at once posts: the total over
  /// every operation confirmed in the same send, shown on one line as
  /// "SỐ LƯỢNG HOÀN THÀNH".
  final double completedTotal;
  final double completed;
  final double defect;
  final double recalled;

  const WorkerQuantitySummary({
    this.workerCode = '',
    required this.uom,
    this.assigned = 0,
    this.completedTotal = 0,
    this.completed = 0,
    this.defect = 0,
    this.recalled = 0,
  });

  factory WorkerQuantitySummary.forAssignment(
    Assignment assignment, {
    double completed = 0,
    double defect = 0,
    double recalled = 0,
  }) {
    return WorkerQuantitySummary(
      workerCode: assignment.workerMaNv.trim(),
      uom: assignment.uom,
      completed: completed,
      defect: defect,
      recalled: recalled,
    );
  }
}

Future<String?> showWorkerVerificationDialog(
  BuildContext context, {
  required String workerName,
  required String actionLabel,
  String? errorText,
  WorkerQuantitySummary? summary,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WorkerVerificationDialog(
      workerName: workerName,
      actionLabel: actionLabel,
      initialError: errorText,
      summary: summary,
    ),
  );
}

/// Outcome of [runWithWorkerPassword].
class WorkerPasswordRun<T> {
  /// The last submit result; null when the operator cancelled before any
  /// accepted attempt.
  final T? result;

  /// SAP refused the password [maxWorkerPasswordAttempts] times in a row.
  final bool exhausted;

  const WorkerPasswordRun._(this.result, {this.exhausted = false});

  bool get cancelled => result == null && !exhausted;
}

/// Asks for the worker's password and submits with it. When SAP answers that
/// the password is wrong ([isWrongPassword]), the popup opens again with the
/// error shown inside it, up to [maxWorkerPasswordAttempts] times; after that
/// it closes, a red notice says the limit was reached, and the run reports
/// [WorkerPasswordRun.exhausted]. A refused password is rolled back on the
/// device, never parked on the Đồng bộ tab.
Future<WorkerPasswordRun<T>> runWithWorkerPassword<T>(
  BuildContext context, {
  required String workerName,
  required String actionLabel,
  required Future<T> Function(String password) submit,
  required bool Function(T result) isWrongPassword,
  WorkerQuantitySummary? summary,
}) async {
  String? error;
  for (var attempt = 1; attempt <= maxWorkerPasswordAttempts; attempt++) {
    if (!context.mounted) return const WorkerPasswordRun._(null);
    final password = await showWorkerVerificationDialog(
      context,
      workerName: workerName,
      actionLabel: actionLabel,
      errorText: error,
      summary: summary,
    );
    if (password == null) return const WorkerPasswordRun._(null);
    final result = await submit(password);
    if (!isWrongPassword(result)) return WorkerPasswordRun._(result);
    final left = maxWorkerPasswordAttempts - attempt;
    if (left <= 0) {
      if (context.mounted) {
        showWorkerPasswordNotice(context, workerPasswordExhaustedMessage);
      }
      return WorkerPasswordRun._(result, exhausted: true);
    }
    error = 'Mật khẩu công nhân không đúng. Còn $left lần nhập.';
  }
  return const WorkerPasswordRun._(null, exhausted: true);
}

const String workerPasswordExhaustedMessage =
    'Bạn đã nhập sai mật khẩu quá $maxWorkerPasswordAttempts lần.';

/// A short red notice at the top of the screen. It sits on the root overlay,
/// so it stays visible above a bottom sheet (the confirmation form) where a
/// SnackBar would be hidden underneath.
void showWorkerPasswordNotice(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 3),
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  var removed = false;
  void remove() {
    if (removed) return;
    removed = true;
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (context) => Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Material(
            color: CaslaColors.danger,
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: remove,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  unawaited(Future<void>.delayed(duration, remove));
}

class _WorkerVerificationDialog extends StatefulWidget {
  final String workerName;
  final String actionLabel;
  final String? initialError;
  final WorkerQuantitySummary? summary;

  const _WorkerVerificationDialog({
    required this.workerName,
    required this.actionLabel,
    this.initialError,
    this.summary,
  });

  @override
  State<_WorkerVerificationDialog> createState() =>
      _WorkerVerificationDialogState();
}

class _WorkerVerificationDialogState extends State<_WorkerVerificationDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _isClosing = false;
  late String? _error = widget.initialError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_isClosing) return;
    final password = _controller.text;
    if (password.trim().isEmpty) {
      setState(() => _error = 'Vui lòng nhập mật khẩu.');
      return;
    }
    _close(password);
  }

  void _close([String? password]) {
    if (_isClosing) return;
    _isClosing = true;
    _controller.clear();
    Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    return AlertDialog(
      titlePadding: CaslaDialog.titlePadding,
      contentPadding: CaslaDialog.contentPadding,
      scrollable: true,
      // The theme's side gap; less above and below so the password field and
      // buttons stay above the keyboard of a small PDA.
      insetPadding: const EdgeInsets.symmetric(
        horizontal: CaslaDialog.sideGap,
        vertical: 12,
      ),
      title: const CaslaDialogHeader(child: Text('Xác minh công nhân')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (summary == null)
            Text(
              '${widget.workerName} cần nhập mật khẩu SAP để ${widget.actionLabel.toLowerCase()}.',
            )
          else
            _QuantitySummaryBlock(
              workerName: widget.workerName,
              summary: summary,
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: TextInputType.visiblePassword,
            // This is a one-shot worker verification secret, not an account
            // credential. `null` explicitly disables Android/web autofill;
            // an empty list still allows the platform to infer autofill.
            autofillHints: null,
            obscureText: _obscure,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: 'Mật khẩu công nhân',
              errorText: _error,
              errorMaxLines: 3,
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Hiện mật khẩu' : 'Ẩn mật khẩu',
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
        ],
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          style: CaslaDialog.actionStyle,
          onPressed: _close,
          child: const Text('Hủy'),
        ),
        FilledButton(
          style: CaslaDialog.actionStyle,
          onPressed: _submit,
          child: const Text('Xác minh & gửi SAP'),
        ),
      ],
    );
  }
}

/// Who signs and the quantities about to be posted: the quantity given on
/// one line, the non-zero confirmation figures side by side, each in a
/// rounded frame.
class _QuantitySummaryBlock extends StatelessWidget {
  final String workerName;
  final WorkerQuantitySummary summary;

  const _QuantitySummaryBlock({
    required this.workerName,
    required this.summary,
  });

  String _format(double value) => formatQuantity(value, uom: summary.uom);

  bool _shows(double value) => value > 0 && _format(value) != '0';

  @override
  Widget build(BuildContext context) {
    final code = summary.workerCode.trim();
    final figures = [
      if (_shows(summary.completed))
        _QuantityFigure(label: 'Số đạt', value: _format(summary.completed)),
      if (_shows(summary.defect))
        _QuantityFigure(label: 'Số phế', value: _format(summary.defect)),
      if (_shows(summary.recalled))
        _QuantityFigure(label: 'Thu hồi', value: _format(summary.recalled)),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            text: workerName,
            style: const TextStyle(fontWeight: FontWeight.w700),
            children: [
              if (code.isNotEmpty && code != workerName.trim())
                TextSpan(
                  text: ' · $code',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: CaslaColors.muted,
                  ),
                ),
            ],
          ),
        ),
        if (_shows(summary.assigned)) ...[
          const SizedBox(height: 10),
          _TotalLine(
            key: const ValueKey('worker-assigned-total'),
            label: 'SỐ LƯỢNG GIAO',
            value: _format(summary.assigned),
          ),
        ],
        if (_shows(summary.completedTotal)) ...[
          const SizedBox(height: 10),
          _TotalLine(
            key: const ValueKey('worker-completed-total'),
            label: 'SỐ LƯỢNG HOÀN THÀNH',
            value: _format(summary.completedTotal),
          ),
        ],
        if (figures.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('worker-quantity-summary'),
            padding: const EdgeInsets.symmetric(
              horizontal: CaslaSpacing.sm,
              vertical: CaslaSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: CaslaColors.muted100,
              borderRadius: BorderRadius.circular(CaslaRadius.sm),
            ),
            child: Row(
              children: [
                for (var index = 0; index < figures.length; index++) ...[
                  if (index > 0) const SizedBox(width: CaslaSpacing.xs),
                  Expanded(child: figures[index]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// One total in a rounded frame: its caption on the left, the figure large on
/// the right.
class _TotalLine extends StatelessWidget {
  final String label;
  final String value;

  /// About half the row of a 320 px PDA dialog at 1.3× text: a long figure
  /// scales down past this instead of squeezing the caption.
  static const double _valueMaxWidth = 104;

  const _TotalLine({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: CaslaSpacing.sm,
        vertical: CaslaSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: CaslaColors.muted100,
        borderRadius: BorderRadius.circular(CaslaRadius.md),
      ),
      child: Row(
        children: [
          // "SỐ LƯỢNG HOÀN THÀNH" does not fit beside the figure on a narrow
          // PDA: it wraps there rather than being cut off.
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: CaslaColors.primaryNavy,
              ),
            ),
          ),
          const SizedBox(width: CaslaSpacing.sm),
          // Scale down instead of wrapping: a total such as 125.000,5 must
          // stay on one line of a 320 px PDA dialog.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _valueMaxWidth),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                value,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: CaslaDialog.totalSize,
                  fontWeight: FontWeight.w800,
                  color: CaslaColors.primaryNavy,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuantityFigure extends StatelessWidget {
  final String label;
  final String value;

  const _QuantityFigure({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    // Scale down instead of wrapping: three figures share a 320 px PDA
    // dialog, and one such as 12.500,5 must stay on one line.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: CaslaColors.primaryNavy,
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: const TextStyle(
              fontSize: CaslaDialog.tileFigureSize,
              fontWeight: FontWeight.w800,
              color: CaslaColors.primaryNavy,
            ),
          ),
        ),
      ],
    );
  }
}
