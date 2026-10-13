import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';

/// Field label used above scan fields: bold navy caption, red star when the
/// field is required.
class ScanFieldLabel extends StatelessWidget {
  final String text;
  final bool required;

  const ScanFieldLabel({super.key, required this.text, this.required = false});

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: CaslaType.caption,
          fontWeight: FontWeight.w700,
          color: CaslaColors.primaryNavy,
        ),
        children: [
          if (required)
            const TextSpan(
              text: ' *',
              style: TextStyle(color: CaslaColors.danger),
            ),
        ],
      ),
    );
  }
}

/// A field that is normally filled by pulling the trigger.
///
/// Filled and empty look deliberately different: an operator glancing down
/// mid-shift has to be able to tell at arm's length which half of the
/// assignment is still missing.
class ScanSlotField extends StatelessWidget {
  final bool isScanTarget;
  final VoidCallback onSelect;
  final String label;
  final bool required;
  final IconData icon;
  final String? value;
  final String? detail;
  final List<String>? detailLines;
  final Widget? filledContent;
  final String placeholder;
  final VoidCallback onOpenScanner;
  final VoidCallback? onClear;

  /// Extra controls before the clear button, e.g. the fold arrow an operation
  /// card gets once several operations are being assigned together.
  final Widget? trailing;

  const ScanSlotField({
    super.key,
    required this.isScanTarget,
    required this.onSelect,
    required this.label,
    required this.required,
    required this.icon,
    required this.value,
    required this.detail,
    this.detailLines,
    this.filledContent,
    required this.placeholder,
    required this.onOpenScanner,
    this.onClear,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final filled = value != null && value!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ScanFieldLabel(text: label, required: required),
            ),
            if (isScanTarget)
              const Text(
                'Đang chọn quét',
                style: TextStyle(
                  color: CaslaColors.primaryNavy,
                  fontSize: CaslaType.caption,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
        const SizedBox(height: CaslaSpacing.xs),
        Material(
          color: filled ? CaslaColors.successBg : CaslaColors.surface,
          shape: RoundedRectangleBorder(
            side: BorderSide(
              color: isScanTarget
                  ? CaslaColors.primaryNavy
                  : filled
                  ? CaslaColors.success
                  : CaslaColors.line,
              width: isScanTarget ? 2 : 1.2,
            ),
            borderRadius: BorderRadius.circular(CaslaRadius.md),
          ),
          child: InkWell(
            onTap: onSelect,
            borderRadius: BorderRadius.circular(CaslaRadius.md),
            child: Padding(
              padding: const EdgeInsets.all(CaslaSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        filled ? Icons.check_circle_rounded : icon,
                        size: 22,
                        color: filled ? CaslaColors.success : CaslaColors.muted,
                      ),
                      const SizedBox(width: CaslaSpacing.sm),
                      Expanded(
                        child: Text(
                          filled ? value! : placeholder,
                          softWrap: true,
                          style: TextStyle(
                            fontSize: CaslaType.body,
                            fontWeight: FontWeight.w700,
                            color: filled
                                ? CaslaColors.primaryNavy
                                : CaslaColors.muted,
                          ),
                        ),
                      ),
                      ?trailing,
                      if (onClear != null)
                        IconButton(
                          tooltip: 'Xóa lựa chọn',
                          onPressed: onClear,
                          icon: const Icon(Icons.close, size: 20),
                          color: CaslaColors.muted,
                        ),
                      IconButton(
                        tooltip: 'Camera',
                        onPressed: onOpenScanner,
                        icon: const Icon(Icons.photo_camera_outlined, size: 22),
                        color: CaslaColors.primaryNavy,
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                      ),
                    ],
                  ),
                  if (filled && filledContent != null) filledContent!,
                  if (filled &&
                      filledContent == null &&
                      detailLines != null &&
                      detailLines!.isNotEmpty)
                    ...detailLines!.map(
                      (line) => Text(
                        line,
                        softWrap: true,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: CaslaType.caption,
                          color: CaslaColors.muted,
                          height: 1.3,
                        ),
                      ),
                    )
                  else if (filled && detail != null && detail!.isNotEmpty)
                    Text(
                      detail!,
                      softWrap: true,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: CaslaType.caption,
                        color: CaslaColors.muted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
