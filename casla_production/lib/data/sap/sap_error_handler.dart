// SAP Integration — Error Handler
// Spec: Section 9.4 (Error contract)
// Error codes: OUT_OF_SCOPE, OVER_REMAINING, ASSIGNMENT_CLOSED, DUPLICATE, AUTH_EXPIRED

import 'package:dio/dio.dart';
import 'sap_dtos.dart';

/// User-friendly error messages for SAP error codes
class SapErrorHandler {
  SapErrorHandler._();

  /// Known SAP error codes (Spec 9.4)
  static const String outOfScope = 'OUT_OF_SCOPE';
  static const String overRemaining = 'OVER_REMAINING';
  static const String assignmentClosed = 'ASSIGNMENT_CLOSED';
  static const String duplicate = 'DUPLICATE';
  static const String authExpired = 'AUTH_EXPIRED';

  /// Convert SAP API error to user-friendly Vietnamese message
  static String getErrorMessage(SapApiError error) {
    switch (error.code) {
      case outOfScope:
        return 'Nhân viên ngoài phạm vi quản lý của bạn';
      case overRemaining:
        return 'Số lượng vượt quá số còn lại tại thời điểm xử lý';
      case assignmentClosed:
        return 'Phân công đã được đóng hoặc thu hồi';
      case duplicate:
        return 'Giao dịch này đã được ghi nhận trước đó';
      case authExpired:
        return 'Phiên đăng nhập đã hết hạn, vui lòng đăng nhập lại';
      default:
        return error.message.isNotEmpty
            ? error.message
            : 'Lỗi không xác định từ hệ thống SAP';
    }
  }

  /// Parse Dio exception to user-friendly message
  static String getDioErrorMessage(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Hết thời gian chờ kết nối. Dữ liệu đã lưu local và sẽ đồng bộ sau.';
      case DioExceptionType.connectionError:
        return 'Không thể kết nối đến máy chủ SAP. Dữ liệu đã lưu offline.';
      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode;
        if (statusCode == 401 || statusCode == 403) {
          return 'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.';
        }
        if (statusCode == 409) {
          return 'Xung đột dữ liệu. Vui lòng làm mới và thử lại.';
        }
        if (statusCode != null && statusCode >= 500) {
          return 'Lỗi máy chủ SAP (${statusCode}). Dữ liệu đã lưu local.';
        }
        return 'Lỗi từ máy chủ SAP (${statusCode ?? 'unknown'})';
      case DioExceptionType.cancel:
        return 'Yêu cầu đã bị hủy';
      default:
        return 'Lỗi kết nối. Dữ liệu đã lưu offline và sẽ đồng bộ sau.';
    }
  }

  /// Check if error is retryable (temporary network issue)
  static bool isRetryable(String errorCode) {
    return !{outOfScope, overRemaining, assignmentClosed, duplicate}
        .contains(errorCode);
  }

  /// Check if error requires re-authentication
  static bool requiresReauth(String errorCode) {
    return errorCode == authExpired;
  }
}
