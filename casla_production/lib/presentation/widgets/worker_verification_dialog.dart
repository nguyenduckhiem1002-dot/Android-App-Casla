import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';

Future<String?> showWorkerVerificationDialog(
  BuildContext context, {
  required String workerName,
  required String actionLabel,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WorkerVerificationDialog(
      workerName: workerName,
      actionLabel: actionLabel,
    ),
  );
}

class _WorkerVerificationDialog extends StatefulWidget {
  final String workerName;
  final String actionLabel;

  const _WorkerVerificationDialog({
    required this.workerName,
    required this.actionLabel,
  });

  @override
  State<_WorkerVerificationDialog> createState() =>
      _WorkerVerificationDialogState();
}

class _WorkerVerificationDialogState extends State<_WorkerVerificationDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _controller.text;
    if (password.trim().isEmpty) {
      setState(() => _error = 'Vui lòng nhập mật khẩu.');
      return;
    }
    Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Xác minh công nhân'),
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
            obscureText: _obscure,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: 'Mật khẩu SAP của công nhân',
              errorText: _error,
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
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Xác minh & gửi SAP'),
        ),
      ],
    );
  }
}
