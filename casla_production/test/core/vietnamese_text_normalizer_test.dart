import 'package:casla_production/core/utils/vietnamese_text_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('matches composed and decomposed Vietnamese department labels', () {
    expect(
      vietnameseLabelsEqual(
        'Tổ may miệng (Xưởng may 1)',
        '  Tổ may miệng (Xưởng may 1)  ',
      ),
      isTrue,
    );
  });

  test('ignores case, accents, and Unicode whitespace', () {
    expect(
      vietnameseLabelsEqual('MAY MIỆNG\u00A0\u00A0XM1', ' may mieng  xm1 '),
      isTrue,
    );
  });

  test('does not merge different department names', () {
    expect(vietnameseLabelsEqual('Tổ may 1', 'Tổ may 2'), isFalse);
    expect(vietnameseLabelsEqual('GẤP TÚI VIỀN-XM2', 'GẤP TÚI-XM2'), isFalse);
    expect(
      vietnameseLabelsEqual('GẤP TÚI VIỀN-XM2', 'MAY LẬP TRÌNH-XM2'),
      isFalse,
    );
  });

  test('normalizes department location separator without merging words', () {
    for (final label in [
      ' gap tui vien xm2 ',
      'GẤP TÚI VIỀN–XM2',
      'Gấp túi viền – XM2',
    ]) {
      expect(vietnameseLabelsEqual('GẤP TÚI VIỀN-XM2', label), isTrue);
    }
    expect(
      vietnameseLabelsEqual('GẤP TÚI VIỀN-XM2', 'GẤP TÚI VIỀN-XM1'),
      isFalse,
    );
  });
}
