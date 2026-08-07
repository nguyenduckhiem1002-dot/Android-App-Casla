// Core — Environment & SAP API Configuration
// Spec: SAP OData / RAP Integration Setup

class AppConfig {
  /// SAP OData ZUI_USER_QR_API Base URL
  static String sapBaseUrl =
      'https://my426501-api.s4hana.cloud.sap/sap/opu/odata/sap/ZUI_USER_QR_API/';

  /// SAP Basic Authentication User
  static String sapBasicAuthUser = 'PB9_LO';

  /// SAP Basic Authentication Password
  static String sapBasicAuthPassword =
      'MF@\$/qa%[\$PX(dA4%8alj<iS#C&lCXY>59(z9NDC';

  /// Default Device Identifier
  static String deviceId = 'PDA-CT02-A17';

  /// Enable SAP Backend Integration (falls back to local DB if offline/unreachable)
  static bool enableSapIntegration = true;
}
