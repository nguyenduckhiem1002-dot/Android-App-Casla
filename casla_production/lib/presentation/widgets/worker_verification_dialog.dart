import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';

/// How many times a worker may re-enter a password SAP refused before the
/// operation is abandoned.
const int maxWorkerPasswordAttempts = 3;

Future<String?> showWorkerVerificationDialog(
  BuildContext context, {
  required String workerName,
  required String actionLabel,
  String? errorText,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WorkerVerificationDialog(
      workerName: workerName,
      actionLabel: actionLabel,
      initialError: errorText,
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
}) async {
  String? error;
  for (var attempt = 1; attempt <= maxWorkerPasswordAttempts; attempt++) {
    if (!context.mounted) return const WorkerPasswordRun._(null);
    final password = await showWorkerVerificationDialog(
      context,
      workerName: workerName,
      actionLabel: actionLabel,
      errorText: error,
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

  const _WorkerVerificationDialog({
    required this.workerName,
    required this.actionLabel,
    this.initialError,
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
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      title: const Text('Xác minh công nhân'),
      titleTextStyle: Theme.of(context).textTheme.titleLarge,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.workerName} cần nhập mật khẩu SAP để ${widget.actionLabel.toLowerCase()}.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Mật khẩu chỉ dùng cho lần gửi này và không được lưu trên thiết bị.',
            style: TextStyle(fontSize: 12, color: CaslaColors.muted),
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
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(onPressed: _close, child: const Text('Hủy')),
        FilledButton(
          onPressed: _submit,
          child: const Text('Xác minh & gửi SAP'),
        ),
      ],
    );
  }
}
