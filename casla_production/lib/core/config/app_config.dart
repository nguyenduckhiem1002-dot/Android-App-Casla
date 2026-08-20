// Core — Environment & SAP API Configuration
// Spec: SAP OData / RAP Integration Setup

class AppConfig {
  /// Tên ứng dụng hiển thị
  static const String _appName = String.fromEnvironment(
    'APP_NAME',
    defaultValue: 'Casla Group',
  );
  static String get appName => _normalizeEnvValue(_appName);

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
