String formatQuantity(double value, {int maxFractionDigits = 3}) {
  if (!value.isFinite) return '—';
  final normalized = value.abs() < 0.0000005 ? 0.0 : value;
  final fixed = normalized.toStringAsFixed(maxFractionDigits);
  return fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
