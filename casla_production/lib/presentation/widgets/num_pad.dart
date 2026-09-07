import 'package:flutter/material.dart';
import '../../app/theme/casla_colors.dart';

class NumPad extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final List<int>? quickAdds;
  final int decimalPlaces;

  const NumPad({
    super.key,
    required this.value,
    required this.onChanged,
    this.quickAdds = const [10, 50, 100],
    this.decimalPlaces = 3,
  });

  void _onKeyPress(String key) {
    if (key == 'Xoá') {
      onChanged('');
    } else if (key == '⌫') {
      if (value.isNotEmpty) {
        onChanged(value.substring(0, value.length - 1));
      }
    } else if (key == '.') {
      if (decimalPlaces > 0 && !value.contains('.')) {
        onChanged(value.isEmpty ? '0.' : '$value.');
      }
    } else {
      // Keep manual entry bounded while still allowing fractional quantities
      // such as 1.250 KG. The limit applies to digits, not the decimal point.
      final digits = value.replaceAll('.', '');
      final decimals = value.contains('.') ? value.split('.').last.length : 0;
      if (digits.length < 6 && decimals < decimalPlaces) {
        if (value == '0') {
          onChanged(key);
        } else {
          onChanged(value + key);
        }
      }
    }
  }

  void _onQuickAdd(int add) {
    final current = double.tryParse(value) ?? 0;
    final sum = current + add;
    final formatted = sum
        .toStringAsFixed(decimalPlaces)
        .replaceFirst(RegExp(r'\.?0+$'), '');
    onChanged(formatted);
  }

  @override
  Widget build(BuildContext context) {
    final keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['.', '0', '⌫'],
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (quickAdds != null && quickAdds!.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: quickAdds!.map((add) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InkWell(
                  onTap: () => _onQuickAdd(add),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: CaslaColors.gold100,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '+$add',
                      style: const TextStyle(
                        color: CaslaColors.gold700,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
        ],

        // 3x4 Grid
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 12,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            childAspectRatio: 1.8,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemBuilder: (context, index) {
            final row = index ~/ 3;
            final col = index % 3;
            final keyStr = keys[row][col];
            final isOp = keyStr == '.' || keyStr == '⌫';

            return Material(
              color: CaslaColors.surface,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                key: ValueKey('num-pad-key-$keyStr'),
                onTap: () => _onKeyPress(keyStr),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: CaslaColors.line),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    keyStr,
                    style: TextStyle(
                      fontFamily: isOp ? 'Inter' : 'Manrope',
                      fontWeight: FontWeight.w700,
                      fontSize: isOp ? 15 : 18,
                      color: isOp
                          ? CaslaColors.danger
                          : CaslaColors.primaryNavy,
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
