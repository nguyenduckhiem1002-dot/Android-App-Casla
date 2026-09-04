// Core — Environment & SAP API Configuration
// Spec: SAP OData / RAP Integration Setup

class AppConfig {
  /// Tên ứng dụng hiển thị
  static const String _appName = String.fromEnvironment(
    'APP_NAME',
    defaultValue: 'Casla Group',
  );
  static String get appName => _normalizeEnvValue(_appName);

  /// Legacy OData V2 base URL (`ZUI_USER_QR_API`).
  ///
  /// That service does not exist in the real backend — the actual mobile
  /// surface is the two RAP OData V4 services below (`ZUI_MOB_AUTH`,
  /// `ZUI_PP_OPALLOC`). Kept only so existing config/tests that read it don't
  /// break; nothing in the app calls it anymore.
  @Deprecated('Use sapAuthServiceUrl / sapPpOpAllocServiceUrl instead.')
  static const String _sapBaseUrl = String.fromEnvironment('SAP_BASE_URL');
  @Deprecated('Use sapAuthServiceUrl / sapPpOpAllocServiceUrl instead.')
  static String get sapBaseUrl => _normalizeEnvValue(_sapBaseUrl);

  /// Full service root for `ZUI_MOB_AUTH` (login/refresh/logout/changePassword).
  ///
  /// ABAP Cloud OData V4 service roots typically look like
  /// `/sap/opu/odata4/sap/<binding>/srvd_a2x/sap/<service_definition>/0001/`,
  /// but the exact binding name is assigned when the service is published on
  /// the target tenant and isn't fixed by the service definition alone — copy
  /// it from the tenant's Communication Arrangement / Service Binding, not
  /// from this default.
  static const String _sapAuthServiceUrl = String.fromEnvironment(
    'SAP_AUTH_SERVICE_URL',
  );
  static String get sapAuthServiceUrl => _normalizeEnvValue(_sapAuthServiceUrl);

  /// Full service root for `ZUI_PP_OPALLOC` (submitInitialAssign/
  /// submitConfirm/submitRecall/submitReverse/getSyncStatus/getWorkHistory).
  /// See [sapAuthServiceUrl] for the URL-shape caveat.
  static const String _sapPpOpAllocServiceUrl = String.fromEnvironment(
    'SAP_PP_OPALLOC_SERVICE_URL',
  );
  static String get sapPpOpAllocServiceUrl =>
      _normalizeEnvValue(_sapPpOpAllocServiceUrl);

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
