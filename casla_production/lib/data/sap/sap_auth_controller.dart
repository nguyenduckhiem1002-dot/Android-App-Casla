// SAP Integration — Auth Controller
// Spec: Section 4.1 (Login flow), Section 10 (Security)
// SAP Service: ZUI_MOB_AUTH (RAP OData V4, entity set `MobileAuthentication`)
//
// Every action here is a *collection-bound* OData V4 action — the URL is
// `<serviceRoot>MobileAuthentication/<namespace>.<action>`, and the JSON body
// carries only the action's own parameters (never the binding parameter).
// This service has no `$metadata`-derived client in this app, so the
// namespace below is copied verbatim from the published EDMX rather than
// derived — SAP's technical namespace for a service is not guessable from the
// ABAP service definition name alone.

import 'package:dio/dio.dart';

import 'odata_error.dart';
import 'sap_odata_client.dart';

/// `com.sap.gateway.srvd_a2x.zui_mob_auth.v0001` — from the published EDMX.
/// If the tenant republishes this service under a different binding, this
/// must be updated to match; there is no way to discover it at runtime
/// without fetching and parsing `$metadata`.
const String _kNamespace = 'com.sap.gateway.srvd_a2x.zui_mob_auth.v0001';
const String _kEntitySet = 'MobileAuthentication';

/// One `ZA_MOB_Permission` row from a login/refresh result.
///
/// `FuncID` is a display hint only — the spec is explicit that every
/// protected action re-validates the function server-side and never trusts
/// this list as authorization.
class SapPermission {
  final String funcId;
  final String funcName;
  final String appModule;

  const SapPermission({
    required this.funcId,
    required this.funcName,
    required this.appModule,
  });

  factory SapPermission.fromJson(Map<String, dynamic> json) => SapPermission(
    funcId: (json['FuncID'] ?? '').toString(),
    funcName: (json['FuncName'] ?? '').toString(),
    appModule: (json['AppModule'] ?? '').toString(),
  );
}

/// One `ZA_MOB_WorkContext` row — a Plant + WorkCenter the account may act in.
class SapWorkContext {
  final String workId;
  final String workName;
  final String plant;
  final String workCenter;
  final String boPhan;
  final String location;

  const SapWorkContext({
    required this.workId,
    required this.workName,
    required this.plant,
    required this.workCenter,
    required this.boPhan,
    required this.location,
  });

  factory SapWorkContext.fromJson(Map<String, dynamic> json) => SapWorkContext(
    workId: (json['WorkID'] ?? '').toString(),
    workName: (json['WorkName'] ?? '').toString(),
    plant: (json['Plant'] ?? '').toString(),
    workCenter: (json['WorkCenter'] ?? '').toString(),
    boPhan: (json['BoPhan'] ?? '').toString(),
    location: (json['Location'] ?? '').toString(),
  );
}

/// `ZA_MOB_LoginResult` — the body of a successful `login`/`refresh` call.
///
/// `status` here is the *account* status the backend chose to reveal to an
/// unauthenticated caller: `'F'` covers wrong password, inactive account, AND
/// a lockout, deliberately collapsed into one outcome so a failed login
/// cannot be used to enumerate which of those is true. `'A'`/`'P'` both mean
/// the credentials were correct; `'P'` additionally requires a password change
/// before anything else. HTTP-level failure (a thrown [DioException]) means
/// something else entirely — a malformed request or a dead refresh token —
/// not a wrong password.
class SapLoginResult {
  final String userUuid;
  final String sessionId;
  final String accessToken;
  final String refreshToken;
  final DateTime? expiresAt;
  final String status;
  final bool passwordChangeRequired;
  final List<SapPermission> permissions;
  final List<SapWorkContext> workContexts;

  const SapLoginResult({
    required this.userUuid,
    required this.sessionId,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.status,
    required this.passwordChangeRequired,
    required this.permissions,
    required this.workContexts,
  });

  bool get isSuccess => status == 'A' || status == 'P';

  factory SapLoginResult.fromJson(Map<String, dynamic> json) {
    final permissionRows = (json['_Permissions'] as List? ?? const [])
        .map((p) => SapPermission.fromJson(Map<String, dynamic>.from(p as Map)))
        .toList();
    final workContextRows = (json['_WorkContexts'] as List? ?? const [])
        .map(
          (w) => SapWorkContext.fromJson(Map<String, dynamic>.from(w as Map)),
        )
        .toList();

    return SapLoginResult(
      userUuid: (json['UserUUID'] ?? '').toString(),
      sessionId: (json['SessionID'] ?? '').toString(),
      accessToken: (json['AccessToken'] ?? '').toString(),
      refreshToken: (json['RefreshToken'] ?? '').toString(),
      expiresAt: DateTime.tryParse((json['ExpiresAt'] ?? '').toString()),
      status: (json['Status'] ?? '').toString(),
      passwordChangeRequired: json['PasswordChangeRequired'] == true,
      permissions: permissionRows,
      workContexts: workContextRows,
    );
  }
}

