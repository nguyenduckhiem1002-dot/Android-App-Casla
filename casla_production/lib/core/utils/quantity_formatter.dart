bool usesWholeQuantity(String? uom) => const {
  'CHC',
  'BOO',
  'CAI',
  'TAM',
  'THH',
  'LIN',
}.contains(uom?.trim().toUpperCase());

/// Red-field message when a count unit (CHC, BOO, ...) receives a fractional
/// quantity such as `10.5` or `10,5`. Nobody hands out half a piece, so the
/// input is rejected as a format error before it can reach SAP. Grouped
/// thousands (`10.000`) parse as whole numbers and stay valid.
String? wholeQuantityInputError(String raw, String? uom) {
  if (!usesWholeQuantity(uom) || raw.trim().isEmpty) return null;
  final value = parseLocalizedQuantity(raw);
  if (value == null || !value.isFinite) return null;
  if ((value - value.roundToDouble()).abs() < 0.0000005) return null;
  return 'Sai định dạng: đơn vị ${uom!.trim().toUpperCase()} '
      'chỉ nhập số nguyên.';
}

String formatQuantity(double value, {int maxFractionDigits = 3, String? uom}) {
  if (!value.isFinite) return '—';
  final normalized = value.abs() < 0.0000005 ? 0.0 : value;
  final fixed = normalized.toStringAsFixed(
    usesWholeQuantity(uom) ? 0 : maxFractionDigits,
  );
  final parts = fixed.split('.');
  final integer = parts.first.replaceFirst(RegExp(r'^-'), '');
  final grouped = StringBuffer();
  for (var index = 0; index < integer.length; index++) {
    if (index > 0 && (integer.length - index) % 3 == 0) {
      grouped.write('.');
    }
    grouped.write(integer[index]);
  }
  var fraction = parts.length == 1 ? '' : parts[1];
  fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
  return '${fixed.startsWith('-') ? '-' : ''}$grouped'
      '${fraction.isEmpty ? '' : '.$fraction'}';
}

/// Whether [remaining] is still something as the screen shows it. A count
/// unit's 0,4 CHC left displays as "0"; it must not keep a worker open
/// ("ĐANG THỰC HIỆN", 99%) next to "Còn lại 0".
bool hasRemainingQuantity(double remaining, {String? uom}) =>
    remaining > 0 && formatQuantity(remaining, uom: uom) != '0';

/// Completion [rate] (0–1) as a whole percent, rounded down: 2.400 of 2.410
/// reads 99%, never 100% while anything is still left to finish.
String formatCompletionPercent(double rate) {
  if (!rate.isFinite || rate <= 0) return '0%';
  // The epsilon keeps an exact finish at 100% despite float noise
  // (0.3 done of 0.1 + 0.2 given is 0.9999999999999999).
  final percent = (rate.clamp(0.0, 1.0) * 100 + 1e-9).floor();
  return '$percent%';
}

/// Parses quantities returned by SAP/printed QR labels.
///
/// The shop-floor payload uses a dot as the thousands separator (`10.000`)
/// and may use a comma for decimals (`10.000,500`). A dot followed by fewer
/// than three digits remains a decimal (`10.5`), so quantities with real
/// fractional precision continue to work.
double? parseLocalizedQuantity(String raw) {
  final match = RegExp(r'-?[\d.,]+').firstMatch(raw.trim());
  if (match == null) return null;
  var value = match.group(0)!;
  final hasDot = value.contains('.');
  final hasComma = value.contains(',');
  if (hasDot && hasComma) {
    value = value.replaceAll('.', '').replaceFirst(',', '.');
  } else if (hasDot) {
    final dot = value.lastIndexOf('.');
    final fractionDigits = value.length - dot - 1;
    if (fractionDigits == 3 &&
        RegExp(r'^-?\d{1,3}(?:\.\d{3})+$').hasMatch(value)) {
      value = value.replaceAll('.', '');
    }
  } else if (hasComma) {
    value = value.replaceFirst(',', '.');
  }
  return double.tryParse(value);
}
