// Core — Environment & SAP API Configuration
// Spec: SAP OData / RAP Integration Setup

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;

enum SapTransportAuthMode { basic, gateway }

class AppConfig {
  /// Only the explicitly selected test flavors, dev and staging (the QAS
  /// build), may embed the shared transport credential: it only opens the
  /// OData service, every business call still carries the session's own
  /// AccessToken. Production and unknown release builds remain gateway-only.
  static const bool requiresGateway =
      kReleaseMode && appFlavor != 'dev' && appFlavor != 'staging';

  /// Tra cứu theo ca: nút "Ca tra cứu" ở Lịch sử và ô chọn ca trong bộ lọc
  /// Tổng quan. Tạm ẩn từ 2026-10-27 vì nhà máy hiện chỉ có một ca; bật lại
  /// khi có thêm ca. Khi ẩn, bộ lọc ca mặc định vẫn giữ nguyên như trước (ca
  /// đang làm việc ở Tổng quan, tất cả ca ở Lịch sử), nên số liệu không đổi.
  static const bool showShiftLookup = false;
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0',
  );

  /// Tên ứng dụng hiển thị
  static const String _appName = String.fromEnvironment(
    'APP_NAME',
    defaultValue: 'Casla Group',
  );
  static String get appName => _normalizeEnvValue(_appName);

  /// `https://<tenant>.s4hana.cloud.sap/sap/opu/odata4/sap/` — the shared
  /// root every OData V4 service on this tenant is published under. In gateway
  /// mode this may instead be the gateway origin, provided it preserves these
  /// service paths when proxying to SAP.
  static const String _sapBaseUrl = String.fromEnvironment('SAP_BASE_URL');
  static String get sapBaseUrl => _normalizeEnvValue(_sapBaseUrl);

  /// Service-binding suffixes, as actually published on the target tenant —
  /// confirmed against the real service, not derived from the ABAP service
  /// definition name (the binding technical name is assigned separately and
  /// isn't guessable from it: `ZUI_MOB_AUTH`'s binding is `ZAPI_MOB_AUTH`, not
  /// `ZUI_MOB_AUTH_O4`). Republishing under a different binding means editing
  /// these two constants.
  @visibleForTesting
  static const String authServiceSuffix =
      'zapi_mob_auth/srvd_a2x/sap/zui_mob_auth/0001/';
  @visibleForTesting
  static const String ppOpAllocServiceSuffix =
      'zapi_pp_opalloc/srvd_a2x/sap/zui_pp_opalloc/0001/';

  /// ZUI_PP_SHIFT_API is exposed under the same tenant root as the other
  /// mobile OData services. Configure SAP_BASE_URL once for all of them.
  @visibleForTesting
  static const String shiftApiServiceSuffix =
      'zapi_pp_shift/srvd_a2x/sap/zui_pp_shift_api/0001/';

  /// ZUI_PP_POS (binding ZAPI_PP_POS): worker position board and the three
  /// position commands. Kept apart from ZUI_PP_OPALLOC on the backend.
  @visibleForTesting
  static const String positionServiceSuffix =
      'zapi_pp_pos/srvd_a2x/sap/zui_pp_pos/0001/';

  /// Full service root for `ZUI_MOB_AUTH` (login/refresh/logout/changePassword).
  static String get sapAuthServiceUrl =>
      joinServiceUrl(sapBaseUrl, authServiceSuffix);

  /// Full service root for `ZUI_PP_OPALLOC` (submitInitialAssign/
  /// submitConfirm/submitRecall/submitReverse/getSyncStatus/getWorkHistory).
  static String get sapPpOpAllocServiceUrl =>
      joinServiceUrl(sapBaseUrl, ppOpAllocServiceSuffix);

  static String get sapShiftApiServiceUrl =>
      joinServiceUrl(sapBaseUrl, shiftApiServiceSuffix);

  /// Full service root for `ZUI_PP_POS` (getPositionBoard/submitPositionCreate/
  /// submitMachineChange/submitPositionTransfer).
  static String get sapPositionServiceUrl =>
      joinServiceUrl(sapBaseUrl, positionServiceSuffix);

  /// Joins [sapBaseUrl] with a service-binding suffix. A blank [base] means
  /// SAP_BASE_URL was never configured — stays blank rather than becoming a
  /// bare `/suffix` path that would resolve against whatever host Dio
  /// defaults to.
  @visibleForTesting
  static String joinServiceUrl(String base, String suffix) {
    if (base.isEmpty) return '';
    final withSlash = base.endsWith('/') ? base : '$base/';
    return '$withSlash$suffix';
  }

  /// Transport authentication between the mobile client and its HTTP origin.
  ///
  /// `basic` exists only for direct SAP development/staging compatibility.
  /// Production releases must use `gateway`: the gateway owns the upstream SAP
  /// service credential and the mobile binary contains no shared Basic secret.
  static const String _sapTransportAuthMode = String.fromEnvironment(
    'SAP_TRANSPORT_AUTH_MODE',
    defaultValue: 'basic',
  );
  static SapTransportAuthMode get sapTransportAuthMode =>
      parseSapTransportAuthMode(_sapTransportAuthMode);

  @visibleForTesting
  static SapTransportAuthMode parseSapTransportAuthMode(String value) {
    switch (_normalizeEnvValue(value).toLowerCase()) {
      case '':
      case 'basic':
        return SapTransportAuthMode.basic;
      case 'gateway':
        return SapTransportAuthMode.gateway;
      default:
        throw FormatException(
          'SAP_TRANSPORT_AUTH_MODE must be either basic or gateway.',
          value,
        );
    }
  }

  /// Reuse the CSRF token of a transport session instead of downloading
  /// `$metadata` before every POST (2026-11-16). This is the rollback switch:
  /// build with `SAP_REUSE_CSRF_TOKEN=false` to fetch a token per request
  /// again, exactly as before.
  static const bool sapReuseCsrfToken = bool.fromEnvironment(
    'SAP_REUSE_CSRF_TOKEN',
    defaultValue: true,
  );

  /// Development/staging direct-SAP Basic Authentication User.
  ///
  /// The gateway-only release branch of this const expression is always empty.
  /// That means even a mistakenly supplied `--dart-define=SAP_BASIC_AUTH_USER`
  /// is not selected into the release program constant.
  static const String _sapBasicAuthUser = requiresGateway
      ? ''
      : String.fromEnvironment('SAP_BASIC_AUTH_USER');
  static String get sapBasicAuthUser => _normalizeEnvValue(_sapBasicAuthUser);

  /// Development/staging direct-SAP Basic Authentication Password.
  /// See [_sapBasicAuthUser] for why the release program selects `''` here.
  static const String _sapBasicAuthPassword = requiresGateway
      ? ''
      : String.fromEnvironment('SAP_BASIC_AUTH_PASSWORD');
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
