import 'package:flutter/material.dart';

import '../../app/theme/casla_colors.dart';
import '../../app/theme/casla_spacing.dart';
import '../../core/scanner/scan_feedback.dart';

class NumPad extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final List<int>? quickAdds;
  final int decimalPlaces;

  /// Fills the field with the largest value the caller will accept.
  ///
  /// "The worker finished the whole batch" is the single most common
  /// confirmation on the floor, and typing it out digit by digit in gloves was
  /// the slowest step in the flow.
  final double? fillMaxValue;
  final String? fillMaxLabel;

  const NumPad({
    super.key,
    required this.value,
    required this.onChanged,
    this.quickAdds = const [10, 50, 100],
    this.decimalPlaces = 3,
    this.fillMaxValue,
    this.fillMaxLabel,
  });

  void _onKeyPress(String key) {
    ScanFeedback.keyPress();

    if (key == _backspace) {
      if (value.isNotEmpty) {
        onChanged(value.substring(0, value.length - 1));
      }
      return;
    }
    if (key == '.') {
      if (decimalPlaces > 0 && !value.contains('.')) {
        onChanged(value.isEmpty ? '0.' : '$value.');
      }
      return;
    }

    // Keep manual entry bounded while still allowing fractional quantities
    // such as 1.250 KG. The limit applies to digits, not the decimal point.
    final digits = value.replaceAll('.', '');
    final decimals = value.contains('.') ? value.split('.').last.length : 0;
    if (digits.length < 6 && decimals < decimalPlaces) {
      onChanged(value == '0' ? key : value + key);
    }
  }

  void _onQuickAdd(int add) {
    ScanFeedback.keyPress();
    final current = double.tryParse(value) ?? 0;
    onChanged(_format(current + add));
  }

  void _onFillMax(double max) {
    ScanFeedback.keyPress();
    onChanged(_format(max));
  }

  String _format(double amount) =>
      amount.toStringAsFixed(decimalPlaces).replaceFirst(RegExp(r'\.?0+$'), '');

  static const String _backspace = '⌫';

  static const List<List<String>> _keys = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['.', '0', _backspace],
  ];

  @override
  Widget build(BuildContext context) {
    final max = fillMaxValue;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (max != null && max > 0) ...[
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              onPressed: () => _onFillMax(max),
              icon: const Icon(Icons.done_all_rounded, size: 18),
              label: Text(fillMaxLabel ?? 'Toàn bộ còn lại (${_format(max)})'),
              style: OutlinedButton.styleFrom(
                foregroundColor: CaslaColors.primaryNavy,
                side: const BorderSide(
                  color: CaslaColors.primaryNavy,
                  width: 1.5,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(CaslaRadius.md),
                ),
              ),
            ),
          ),
          const SizedBox(height: CaslaSpacing.sm),
        ],

        if (quickAdds != null && quickAdds!.isNotEmpty) ...[
          Wrap(
            alignment: WrapAlignment.center,
            spacing: CaslaSpacing.xs,
            runSpacing: CaslaSpacing.xs,
            children: [
              for (final add in quickAdds!)
                _QuickAddChip(amount: add, onTap: () => _onQuickAdd(add)),
            ],
          ),
          const SizedBox(height: CaslaSpacing.sm),
        ],

        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 12,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            // Fixed height, not an aspect ratio. 64dp is a comfortable target
            // for a gloved thumb, and it stays 64dp on a wide screen instead
            // of growing into a keypad taller than the sheet holding it.
            mainAxisExtent: 64,
            crossAxisSpacing: CaslaSpacing.xs,
            mainAxisSpacing: CaslaSpacing.xs,
          ),
          itemBuilder: (context, index) {
            final keyStr = _keys[index ~/ 3][index % 3];
            final isBackspace = keyStr == _backspace;

            return Material(
              color: CaslaColors.surface,
              borderRadius: BorderRadius.circular(CaslaRadius.sm),
              child: InkWell(
                key: ValueKey('num-pad-key-$keyStr'),
                onTap: () => _onKeyPress(keyStr),
                borderRadius: BorderRadius.circular(CaslaRadius.sm),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: CaslaColors.line),
                    borderRadius: BorderRadius.circular(CaslaRadius.sm),
                  ),
                  alignment: Alignment.center,
                  child: isBackspace
                      ? const Icon(
                          Icons.backspace_outlined,
                          size: 20,
                          color: CaslaColors.danger,
                        )
                      : Text(
                          keyStr,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: CaslaType.title,
                            // The decimal point is punctuation, not a
                            // destructive action; only backspace is red.
                            color: CaslaColors.primaryNavy,
                          ),
                        ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _QuickAddChip extends StatelessWidget {
  final int amount;
  final VoidCallback onTap;

  const _QuickAddChip({required this.amount, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CaslaRadius.pill),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: CaslaSpacing.md),
          decoration: BoxDecoration(
            color: CaslaColors.gold100,
            borderRadius: BorderRadius.circular(CaslaRadius.pill),
          ),
          child: Text(
            '+$amount',
            style: const TextStyle(
              color: CaslaColors.gold700,
              fontWeight: FontWeight.w700,
              fontSize: CaslaType.body,
            ),
          ),
        ),
      ),
    );
  }
}
