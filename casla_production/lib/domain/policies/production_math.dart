// Domain Policies — Production Math
// Spec: Section 3.1 (Formulas)
// Pure business logic, no framework dependencies

class ProductionMath {
  ProductionMath._();

  /// Số chữ số thập phân SAP lưu cho mọi số lượng phân bổ.
  ///
  /// `ztb_pp_alloc_txn-quantity` là `quan(15,3)`, và `Edm.Decimal` trên
  /// ZUI_PP_OPALLOC cũng khai báo `Scale="3"`. Mọi số lượng đi vào SQLite hay
  /// vào payload đều phải quy về đúng thang này, tại cùng một chỗ.
  static const int sapQuantityScale = 3;

  /// Quy [value] về thang SAP lưu được.
  ///
  /// Đây là phép làm tròn *duy nhất* trong luồng ghi. Trước đây gateway tự
  /// `toStringAsFixed(3)` ngay lúc gửi, còn bản ghi local giữ nguyên giá trị
  /// người dùng nhập — nhập `1.2345` thì local lưu `1.2345` nhưng SAP nhận
  /// `1.234`, và không màn hình nào phát hiện được chênh lệch đó.
  static double toSapScale(double value) {
    if (!value.isFinite) return 0.0;
    return double.parse(value.toStringAsFixed(sapQuantityScale));
  }

  /// `value > limit` sau khi cả hai đã ở thang SAP.
  ///
  /// So sánh `double` thô làm hỏng các số lẻ hợp lệ: giao `0.3`, hoàn thành
  /// `0.1`, phần còn lại trong `double` là `0.19999999999999998`, nên nhập
  /// đúng `0.2` lại bị coi là vượt. Quy cả hai vế về thang SAP rồi mới so
  /// sánh, thay vì rải epsilon mỗi nơi một kiểu.
  static bool exceedsAtSapScale(double value, double limit) {
    if (!value.isFinite || !limit.isFinite) return true;
    return toSapScale(value) > toSapScale(limit);
  }

  /// Định dạng số lượng cho người đọc, không kéo theo đuôi số 0 vô nghĩa.
  static String formatQuantity(double value) {
    final scaled = toSapScale(value);
    if (scaled == scaled.roundToDouble()) return scaled.toStringAsFixed(0);
    return scaled
        .toStringAsFixed(sapQuantityScale)
        .replaceFirst(RegExp(r'0+$'), '');
  }

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
    if (exceedsAtSapScale(newQuantity, remaining)) {
      return 'Số lượng vượt quá số lượng còn lại (${formatQuantity(remaining)})';
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
    if (exceedsAtSapScale(newRecall, maxRecall)) {
      return 'Số lượng thu hồi vượt quá hạn mức tối đa (${formatQuantity(maxRecall)})';
    }
    if (reasonCode == 'OTHER' && (note == null || note.trim().isEmpty)) {
      return 'Vui lòng nhập ghi chú khi chọn lý do "Khác"';
    }
    return null;
  }
}
