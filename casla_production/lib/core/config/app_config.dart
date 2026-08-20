// Core — Environment & SAP API Configuration
// Spec: SAP OData / RAP Integration Setup

import 'package:flutter/foundation.dart';

class AppConfig {
  /// Tên ứng dụng hiển thị
  static const String _appName = String.fromEnvironment(
    'APP_NAME',
    defaultValue: 'Casla Group',
  );
  static String get appName => _normalizeEnvValue(_appName);

  /// Tiêu đề đầy đủ ứng dụng
  static String get appTitle => '$appName — Quản lý sản lượng';

  /// Đơn vị sở hữu
  static const String companyName = 'Casla Group';

  /// Đường dẫn logo SVG trắng của ứng dụng
  static const String logoSvgPath = 'assets/images/logo_white.svg';

  /// SAP OData ZUI_USER_QR_API Base URL
  static const String _sapBaseUrl = String.fromEnvironment('SAP_BASE_URL');
  static String get sapBaseUrl => _normalizeEnvValue(_sapBaseUrl);

  /// SAP Basic Authentication User
  static const String _sapBasicAuthUser = String.fromEnvironment(
    'SAP_BASIC_AUTH_USER',
  );
  static String get sapBasicAuthUser => _normalizeEnvValue(_sapBasicAuthUser);

  /// SAP Basic Authentication Password
  static const String _sapBasicAuthPassword = String.fromEnvironment(
    'SAP_BASIC_AUTH_PASSWORD',
  );
  static String get sapBasicAuthPassword =>
      _normalizeEnvValue(_sapBasicAuthPassword);

  /// Enable SAP Backend Integration (falls back to local DB if offline/unreachable)
  static const bool _sapIntegrationRequested = bool.fromEnvironment(
    'ENABLE_SAP_INTEGRATION',
  );

  static bool? _sapIntegrationOverride;

  /// Read-only: derived from build-time configuration, not settable at runtime.
  ///
  /// NOTE: nothing in `lib/` reads this yet — the sync engine that would consume
  /// it does not exist. See the SAP phase of the remediation plan.
  static bool get enableSapIntegration =>
      _sapIntegrationOverride ??
      (_sapIntegrationRequested &&
          sapBaseUrl.isNotEmpty &&
          sapBasicAuthUser.isNotEmpty &&
          sapBasicAuthPassword.isNotEmpty);

  @visibleForTesting
  static void debugOverrideSapIntegration(bool value) =>
      _sapIntegrationOverride = value;

  @visibleForTesting
  static void debugClearSapIntegrationOverride() =>
      _sapIntegrationOverride = null;

  static String _normalizeEnvValue(String value) {
    var normalized = value.trim();
    if (normalized.length >= 2) {
      final first = normalized[0];
      final last = normalized[normalized.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        normalized = normalized.substring(1, normalized.length - 1);
      }
    }

    // Supports values copied from the previous JSON configuration.
    return normalized.replaceAll(r'\$', r'$');
  }
}
