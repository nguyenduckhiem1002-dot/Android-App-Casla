// Shared by S14 (Vị trí & công nhân) and S16 (Danh mục máy): both talk to
// ZUI_PP_POS and show its rejections the same way.

import '../../core/sync/sync_failure.dart';
import '../../data/sap/odata_error.dart';
import '../../data/sap/sap_odata_client.dart';
import '../../data/sap/sap_session_provider.dart';

/// Vietnamese text for a position call failure. Codes come from
/// `zcl_pp_position_api` (docs/POSITION_MANAGEMENT.md, "Lỗi").
String describePositionError(Object error) {
  if (error is SapConfigurationException) return error.message;
  if (error is SapBusinessError) {
    final text = switch (error.code) {
      'AUTH_FAILED' ||
      'TOKEN_INVALID_OR_EXPIRED' ||
      'DEVICE_MISMATCH' ||
      'USER_INACTIVE' =>
        'Phiên đăng nhập đã hết hạn hoặc không hợp lệ. Hãy '
            'đăng nhập lại.',
      'PASSWORD_CHANGE_REQUIRED' =>
        'Tài khoản cần đổi mật khẩu trước khi tiếp tục.',
      'MISSING_PERMISSION' =>
        'Tài khoản chưa được cấp quyền quản lý vị trí (PP_POS_MANAGE).',
      'NO_WORK_CENTER_SCOPE' =>
        'Xưởng của vị trí, hoặc chỗ ngồi hiện tại của công nhân, nằm ngoài '
            'phạm vi quyền của bạn.',
      'INPUT_INVALID' =>
        'Thiếu hoặc sai mã xưởng, vị trí, máy hay công nhân. Kiểm tra lại '
            'nhãn vừa quét.',
      'POSITION_EXISTS' =>
        'Vị trí này đang gắn máy khác. Quét lại để SAP đổi máy thay vì tạo '
            'mới.',
      'POSITION_NOT_ACTIVE' => 'Vị trí chưa có hoặc đang ngừng dùng.',
      'MACHINE_NOT_ACTIVE' =>
        'Mã máy chưa có trong danh mục máy hoặc đã ngừng dùng. Báo quản trị '
            'thêm máy trên Fiori trước.',
      'MACHINE_IN_USE' =>
        'Máy đang gắn ở vị trí thuộc xưởng ngoài phạm vi quyền của bạn nên '
            'không chuyển sang được. Nhờ người quản lý xưởng đó gỡ máy trước.',
      'WORKER_NOT_IN_WORK_CENTER' =>
        'Công nhân không thuộc xưởng này theo danh sách nhân công hôm nay.',
      'POSITION_LOCKED' =>
        'Dòng này đang được mở chỉnh sửa trên Fiori. Thử lại sau ít phút.',
      'POSITION_SAVE_FAILED' => 'SAP không ghi được thay đổi. Thử lại sau.',
      _ => null,
    };
    if (text != null) return text;
  }
  if (error is SapSessionInvalidatedException) {
    return 'Phiên đăng nhập vừa thay đổi. Hãy thử lại.';
  }
  return classifySyncError(error).message;
}
