/// Builds a stable key for human-entered Vietnamese labels.
///
/// SAP, QR generators, and Android scanners can encode the same visible
/// Vietnamese text with either precomposed characters (for example `ổ`) or a
/// base letter followed by combining marks (`o` + `̂` + `̉`). Department
/// matching should also tolerate missing accents, casing, and accidental
/// surrounding/repeated whitespace because these labels are identifiers in
/// the mobile flow rather than free-form prose.
String normalizeVietnameseComparisonKey(String value) {
  final folded = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    if (_vietnameseCombiningMarks.contains(rune)) continue;
    final character = String.fromCharCode(rune);
    folded.write(_vietnameseLetterFold[character] ?? character);
  }

  return folded
      .toString()
      .replaceAll(_departmentSeparators, ' ')
      .replaceAll(_unicodeWhitespace, ' ')
      .trim();
}

bool vietnameseLabelsEqual(String left, String right) =>
    normalizeVietnameseComparisonKey(left) ==
    normalizeVietnameseComparisonKey(right);

final RegExp _unicodeWhitespace = RegExp(
  r'[\s\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+',
);

// Printed QR labels use both hyphens and typographic dashes before a location
// ("VIỀN-XM2", "VIỀN – XM2", "VIỀN XM2"). Keep the word boundary while
// treating those presentation differences equally; never use substring match.
final RegExp _departmentSeparators = RegExp(
  r'[-\u2010-\u2015\u2212\uFE63\uFF0D]',
);

const Set<int> _vietnameseCombiningMarks = {
  0x0300, // grave
  0x0301, // acute
  0x0302, // circumflex
  0x0303, // tilde
  0x0306, // breve
  0x0309, // hook above
  0x031B, // horn
  0x0323, // dot below
};

const Map<String, String> _vietnameseLetterFold = {
  'à': 'a',
  'á': 'a',
  'ạ': 'a',
  'ả': 'a',
  'ã': 'a',
  'â': 'a',
  'ầ': 'a',
  'ấ': 'a',
  'ậ': 'a',
  'ẩ': 'a',
  'ẫ': 'a',
  'ă': 'a',
  'ằ': 'a',
  'ắ': 'a',
  'ặ': 'a',
  'ẳ': 'a',
  'ẵ': 'a',
  'è': 'e',
  'é': 'e',
  'ẹ': 'e',
  'ẻ': 'e',
  'ẽ': 'e',
  'ê': 'e',
  'ề': 'e',
  'ế': 'e',
  'ệ': 'e',
  'ể': 'e',
  'ễ': 'e',
  'ì': 'i',
  'í': 'i',
  'ị': 'i',
  'ỉ': 'i',
  'ĩ': 'i',
  'ò': 'o',
  'ó': 'o',
  'ọ': 'o',
  'ỏ': 'o',
  'õ': 'o',
  'ô': 'o',
  'ồ': 'o',
  'ố': 'o',
  'ộ': 'o',
  'ổ': 'o',
  'ỗ': 'o',
  'ơ': 'o',
  'ờ': 'o',
  'ớ': 'o',
  'ợ': 'o',
  'ở': 'o',
  'ỡ': 'o',
  'ù': 'u',
  'ú': 'u',
  'ụ': 'u',
  'ủ': 'u',
  'ũ': 'u',
  'ư': 'u',
  'ừ': 'u',
  'ứ': 'u',
  'ự': 'u',
  'ử': 'u',
  'ữ': 'u',
  'ỳ': 'y',
  'ý': 'y',
  'ỵ': 'y',
  'ỷ': 'y',
  'ỹ': 'y',
  'đ': 'd',
};
