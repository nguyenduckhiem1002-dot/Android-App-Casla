// Domain Policies — Production Math
// Spec: Section 3.1 (Formulas)
// Pure business logic, no framework dependencies

class ProductionMath {
  ProductionMath._();

  /// Giao hiệu lực = Giao ban đầu − Đã thu hồi
  static double calculateEffectiveAssigned(double assigned, double recalled) {
    if (!assigned.isFinite || !recalled.isFinite) return 0.0;
    return (assigned - recalled).clamp(0.0, double.infinity);
  }

  /// Còn lại = Giao hiệu lực − Hoàn thành lũy kế
  static double calculateRemaining(double effectiveAssigned, double completed) {
    if (!effectiveAssigned.isFinite || !completed.isFinite) return 0.0;
    return (effectiveAssigned - completed).clamp(0.0, double.infinity);
  }

  /// Có thể thu hồi = Giao ban đầu − Hoàn thành − Đã thu hồi
  static double calculateMaxRecall(
    double assigned,
    double completed,
    double recalled,
  ) {
    if (!assigned.isFinite || !completed.isFinite || !recalled.isFinite) {
      return 0.0;
    }
    return (assigned - completed - recalled).clamp(0.0, double.infinity);
  }

  /// Tỷ lệ hoàn thành (Spec 3.1)
  static double calculateCompletionRate(
    double completed,
    double effectiveAssigned,
  ) {
    if (!completed.isFinite || !effectiveAssigned.isFinite) return 0.0;
    if (effectiveAssigned <= 0) return 0.0;
    return (completed / effectiveAssigned).clamp(0.0, 1.0);
  }

  /// Validate ghi nhận sản lượng (Spec 3.1: 0 < newCompletion <= remaining)
  static String? validateProductionEntry(double newQuantity, double remaining) {
    if (!newQuantity.isFinite || !remaining.isFinite) {
      return 'Số lượng hoàn thành không hợp lệ';
    }
    if (newQuantity <= 0) {
      return 'Số lượng hoàn thành phải lớn hơn 0';
    }
    if (newQuantity > remaining + 0.0001) {
      return 'Số lượng vượt quá số lượng còn lại (${remaining.toInt()})';
    }
    return null;
  }

  /// Validate thu hồi (Spec 3.1: 0 < newRecall <= maxRecall)
  static String? validateRecallEntry(
    double newRecall,
    double maxRecall,
    String reasonCode,
    String? note,
  ) {
    if (!newRecall.isFinite || !maxRecall.isFinite) {
      return 'Số lượng thu hồi không hợp lệ';
    }
    if (newRecall <= 0) {
      return 'Số lượng thu hồi phải lớn hơn 0';
    }
    if (newRecall > maxRecall + 0.0001) {
      return 'Số lượng thu hồi vượt quá hạn mức tối đa (${maxRecall.toInt()})';
    }
    if (reasonCode == 'OTHER' && (note == null || note.trim().isEmpty)) {
      return 'Vui lòng nhập ghi chú khi chọn lý do "Khác"';
    }
    return null;
  }
}
