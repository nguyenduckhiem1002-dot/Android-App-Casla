import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';

/// "Có số lượng phế": a checkbox row that, once ticked, opens the defective
/// quantity field underneath. Shared by the confirmation sheet and the
/// give-and-confirm form so both read the same.
class DefectQuantitySection extends StatelessWidget {
  final bool enabled;
  final TextEditingController controller;
  final String unit;
  final String? error;
  final ValueChanged<bool> onToggle;
  final ValueChanged<String> onChanged;

  /// Where the focus sits while typing, for forms that pause a barcode wedge
  /// on a focused number field.
  final FocusNode? focusNode;

  /// The line under the field explaining where the figure goes.
  final String note;

  /// Test key of the quantity field.
  final Key fieldKey;

  const DefectQuantitySection({
    super.key,
    required this.enabled,
    required this.controller,
    required this.unit,
    required this.error,
    required this.onToggle,
    required this.onChanged,
    this.focusNode,
    this.note = 'Số phế được gửi riêng và vẫn trừ vào số lượng còn lại.',
    this.fieldKey = const ValueKey('defect-quantity'),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(
          color: enabled ? CaslaColors.danger : CaslaColors.line,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: enabled ? CaslaColors.dangerBg : CaslaColors.surface,
            child: InkWell(
              onTap: () => onToggle(!enabled),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
                child: Row(
                  children: [
                    Checkbox(
                      value: enabled,
                      activeColor: CaslaColors.danger,
                      onChanged: (value) => onToggle(value ?? false),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Có số lượng phế',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: CaslaColors.primaryNavy,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Tích để nhập số lượng sản phẩm phế',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: CaslaColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      enabled ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: CaslaColors.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (enabled)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    key: fieldKey,
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: onChanged,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: CaslaColors.primaryNavy,
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Số lượng phế',
                      suffixText: ' $unit',
                      errorText: error,
                      errorMaxLines: 2,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    note,
                    style: const TextStyle(
                      fontSize: 13,
                      color: CaslaColors.muted,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
