import 'package:flutter/material.dart';
import '../../app/theme/casla_colors.dart';

class NumPad extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final List<int>? quickAdds;

  const NumPad({
    super.key,
    required this.value,
    required this.onChanged,
    this.quickAdds = const [10, 50, 100],
  });

  void _onKeyPress(String key) {
    if (key == 'Xoá') {
      onChanged('');
    } else if (key == '⌫') {
      if (value.isNotEmpty) {
        onChanged(value.substring(0, value.length - 1));
      }
    } else {
      // Limit to 6 digits max
      if (value.length < 6) {
        if (value == '0') {
          onChanged(key);
        } else {
          onChanged(value + key);
        }
      }
    }
  }

  void _onQuickAdd(int add) {
    final current = int.tryParse(value) ?? 0;
    onChanged((current + add).toString());
  }

  @override
  Widget build(BuildContext context) {
    final keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['Xoá', '0', '⌫'],
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
            final isOp = keyStr == 'Xoá' || keyStr == '⌫';

            return Material(
              color: CaslaColors.surface,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
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
