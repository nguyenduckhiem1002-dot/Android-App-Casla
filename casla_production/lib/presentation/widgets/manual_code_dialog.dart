import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/casla_spacing.dart';
import '../../data/sap/sap_position_gateway.dart';

/// Asks for a code typed by hand when a label cannot be scanned.
///
/// Returns the trimmed text, or null when cancelled.
Future<String?> showManualCodeDialog(
  BuildContext context, {
  required String title,
  required String label,
  required String helperText,
}) async {
  final values = await showDialog<List<String>>(
    context: context,
    builder: (_) => _ManualCodeDialog(
      title: title,
      fields: [_ManualField(label: label, helperText: helperText)],
    ),
  );
  return values?.single;
}

/// Asks for the position and the machine code in separate fields when a
/// machine label cannot be scanned.
///
/// Returns them in the printed label's `position@machine` form, so typed input
/// goes through the same reader and checks as a scan; null when cancelled.
/// The Work Center is the caller's, as for a scanned label.
Future<String?> showManualSlotDialog(BuildContext context) async {
  final values = await showDialog<List<String>>(
    context: context,
    builder: (_) => _ManualCodeDialog(
      title: 'Nhập vị trí và mã máy',
      fields: [
        _ManualField.code(
          label: 'Mã vị trí',
          helperText: 'Ví dụ: G05',
          maxLength: PositionFieldLimits.positionId,
        ),
        _ManualField.code(
          label: 'Mã máy',
          helperText: 'Ví dụ: M105',
          maxLength: PositionFieldLimits.machineId,
        ),
      ],
    ),
  );
  return values?.join('@');
}

class _ManualField {
  final String label;
  final String helperText;
  final List<TextInputFormatter> inputFormatters;

  const _ManualField({required this.label, required this.helperText})
    : inputFormatters = const [];

  /// Only what a SAP position or machine code may contain, so a stray `@`
  /// cannot shift the joined value into another field.
  _ManualField.code({
    required this.label,
    required this.helperText,
    required int maxLength,
  }) : inputFormatters = [
         FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9._-]')),
         LengthLimitingTextInputFormatter(maxLength),
       ];
}

class _ManualCodeDialog extends StatefulWidget {
  final String title;
  final List<_ManualField> fields;

  const _ManualCodeDialog({required this.title, required this.fields});

  @override
  State<_ManualCodeDialog> createState() => _ManualCodeDialogState();
}

class _ManualCodeDialogState extends State<_ManualCodeDialog> {
  late final _controllers = [
    for (final _ in widget.fields) TextEditingController(),
  ];
  late final _focusNodes = [for (final _ in widget.fields) FocusNode()];

  @override
  void dispose() {
    // Owned here, not by the caller: pop() resolves showDialog's Future while
    // the exit transition is still rebuilding these TextFields. Disposing on
    // that Future threw "TextEditingController used after being disposed" and
    // left the whole Navigator on the error screen.
    for (final controller in _controllers) {
      controller.dispose();
    }
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  bool get _isComplete =>
      _controllers.every((controller) => controller.text.trim().isNotEmpty);

  void _submit() {
    final empty = _controllers.indexWhere((c) => c.text.trim().isEmpty);
    if (empty != -1) {
      _focusNodes[empty].requestFocus();
      return;
    }
    Navigator.of(
      context,
    ).pop([for (final controller in _controllers) controller.text.trim()]);
  }

  @override
  Widget build(BuildContext context) {
    final last = widget.fields.length - 1;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i <= last; i++) ...[
            if (i > 0) const SizedBox(height: CaslaSpacing.sm),
            TextField(
              controller: _controllers[i],
              focusNode: _focusNodes[i],
              autofocus: i == 0,
              textCapitalization: TextCapitalization.characters,
              textInputAction: i == last
                  ? TextInputAction.done
                  : TextInputAction.next,
              inputFormatters: widget.fields[i].inputFormatters,
              decoration: InputDecoration(
                labelText: widget.fields[i].label,
                helperText: widget.fields[i].helperText,
              ),
              onEditingComplete: i == last
                  ? null
                  : () => _focusNodes[i + 1].requestFocus(),
              onSubmitted: i == last ? (_) => _submit() : null,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Hủy'),
        ),
        ListenableBuilder(
          listenable: Listenable.merge(_controllers),
          builder: (context, _) => TextButton(
            onPressed: _isComplete ? _submit : null,
            child: const Text('Xác nhận'),
          ),
        ),
      ],
    );
  }
}
