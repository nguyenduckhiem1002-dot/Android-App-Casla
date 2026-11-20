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
import '../../core/auth/session_refresh.dart';

/// `com.sap.gateway.srvd_a2x.zui_mob_auth.v0001` — from the published EDMX.
/// If the tenant republishes this service under a different binding, this
/// must be updated to match; there is no way to discover it at runtime
/// without fetching and parsing `$metadata`.
const String _kNamespace = 'com.sap.gateway.srvd_a2x.zui_mob_auth.v0001';
const String _kEntitySet = 'MobileAuthentication';

/// `refresh` only: a temporary technical failure, not a refusal. Contract in
/// the backend's `docs/MOBILE_ERROR_MAPPING.md`.
const String _kRefreshUnavailableCode = 'AUTH_REFRESH_UNAVAILABLE';

const Map<String, String> _authBusinessMessages = {
  'AUTH_FAILED': 'Không thể xác thực yêu cầu. Vui lòng đăng nhập lại.',
  'EMPTY_TOKEN': 'Phiên đăng nhập không hợp lệ. Vui lòng đăng nhập lại.',
  'TOKEN_INVALID_OR_EXPIRED':
      'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.',
  'DEVICE_MISMATCH':
      'Token không thuộc thiết bị này. Vui lòng đăng nhập lại trên thiết bị này.',
  'PASSWORD_CHANGE_REQUIRED': 'Tài khoản cần đổi mật khẩu trước khi tiếp tục.',
  'USER_INACTIVE': 'Tài khoản đã bị vô hiệu hoá trên SAP.',
  'WORKER_AUTH_FAILED': 'Mật khẩu xác nhận của công nhân không đúng.',
  'WORKER_NO_ACCOUNT': 'Công nhân chưa có tài khoản.',
  'WORKER_IS_INACTIVE': 'Tài khoản công nhân đã vô hiệu hóa.',
};

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
/// `PlantName` is optional for compatibility with older login responses.
class SapWorkContext {
  final String workId;
  final String workName;
  final String plant;
  final String plantName;
  final String workCenter;
  final String workCenterName;
  final String boPhan;
  final String location;

  const SapWorkContext({
    required this.workId,
    required this.workName,
    required this.plant,
    this.plantName = '',
    required this.workCenter,
    this.workCenterName = '',
    required this.boPhan,
    required this.location,
  });

  factory SapWorkContext.fromJson(Map<String, dynamic> json) => SapWorkContext(
    workId: (json['WorkID'] ?? '').toString(),
    workName: (json['WorkName'] ?? '').toString(),
    plant: (json['Plant'] ?? '').toString(),
    plantName:
        (json['PlantName'] ??
                json['plantName'] ??
                json['Plant Name'] ??
                json['Plant_Name'] ??
                '')
            .toString(),
    workCenter: (json['WorkCenter'] ?? '').toString(),
    workCenterName: (json['WorkCenterName'] ?? json['WorkCenterText'] ?? '')
        .toString(),
    boPhan: (json['BoPhan'] ?? '').toString(),
    location: (json['Location'] ?? '').toString(),
  );
}