/// Handles SAP authentication against `ZUI_MOB_AUTH`.
class SapAuthController {
  final SapODataClient client;

  SapAuthController(this.client);

  Uri _actionPath(String action) =>
      Uri.parse('$_kEntitySet/$_kNamespace.$action');

  /// `login(Username, Password, DeviceID)`.
  ///
  /// Returns a result with `status == 'F'` for any wrong-credentials/inactive/
  /// locked case — check [SapLoginResult.isSuccess], don't assume a returned
  /// result means success. Throws only on a genuine transport/server failure.
  Future<SapLoginResult> login({
    required String username,
    required String password,
    required String deviceId,
  }) async {
    await client.fetchCsrfToken();
    try {
      final response = await client.dio.post(
        _actionPath('login').toString(),
        data: {
          'Username': username,
          'Password': password,
          'DeviceID': deviceId,
        },
      );
      return SapLoginResult.fromJson(odataActionResult(response));
    } on DioException catch (error) {
      throw Exception(
        _friendlyMessage(error, fallback: 'Không thể đăng nhập.'),
      );
    }
  }

  /// `refresh(RefreshToken, DeviceID)`.
  ///
  /// The backend rotates the refresh token on every call — the token in the
  /// returned result must replace whatever was stored, not be discarded; the
  /// old one is single-use and this call already consumed it.
  Future<SapLoginResult> refresh({
    required String refreshToken,
    required String deviceId,
  }) async {
    await client.fetchCsrfToken();
    try {
      final response = await client.dio.post(
        _actionPath('refresh').toString(),
        data: {'RefreshToken': refreshToken, 'DeviceID': deviceId},
      );
      return SapLoginResult.fromJson(odataActionResult(response));
    } on DioException catch (error) {
      throw Exception(
        _friendlyMessage(error, fallback: 'Phiên đăng nhập đã hết hạn.'),
      );
    }
  }

  /// Best-effort profile lookup: `GET MobileAuthentication(<UserUUID>)`.
  ///
  /// `ZA_MOB_LoginResult` (the `login`/`refresh` return type) carries the
  /// session, not the profile — no `FullName`/`Email`/`WorkerID`. Those live on
  /// the entity itself, which is a plain GET, not a bound action, so it isn't
  /// guarded by the same token/session/device check every mutation goes
  /// through; it relies on the service's own inbound authentication. Returns
  /// null on any failure so a login never fails just because this lookup did
  /// — every field it fills in is display-only.
  Future<Map<String, dynamic>?> getUserDetail(String userUuid) async {
    if (userUuid.isEmpty) return null;
    try {
      final response = await client.dio.get('$_kEntitySet($userUuid)');
      return odataActionResult(response);
    } catch (_) {
      return null;
    }
  }

  /// `logout(AccessToken, DeviceID)`. Best-effort: the local session is torn
  /// down by the caller regardless of whether this succeeds.
  Future<void> logout({
    required String accessToken,
    required String deviceId,
  }) async {
    try {
      await client.fetchCsrfToken();
      await client.dio.post(
        _actionPath('logout').toString(),
        data: {'AccessToken': accessToken, 'DeviceID': deviceId},
      );
    } catch (_) {
      // Local logout must proceed even if SAP is unreachable — see
      // SessionManager, which already treats this as best-effort.
    } finally {
      client.resetCsrfSession();
    }
  }

  /// `changePassword(AccessToken, CurrentPassword, NewPassword, DeviceID)`.
  Future<void> changePassword({
    required String accessToken,
    required String currentPassword,
    required String newPassword,
    required String deviceId,
  }) async {
    await client.fetchCsrfToken();
    try {
      await client.dio.post(
        _actionPath('changePassword').toString(),
        data: {
          'AccessToken': accessToken,
          'CurrentPassword': currentPassword,
          'NewPassword': newPassword,
          'DeviceID': deviceId,
        },
      );
    } on DioException catch (error) {
      throw Exception(
        _friendlyMessage(error, fallback: 'Đổi mật khẩu thất bại.'),
      );
    }
  }

  static String _friendlyMessage(
    DioException error, {
    required String fallback,
  }) {
    final code = odataErrorMessage(error);
    if (code == null || code.isEmpty) return fallback;
    // These codes are already short, human-readable Vietnamese text set by the
    // ABAP handler (e.g. 'Refresh token không hợp lệ hoặc hết hạn') — unlike
    // ZUI_PP_OPALLOC's machine codes, there is nothing to translate here.
    return code;
  }
}
