// SAP Integration — Auth Controller
// Spec: Section 4.1 (Login flow), Section 10 (Security)
// SAP Service: ZUI_USER_QR_API

import 'dart:convert';
import 'package:dio/dio.dart';
import '../../core/utils/device_info.dart';
import 'odata_sanitizer.dart';
import 'sap_odata_client.dart';
import 'sap_endpoints.dart';

/// Result DTO for SAP Login Response
class SapLoginResult {
  final String accessToken;
  final String refreshToken;
  final String sessionId;
  final String userUuid;
  final String status;
  final String? expiresAt;
  final Map<String, dynamic>? userDetail;

  SapLoginResult({
    required this.accessToken,
    required this.refreshToken,
    required this.sessionId,
    required this.userUuid,
    required this.status,
    this.expiresAt,
    this.userDetail,
  });

  factory SapLoginResult.fromJson(Map<String, dynamic> json) {
    return SapLoginResult(
      accessToken: (json['access_token'] ?? '').toString(),
      refreshToken: (json['refresh_token'] ?? '').toString(),
      sessionId: (json['session_id'] ?? '').toString(),
      userUuid: (json['user_uuid'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      expiresAt: json['expires_at']?.toString(),
    );
  }
}

/// Handles SAP authentication flow against ZUI_USER_QR_API endpoint
class SapAuthController {
  final SapODataClient client;
  late final SapEndpoints endpoints;

  SapAuthController(this.client) {
    endpoints = SapEndpoints(client);
  }

  /// Login with Username / Password against SAP ZUI_USER_QR_API/login
  Future<SapLoginResult?> loginWithCredentials(
    String username,
    String password,
  ) async {
    try {
      return await _loginWithCredentials(username, password);
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        throw Exception(
          'SAP từ chối xác thực Basic Auth. Vui lòng kiểm tra '
          'SAP_BASIC_AUTH_USER và SAP_BASIC_AUTH_PASSWORD trong file .env.',
        );
      }
      rethrow;
    }
  }

  Future<SapLoginResult?> _loginWithCredentials(
    String username,
    String password,
  ) async {
    // 1. Fetch fresh CSRF token & cookies from SAP before POST login
    await client.fetchCsrfToken();

    final safeUser = ODataSanitizer.escapeValue(username);
    final safePass = ODataSanitizer.escapeValue(password);

    final response = await client.dio.post(
      'login',
      queryParameters: {
        // SAP OData function-import string parameters include single quotes.
        'Username': "'$safeUser'",
        'password': "'$safePass'",
        'device_id': "'${await DeviceInfoHelper.getDeviceId()}'",
      },
    );

    // 2. Inspect SAP Response Header `sap-message` for SAP error messages
    final sapMessageHeader = response.headers.value('sap-message');
    if (sapMessageHeader != null && sapMessageHeader.isNotEmpty) {
      try {
        final Map<String, dynamic> sapMsg = jsonDecode(sapMessageHeader);
        final severity = (sapMsg['severity'] ?? '').toString().toLowerCase();
        final msgText = (sapMsg['message'] ?? '').toString();

        if (severity == 'error' || msgText.toLowerCase().contains('invalid')) {
          // Clean up SAP message prefix (e.g. "I:ZAUTH:031 Invalid username or password")
          final cleanMsg = msgText.replaceAll(
            RegExp(r'^[A-Z]:[A-Z0-9_]+:\d+\s*'),
            '',
          );
          throw Exception(
            cleanMsg.isNotEmpty
                ? cleanMsg
                : 'Tài khoản hoặc mật khẩu không đúng',
          );
        }
      } catch (e) {
        if (e is Exception) rethrow;
      }
    }

    // 3. Inspect Body Data & validate access_token
    if (response.statusCode == 200 && response.data != null) {
      final d = response.data['d'];
      if (d != null && d['login'] != null) {
        final loginData = d['login'] as Map<String, dynamic>;
        final result = SapLoginResult.fromJson(loginData);

        // Validation: access_token MUST NOT BE EMPTY and status MUST NOT BE 'e'/'E'
        if (result.accessToken.isEmpty ||
            result.status.toLowerCase() == 'e' ||
            result.userUuid == '00000000-0000-0000-0000-000000000000') {
          throw Exception('Tài khoản hoặc mật khẩu không đúng');
        }

        // Fetch full user details if userUuid is provided
        Map<String, dynamic>? detail;
        if (result.userUuid.isNotEmpty) {
          detail = await getUserDetail(
            result.userUuid,
            accessToken: result.accessToken,
          );
        }

        return SapLoginResult(
          accessToken: result.accessToken,
          refreshToken: result.refreshToken,
          sessionId: result.sessionId,
          userUuid: result.userUuid,
          status: result.status,
          expiresAt: result.expiresAt,
          userDetail: detail,
        );
      }
    }

    throw Exception(
      'Đăng nhập thất bại. Không nhận được phản hồi hợp lệ từ SAP.',
    );
  }

  /// Fetch user profile from SAP ZC_USER_QR_API(guid'{UserUuid}')
  Future<Map<String, dynamic>?> getUserDetail(
    String userUuid, {
    String? accessToken,
  }) async {
    try {
      final cleanUuid = ODataSanitizer.sanitizeUuid(userUuid);
      final safeToken = accessToken != null
          ? ODataSanitizer.escapeValue(accessToken)
          : null;
      var path = "ZC_USER_QR_API(guid'$cleanUuid')";
      if (safeToken != null && safeToken.isNotEmpty) {
        path += "?access_token='$safeToken'";
      }

      final response = await client.dio.get(path);
      if (response.statusCode == 200 && response.data != null) {
        final d = response.data['d'];
        if (d != null) {
          return Map<String, dynamic>.from(d as Map);
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Logout action on SAP backend: POST logout?access_token='{access_token}'
  Future<bool> logout(String accessToken) async {
    try {
      await client.fetchCsrfToken();
      final safeToken = ODataSanitizer.escapeValue(accessToken);
      final path = "logout?access_token='$safeToken'";
      final response = await client.dio.post(path);
      client.setAuthToken(null);
      client.resetCsrfSession();
      return response.statusCode == 200;
    } catch (e) {
      client.setAuthToken(null);
      client.resetCsrfSession();
      return false;
    }
  }

  /// Refresh token action on SAP backend
  Future<SapLoginResult?> refreshToken(
    String userUuid,
    String refreshToken,
  ) async {
    try {
      final cleanUuid = ODataSanitizer.sanitizeUuid(userUuid);
      final safeRefreshToken = ODataSanitizer.escapeValue(refreshToken);
      final path =
          "refresh?user_uuid=guid'$cleanUuid'&refresh_token='$safeRefreshToken'";

      final response = await client.dio.post(path);
      if (response.statusCode == 200 && response.data != null) {
        final d = response.data['d'];
        if (d != null && d['refresh'] != null) {
          final result = SapLoginResult.fromJson(d['refresh']);
          return result;
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Change password action on SAP backend
  /// POST changePassword?user_uuid=guid'{user_uuid}'&access_token='{access_token}'&old_password='{old_password}'&new_password='{new_password}'
  Future<bool> changePassword({
    required String userUuid,
    required String accessToken,
    required String oldPassword,
    required String newPassword,
  }) async {
    try {
      await client.fetchCsrfToken();
      final cleanUuid = ODataSanitizer.sanitizeUuid(userUuid);
      final safeToken = ODataSanitizer.escapeValue(accessToken);
      final safeOldPwd = ODataSanitizer.escapeValue(oldPassword);
      final safeNewPwd = ODataSanitizer.escapeValue(newPassword);
      final path =
          "changePassword?user_uuid=guid'$cleanUuid'&access_token='$safeToken'&old_password='$safeOldPwd'&new_password='$safeNewPwd'";

      final response = await client.dio.post(path);

      // Check sap-message header for error
      final sapMessageHeader = response.headers.value('sap-message');
      if (sapMessageHeader != null && sapMessageHeader.isNotEmpty) {
        try {
          final Map<String, dynamic> sapMsg = jsonDecode(sapMessageHeader);
          final severity = (sapMsg['severity'] ?? '').toString().toLowerCase();
          final msgText = (sapMsg['message'] ?? '').toString();

          if (severity == 'error') {
            final cleanMsg = msgText.replaceAll(
              RegExp(r'^[A-Z]:[A-Z0-9_]+:\d+\s*'),
              '',
            );
            throw Exception(
              cleanMsg.isNotEmpty
                  ? cleanMsg
                  : 'Đổi mật khẩu thất bại trên hệ thống SAP',
            );
          }
        } catch (e) {
          if (e is Exception) rethrow;
        }
      }

      return response.statusCode == 200;
    } catch (e) {
      if (e is Exception) rethrow;
      throw Exception('Không thể kết nối đến hệ thống SAP để đổi mật khẩu');
    }
  }
}