/// `ZA_MOB_LoginResult` — the body of a successful `login`/`refresh` call.
///
/// `status` here is the *account* status the backend chose to reveal to an
/// unauthenticated caller: `'F'` covers wrong password AND inactive account,
/// deliberately collapsed into one outcome so a failed login cannot be used to
/// enumerate which of those is true. `'L'` means the account is temporarily
/// locked after too many consecutive failures (backend rule: 5 wrong passwords
/// within 1 minute lock the account for 10 minutes) — a correct password is
/// still refused until the lock expires, so the user must be told to wait
/// rather than retype. `'A'`/`'P'` both mean the credentials were correct;
/// `'P'` additionally requires a password change before anything else.
/// HTTP-level failure (a thrown [DioException]) means something else entirely
/// — a malformed request or a dead refresh token — not a wrong password.
class SapLoginResult {
  final String userUuid;
  final String sessionId;
  final String accessToken;
  final String refreshToken;
  final DateTime? expiresAt;
  final String status;
  final bool passwordChangeRequired;
  final String fullName;
  final String email;
  final String workerId;
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
    this.fullName = '',
    this.email = '',
    this.workerId = '',
    required this.permissions,
    required this.workContexts,
  });

  bool get isSuccess => status == 'A' || status == 'P';

  /// Backend refused the login because the account is temporarily locked
  /// after repeated wrong passwords. Distinct from [isSuccess] == false with
  /// `'F'`: retyping the password will not help until the lock expires.
  bool get isLocked => status == 'L';

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
      fullName: (json['FullName'] ?? '').toString(),
      email: (json['Email'] ?? '').toString(),
      workerId: (json['WorkerID'] ?? '').toString(),
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
  /// Returns a result with `status == 'F'` for any wrong-credentials/inactive
  /// case and `'L'` for a temporarily locked account — check
  /// [SapLoginResult.isSuccess] / [SapLoginResult.isLocked], don't assume a
  /// returned result means success. Throws only on a genuine transport/server
  /// failure.
  Future<SapLoginResult> login({
    required String username,
    required String password,
    required String deviceId,
  }) async {
    await client.requireCsrfToken();
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
  /// returned result must replace whatever was stored, not be discarded. The
  /// token this call used stays acceptable for 15 minutes only (backend grace
  /// since 2026-11-16, for a refresh whose answer never arrived); anything
  /// older is refused.
  ///
  /// SAP answers a failed refresh with one of two codes: a refusal
  /// (`TOKEN_INVALID_OR_EXPIRED`, the session is over) or
  /// [_kRefreshUnavailableCode] (nothing changed on SAP, keep the session and
  /// try again later).
  Future<SapLoginResult> refresh({
    required String refreshToken,
    required String deviceId,
  }) async {
    await client.requireCsrfToken();
    try {
      final response = await client.dio.post(
        _actionPath('refresh').toString(),
        data: {'RefreshToken': refreshToken, 'DeviceID': deviceId},
      );
      return SapLoginResult.fromJson(odataActionResult(response));
    } on DioException catch (error) {
      // Only an answer from the RAP handler itself (an OData error envelope
      // on a 4xx) means the refresh token was refused. A timeout, a dropped
      // connection, a 5xx or a proxy page says nothing about the session.
      final status = error.response?.statusCode ?? 0;
      final business = odataErrorMessage(error);
      // The handler's own "could not do it right now" (a lock held by a
      // parallel refresh, a hashing or UUID failure) leaves the session on
      // SAP untouched, so it must not end the session here either.
      if (odataSafeDiagnostic(error) == _kRefreshUnavailableCode) {
        throw const SessionRefreshUnavailableException(
          'Chưa làm mới được phiên SAP. Sẽ tự động thử lại.',
        );
      }
      if (status >= 400 && status < 500 && business != null) {
        throw SessionRefreshRejectedException(
          code: odataSafeDiagnostic(error) ?? 'TOKEN_INVALID_OR_EXPIRED',
          message: _friendlyMessage(
            error,
            fallback: 'Phiên đăng nhập đã hết hạn.',
          ),
        );
      }
      throw SessionRefreshUnavailableException(
        'Chưa làm mới được phiên SAP (${error.type.name}).',
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
      await client.requireCsrfToken();
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
    await client.requireCsrfToken();
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
      // The handler answers an invalid token with the validator's bare code
      // (before 2026-11-16: "Token không hợp lệ: TOKEN_INVALID_OR_EXPIRED",
      // which `contains` still covers). An expired access token is
      // recoverable with a refresh, so it gets its own type instead of a
      // message telling the user to log in again.
      final raw = odataErrorMessage(error) ?? '';
      if (raw.contains('TOKEN_INVALID_OR_EXPIRED')) {
        throw AccessTokenExpiredException(
          _authBusinessMessages['TOKEN_INVALID_OR_EXPIRED']!,
        );
      }
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
    // Known machine codes get their Vietnamese message; anything else is
    // already short, human-readable Vietnamese text set by the ABAP handler
    // (e.g. 'Mật khẩu hiện tại không đúng') and is shown as it is.
    return _authBusinessMessages[code] ?? code;
  }
}
